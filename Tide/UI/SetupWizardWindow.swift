import SwiftUI
import AppKit

struct SetupWizardWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step: Step = .credentials
    @State private var accessKeyId: String = ""
    @State private var secretAccessKey: String = ""
    @State private var bucket: String = ""
    @State private var region: String = "ap-northeast-1"
    @State private var syncRootPath: String = ""
    @State private var bucketSetupLog: [String] = []
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var pendingCreateBucket: Bool = false

    enum Step: Int, CaseIterable {
        case credentials = 0
        case bucket = 1
        case provisioning = 2
        case folder = 3
        case done = 4

        var title: String {
            switch self {
            case .credentials: return String(localized: "AWS Credentials")
            case .bucket:      return String(localized: "Bucket")
            case .provisioning:return String(localized: "Provisioning")
            case .folder:      return String(localized: "Sync Folder")
            case .done:        return String(localized: "Ready")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tide setup — \(step.title)")
                .font(.title2.bold())

            ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                .progressViewStyle(.linear)

            Group {
                switch step {
                case .credentials: credentialsView
                case .bucket:      bucketView
                case .provisioning:provisioningView
                case .folder:      folderView
                case .done:        doneView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()

            HStack {
                if step != .credentials && step != .done {
                    Button("Back") { goBack() }
                        .disabled(isWorking)
                }
                Spacer()
                if step == .done {
                    Button("Finish") {
                        dismissWindow(id: "setup")
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(nextButtonLabel) { Task { await onNext() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdvance || isWorking)
                }
            }
        }
        .padding(20)
        .alert("Bucket not found", isPresented: $pendingCreateBucket) {
            Button("Cancel", role: .cancel) {
                step = .bucket
            }
            Button("Create new bucket") {
                Task { await runCreateBucketAndProvision() }
            }
        } message: {
            Text("Bucket \(bucket) does not exist. Create it in region \(region)?")
        }
    }

    private var nextButtonLabel: String {
        switch step {
        case .credentials: return String(localized: "Next")
        case .bucket:      return String(localized: "Test & Provision")
        case .provisioning:return String(localized: "Continue")
        case .folder:      return String(localized: "Start syncing")
        case .done:        return String(localized: "Finish")
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .credentials:
            return !accessKeyId.isEmpty && !secretAccessKey.isEmpty
        case .bucket:
            return !bucket.isEmpty && !region.isEmpty
        case .provisioning:
            return !isWorking
        case .folder:
            return !syncRootPath.isEmpty
        case .done:
            return true
        }
    }

    // MARK: - Steps

    private var credentialsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste an IAM access key pair with permission to read/write your Tide bucket.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Access Key ID", text: $accessKeyId)
                .textFieldStyle(.roundedBorder)
            SecureField("Secret Access Key", text: $secretAccessKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var bucketView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Specify a bucket and its region. If the bucket doesn't exist, Tide will offer to create it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Bucket name", text: $bucket)
                .textFieldStyle(.roundedBorder)
            Picker("Region", selection: $region) {
                ForEach(KnownRegions.all) { r in
                    Text("\(r.displayName) — \(r.code)").tag(r.code)
                }
            }
            Text("On Next: HeadBucket → (create if missing) → enable versioning if needed → install lifecycle rules.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var provisioningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(bucketSetupLog.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.body, design: .monospaced))
            }
            if isWorking {
                ProgressView()
            }
        }
    }

    private var folderView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose the local folder to sync into the bucket. `.git/` and other hidden files will be included.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Folder path", text: $syncRootPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseFolder() }
            }
            if !syncRootPath.isEmpty {
                let warn = validateSyncRoot(syncRootPath)
                if let warn {
                    Text(warn)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup complete. Tide will sync your folder with S3 (uploads and downloads).")
                .font(.callout)
            Text("If this bucket already has data from another Mac, those files will be downloaded on the first scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("• Bucket: \(bucket)")
            Text("• Region: \(region)")
            Text("• Folder: \(syncRootPath)")
            Text("• Device ID: \(env.config.deviceId)").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func goBack() {
        errorMessage = nil
        step = Step(rawValue: step.rawValue - 1) ?? .credentials
    }

    private func onNext() async {
        errorMessage = nil
        switch step {
        case .credentials:
            step = .bucket
        case .bucket:
            await runProvisioning()
        case .provisioning:
            step = .folder
        case .folder:
            await runStartSyncing()
        case .done:
            dismissWindow(id: "setup")
        }
    }

    private func runProvisioning() async {
        isWorking = true
        bucketSetupLog = []
        step = .provisioning
        defer { isWorking = false }

        guard let probe = makeProbeClient() else { return }

        do {
            try await probe.headBucket()
            bucketSetupLog.append(String(localized: "✓ HeadBucket: reachable"))
        } catch {
            if S3ErrorClassifier.isNotFound(error) {
                pendingCreateBucket = true
                return  // alert で続行を委ねる
            }
            let reason: String
            if S3ErrorClassifier.isForbidden(error) {
                reason = String(localized: "Bucket exists but you do not have access. Check credentials.")
            } else {
                reason = String(describing: error)
            }
            errorMessage = String(localized: "Provisioning failed: \(reason)")
            step = .bucket
            return
        }

        await finishProvisioning(probe: probe)
    }

    /// 「作成する」アラートが押されたあとに呼ばれる: バケット作成 → 既存パスへ合流。
    private func runCreateBucketAndProvision() async {
        isWorking = true
        defer { isWorking = false }
        guard let probe = makeProbeClient() else { return }

        do {
            try await probe.createBucket()
            bucketSetupLog.append(String(localized: "✓ Bucket created"))
        } catch {
            let detail = String(describing: error)
            errorMessage = String(localized: "Failed to create bucket: \(detail)")
            step = .bucket
            return
        }
        await finishProvisioning(probe: probe)
    }

    /// HeadBucket / CreateBucket 後の共通処理（バージョニング + ライフサイクル）。
    private func finishProvisioning(probe: TideS3Client) async {
        do {
            let alreadyEnabled = try await probe.isVersioningEnabled()
            if !alreadyEnabled {
                try await probe.enableVersioning()
            }
            bucketSetupLog.append(alreadyEnabled
                ? String(localized: "✓ Versioning was already enabled")
                : String(localized: "✓ Versioning enabled"))

            let lifecycle = try await probe.ensureLifecycleRules()
            bucketSetupLog.append(lifecycle == .alreadyConfigured
                ? String(localized: "✓ Lifecycle rules already configured")
                : String(localized: "✓ Lifecycle rules updated"))

            // Block Public Access の 4 つの設定を強制
            try await probe.enforcePublicAccessBlock()
            bucketSetupLog.append(String(localized: "✓ Public access block enforced"))

            bucketSetupLog.append(String(localized: "✓ Provisioning complete"))
        } catch {
            let detail = String(describing: error)
            errorMessage = String(localized: "Provisioning failed: \(detail)")
            step = .bucket
        }
    }

    private func makeProbeClient() -> TideS3Client? {
        let creds = AWSCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey)
        do {
            return try TideS3Client(
                credentials: creds,
                region: region,
                bucket: bucket,
                deviceId: env.config.deviceId
            )
        } catch {
            let detail = String(describing: error)
            errorMessage = String(localized: "Provisioning failed: \(detail)")
            step = .bucket
            return nil
        }
    }

    private func runStartSyncing() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let creds = AWSCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey)
            try await env.completeSetup(
                credentials: creds,
                bucket: bucket,
                region: region,
                syncRootPath: syncRootPath
            )
            // L7: 成功したらメモリ上の鍵をすぐ手放す（参照を切る。ヒープ上のバイトは GC 任せ）
            accessKeyId = ""
            secretAccessKey = ""
            step = .done
        } catch {
            let detail = String(describing: error)
            errorMessage = String(localized: "Failed to start sync engine: \(detail)")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose a sync folder")
        if panel.runModal() == .OK, let url = panel.url {
            syncRootPath = url.path
        }
    }

    private func validateSyncRoot(_ path: String) -> String? {
        let lower = path.lowercased()
        if lower.contains("/library/mobile documents") || lower.contains("/icloud") {
            return String(localized: "⚠️ iCloud Drive paths can cause sync conflicts; please choose another folder.")
        }
        // ホームディレクトリ直下 / Library / システム領域は危険な選択肢
        let home = NSHomeDirectory()
        let normalized = (path as NSString).standardizingPath
        let dangerousExact: Set<String> = [
            home, "\(home)/Library", "/", "/Users", "/Applications", "/System", "/Library"
        ]
        if dangerousExact.contains(normalized) {
            return String(localized: "⚠️ This folder is too broad to sync safely. Pick a specific subfolder.")
        }
        if normalized.hasPrefix("\(home)/Library/") || normalized.hasPrefix("/System/") {
            return String(localized: "⚠️ System or Library paths are not suitable for sync; pick a regular folder.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return String(localized: "Path does not exist.")
        }
        if !isDir.boolValue { return String(localized: "Path is not a directory.") }
        return nil
    }
}
