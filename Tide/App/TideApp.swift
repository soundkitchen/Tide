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

        Window("About Tide", id: "about") {
            AboutWindow()
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

    /// syncing アニメのコマ送り速度（フレーム数 / グリフ名 / フレーム名のマッピングは
    /// `MenuBarPresentation` 側の純粋関数に集約＝表示ロジックの単一管理・テスト可能）。
    private static let syncFPS: Double = 8

    /// syncing 中に表示するフレーム番号。下の `.task` が syncing の間だけ進める。
    @State private var animationFrame = 0

    /// 現在の同期状態を、ポップオーバー見出しと同じ純粋関数で算出する（表示ロジックの単一管理）。
    private var presentation: MenuBarPresentation {
        MenuBarPresentation.headline(
            status: env.engine?.status ?? .notConfigured,
            queueDepth: env.engine?.queueDepth ?? 0,
            activeTransferCount: env.engine?.activeTransfers.count ?? 0
        )
    }

    var body: some View {
        // 状態はアイコンの「様子」で表現する：syncing は波が流れるフレームアニメ、
        // それ以外は状態ごとの固定グリフを切り替える（バッジ・色は使わない）。
        // グリフ名 / フレーム名のマッピングは MenuBarPresentation 側の純粋関数で単一管理。
        Group {
            if presentation.isSyncing {
                Image(MenuBarPresentation.syncFrameName(animationFrame))
            } else {
                Image(presentation.menuBarIconName)
            }
        }
        // フレーム送りは MainActor 上の自前の低 FPS タイマーで行う。
        // 【重要】TimelineView(.animation) を MenuBarExtra のラベルに置いてはならない。
        // その文脈では minimumInterval が効かず、SwiftUI が requestUpdate(after:) を
        // 実質ゼロ間隔で再発火し続け、毎フレーム NSStatusItem の画像差し替え＋Auto Layout
        // 再計算でメインスレッドが 100% スピン→アプリ全体が無応答になる（実機で確認済み）。
        // .task(id:) は isSyncing が変化した時だけ起動/キャンセルされるので、
        // syncing でない間はタイマーが一切回らず CPU を消費しない。
        .task(id: presentation.isSyncing) {
            guard presentation.isSyncing else { return }
            animationFrame = 0  // 同期開始のたびに先頭フレームから（途中フレーム継続を避け挙動を明示）
            let interval = Duration.milliseconds(Int(1000 / Self.syncFPS))
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                animationFrame = (animationFrame + 1) % MenuBarPresentation.syncFrameCount
            }
        }
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
