import SwiftUI

/// UI 層で複数の View が共有する小さな表示ヘルパ群。
/// SwiftUI 依存（`Color` / `ViewModifier`）があるため Storage / Core ではなく UI 層に置く。

// MARK: - SyncLogEventType の表示属性（Sync Activity / メニューバー共用）

extension SyncLogEventType {
    /// イベント種別アイコン（SF Symbol 名）。
    var iconSymbol: String {
        switch self {
        case .upload:   return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .delete:   return "trash"
        case .conflict: return "exclamationmark.triangle"
        case .error:    return "xmark.octagon"
        case .info:     return "info.circle"
        }
    }

    /// イベント種別アイコンの色。
    var iconColor: Color {
        switch self {
        case .upload, .download: return .blue
        case .conflict:          return .orange
        case .error:             return .red
        case .delete, .info:     return .secondary
        }
    }
}

// MARK: - パス末尾要素

extension String {
    /// `(self as NSString).lastPathComponent`。表示用にパスの末尾要素を取り出す。
    var lastPathComponent: String { (self as NSString).lastPathComponent }
}

// MARK: - 日付表示書式

extension Date {
    /// ログ / 履歴表示用の標準書式（abbreviated date + standard time）。
    var tideTimestampLabel: String {
        formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - カード背景

extension View {
    /// カード状コンテナの背景（quinary + 角丸 8）。ポップオーバー / ウィンドウ共通の見た目を 1 箇所に集約。
    func cardBackground() -> some View {
        background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}
