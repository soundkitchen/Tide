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

    /// 現在有効な `.syncignore` のパターン（閲覧のみ・ディレクトリ単位）。ネスト対応で階層ごとに表示する。
    private var ignoreGroups: [LayeredSyncIgnore.DirectoryGroup] {
        env.engine?.activeIgnorePatterns ?? []
    }

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
                LabeledContent("Sync Folder", value: env.config.syncRootPath ?? "—")
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
                if ignoreGroups.isEmpty {
                    Text("No .syncignore patterns").foregroundStyle(.secondary)
                } else {
                    ForEach(ignoreGroups) { group in
                        // ディレクトリ見出し（ルート直下は "/"）。パスは生文字列なので verbatim 表示。
                        Text(verbatim: group.directory.isEmpty ? "/" : group.directory + "/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(group.patterns, id: \.self) { p in
                            // ユーザが書いた除外パターンを verbatim 表示する
                            Text(verbatim: p)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
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
                Text("Export saves your bucket, region, folder, and preferences (no AWS credentials) to a JSON file. Import restores preferences immediately; bucket/region/folder changes open the Setup Wizard.")
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
            Section("File Provider (experimental)") {
                if let fileProviderEnabled {
                    Text(fileProviderEnabled
                         ? String(localized: "Domain is enabled.")
                         : String(localized: "Domain is not enabled."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Enable File Provider (PoC)") {
                    Task {
                        do {
                            try await FileProviderPoC.enable()
                            fileProviderMessage = String(localized: "Enabled — check “Tide” under Locations in Finder (~/Library/CloudStorage).")
                        } catch {
                            fileProviderMessage = String(describing: error)
                        }
                        fileProviderEnabled = await FileProviderPoC.isEnabled()
                    }
                }
                Button("Disable File Provider") {
                    Task {
                        do {
                            try await FileProviderPoC.disable()
                            fileProviderMessage = String(localized: "File Provider domain removed.")
                        } catch {
                            fileProviderMessage = String(describing: error)
                        }
                        fileProviderEnabled = await FileProviderPoC.isEnabled()
                    }
                }
                if let fileProviderMessage {
                    Text(fileProviderMessage)
                        .textSelection(.enabled)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Read-only preview (PoC): shows synced files as cloud placeholders and downloads them when opened. Independent from the sync folder — enabling or disabling does not affect syncing.")
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
        .task { fileProviderEnabled = await FileProviderPoC.isEnabled() }
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
                settingsMessage = String(localized: "Preferences imported. Opening Setup Wizard to apply bucket/region/folder changes.")
            } else {
                settingsMessage = String(localized: "Settings imported.")
            }
        } catch {
            AppLogger.ui.error("Settings import failed: \(String(describing: error), privacy: .private)")
            settingsMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "Import failed.")
        }
    }

    /// import payload の接続設定が現在の config と異なるか（前後空白を無視して比較）。
    private func connectionDiffers(from payload: SettingsTransfer.Payload) -> Bool {
        func norm(_ s: String?) -> String {
            (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return norm(payload.bucketName) != norm(env.config.bucketName)
            || norm(payload.region) != norm(env.config.region)
            || norm(payload.syncRootPath) != norm(env.config.syncRootPath)
    }
}
