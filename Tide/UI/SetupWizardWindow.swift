import TideCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SetupWizardWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step: Step = .credentials
    @State private var accessKeyId: String = ""
    @State private var secretAccessKey: String = ""
    @State private var bucket: String = ""
    @State private var region: String = "ap-northeast-1"
    @State private var bucketSetupLog: [String] = []
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var pendingCreateBucket: Bool = false
    /// FP ドメインの現況（fileProvider ステップの表示専用・再セットアップ経路向け）。
    /// nil = 未取得/取得失敗（表示しないだけで進行は妨げない）。
    @State private var fileProviderAlreadyEnabled: Bool?
    /// 「Start syncing」でドメインが作り直される（= 破壊的）か。判定は completeSetup と共有
    /// （`AppEnvironment.probeDomainRecreation(forBucket:)`・PR #101 五次レビュー指摘 2）。
    @State private var willRecreateDomain: Bool?

    enum Step: Int, CaseIterable {
        case credentials = 0
        case bucket = 1
        case provisioning = 2
        case fileProvider = 3
        case done = 4

        var title: String {
            switch self {
            case .credentials: return String(localized: "AWS Credentials")
            case .bucket:      return String(localized: "Bucket")
            case .provisioning:return String(localized: "Provisioning")
            case .fileProvider:return String(localized: "Tide in Finder")
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
                case .fileProvider:fileProviderView
                case .done:        doneView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage)
                        .textSelection(.enabled)
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
        // Settings 画面の import から引き渡された設定があれば事前充填して消費する（#29）。
        // `"setup"` は単一・常駐の `Window` なので、既に開いている状態で `openWindow(id:"setup")` を
        // 呼んでも `.onAppear` は再発火しない。`.onChange(initial: true)` にすることで「初回 appear
        // （Settings が payload を立ててから開いた場合）」と「既に開いていて後から payload が立った場合」の
        // 両方で消費でき、消費後は nil に戻すので古い payload が将来の appear まで居残らない。
        .onChange(of: env.pendingImportedSettings, initial: true) {
            if let pending = env.pendingImportedSettings {
                applyImported(pending)
                env.pendingImportedSettings = nil
            }
        }
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
        case .fileProvider:return String(localized: "Start syncing")
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
        case .fileProvider:
            // probe（作り直し判定）解決前は進めない（六次レビュー指摘 2）: 無条件 true だと
            // ステップ表示直後の Return（.defaultAction）が警告を一度もレンダリングしないまま
            // completeSetup → disableForRecreation に到達し得る。
            return willRecreateDomain != nil
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
            Divider()
            HStack {
                Button("Import settings…") { importSettings() }
                Text("Have a Tide settings file from another Mac? Import it to pre-fill the bucket and region.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private var fileProviderView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tide will appear in the Finder sidebar under Locations. Your files show up as placeholders and download when you open them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("No local sync folder is needed. Press “Start syncing” to enable the Tide folder and begin syncing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // 破壊的 recreation の警告は enabled 判定の**外**（六次レビュー指摘 1）: willRecreateDomain
            // は不明（isEnabled nil = fileproviderd 無応答）を作り直し側に倒すため、警告も同じ側で
            // 出さないと「domains() 一時失敗 × Start syncing」で無警告破棄になる。既知の未登録
            // （enabled == false）だけは破棄対象が存在しないため除外（バケット切替でも空作り直し）。
            // 判定は completeSetup と共有 = バケット切替と素性不明ドメインの両枝をカバー
            // （四次レビュー指摘 2 / 五次レビュー指摘 2）。
            if willRecreateDomain == true, fileProviderAlreadyEnabled != false {
                Label("This setup will recreate the Tide folder. Changes not yet uploaded will be discarded.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if fileProviderAlreadyEnabled == true, willRecreateDomain == false {
                // 同一バケットの再セットアップ経路: enable は冪等（再 add no-op）なのでそのまま進める
                Label("The Tide folder is already enabled on this Mac.", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
        // completeSetup がドメイン状態を変える（部分失敗で disableForRecreation 済み等）ため、
        // Settings と同じ変更カウンタで再取得する（五次レビュー指摘 3 — id 無しだとエラー表示の
        // 隣に stale な緑チェックが残る）。ステップ再出現時（Back で bucket 変更後）も走る。
        // id には bucket も含める（八次レビュー指摘 1）: 設定インポート（ウィザードのルートの
        // .onChange）は fileProvider ステップ滞在中でも発火して bucket をその場で書き換えるため、
        // version のみだと stale な緑チェック + 活性ボタンのまま破壊的作り直しへ進めてしまう。
        .task(id: "\(env.fileProviderStateVersion)|\(bucket)") {
            // 再入時は probe 前に必ず nil へ戻す（七次レビュー指摘 1）: ウィンドウレベル @State の
            // 前回訪問値が残ると、XPC 往復中の窓で canAdvance ゲート（六次②）が stale 値で
            // 素通りし、Back → bucket 変更 → Return で警告未レンダリングのまま実行され得る。
            fileProviderAlreadyEnabled = nil
            willRecreateDomain = nil
            // 単一 probe（七次レビュー指摘 5）: isEnabled を別途叩くと警告条件が異時点の
            // 2 スナップショット合成になり、片方だけ失敗したとき矛盾表示になる。
            let probe = await env.probeDomainRecreation(forBucket: bucket)
            willRecreateDomain = probe.recreate
            fileProviderAlreadyEnabled = probe.enabled
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup complete. Tide is now available in the Finder sidebar under Locations.")
                .font(.callout)
            Text("If this bucket already has data, files appear as placeholders and download when you open them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("• Bucket: \(bucket)")
            Text("• Region: \(region)")
            Text("• Device ID: \(env.config.deviceId)").font(.caption).foregroundStyle(.secondary)
            Button("Open Tide in Finder") {
                Task { await FileProviderController.openUserVisibleFolderInFinder() }
            }
            .padding(.top, 4)
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
            step = .fileProvider
        case .fileProvider:
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
            AppLogger.s3.error("HeadBucket failed: \(String(describing: error), privacy: .private)")
            // 404（非存在）、または 404 以外の空ボディ（権限不足 / 別リージョン / 名前重複などが
            // missingRequiredData として届く）。後者は HeadBucket だけでは確定できないので、
            // 「作成または既存利用」フローへ進め、createBucket の結果で確定させる。
            if S3ErrorClassifier.isNotFound(error) || S3ErrorClassifier.isInconclusiveHeadError(error) {
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
            AppLogger.s3.error("CreateBucket failed: \(String(describing: error), privacy: .private)")
            if S3ErrorClassifier.isBucketAlreadyOwnedByYou(error) {
                // 既に存在し、かつ自分の所有 → そのまま使う（複数マシンでの既存バケット合流）
                bucketSetupLog.append(String(localized: "✓ Bucket already exists (owned by you) — using it"))
            } else if S3ErrorClassifier.isBucketNameTaken(error) {
                errorMessage = String(localized: "That bucket name is already used by another AWS account. Choose a different name.")
                step = .bucket
                return
            } else if S3ErrorClassifier.isForbidden(error) {
                errorMessage = String(localized: "Couldn't create the bucket: insufficient permissions. Your IAM policy needs s3:CreateBucket.")
                step = .bucket
                return
            } else {
                let detail = String(describing: error)
                errorMessage = String(localized: "Failed to create bucket: \(detail)")
                step = .bucket
                return
            }
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

            // HTTPS 強制バケットポリシー（C3 後半・Issue #26）。非致命: 失敗してもセットアップは続行する
            // （SDK 既定 HTTPS の多層防御。s3:PutBucketPolicy 権限が無い構成でも止めない）。Block Public Access の
            // 後でよい（Deny statement は public 判定にならず弾かれない）。
            do {
                switch try await probe.enforceTLSBucketPolicy() {
                case .alreadyEnforced:
                    bucketSetupLog.append(String(localized: "✓ HTTPS-only bucket policy already enforced"))
                case .updated:
                    bucketSetupLog.append(String(localized: "✓ HTTPS-only bucket policy enforced"))
                case .checkDenied:
                    // IAM に s3:GetBucketPolicy が無い構成。適用状態は検証できないが非致命（多層防御・Issue #81）。
                    AppLogger.s3.notice("enforceTLSBucketPolicy check skipped: access denied (likely missing s3:GetBucketPolicy; non-fatal)")
                    bucketSetupLog.append(String(localized: "⚠ Could not verify HTTPS-only policy (no permission; continuing)"))
                }
            } catch {
                AppLogger.s3.error("enforceTLSBucketPolicy failed (non-fatal): \(String(describing: error), privacy: .private)")
                bucketSetupLog.append(String(localized: "⚠ Could not set HTTPS-only policy (continuing)"))
            }

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
                region: region
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

    /// 設定 JSON を選ばせて接続フィールドを事前充填する（#29）。AWS 認証情報はファイルに無いので手入力のまま。
    private func importSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let payload = try SettingsTransfer.read(from: url)
            applyImported(payload)
            errorMessage = nil
        } catch {
            AppLogger.ui.error("Settings import failed: \(String(describing: error), privacy: .private)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Import failed.")
        }
    }

    /// payload の tunables を config に反映し、接続フィールド（@State）を事前充填する。
    /// 接続設定は provisioning で使うため @State にだけ入れ（completeSetup が最終的に config へ確定する）、
    /// tunables はウィザードに UI が無いものも含めて config に持ち回る。
    /// `syncRootPath` は読まない（#97: fpOnly にローカル同期フォルダは無い。旧 export の値は無視）。
    private func applyImported(_ payload: SettingsTransfer.Payload) {
        SettingsTransfer.applyTunables(payload, to: env.config)
        if let b = payload.bucketName, !b.isEmpty { bucket = b }
        if let r = payload.region, !r.isEmpty { region = r }
    }
}
