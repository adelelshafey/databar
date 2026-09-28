import SwiftUI
import NetworkMonitorCore

struct NetworkSummary: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 32) {
                summaryItem(
                    systemImage: "arrow.down",
                    color: .blue,
                    value: Formatting.rate(appState.monitor.totalDownloadRate)
                )
                summaryItem(
                    systemImage: "arrow.up",
                    color: .orange,
                    value: Formatting.rate(appState.monitor.totalUploadRate)
                )
                Spacer()
            }
        }
    }

    private func summaryItem(systemImage: String, color: Color, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
    }
}
