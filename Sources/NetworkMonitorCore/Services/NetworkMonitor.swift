import Foundation
import Combine

/// Orchestrates polling a `NetworkDataProvider` on a timer, turning
/// successive cumulative-counter snapshots into per-process rates and
/// running session totals. This is the piece that owns "correctly
/// calculate rates using counter deltas and elapsed time", "handle
/// processes appearing/disappearing", and "handle counter resets" — kept
/// independent of any provider implementation detail and independent of
/// SwiftUI so it can be driven and tested with a fake provider.
@MainActor
public final class NetworkMonitor: ObservableObject {

    @Published public private(set) var processes: [NetworkProcess] = []
    @Published public private(set) var totalDownloadRate: Double = 0
    @Published public private(set) var totalUploadRate: Double = 0
    /// Today's totals, overall across every process. Restored from disk on
    /// launch — quitting and reopening the app doesn't lose today's count —
    /// and automatically rolled over to zero at the next local midnight, so
    /// this always answers "how much have I used today", not just "since I
    /// last opened the monitor". `clearSessionTotals()` also resets it early.
    @Published public private(set) var sessionDownloadTotal: UInt64 = 0
    @Published public private(set) var sessionUploadTotal: UInt64 = 0
    /// Start of the day these totals cover.
    @Published public private(set) var sessionStartedAt: Date = Date()
    @Published public private(set) var isMonitoring: Bool = false
    @Published public private(set) var lastError: String?

    /// Seconds between samples. Clamped to a sane range so the UI can't be
    /// configured into hammering the system or freezing entirely.
    @Published public var refreshInterval: TimeInterval {
        didSet {
            let clamped = min(max(refreshInterval, minRefreshInterval), maxRefreshInterval)
            if clamped != refreshInterval {
                refreshInterval = clamped
                return
            }
            if isMonitoring { scheduleLoop() }
        }
    }

    public let minRefreshInterval: TimeInterval = 0.5
    public let maxRefreshInterval: TimeInterval = 30

    private let provider: NetworkDataProvider
    private let persistence: SessionPersistenceStore
    private let staleTickLimit = 10

    private var pollTask: Task<Void, Never>?
    private var trackers: [Int32: Tracker] = [:]
    /// Today's per-process totals, keyed by process *name* (not pid) so an
    /// app quit and reopened mid-day keeps accumulating under one total
    /// instead of silently starting over. This is what `NetworkProcess.
    /// totalDownload/totalUpload` is actually built from.
    private var dailyTotals: [String: ProcessDailyTotal] = [:]
    private var lastSampleTime: Date?
    private var tick = 0
    private var calendar = Calendar.current

    private struct Tracker {
        var name: String
        var bytesIn: UInt64
        var bytesOut: UInt64
        var currentDownloadRate: Double
        var currentUploadRate: Double
        var lastSeenTick: Int
    }

    public init(
        provider: NetworkDataProvider = NetTopProvider(),
        persistence: SessionPersistenceStore = UserDefaultsSessionStore(),
        refreshInterval: TimeInterval = 1.0,
        now: Date = Date()
    ) {
        self.provider = provider
        self.persistence = persistence
        self.refreshInterval = min(max(refreshInterval, 0.5), 30)

        if let saved = persistence.loadSession(), calendar.isDate(saved.startedAt, inSameDayAs: now) {
            self.sessionStartedAt = saved.startedAt
            self.sessionDownloadTotal = saved.downloadTotal
            self.sessionUploadTotal = saved.uploadTotal
            self.dailyTotals = saved.perProcess
        } else {
            // No saved data, or it's from a previous day: start today fresh.
            self.sessionStartedAt = calendar.startOfDay(for: now)
        }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastSampleTime = nil
        scheduleLoop()
    }

    public func pause() {
        isMonitoring = false
        pollTask?.cancel()
        pollTask = nil
        // Zero out instantaneous rates so the UI doesn't show stale motion
        // while paused; totals and baselines are preserved.
        for pid in trackers.keys {
            trackers[pid]?.currentDownloadRate = 0
            trackers[pid]?.currentUploadRate = 0
        }
        totalDownloadRate = 0
        totalUploadRate = 0
        rebuildProcessList()
    }

    public func resume() {
        start()
    }

    public func clearSessionTotals() {
        sessionDownloadTotal = 0
        sessionUploadTotal = 0
        sessionStartedAt = calendar.startOfDay(for: Date())
        dailyTotals.removeAll()
        persistSession()
        rebuildProcessList()
    }

    // MARK: - Polling loop

    private func scheduleLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tickOnce()
                guard !Task.isCancelled else { return }
                let nanos = UInt64(self.refreshInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    private func tickOnce() async {
        let now = Date()
        do {
            let samples = try await provider.fetchSamples()
            // `pause()` may have run while we were awaiting the fetch; drop
            // this now-stale result instead of reviving rates/totals after
            // the user asked us to stop.
            guard isMonitoring else { return }
            lastError = nil
            applySamples(samples, at: now)
        } catch {
            guard isMonitoring else { return }
            // Transient failures (a single bad nettop run, a permission
            // hiccup) shouldn't crash the app or wipe the last-known table;
            // just surface the error and try again next tick.
            lastError = error.localizedDescription
        }
    }

    // MARK: - Delta / rate application

    private func applySamples(_ samples: [NetworkProcessSample], at now: Date) {
        rolloverIfNewDay(now: now)

        tick += 1
        let elapsed: Double = lastSampleTime.map { now.timeIntervalSince($0) } ?? 0
        lastSampleTime = now

        var seenPIDs = Set<Int32>()
        var tickDownloadDelta: UInt64 = 0
        var tickUploadDelta: UInt64 = 0

        for sample in samples {
            seenPIDs.insert(sample.pid)

            if var existing = trackers[sample.pid], existing.name == sample.name {
                let inDelta = RateCalculator.delta(previous: existing.bytesIn, current: sample.bytesIn, elapsedSeconds: elapsed)
                let outDelta = RateCalculator.delta(previous: existing.bytesOut, current: sample.bytesOut, elapsedSeconds: elapsed)

                existing.bytesIn = sample.bytesIn
                existing.bytesOut = sample.bytesOut
                existing.currentDownloadRate = inDelta.rate
                existing.currentUploadRate = outDelta.rate
                existing.lastSeenTick = tick
                trackers[sample.pid] = existing

                if inDelta.deltaBytes > 0 || outDelta.deltaBytes > 0 {
                    var daily = dailyTotals[sample.name] ?? ProcessDailyTotal(downloadTotal: 0, uploadTotal: 0)
                    daily.downloadTotal += inDelta.deltaBytes
                    daily.uploadTotal += outDelta.deltaBytes
                    dailyTotals[sample.name] = daily
                }

                tickDownloadDelta += inDelta.deltaBytes
                tickUploadDelta += outDelta.deltaBytes
            } else {
                // First time we've seen this pid (new process, or the pid
                // was recycled for a differently-named process). We only
                // have a single cumulative reading, so there's no delta to
                // report yet — this sample becomes the rate baseline. Its
                // name may already have accumulated totals today from a
                // previous pid instance (see `dailyTotals`), which is kept.
                trackers[sample.pid] = Tracker(
                    name: sample.name,
                    bytesIn: sample.bytesIn,
                    bytesOut: sample.bytesOut,
                    currentDownloadRate: 0,
                    currentUploadRate: 0,
                    lastSeenTick: tick
                )
            }
        }

        // A process missing from this sample (socket closed, still running
        // quietly, or about to disappear entirely) has no fresh delta.
        for pid in trackers.keys where !seenPIDs.contains(pid) {
            trackers[pid]?.currentDownloadRate = 0
            trackers[pid]?.currentUploadRate = 0
        }

        // Garbage-collect processes that have been gone for a while so a
        // long-running session doesn't accumulate an ever-growing dead list.
        // (Their totals live on in `dailyTotals`, keyed by name, so nothing
        // is lost — only the pid-scoped rate tracker is dropped.)
        let staleBefore = tick - staleTickLimit
        trackers = trackers.filter { $0.value.lastSeenTick > staleBefore }

        sessionDownloadTotal += tickDownloadDelta
        sessionUploadTotal += tickUploadDelta
        totalDownloadRate = RateCalculator.rate(deltaBytes: tickDownloadDelta, elapsedSeconds: elapsed)
        totalUploadRate = RateCalculator.rate(deltaBytes: tickUploadDelta, elapsedSeconds: elapsed)

        if tickDownloadDelta > 0 || tickUploadDelta > 0 {
            persistSession()
        }

        rebuildProcessList()
    }

    /// If wall-clock time has crossed local midnight since totals started
    /// accumulating, reset today's totals rather than silently mixing two
    /// days' usage together. Handles the machine sleeping across midnight
    /// fine, since this compares real dates, not elapsed tick count.
    private func rolloverIfNewDay(now: Date) {
        guard !calendar.isDate(sessionStartedAt, inSameDayAs: now) else { return }
        sessionDownloadTotal = 0
        sessionUploadTotal = 0
        sessionStartedAt = calendar.startOfDay(for: now)
        dailyTotals.removeAll()
        persistSession()
    }

    private func persistSession() {
        persistence.saveSession(
            PersistedSession(
                startedAt: sessionStartedAt,
                downloadTotal: sessionDownloadTotal,
                uploadTotal: sessionUploadTotal,
                perProcess: dailyTotals
            )
        )
    }

    private func rebuildProcessList() {
        // Several running instances of the same app (multiple CLI sessions,
        // helper processes, etc.) share one name and therefore one daily
        // total — merge them into a single row with summed current rates
        // instead of showing duplicate-looking rows that would each
        // display that same shared total redundantly.
        struct Aggregate {
            var downloadRate: Double = 0
            var uploadRate: Double = 0
            var representativePID: Int32
        }
        var aggregates: [String: Aggregate] = [:]
        for (pid, t) in trackers {
            var entry = aggregates[t.name] ?? Aggregate(representativePID: pid)
            entry.downloadRate += t.currentDownloadRate
            entry.uploadRate += t.currentUploadRate
            aggregates[t.name] = entry
        }

        let newProcesses = aggregates.map { name, aggregate -> NetworkProcess in
            let daily = dailyTotals[name]
            return NetworkProcess(
                pid: aggregate.representativePID,
                name: name,
                downloadRate: aggregate.downloadRate,
                uploadRate: aggregate.uploadRate,
                totalDownload: daily?.downloadTotal ?? 0,
                totalUpload: daily?.uploadTotal ?? 0
            )
        }
        // Deferring to the next run loop turn (rather than assigning
        // @Published synchronously here) avoids SwiftUI's Table/NSTableView
        // occasionally reporting a "reentrant operation" when a data update
        // lands while it's still mid-layout from the previous one.
        DispatchQueue.main.async { [weak self] in
            self?.processes = newProcesses
        }
    }
}
