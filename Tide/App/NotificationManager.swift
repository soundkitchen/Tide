import TideCore
import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

/// OS 通知（UserNotifications）の発行とクリック処理。アプリ全体で 1 つ（`AppEnvironment` が保持）。
///
/// - 許可（authorization）は **初回の通知発火時に一度だけ**リクエストする。エラー / 競合が一度も
///   起きないユーザにいきなり許可プロンプトを出さないため（起動時 / セットアップ時には出さない）。
/// - 表示可否のトグルは `ConfigStore.notificationsEnabled`（既定 on）。off のときは許可も求めない。
/// - 通知クリックは `openActivity` 経由で Sync Activity ウィンドウを開く（App 層が登録）。
@MainActor
final class NotificationManager: NSObject, SyncNotifying {
    private let config: ConfigStore

    /// 通知クリック時に Sync Activity を開くアクション。`openWindow` は SwiftUI の View 環境にしか
    /// 無いため、App 層（MenuBarExtra のラベル等）が onAppear でここへクロージャを登録する。
    var openActivity: (() -> Void)?

    /// 初回 post で起こす許可リクエストの単一タスク。並行 post はこの完了を待ってから許可状態を
    /// 読むことで、初回プロンプト応答待ち中に来た 2 件目が `.notDetermined` で early-return され
    /// 取りこぼされるのを防ぐ（PR #18 レビュー Low）。リクエスト自体はアプリ生涯で 1 回だけ起こす。
    private var authorizationRequest: Task<Void, Never>?

    init(config: ConfigStore) {
        self.config = config
        super.init()
    }

    /// UNUserNotificationCenter のデリゲートとして自身を登録する（クリック処理・前面時のバナー表示）。
    /// 起動時（`applicationDidFinishLaunching`）に 1 回呼ぶ。許可プロンプトはここでは出さない。
    func registerAsDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ event: NotificationEvent) async {
        guard config.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()

        // 初回だけ許可リクエストを 1 回起こし、後続の post はその完了を待ってから許可状態を読む。
        // requestAuthorization は `.notDetermined` のときだけプロンプトを出し、確定済みなら即返る。
        if authorizationRequest == nil {
            authorizationRequest = Task {
                do {
                    _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                } catch {
                    AppLogger.ui.error("Notification authorization request failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
        await authorizationRequest?.value

        // 許可状態は毎回読む（後から System Settings で許可された場合も拾う）。
        // 許可されていなければ静かに諦める（拒否済み / 未決を尊重）。
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            return
        }

        let content = NotificationPolicy.content(for: event)
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.sound = .default
        // 同一 (path, 種別) は同じ identifier ＝ 連発しても 1 件に置換される。
        let request = UNNotificationRequest(identifier: content.identifier, content: body, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            AppLogger.ui.error("Failed to post notification: \(String(describing: error), privacy: .private)")
        }
    }

    /// 配達済み通知の撤去（Issue #103: FP 拡張の復帰エッジで「まだ止まっている」という
    /// stale な通知を通知センターに残さない）。未配達 / 不在の識別子は no-op。
    nonisolated func removeDelivered(identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// アプリが前面にいても（メニューバー常駐なので「前面」になる契機は限られるが）バナーを出す。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// 通知クリック → Sync Activity ウィンドウを開く。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            self.openActivity?()
        }
    }
}
