import SwiftUI
import NetworkMonitorCore

/// Renders the process rows as a `List` rather than SwiftUI's `Table`.
/// `Table` on macOS has a known AppKit-bridging issue where frequent full
/// data-source updates (exactly what a 1s auto-refresh does) can trigger
/// "reentrant operation in its NSTableView delegate" warnings; `List`
/// handles rapid whole-array replacement far more gracefully.
struct NetworkTable: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()

            if appState.displayedProcesses.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                List(appState.displayedProcesses) { process in
                    row(for: process)
                }
                .listStyle(.plain)
                // SwiftUI's default implicit animation on List row
                // insert/remove (which happens on every refresh tick where
                // a process crosses the "meaningful activity" threshold)
                // is what collides with AppKit's NSTableView reentrancy
                // guard, producing the "reentrant operation" warning.
                // Disabling it here is the documented workaround.
                .transaction { $0.animation = nil }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            sortableHeader("Process", keyPath: \.name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortableHeader("Download", keyPath: \.downloadRate, alignment: .trailing)
                .frame(width: 110, alignment: .trailing)
            sortableHeader("Upload", keyPath: \.uploadRate, alignment: .trailing)
                .frame(width: 110, alignment: .trailing)
            sortableHeader("Today", keyPath: \.totalBytes, alignment: .trailing)
                .frame(width: 100, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func sortableHeader<V: Comparable>(
        _ title: String,
        keyPath: KeyPath<NetworkProcess, V>,
        alignment: Alignment
    ) -> some View {
        Button {
            appState.toggleSort(keyPath)
        } label: {
            HStack(spacing: 2) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                if appState.isSorting(by: keyPath) {
                    Image(systemName: appState.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
        }
        .buttonStyle(.plain)
    }

    private func row(for process: NetworkProcess) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                iconView(for: process.pid)
                    .frame(width: 16, height: 16)
                Text(process.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Formatting.rate(process.downloadRate))
                .monospacedDigit()
                .foregroundStyle(.blue)
                .frame(width: 110, alignment: .trailing)

            Text(Formatting.rate(process.uploadRate))
                .monospacedDigit()
                .foregroundStyle(.orange)
                .frame(width: 110, alignment: .trailing)

            Text(Formatting.total(process.totalDownload + process.totalUpload))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 2)
    }

    /// A plain dictionary lookup — never resolves an icon itself. If it's
    /// not cached yet (this pid was only just discovered), a static SF
    /// Symbol placeholder is shown for that one frame instead of triggering
    /// an AppKit icon lookup from within the row body.
    @ViewBuilder
    private func iconView(for pid: Int32) -> some View {
        if let icon = appState.icons[pid] {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(appState.searchText.isEmpty ? "No active network usage yet" : "No processes match \"\(appState.searchText)\"")
                .foregroundStyle(.secondary)
        }
    }
}
