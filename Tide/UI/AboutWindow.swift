import SwiftUI
import AppKit

/// About / バージョン情報ウィンドウ。
/// バージョン・ビルド番号は `Bundle.main` から動的に読む（Info.plist の単一ソースに追従）。
/// ベータテスターが「バージョン教えて」に答えられる導線と、問題報告のリンクを提供する。
struct AboutWindow: View {
    /// 問題報告先（GitHub Issues）。配布先のフィードバック導線。
    private static let issuesURL = URL(string: "https://github.com/soundkitchen/Tide/issues")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text(verbatim: "Tide")
                .font(.title.bold())

            Text("Sync your folders through your own S3 bucket.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // 表示バージョン (build 番号)。テスターが報告時にそのまま伝えられるよう選択可能に。
            Text("Version \(version) (build \(build))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            Text("Released under the MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !copyright.isEmpty {
                // 著作権表記は Info.plist 由来の固定文字列なので verbatim 表示。
                Text(verbatim: copyright)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Link("Report an Issue", destination: Self.issuesURL)
                .font(.callout)
        }
        .padding(24)
        .frame(width: 360)
    }
}
