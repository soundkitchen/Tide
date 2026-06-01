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
    @State private var uploadLimit: Int64 = ConfigStore.defaultUploadSizeLimitBytes

    private static let oneGiB: Int64 = 1 * 1024 * 1024 * 1024

    /// 既定（1GiB）より大きい、または無制限を選んでいるとき課金注意を出す。
    private var showsCostAttention: Bool {
        uploadLimit < 0 || uploadLimit > Self.oneGiB
    }

    var body: some View {
        Form {
            Section("Sync") {
                LabeledContent("Bucket", value: env.config.bucketName ?? "—")
                LabeledContent("Region", value: env.config.region ?? "—")
                LabeledContent("Sync Folder", value: env.config.syncRootPath ?? "—")
                LabeledContent("Device ID", value: env.config.deviceId)
                Picker("Upload size limit", selection: $uploadLimit) {
                    Text("1 GB").tag(Self.oneGiB)
                    Text("10 GB").tag(Int64(10) * 1024 * 1024 * 1024)
                    Text("50 GB").tag(Int64(50) * 1024 * 1024 * 1024)
                    Text("No limit").tag(Int64(-1))
                }
                if showsCostAttention {
                    Text("A larger limit can increase your AWS storage costs.")
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
            uploadLimit = env.config.uploadSizeLimitBytes
        }
        .onChange(of: uploadLimit) { _, newValue in
            // 次回キュー周回で Uploader が読み直すので即反映される。
            env.config.uploadSizeLimitBytes = newValue
        }
    }
}
