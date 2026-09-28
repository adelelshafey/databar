import SwiftUI
import NetworkMonitorCore

@main
struct MacNetworkMonitorApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Respect a previously-chosen "Show in Dock" preference (from
        // MenuBarView) right away, rather than defaulting to visible every
        // launch until the user re-toggles it.
        let showDockIcon = (UserDefaults.standard.object(forKey: "showDockIcon") as? Bool) ?? true
        // `NSApplication.shared` (unlike the `NSApp` global) lazily creates
        // the application instance, so it's safe to call this early — the
        // `NSApp` global itself is still nil at App.init() time and crashes.
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    var body: some Scene {
        WindowGroup("Databar", id: "main") {
            ContentView()
                .environmentObject(appState)
                .onAppear { appState.monitor.start() }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 640, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The compact menu bar text: current rates plus today's running total, e.g.
/// "↓ 2.4 MB/s  ↑ 180 KB/s  ·  119 MB today".
private struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let monitor = appState.monitor
        let todayTotal = Formatting.total(monitor.sessionDownloadTotal + monitor.sessionUploadTotal)
        Text("↓ \(Formatting.rate(monitor.totalDownloadRate))  ↑ \(Formatting.rate(monitor.totalUploadRate))  ·  \(todayTotal) today")
    }
}
