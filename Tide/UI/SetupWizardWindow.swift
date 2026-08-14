import TideCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SetupWizardWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismissWindow) private var dismissWindow

    private static let defaultRegion = "ap-northeast-1"

    @State private var step: Step = .credentials
    @State private var accessKeyId: String = ""
    @State private var secretAccessKey: String = ""
    @State private var bucket: String = ""
    @State private var region: String = Self.defaultRegion
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
    /// probe サイクルの世代（.task 起動ごとに +1）。フォールバック Task の自世代検査用
    /// （十次レビュー指摘 3 — 非構造化 Task は .task(id:) 再起動でキャンセルされないため、
    /// 旧サイクルの fallback が新サイクルの probe 窓で早期発火するのを防ぐ）。
    @State private var probeGeneration = 0
    /// ウィザードセッションの世代（`resetWizard` ごとに +1・Issue #102）。async アクション
    /// （runProvisioning / finishProvisioning / runStartSyncing）は開始時の世代を capture し、
    /// await 復帰後の `@State` 書込前に自世代を検査する — リセット後に stale 完了が新セッションの
    /// step / log / errorMessage / isWorking を汚さないため（probeGeneration と同じパターン。
    /// factoryReset は setupGate で completeSetup とは排他だが、S3 probe 系はゲート外なので
    /// 進行中リセットが実際に起こり得る）。
    @State private var wizardGeneration = 0

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
                        // 常駐 Window は閉じても @State が生存するため、閉じると同時に
                        // 新規セッションへ戻す（#102 現象 3 — 次回表示を done から始めない）。
                        dismissWindow(id: "setup")
                        resetWizard()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(nextButtonLabel) {
                        // 世代は**押下 tick で** capture する（PR #108 レビュー指摘 = stale「意図」）:
                        // Task スケジュールと本体実行の間の 1 tick にリセット（factoryReset 通知 /
                        // import 消費）が割り込むと、本体側 capture ではリセット**後**の世代を掴んで
                        // 新セッション上で実行されてしまう。押下時世代を渡し本体冒頭で検査する。
                        let generation = wizardGeneration
                        Task { await onNext(generation: generation) }
                    }
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
                // 消費前に必ず新規セッションへ戻す（#102 現象 2・3）: done 到達後は資格情報
                // @State が消去済み（L7）のため、残存 step のまま充填しても done 画面のまま
                // = 誘導が機能しない。リセット後に充填するので着地は credentials
                // （bucket/region は事前充填済み・資格情報の再入力から自然に bucket へ進む）。
                // ウィザード内の「Import settings…」ボタン（applyImported 直呼び）はリセット
                // しない — credentials 入力途中の値を消さないため。
                resetWizard()
                applyImported(pending)
                env.pendingImportedSettings = nil
            }
        }
        // factoryReset の通知（#102 現象 1）: 開きっぱなしの窓（done 出っぱなし等）を閉じて
        // 状態を破棄する — リセット済みアプリに旧セッションの done 画面 / 入力値を見せない。
        // 常駐 scene のため窓が閉じていても発火するが、その場合 dismiss は no-op・リセットは無害。
        .onChange(of: env.setupWizardResetVersion) {
            dismissWindow(id: "setup")
            resetWizard()
        }
        .alert("Bucket not found", isPresented: $pendingCreateBucket) {
            Button("Cancel", role: .cancel) {
                step = .bucket
            }
            Button("Create new bucket") {
                // Next ボタンと同じ stale「意図」対策（PR #108 レビュー指摘）。なお
                // pendingCreateBucket での判別は不可 — alert は正常経路でもボタン押下で
                // isPresented を false に戻すため、リセット由来の強制クリアと区別できない。
                let generation = wizardGeneration
                Task { await runCreateBucketAndProvision(generation: generation) }
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
            if willRecreateDomain == nil {
                // probe 未解決（XPC 応答待ち）。進行ゲート（canAdvance）が閉じている理由を
                // 可視化する（九次レビュー指摘 7）。10 秒でフォールバック解決する。
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking File Provider status…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            probeGeneration &+= 1
            let generation = probeGeneration
            // タイムアウトフォールバック（九次レビュー指摘 7）: fileproviderd がハングすると
            // domains() はエラーも返さず戻らない（#96 受け入れ実測）。10 秒で「不明 = 作り直し側」
            // へ倒して進行ゲートを解く（unknown は警告表示側なので安全・probe が後から返れば実値で
            // 上書き。completeSetup 側の権威判定は従来どおりで、この値は表示とゲートのみ）。
            // 自世代検査（十次レビュー指摘 3）: 非構造化 Task は .task(id:) 再起動でキャンセル
            // されない（defer は parked な本体が戻るまで走らない）ため、旧サイクルの fallback が
            // 新サイクルの 10 秒契約を破って早期発火しないよう世代で縛る。
            let fallback = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard probeGeneration == generation, willRecreateDomain == nil else { return }
                willRecreateDomain = true
                // fileProviderAlreadyEnabled は nil のまま = enabled != false で警告が出る
            }
            defer { fallback.cancel() }
            // 単一 probe（七次レビュー指摘 5）: isEnabled を別途叩くと警告条件が異時点の
            // 2 スナップショット合成になり、片方だけ失敗したとき矛盾表示になる。
            let probe = await env.probeDomainRecreation(forBucket: bucket)
            // キャンセル検査（十次レビュー指摘 7）: XPC はキャンセル非対応なので、id 変化で
            // キャンセルされた旧 task も応答が返れば必ずここへ resume する。無検査だと逆順応答
            // （新 probe が先・旧 probe が後）で stale 判定が新値を上書きし、緑チェック + 警告
            // なしのまま破壊的作り直しへ進めてしまう。
            guard !Task.isCancelled else { return }
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

    /// ウィザードを新規セッションへ戻す（Issue #102）。単一・常駐の `Window` は閉じても
    /// `@State` が生存し `.onAppear` 再発火にも頼れないため、「セッション終端」の 3 点
    /// （Finish 押下 / import 誘導の消費 / factoryReset 通知）で明示的に呼ぶ。
    /// 世代カウンタを進めることで in-flight の async アクションと probe fallback の
    /// 遅延書込を無効化する（stale 完了が新セッションを汚さない）。
    private func resetWizard() {
        wizardGeneration &+= 1
        probeGeneration &+= 1
        step = .credentials
        accessKeyId = ""
        secretAccessKey = ""
        bucket = ""
        region = Self.defaultRegion
        bucketSetupLog = []
        isWorking = false
        errorMessage = nil
        pendingCreateBucket = false
        fileProviderAlreadyEnabled = nil
        willRecreateDomain = nil
    }

    /// `generation` = ボタン押下 tick の世代。押下〜本体実行の 1 tick にリセットが割り込んだ
    /// stale「意図」はここで棄却する（PR #108 レビュー指摘・新セッションを進めない/汚さない）。
    private func onNext(generation: Int) async {
        guard generation == wizardGeneration else { return }
        errorMessage = nil
        switch step {
        case .credentials:
            step = .bucket
        case .bucket:
            await runProvisioning(generation: generation)
        case .provisioning:
            step = .fileProvider
        case .fileProvider:
            await runStartSyncing(generation: generation)
        case .done:
            // Finish ボタンと同義（done では Next は出ないが分岐は対称に保つ・#102）
            dismissWindow(id: "setup")
            resetWizard()
        }
    }

    /// `generation` = 押下 tick の世代（#102 / PR #108 レビュー指摘）: await 復帰後の @State
    /// 書込は自世代のときだけ行う。isWorking の復帰も自世代限定 — stale 完了の defer が
    /// 新セッションの実行中フラグを落とすと、進行中の新アクションのボタンが誤って再活性化する。
    private func runProvisioning(generation: Int) async {
        guard generation == wizardGeneration else { return }
        isWorking = true
        bucketSetupLog = []
        step = .provisioning
        defer { if generation == wizardGeneration { isWorking = false } }

        guard let probe = makeProbeClient() else { return }

        do {
            try await probe.headBucket()
            guard generation == wizardGeneration else { return }
            bucketSetupLog.append(String(localized: "✓ HeadBucket: reachable"))
        } catch {
            AppLogger.s3.error("HeadBucket failed: \(String(describing: error), privacy: .private)")
            guard generation == wizardGeneration else { return }
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

        await finishProvisioning(probe: probe, generation: generation)
    }

    /// 「作成する」アラートが押されたあとに呼ばれる: バケット作成 → 既存パスへ合流。
    private func runCreateBucketAndProvision(generation: Int) async {
        guard generation == wizardGeneration else { return }
        isWorking = true
        defer { if generation == wizardGeneration { isWorking = false } }
        guard let probe = makeProbeClient() else { return }

        do {
            try await probe.createBucket()
            guard generation == wizardGeneration else { return }
            bucketSetupLog.append(String(localized: "✓ Bucket created"))
        } catch {
            AppLogger.s3.error("CreateBucket failed: \(String(describing: error), privacy: .private)")
            guard generation == wizardGeneration else { return }
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
        await finishProvisioning(probe: probe, generation: generation)
    }

    /// HeadBucket / CreateBucket 後の共通処理（バージョニング + ライフサイクル）。
    /// `generation` は呼び出し元アクションの開始時世代（#102 — await 復帰後の書込ガード用）。
    private func finishProvisioning(probe: TideS3Client, generation: Int) async {
        do {
            let alreadyEnabled = try await probe.isVersioningEnabled()
            if !alreadyEnabled {
                try await probe.enableVersioning()
            }
            guard generation == wizardGeneration else { return }
            bucketSetupLog.append(alreadyEnabled
                ? String(localized: "✓ Versioning was already enabled")
                : String(localized: "✓ Versioning enabled"))

            let lifecycle = try await probe.ensureLifecycleRules()
            guard generation == wizardGeneration else { return }
            bucketSetupLog.append(lifecycle == .alreadyConfigured
                ? String(localized: "✓ Lifecycle rules already configured")
                : String(localized: "✓ Lifecycle rules updated"))

            // Block Public Access の 4 つの設定を強制
            try await probe.enforcePublicAccessBlock()
            guard generation == wizardGeneration else { return }
            bucketSetupLog.append(String(localized: "✓ Public access block enforced"))

            // HTTPS 強制バケットポリシー（C3 後半・Issue #26）。非致命: 失敗してもセットアップは続行する
            // （SDK 既定 HTTPS の多層防御。s3:PutBucketPolicy 権限が無い構成でも止めない）。Block Public Access の
            // 後でよい（Deny statement は public 判定にならず弾かれない）。
            do {
                let outcome = try await probe.enforceTLSBucketPolicy()
                guard generation == wizardGeneration else { return }
                switch outcome {
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
                guard generation == wizardGeneration else { return }
                bucketSetupLog.append(String(localized: "⚠ Could not set HTTPS-only policy (continuing)"))
            }

            bucketSetupLog.append(String(localized: "✓ Provisioning complete"))
        } catch {
            let detail = String(describing: error)
            guard generation == wizardGeneration else { return }
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

    private func runStartSyncing(generation: Int) async {
        guard generation == wizardGeneration else { return }
        isWorking = true
        defer { if generation == wizardGeneration { isWorking = false } }
        do {
            let creds = AWSCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey)
            try await env.completeSetup(
                credentials: creds,
                bucket: bucket,
                region: region
            )
            // 世代ガード（#102）: completeSetup 自体は setupGate で factoryReset と排他だが、
            // import 誘導の消費（リセット）は進行中でも発火し得る。stale 完了で step = .done に
            // 進めない（リセットが資格情報の消去も済ませている）。
            guard generation == wizardGeneration else { return }
            // L7: 成功したらメモリ上の鍵をすぐ手放す（参照を切る。ヒープ上のバイトは GC 任せ）
            accessKeyId = ""
            secretAccessKey = ""
            step = .done
        } catch {
            let detail = String(describing: error)
            guard generation == wizardGeneration else { return }
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
