import XCTest
@testable import NetworkMonitorCore

/// A scripted `NetworkDataProvider`: each call to `fetchSamples()` returns
/// the next array from `scriptedSamples`, in order. Lets tests drive
/// `NetworkMonitor` through specific appear/disappear/reset scenarios
/// without depending on the real `nettop` or on wall-clock timing.
private actor FakeProvider: NetworkDataProvider {
    private var scriptedSamples: [[NetworkProcessSample]]
    private var index = 0

    init(_ scriptedSamples: [[NetworkProcessSample]]) {
        self.scriptedSamples = scriptedSamples
    }

    func fetchSamples() async throws -> [NetworkProcessSample] {
        guard index < scriptedSamples.count else {
            return scriptedSamples.last ?? []
        }
        defer { index += 1 }
        return scriptedSamples[index]
    }
}

@MainActor
final class NetworkMonitorTests: XCTestCase {

    /// Drives one tick of the monitor manually (bypassing the timer loop)
    /// by calling the same private path indirectly via `start()`+pause()`
    /// is too timing-dependent; instead we reach into the monitor with a
    /// very short refresh interval and poll its published state until it
    /// reflects the expected sample count.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition not met before timeout", file: file, line: line)
    }

    func testAppearingProcessStartsAtZeroThenAccumulates() async {
        let provider = FakeProvider([
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 1_000, bytesOut: 100)],
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 3_000, bytesOut: 300)]
        ])
        let monitor = NetworkMonitor(provider: provider, persistence: InMemorySessionStore(), refreshInterval: 0.05)
        monitor.start()

        await waitUntil { monitor.processes.first?.totalDownload == 2_000 }

        XCTAssertEqual(monitor.processes.first?.name, "Chrome")
        XCTAssertEqual(monitor.processes.first?.totalDownload, 2_000)
        XCTAssertEqual(monitor.processes.first?.totalUpload, 200)
        monitor.pause()
    }

    func testDisappearingProcessDropsToZeroRateButKeepsTotal() async {
        let provider = FakeProvider([
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 1_000, bytesOut: 0)],
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 5_000, bytesOut: 0)],
            [] // Chrome vanished from this sample
        ])
        let monitor = NetworkMonitor(provider: provider, persistence: InMemorySessionStore(), refreshInterval: 0.05)
        monitor.start()

        await waitUntil { monitor.processes.first?.totalDownload == 4_000 }
        await waitUntil { monitor.processes.first?.downloadRate == 0 }

        // Total is preserved even though the process is momentarily absent.
        XCTAssertEqual(monitor.processes.first?.totalDownload, 4_000)
        monitor.pause()
    }

    func testCounterResetDoesNotProduceHugeSpike() async {
        let provider = FakeProvider([
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 1_000_000, bytesOut: 0)],
            // Process restarted with the same pid: counters reset to a
            // small value.
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 500, bytesOut: 0)]
        ])
        let monitor = NetworkMonitor(provider: provider, persistence: InMemorySessionStore(), refreshInterval: 0.05)
        monitor.start()

        await waitUntil { monitor.processes.first?.downloadRate == 0 && (monitor.processes.first?.totalDownload ?? 0) < 1_000_000 }

        // The reset should not have been counted as a ~1MB delta.
        XCTAssertLessThan(monitor.processes.first?.totalDownload ?? .max, 1_000_000)
        monitor.pause()
    }

    func testClearSessionTotalsResetsAccumulatorsOnly() async {
        let provider = FakeProvider([
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 1_000, bytesOut: 500)],
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 4_000, bytesOut: 2_000)]
        ])
        let monitor = NetworkMonitor(provider: provider, persistence: InMemorySessionStore(), refreshInterval: 0.05)
        monitor.start()

        await waitUntil { monitor.sessionDownloadTotal == 3_000 }
        XCTAssertEqual(monitor.sessionUploadTotal, 1_500)

        monitor.clearSessionTotals()
        XCTAssertEqual(monitor.sessionDownloadTotal, 0)
        XCTAssertEqual(monitor.sessionUploadTotal, 0)
        // `processes` is republished via a deferred main-queue hop (to avoid
        // an AppKit Table reentrancy issue), so give it a moment to catch up.
        await waitUntil { monitor.processes.first?.totalDownload == 0 }
        monitor.pause()
    }

    func testPauseStopsRateUpdatesAndResumeContinues() async {
        let provider = FakeProvider([
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 1_000, bytesOut: 0)],
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 2_000, bytesOut: 0)],
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 3_000, bytesOut: 0)],
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 4_000, bytesOut: 0)]
        ])
        let monitor = NetworkMonitor(provider: provider, persistence: InMemorySessionStore(), refreshInterval: 0.05)
        monitor.start()
        XCTAssertTrue(monitor.isMonitoring)

        await waitUntil { monitor.processes.first?.totalDownload ?? 0 > 0 }
        monitor.pause()
        XCTAssertFalse(monitor.isMonitoring)
        // Deferred republish (see above) — wait for it to reflect the pause.
        await waitUntil { monitor.processes.first?.downloadRate == 0 }

        let totalAtPause = monitor.processes.first?.totalDownload ?? 0

        monitor.resume()
        XCTAssertTrue(monitor.isMonitoring)
        await waitUntil { (monitor.processes.first?.totalDownload ?? 0) > totalAtPause }
        monitor.pause()
    }

    func testRefreshIntervalIsClampedToValidRange() {
        let monitor = NetworkMonitor(provider: FakeProvider([]), persistence: InMemorySessionStore(), refreshInterval: 1)
        monitor.refreshInterval = 100
        XCTAssertEqual(monitor.refreshInterval, monitor.maxRefreshInterval)

        monitor.refreshInterval = 0.01
        XCTAssertEqual(monitor.refreshInterval, monitor.minRefreshInterval)
    }

    // MARK: - Session persistence across relaunches

    func testRestoresPersistedSessionFromEarlierTodayOnInit() {
        let now = Date()
        let priorSession = PersistedSession(
            startedAt: Calendar.current.startOfDay(for: now),
            downloadTotal: 42_000,
            uploadTotal: 7_000,
            perProcess: ["Chrome": ProcessDailyTotal(downloadTotal: 42_000, uploadTotal: 7_000)]
        )
        let store = InMemorySessionStore(priorSession)

        let monitor = NetworkMonitor(provider: FakeProvider([]), persistence: store, refreshInterval: 1, now: now)

        XCTAssertEqual(monitor.sessionDownloadTotal, 42_000)
        XCTAssertEqual(monitor.sessionUploadTotal, 7_000)
        XCTAssertEqual(monitor.sessionStartedAt, priorSession.startedAt)
    }

    /// A persisted session from a *previous* day (e.g. the app was quit
    /// yesterday and reopened today) must not be blindly restored — that
    /// would silently mix two days' totals together. It should reset to a
    /// fresh, empty "today" instead.
    func testStalePersistedSessionFromAPreviousDayIsDiscarded() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let staleSession = PersistedSession(startedAt: yesterday, downloadTotal: 999_999, uploadTotal: 999_999)
        let store = InMemorySessionStore(staleSession)

        let monitor = NetworkMonitor(provider: FakeProvider([]), persistence: store, refreshInterval: 1, now: now)

        XCTAssertEqual(monitor.sessionDownloadTotal, 0)
        XCTAssertEqual(monitor.sessionUploadTotal, 0)
        XCTAssertTrue(Calendar.current.isDate(monitor.sessionStartedAt, inSameDayAs: now))
    }

    /// A process that was quit and relaunched mid-day (new pid, same name)
    /// keeps accumulating under one running total instead of resetting.
    func testSameNameDifferentPIDKeepsAccumulatingTodaysTotal() async {
        let provider = FakeProvider([
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 1_000, bytesOut: 0)],
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 4_000, bytesOut: 0)], // +3000, pid 100
            [NetworkProcessSample(name: "Chrome", pid: 200, bytesIn: 500, bytesOut: 0)] // Chrome relaunched as pid 200; baseline only
        ])
        let monitor = NetworkMonitor(provider: provider, persistence: InMemorySessionStore(), refreshInterval: 0.05)
        monitor.start()

        await waitUntil { monitor.processes.first?.totalDownload == 3_000 }

        XCTAssertEqual(monitor.processes.first?.name, "Chrome")
        XCTAssertEqual(monitor.processes.first?.totalDownload, 3_000)
        monitor.pause()
    }

    func testSessionIsPersistedAsItAccumulates() async {
        let store = InMemorySessionStore()
        let provider = FakeProvider([
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 1_000, bytesOut: 0)],
            [NetworkProcessSample(name: "Chrome", pid: 100, bytesIn: 6_000, bytesOut: 0)]
        ])
        let monitor = NetworkMonitor(provider: provider, persistence: store, refreshInterval: 0.05)
        monitor.start()

        await waitUntil { store.loadSession()?.downloadTotal == 5_000 }
        monitor.pause()
    }

    func testClearSessionTotalsPersistsTheReset() async {
        let store = InMemorySessionStore(PersistedSession(startedAt: Date(), downloadTotal: 999, uploadTotal: 999))
        let monitor = NetworkMonitor(provider: FakeProvider([]), persistence: store, refreshInterval: 1)

        monitor.clearSessionTotals()

        XCTAssertEqual(store.loadSession()?.downloadTotal, 0)
        XCTAssertEqual(store.loadSession()?.uploadTotal, 0)
    }

    // MARK: - Same-name processes are merged, not duplicated

    /// Multiple simultaneously-running instances of the same app (e.g.
    /// several `claude` CLI sessions) must appear as ONE row with summed
    /// current rates, not one row per pid — otherwise the shared daily
    /// total looks like it's displayed (and could be misread as counted)
    /// once per duplicate row.
    func testMultipleSimultaneousProcessesWithSameNameAreMergedIntoOneRow() async {
        let provider = FakeProvider([
            [
                NetworkProcessSample(name: "claude", pid: 100, bytesIn: 1_000, bytesOut: 0),
                NetworkProcessSample(name: "claude", pid: 200, bytesIn: 500, bytesOut: 0),
                NetworkProcessSample(name: "claude", pid: 300, bytesIn: 2_000, bytesOut: 0)
            ],
            [
                NetworkProcessSample(name: "claude", pid: 100, bytesIn: 3_000, bytesOut: 0), // +2000
                NetworkProcessSample(name: "claude", pid: 200, bytesIn: 1_500, bytesOut: 0), // +1000
                NetworkProcessSample(name: "claude", pid: 300, bytesIn: 2_000, bytesOut: 0)  // +0
            ]
        ])
        let monitor = NetworkMonitor(provider: provider, persistence: InMemorySessionStore(), refreshInterval: 0.05)
        monitor.start()

        await waitUntil { monitor.processes.count == 1 && monitor.processes.first?.totalDownload == 3_000 }

        XCTAssertEqual(monitor.processes.count, 1, "three pids sharing a name must collapse into a single row")
        XCTAssertEqual(monitor.processes.first?.name, "claude")
        XCTAssertEqual(monitor.processes.first?.totalDownload, 3_000) // 2000 + 1000 + 0, summed once
        monitor.pause()
    }
}
