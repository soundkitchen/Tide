import SwiftUI

struct SettingsWindow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// 現在有効な `.syncignore` のパターン（閲覧のみ）。
    private var syncignorePatterns: [String] {
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
            Section("Excluded patterns (built-in)") {
                ForEach(Array(HardcodedIgnoreRules.exactNames).sorted(), id: \.self) { name in
                    Text(name).font(.system(.body, design: .monospaced))
                }
                ForEach(HardcodedIgnoreRules.prefixPatterns, id: \.self) { p in
                    Text("\(p)* (prefix)").font(.system(.body, design: .monospaced))
                }
            }
            Section(".syncignore") {
                if syncignorePatterns.isEmpty {
                    Text("No .syncignore patterns").foregroundStyle(.secondary)
                } else {
                    ForEach(syncignorePatterns, id: \.self) { p in
                        // ユーザが書いた除外パターンを verbatim 表示する
                        Text(p).font(.system(.body, design: .monospaced))
                    }
                }
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
        .onAppear {
            let bytes = env.config.uploadSizeLimitBytes
            if bytes < 0 {
                noLimit = true
            } else {
                noLimit = false
                limitGB = min(Self.maxLimitGB, max(1, Double(bytes / Self.oneGiB)))
            }
            loadBandwidth()
        }
        .onChange(of: noLimit) { _, _ in persistLimit() }
        .onChange(of: limitGB) { _, _ in persistLimit() }
        .onChange(of: noUploadBwLimit) { _, _ in persistBandwidth() }
        .onChange(of: uploadBwMBps) { _, _ in persistBandwidth() }
        .onChange(of: noDownloadBwLimit) { _, _ in persistBandwidth() }
        .onChange(of: downloadBwMBps) { _, _ in persistBandwidth() }
    }

    /// 帯域上限を config から @State へ読み込む（`<= 0` = 無制限）。
    private func loadBandwidth() {
        let up = env.config.uploadBandwidthBytesPerSec
        if up <= 0 {
            noUploadBwLimit = true
        } else {
            noUploadBwLimit = false
            uploadBwMBps = min(Self.maxBwMBps, max(1, Double(up / Self.bytesPerMBps)))
        }
        let down = env.config.downloadBandwidthBytesPerSec
        if down <= 0 {
            noDownloadBwLimit = true
        } else {
            noDownloadBwLimit = false
            downloadBwMBps = min(Self.maxBwMBps, max(1, Double(down / Self.bytesPerMBps)))
        }
    }
}
