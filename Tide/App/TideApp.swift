import SwiftUI
import AppKit

@main
struct TideApp: App {
    // AppEnvironment は AppDelegate が所有する。LSUIElement なメニューバー常駐アプリでは
    // MenuBarExtra(.window) のポップオーバーコンテンツが「初回オープン時に初めて」生成されるため、
    // bootstrap を MenuBarContent.task だけに置くとメニューを開くまで SyncEngine が立ち上がらない
    // （= ログイン自動起動後やアプリ再起動後にメニューを開くまで同期/再開が始まらない）。
    // applicationDidFinishLaunching で起動時に eager に bootstrap するため、環境を AppDelegate 側に持つ。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.environment)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.environment)
        }
        .menuBarExtraStyle(.window)

        Window("Tide Settings", id: "settings") {
            SettingsWindow()
                .environment(appDelegate.environment)
                .frame(minWidth: 480, minHeight: 360)
        }
        .windowResizability(.contentSize)

        Window("Tide Setup", id: "setup") {
            SetupWizardWindow()
                .environment(appDelegate.environment)
                .frame(width: 540, height: 420)
        }
        .windowResizability(.contentSize)

        Window("Version History", id: "versions") {
            VersionHistoryWindow()
                .environment(appDelegate.environment)
        }
        .windowResizability(.contentSize)

        Window("Sync Activity", id: "activity") {
            SyncActivityWindow()
                .environment(appDelegate.environment)
        }
        .windowResizability(.contentSize)
    }
}

/// メニューバーアイコン（MenuBarExtra のラベル）。常駐アプリでは起動直後に必ず生成されるため、
/// ここで通知クリック → Sync Activity を開くアクションを `NotificationManager` に登録する
/// （`openWindow` は View 環境にしか無く、AppKit のデリゲートからは直接呼べないため）。
/// MenuBarContent.task でも同じ登録を保険として行う。
private struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "icloud.and.arrow.up")
            .onAppear {
                env.notifications.openActivity = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "activity")
                }
            }
    }
}

/// 起動時に SyncEngine を eager に立ち上げるためのデリゲート。
/// `AppEnvironment` をここで 1 つだけ生成して保持し、Scene 各所へ `.environment(...)` で配る。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 通知のデリゲートを登録（クリック処理 / 前面時のバナー）。許可プロンプトは初回発火時まで出さない。
        environment.notifications.registerAsDelegate()
        // bootstrap() は冪等（engine 起動済み or 進行中なら no-op）なので、
        // 後から走る MenuBarContent.task の bootstrap 呼びと二重に起動することはない。
        Task { await environment.bootstrap() }
    }
}
