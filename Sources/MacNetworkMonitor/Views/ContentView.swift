import SwiftUI
import NetworkMonitorCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingClearConfirmation = false

    private var monitor: NetworkMonitor { appState.monitor }

    private var refreshIntervalBinding: Binding<Double> {
        Binding(
            get: { monitor.refreshInterval },
            set: { monitor.refreshInterval = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            NetworkSummary()
                .padding(.horizontal)
                .padding(.top, 12)

            if let error = monitor.lastError {
                errorBanner(error)
            }

            searchAndControls

            NetworkTable()
                .padding(.horizontal)
                .padding(.top, 4)

            Divider()
            sessionFooter
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Text("Databar")
                .font(.title2.bold())
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isMonitoring ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(monitor.isMonitoring ? "Monitoring" : "Paused")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var searchAndControls: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter processes", text: $appState.searchText)
                .textFieldStyle(.plain)

            Spacer()

            Stepper(value: refreshIntervalBinding, in: monitor.minRefreshInterval...monitor.maxRefreshInterval, step: 0.5) {
                Text("Refresh: \(monitor.refreshInterval, specifier: "%.1f")s")
                    .font(.callout)
                    .frame(width: 100, alignment: .leading)
            }

            Button {
                monitor.isMonitoring ? monitor.pause() : monitor.resume()
            } label: {
                Image(systemName: monitor.isMonitoring ? "pause.fill" : "play.fill")
            }
            .help(monitor.isMonitoring ? "Pause monitoring" : "Resume monitoring")

            Button {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear today's totals")
            .confirmationDialog(
                "Clear today's totals?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { monitor.clearSessionTotals() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This resets today's download/upload totals, overall and per app. It won't affect current rates.")
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }

    private var sessionFooter: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today")
                    .font(.headline)
                Text("since \(monitor.sessionStartedAt, format: .dateTime.hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // Combined total first — this is the number directly
                // comparable to each app's "Today" column (which is also
                // download+upload combined), avoiding the confusing
                // "an app's total looks bigger than the overall total"
                // read you get from only glancing at one of the two split
                // numbers below.
                Text(Formatting.total(monitor.sessionDownloadTotal + monitor.sessionUploadTotal))
                    .font(.headline)
                    .monospacedDigit()
                HStack(spacing: 10) {
                    Label(Formatting.total(monitor.sessionDownloadTotal), systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                    Label(Formatting.total(monitor.sessionUploadTotal), systemImage: "arrow.up")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
        .padding()
    }
}
