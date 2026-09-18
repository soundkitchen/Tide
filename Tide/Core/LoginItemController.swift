import Foundation
import ServiceManagement
import TideCore

/// ログイン時の自動起動（Issue #116）: `SMAppService.mainApp` でアプリ自身をログイン項目へ
/// 登録 / 解除する薄いラッパ。
///
/// **真の状態はシステム側**（`SMAppService.mainApp.status`）にあり、アプリは設定値を二重保存しない
/// （システム設定「ログイン項目」でユーザが外した場合と乖離させないため）。アプリ側に持つのは
/// 「既存インストールへ一度だけ既定 ON を適用したか」のフラグ（`ConfigStore.launchAtLoginMigrated`）
/// だけ。登録されるのは**現在のバンドルパス**（開発ビルドは `build/Build/Products/Debug/Tide.app`）で、
/// 同一パスへの再ビルドはそのまま有効・パスが消えると `status == .notFound` になる。
///
/// app-bound（ServiceManagement はアプリ拡張から使わない）のため `Tide/Core/` に置く。
@MainActor
enum LoginItemController {
    /// UI 向けに縮約したログイン項目の状態。
    enum Status: Equatable, Sendable {
        /// 登録済み・有効。
        case enabled
        /// 未登録（ユーザが OFF にした / まだ登録していない）。
        case notRegistered
        /// 登録したがユーザの承認待ち（システム設定「ログイン項目」で ON にする必要がある）。
        case requiresApproval
        /// 登録記録はあるがバンドルが見つからない（リポジトリ移動 / `build/` 削除等）。
        case notFound

        var isEnabled: Bool { self == .enabled }
    }

    static func status() -> Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    /// ログイン項目へ登録する。既に登録済みなら no-op（`register()` の再呼び出しは無害だが XPC を省く）。
    static func register() throws {
        guard SMAppService.mainApp.status != .enabled else { return }
        try SMAppService.mainApp.register()
        AppLogger.ui.info("Login item registered (status: \(String(describing: SMAppService.mainApp.status), privacy: .public))")
    }

    /// ログイン項目から外す。未登録なら no-op。
    static func unregister() throws {
        guard SMAppService.mainApp.status != .notRegistered else { return }
        try SMAppService.mainApp.unregister()
        AppLogger.ui.info("Login item unregistered")
    }

    /// システム設定の「ログイン項目」ペインを開く（`requiresApproval` の承認誘導）。
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
