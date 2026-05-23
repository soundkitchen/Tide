import SwiftUI

@main
struct TideApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(environment)
        } label: {
            Image(systemName: "icloud.and.arrow.up")
        }
        .menuBarExtraStyle(.window)

        Window("Tide Settings", id: "settings") {
            SettingsWindow()
                .environment(environment)
                .frame(minWidth: 480, minHeight: 360)
        }
        .windowResizability(.contentSize)

        Window("Tide Setup", id: "setup") {
            SetupWizardWindow()
                .environment(environment)
                .frame(width: 540, height: 420)
        }
        .windowResizability(.contentSize)
    }
}
