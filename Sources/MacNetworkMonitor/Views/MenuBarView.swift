import SwiftUI
import NetworkMonitorCore

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showDockIcon") private var showDockIcon: Bool = true
    @ObservedObject private var loginItems = LoginItemManager.shared

    private var topProcesses: [NetworkProcess] {
        Array(appState.displayedProcesses.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(Formatting.rate(appState.monitor.totalDownloadRate), systemImage: "arrow.down")
                    .foregroundStyle(.blue)
                Spacer()
                Label(Formatting.rate(appState.monitor.totalUploadRate), systemImage: "arrow.up")
                    .foregroundStyle(.orange)
            }
            .font(.system(.body, design: .rounded).weight(.semibold))

            HStack {
                Text("Today")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Formatting.total(appState.monitor.sessionDownloadTotal + appState.monitor.sessionUploadTotal))
                    .fontWeight(.medium)
            }
            .font(.caption)

            Divider()

            if topProcesses.isEmpty {
                Text("No active network usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(topProcesses) { process in
                        HStack(spacing: 6) {
                            if let icon = appState.icons[process.pid] {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "app.dashed").resizable().frame(width: 14, height: 14).foregroundStyle(.tertiary)
                            }
                            Text(process.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(Formatting.rate(process.downloadRate + process.uploadRate))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Databar", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Toggle(isOn: $showDockIcon) {
                Text("Show in Dock")
            }
            .toggleStyle(.checkbox)
            .onChange(of: showDockIcon) { newValue in
                NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                if newValue {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            Toggle(isOn: Binding(
                get: { loginItems.isEnabled },
                set: { loginItems.setEnabled($0) }
            )) {
                Text("Launch at Login")
            }
            .toggleStyle(.checkbox)
            .help("For accurate daily totals, the app needs to be running. This starts it automatically at login.")

            if let loginError = loginItems.lastError {
                Text(loginError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 260)
    }
}
