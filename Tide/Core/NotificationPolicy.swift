import Foundation

/// ユーザに OS 通知で知らせるべき同期イベント。
/// 通知を出すのは「ユーザの介入が要る／取りこぼし（未バックアップ）が起きうる」**確定的な**事象だけに絞る。
/// ネットワーク瞬断のように自己回復する一過性エラーは出さない（オフラインのたびに通知が溢れるのを避ける）。
enum NotificationEvent: Equatable, Sendable {
    /// 競合でローカル版を別名コピーへ退避し、リモート版を採用した（手動マージが要る）。
    case conflictCopyCreated(path: String, localCopyPath: String)
    /// アップロードサイズ上限を超過し、恒久的に未バックアップ（Settings で上限調整が要る）。
    case fileTooLarge(path: String)
    /// 規定回数リトライしても失敗し、未バックアップのまま give-up した。
    case uploadGaveUp(path: String)
    /// 読込中に変化し続けて安定せず、まだバックアップされていない（L6 A-detect の延期）。
    case fileKeepsChanging(path: String)
}

/// OS 通知 1 件分の表示内容。`NotificationManager` が `UNMutableNotificationContent` へ詰め替える。
struct NotificationContent: Equatable, Sendable {
    /// 通知の一意 ID。**同一 (path, 種別) は同じ識別子**にして、UNUserNotificationCenter の
    /// 「同じ識別子は置換」仕様で重複通知を 1 件に畳む（同種イベントの連発でバナーを溢れさせない）。
    let identifier: String
    let title: String
    let body: String
}

/// 通知イベント → 表示内容の対応を決める純粋ロジック（副作用ゼロ・`NotificationPolicyTests` で全分岐固定）。
/// UNUserNotificationCenter から切り離してテスト可能にする（`MenuBarPresentation` / `StabilityCheck` と同じ流儀）。
enum NotificationPolicy {
    static func content(for event: NotificationEvent) -> NotificationContent {
        switch event {
        case let .conflictCopyCreated(path, _):
            let name = lastComponent(path)
            return NotificationContent(
                identifier: "conflict:\(path)",
                title: String(localized: "Sync conflict"),
                body: String(localized: "“\(name)” changed on another device. Your local edits were kept as a separate copy.")
            )
        case let .fileTooLarge(path):
            let name = lastComponent(path)
            return NotificationContent(
                identifier: "tooLarge:\(path)",
                title: String(localized: "File not backed up"),
                body: String(localized: "“\(name)” is too large to upload. Adjust the size limit in Settings.")
            )
        case let .uploadGaveUp(path):
            let name = lastComponent(path)
            return NotificationContent(
                identifier: "gaveUp:\(path)",
                title: String(localized: "Upload failed"),
                body: String(localized: "“\(name)” could not be uploaded after several attempts.")
            )
        case let .fileKeepsChanging(path):
            let name = lastComponent(path)
            return NotificationContent(
                identifier: "unstable:\(path)",
                title: String(localized: "File not backed up yet"),
                body: String(localized: "“\(name)” keeps changing and hasn’t been backed up yet.")
            )
        }
    }

    /// 通知本文に出すファイル名（末尾コンポーネント）。POSIX 相対パスなので `/` 区切りの末尾を採る。
    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// SyncEngine から OS 通知層への依存を抽象化する（`NotificationManager` が実装）。
/// SyncEngine に UserNotifications / AppKit を持ち込まず、テストでも差し替え可能にする。
@MainActor
protocol SyncNotifying: AnyObject {
    func post(_ event: NotificationEvent) async
}
