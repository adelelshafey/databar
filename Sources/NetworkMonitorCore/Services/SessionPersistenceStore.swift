import Foundation

/// One process's running total for the current day, keyed by name (not
/// pid) so it survives that process being quit and relaunched — e.g.
/// closing and reopening Chrome mid-day keeps accumulating under "Chrome"
/// rather than starting a fresh, invisible-to-you total.
public struct ProcessDailyTotal: Codable, Equatable, Sendable {
    public var downloadTotal: UInt64
    public var uploadTotal: UInt64

    public init(downloadTotal: UInt64, uploadTotal: UInt64) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
    }
}

/// A snapshot of today's usage worth remembering across app relaunches —
/// inspired by TripMode keeping usage history rather than resetting to zero
/// every time you reopen it. Automatically rolls over at midnight (see
/// `NetworkMonitor`), so this answers "how much have I used today, overall
/// and per app" rather than just "since I last opened the monitor".
public struct PersistedSession: Codable, Equatable, Sendable {
    /// Start of the day this snapshot covers (used to detect day rollover).
    public var startedAt: Date
    public var downloadTotal: UInt64
    public var uploadTotal: UInt64
    /// Per-process totals for that same day, keyed by process name.
    public var perProcess: [String: ProcessDailyTotal]

    public init(
        startedAt: Date,
        downloadTotal: UInt64,
        uploadTotal: UInt64,
        perProcess: [String: ProcessDailyTotal] = [:]
    ) {
        self.startedAt = startedAt
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.perProcess = perProcess
    }
}

/// Abstraction over "somewhere to remember today's usage between launches",
/// kept as a protocol (like `NetworkDataProvider`) so `NetworkMonitor` stays
/// unit-testable without touching real `UserDefaults`.
public protocol SessionPersistenceStore: Sendable {
    func loadSession() -> PersistedSession?
    func saveSession(_ session: PersistedSession)
}

/// Default `UserDefaults`-backed store. A day's usage data is small (a
/// couple hundred processes at most), so a full database is unnecessary —
/// a single encoded value is plenty.
public final class UserDefaultsSessionStore: SessionPersistenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.databar.session") {
        self.defaults = defaults
        self.key = key
    }

    public func loadSession() -> PersistedSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    public func saveSession(_ session: PersistedSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: key)
    }
}

/// No-op store for tests/previews that shouldn't touch real UserDefaults or
/// carry state between runs.
public final class InMemorySessionStore: SessionPersistenceStore, @unchecked Sendable {
    private var stored: PersistedSession?
    public init(_ initial: PersistedSession? = nil) { self.stored = initial }
    public func loadSession() -> PersistedSession? { stored }
    public func saveSession(_ session: PersistedSession) { stored = session }
}
