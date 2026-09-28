import Foundation
import Combine
import AppKit
import NetworkMonitorCore

/// Thin UI-facing wrapper around `NetworkMonitor`: adds search text and
/// sort-order state, and derives the sorted+filtered rows the table
/// actually renders. All the network/rate logic itself lives in
/// NetworkMonitorCore.
@MainActor
final class AppState: ObservableObject {
    let monitor: NetworkMonitor

    @Published var searchText: String = ""
    /// Defaults to sorting by today's total, descending. Sorting by
    /// instantaneous rate instead (the original default) made the row
    /// order visibly reshuffle almost every refresh tick — network rates
    /// are bursty second to second, so that made "which app used the
    /// most" unreadable. Today's cumulative total only grows, so ranking
    /// by it is far more stable, and it's what answers that question
    /// directly. A name tie-breaker (see `toggleSort`) keeps ordering
    /// fully deterministic even between rows with equal totals.
    @Published var sortOrder: [KeyPathComparator<NetworkProcess>] = [
        KeyPathComparator(\.totalBytes, order: .reverse),
        KeyPathComparator(\.name, order: .forward)
    ]

    /// Icons for the currently-tracked processes, keyed by pid. Resolved
    /// here — outside of NetworkTable's row `body` — because calling
    /// AppKit icon APIs (NSWorkspace/NSRunningApplication) synchronously
    /// from inside a List row's body runs during NSTableView's own
    /// delegate callback, which is exactly the reentrant-AppKit-call
    /// pattern that triggers "reentrant operation in its NSTableView
    /// delegate". Precomputing here and having rows do a plain dictionary
    /// lookup avoids that entirely.
    @Published private(set) var icons: [Int32: NSImage] = [:]

    private var cancellables: Set<AnyCancellable> = []

    init(monitor: NetworkMonitor? = nil) {
        self.monitor = monitor ?? NetworkMonitor()
        // Re-publish AppState's own objectWillChange whenever the monitor
        // changes, so views observing AppState update for monitor data too.
        self.monitor.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                // `objectWillChange` fires *before* the new value lands, so
                // read `monitor.processes` on the next run loop turn
                // (matches NetworkMonitor's own deferred publish of it).
                DispatchQueue.main.async { self?.refreshIcons() }
            }
            .store(in: &cancellables)
    }

    private func refreshIcons() {
        let livePIDs = Set(monitor.processes.map { $0.pid })
        for pid in livePIDs where icons[pid] == nil {
            icons[pid] = ProcessIconProvider.shared.icon(for: pid)
        }
        if icons.count != livePIDs.count || !icons.keys.allSatisfy(livePIDs.contains) {
            icons = icons.filter { livePIDs.contains($0.key) }
        }
    }

    var displayedProcesses: [NetworkProcess] {
        var rows = monitor.processes.filter { $0.hasMeaningfulActivity }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            rows = rows.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
        }

        rows.sort(using: sortOrder)
        return rows
    }

    var sortAscending: Bool {
        sortOrder.first?.order == .forward
    }

    func isSorting(by keyPath: PartialKeyPath<NetworkProcess>) -> Bool {
        sortOrder.first?.keyPath == keyPath
    }

    func toggleSort<V: Comparable>(_ keyPath: KeyPath<NetworkProcess, V>) {
        let isNameColumn = (keyPath as PartialKeyPath<NetworkProcess>) == \NetworkProcess.name
        let primaryOrder: SortOrder
        if isSorting(by: keyPath) {
            primaryOrder = sortAscending ? .reverse : .forward
        } else {
            // Numeric usage columns default to biggest-first; the name
            // column defaults to alphabetical.
            primaryOrder = isNameColumn ? .forward : .reverse
        }
        let primary = KeyPathComparator(keyPath, order: primaryOrder)
        // Always keep a name tie-breaker so rows with equal (or equally
        // fluctuating) values don't visibly reorder at random between
        // refresh ticks. Sorting by name itself needs no tie-breaker.
        sortOrder = isNameColumn ? [primary] : [primary, KeyPathComparator(\NetworkProcess.name, order: .forward)]
    }
}
