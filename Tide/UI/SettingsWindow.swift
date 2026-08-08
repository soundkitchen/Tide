import TideCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// 診断エクスポートの結果メッセージ（成功/失敗の一過性表示）。
    @State private var exportMessage: String?

    /// 設定 export/import（#29）の結果メッセージ（成功/失敗の一過性表示）。
    @State private var settingsMessage: String?

    /// 1 ファイルあたりのアップロード上限（ConfigStore は @Observable ではないので @State で持つ）。
    /// スライダで GB 単位（1〜100GB）を柔軟に設定。`noLimit` が true のときは無制限（-1 センチネル）。
    @State private var noLimit: Bool = false
    @State private var limitGB: Double = 1

    private static let oneGiB: Int64 = 1 * 1024 * 1024 * 1024
    private static let maxLimitGB: Double = 100

    /// 帯域上限（サブ E・MB/s、decimal=1,000,000 bytes/s）。No limit トグルが true のとき無制限（-1 センチネル）。
    /// ConfigStore は @Observable でないので upload-size-limit と同じく @State + onAppear/onChange の write-through。
    @State private var noUploadBwLimit: Bool = true
    @State private var uploadBwMBps: Double = 10
    @State private var noDownloadBwLimit: Bool = true
    @State private var downloadBwMBps: Double = 10

    /// 通知トグル（既定 on）。ConfigStore は @Observable でないので他の設定と同じ @State write-through。
    @State private var notificationsEnabled: Bool = true

    /// File Provider PoC ドメインの状態表示（M5 Phase 3）。nil = 未取得。
    @State private var fileProviderEnabled: Bool?
    @State private var fileProviderMessage: String?

    private static let bytesPerMBps: Int64 = 1_000_000
    private static let maxBwMBps: Double = 100

    /// 現在の選択をバイトに直す（無制限は -1）。
    private var currentLimitBytes: Int64 {
        noLimit ? -1 : Int64(limitGB.rounded()) * Self.oneGiB
    }

    private var currentUploadBwBytes: Int64 {
        noUploadBwLimit ? -1 : Int64(uploadBwMBps.rounded()) * Self.bytesPerMBps
    }
    private var currentDownloadBwBytes: Int64 {
        noDownloadBwLimit ? -1 : Int64(downloadBwMBps.rounded()) * Self.bytesPerMBps
    }
    private func persistBandwidth() {
        env.config.uploadBandwidthBytesPerSec = currentUploadBwBytes
        env.config.downloadBandwidthBytesPerSec = currentDownloadBwBytes
    }

    /// 既定（1GB）より大きい、または無制限を選んでいるとき課金注意を出す。
    private var showsCostAttention: Bool {
        noLimit || limitGB > 1
    }

    /// 選択値を ConfigStore に書く（次回キュー周回で Uploader が読み直す＝即反映）。
    private func persistLimit() {
        env.config.uploadSizeLimitBytes = currentLimitBytes
    }

    var body: some View {
        Form {
            Section("Sync") {
                LabeledContent("Bucket", value: env.config.bucketName ?? "—")
                LabeledContent("Region", value: env.config.region ?? "—")
                LabeledContent("Device ID", value: env.config.deviceId)
                Toggle("No upload size limit", isOn: $noLimit)
                if !noLimit {
                    LabeledContent("Upload size limit") {
                        Text("\(Int(limitGB.rounded())) GB")
                    }
                    Slider(value: $limitGB, in: 1...Self.maxLimitGB, step: 1)
                }
                if showsCostAttention {
                    Text("A larger limit can increase your AWS storage and data-transfer (egress) costs.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Bandwidth") {
                Toggle("No upload bandwidth limit", isOn: $noUploadBwLimit)
                if !noUploadBwLimit {
                    LabeledContent("Upload limit") {
                        Text("\(Int(uploadBwMBps.rounded())) MB/s")
                    }
                    Slider(value: $uploadBwMBps, in: 1...Self.maxBwMBps, step: 1)
                }
                Toggle("No download bandwidth limit", isOn: $noDownloadBwLimit)
                if !noDownloadBwLimit {
                    LabeledContent("Download limit") {
                        Text("\(Int(downloadBwMBps.rounded())) MB/s")
                    }
                    Slider(value: $downloadBwMBps, in: 1...Self.maxBwMBps, step: 1)
                }
                Text("Limits throttle file transfers in the background. Leave off for full speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Notify about conflicts and backup problems", isOn: $notificationsEnabled)
                Text("Shows a notification when a sync conflict happens or a file can’t be backed up. macOS notification settings still apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Excluded patterns (built-in)") {
                ForEach(Array(HardcodedIgnoreRules.exactNames).sorted(), id: \.self) { name in
                    Text(name).font(.system(.body, design: .monospaced))
                }
                ForEach(HardcodedIgnoreRules.prefixPatterns, id: \.self) { p in
                    Text("\(p)* (prefix)").font(.system(.body, design: .monospaced))
                }
            }
            Section(".syncignore") {
                // #97: パターン一覧は撤去（ソースが engine.activeIgnorePatterns = fpOnly では
                // engine 恒常 nil のため常に空表示 = パターンが実効なのに空という誤情報だった）。
                // 実効は FP createItem 側（ManifestIgnoreCache）で維持。一覧表示の復権が必要に
                // なったら別 Issue（docs/09 v0.3.0 節）。
                Text("Exclusion patterns are managed in the .syncignore file inside the Tide folder (Locations in the Finder sidebar). They apply to newly added files only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Tide in Finder") {
                    Task { await FileProviderController.openUserVisibleFolderInFinder() }
                }
                // メニューバー行（MenuBarContent.secondaryActions）と同じ活性条件（PR #101
                // 再レビュー指摘 5）: 既知の無効（false）だけ disable — 直下の FP セクションが
                // 「Domain is not enabled.」を出している状態で素の CloudStorage が開く矛盾を防ぐ。
                .disabled(fileProviderEnabled == false)
            }
            Section("Settings file") {
                Button("Export Settings…") { exportSettings() }
                Button("Import Settings…") { importSettings() }
                if let settingsMessage {
                    Text(settingsMessage)
                        .textSelection(.enabled)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Export saves your bucket, region, and preferences (no AWS credentials) to a JSON file. Import restores preferences immediately; bucket/region changes open the Setup Wizard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Button("Export Diagnostics…") { exportDiagnostics() }
                if let exportMessage {
                    Text(exportMessage)
                        .textSelection(.enabled)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Saves a .zip with app logs, settings, and the local database — includes file names/paths and the bucket name, but no AWS credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("File Provider") {
                if let fileProviderEnabled {
                    Text(fileProviderEnabled
                         ? String(localized: "Domain is enabled.")
                         : String(localized: "Domain is not enabled."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Enable File Provider") {
                    runFileProviderAction(
                        FileProviderController.enable,
                        successMessage: String(localized: "Enabled — check “Tide” under Locations in Finder (~/Library/CloudStorage)."))
                }
                Button("Disable File Provider") {
                    runFileProviderAction(
                        FileProviderController.disable,
                        successMessage: String(localized: "File Provider domain removed."))
                }
                if let fileProviderMessage {
                    Text(fileProviderMessage)
                        .textSelection(.enabled)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Shows synced files in Finder (Locations → Tide) as cloud placeholders and downloads them when opened. Files you add, edit, or delete there sync directly to S3. This is how Tide syncs — disabling stops all syncing and removes the local replica (placeholders and downloaded copies); data in S3 is kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Open Setup Wizard") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "setup")
                }
                Button("Factory reset…", role: .destructive) {
                    Task {
                        await env.factoryReset()
                        dismissWindow(id: "settings")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loadStateFromConfig() }
        .task { fileProviderEnabled = await FileProviderController.isEnabled() }
        .onChange(of: notificationsEnabled) { _, newValue in
            env.config.notificationsEnabled = newValue
        }
        .onChange(of: noLimit) { _, _ in persistLimit() }
        .onChange(of: limitGB) { _, _ in persistLimit() }
        .onChange(of: noUploadBwLimit) { _, _ in persistBandwidth() }
        .onChange(of: uploadBwMBps) { _, _ in persistBandwidth() }
        .onChange(of: noDownloadBwLimit) { _, _ in persistBandwidth() }
        .onChange(of: downloadBwMBps) { _, _ in persistBandwidth() }
    }

    /// File Provider の有効化/無効化ボタン共通処理（成功文言と await する操作だけが差分）。
    private func runFileProviderAction(
        _ action: @escaping @MainActor () async throws -> Void,
        successMessage: String
    ) {
        Task {
            do {
                try await action()
                fileProviderMessage = successMessage
            } catch {
                fileProviderMessage = String(describing: error)
            }
            fileProviderEnabled = await FileProviderController.isEnabled()
        }
    }

    /// ConfigStore の現値を @State へ読み込む（初回表示と import 反映後の再読込で共用）。
    private func loadStateFromConfig() {
        let bytes = env.config.uploadSizeLimitBytes
        if bytes < 0 {
            noLimit = true
        } else {
            noLimit = false
            limitGB = min(Self.maxLimitGB, max(1, Double(bytes / Self.oneGiB)))
        }
        loadBandwidth()
        notificationsEnabled = env.config.notificationsEnabled
    }

    /// config のバイト/秒値を (無制限フラグ, MB/s クランプ値) に変換する（`<= 0` = 無制限）。
    /// 無制限時の MB/s は呼び出し側で未使用（@State の現値を温存する）。
    private static func decodeBandwidth(_ bytes: Int64) -> (noLimit: Bool, mbps: Double) {
        guard bytes > 0 else { return (true, 0) }
        return (false, min(maxBwMBps, max(1, Double(bytes / bytesPerMBps))))
    }

    /// 帯域上限を config から @State へ読み込む（`<= 0` = 無制限）。
    private func loadBandwidth() {
        let up = Self.decodeBandwidth(env.config.uploadBandwidthBytesPerSec)
        noUploadBwLimit = up.noLimit
        if !up.noLimit { uploadBwMBps = up.mbps }

        let down = Self.decodeBandwidth(env.config.downloadBandwidthBytesPerSec)
        noDownloadBwLimit = down.noLimit
        if !down.noLimit { downloadBwMBps = down.mbps }
    }

    /// 診断 zip の保存先を NSSavePanel で選ばせ、`DiagnosticsExporter` で書き出す。
    /// LSUIElement アプリなので panel を前面に出すため NSApp.activate を前置する。
    private func exportDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Tide-Diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportMessage = nil  // 前回の結果メッセージを消してから走らせる（2 回目以降に古い表示が残らない）
        Task {
            do {
                try await DiagnosticsExporter.export(to: url, env: env)
                exportMessage = String(localized: "Saved diagnostics.")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                AppLogger.ui.error("Diagnostics export failed: \(String(describing: error), privacy: .private)")
                exportMessage = String(localized: "Export failed.")
            }
        }
    }

    // MARK: - 設定 export / import（#29）

    /// 非機密設定を JSON で書き出す。保存先は NSSavePanel でユーザが選んだ場所のみ。
    /// LSUIElement アプリなので panel を前面に出すため NSApp.activate を前置する。
    private func exportSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Tide-Settings.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settingsMessage = nil
        do {
            try SettingsTransfer.export(to: url, config: env.config)
            settingsMessage = String(localized: "Saved settings.")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            AppLogger.ui.error("Settings export failed: \(String(describing: error), privacy: .private)")
            settingsMessage = String(localized: "Export failed.")
        }
    }

    /// JSON から設定を読み込む。tunables（サイズ上限/帯域/通知/ポーリング）は即適用し、
    /// 接続設定（bucket/region/folder）が現設定と異なるときだけ、ローカル DB がバケットに紐づく安全のため
    /// ホットスワップせずセットアップウィザードへ事前充填して誘導する。
    private func importSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settingsMessage = nil
        do {
            let payload = try SettingsTransfer.read(from: url)
            SettingsTransfer.applyTunables(payload, to: env.config)
            loadStateFromConfig()  // 反映を即座に UI へ
            if connectionDiffers(from: payload) {
                env.pendingImportedSettings = payload
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "setup")
                settingsMessage = String(localized: "Preferences imported. Opening Setup Wizard to apply bucket/region changes.")
            } else {
                settingsMessage = String(localized: "Settings imported.")
            }
        } catch {
            AppLogger.ui.error("Settings import failed: \(String(describing: error), privacy: .private)")
            settingsMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Import failed.")
        }
    }

    /// import payload の接続設定が現在の config と異なるか（前後空白を無視して比較）。
    /// `syncRootPath` は比較しない（#97: fpOnly にローカル同期フォルダは無い。旧 export の
    /// 死にキー値との差分で不要なウィザード誘導を出さない）。
    private func connectionDiffers(from payload: SettingsTransfer.Payload) -> Bool {
        func norm(_ s: String?) -> String {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return norm(payload.bucketName) != norm(env.config.bucketName)
            || norm(payload.region) != norm(env.config.region)
    }
}
