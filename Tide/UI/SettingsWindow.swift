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

    /// 現在の選択をバイトに直す（無制限は -1）。
    private var currentLimitBytes: Int64 {
        noLimit ? -1 : Int64(limitGB.rounded()) * Self.oneGiB
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
        }
        .onChange(of: noLimit) { _, _ in persistLimit() }
        .onChange(of: limitGB) { _, _ in persistLimit() }
    }
}
