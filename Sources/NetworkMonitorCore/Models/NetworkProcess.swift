import Foundation

/// UI/domain-facing view of a process's network activity, combining the latest
/// instantaneous rate with running session totals.
///
/// Identity is the process *name*, not pid: several running instances of
/// the same app (e.g. multiple CLI sessions of the same tool) are merged
/// into a single row with summed rates, rather than shown as separate
/// duplicate-looking rows that would each display the same shared daily
/// total. `pid` is kept as a representative instance for things like icon
/// lookup, but isn't unique across a session.
public struct NetworkProcess: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { name }

    public let pid: Int32
    public let name: String
    public var downloadRate: Double   // bytes/sec
    public var uploadRate: Double     // bytes/sec
    public var totalDownload: UInt64  // bytes, this session
    public var totalUpload: UInt64    // bytes, this session

    public init(
        pid: Int32,
        name: String,
        downloadRate: Double,
        uploadRate: Double,
        totalDownload: UInt64,
        totalUpload: UInt64
    ) {
        self.pid = pid
        self.name = name
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.totalDownload = totalDownload
        self.totalUpload = totalUpload
    }

    /// Whether this process has done anything worth showing this session.
    public var hasMeaningfulActivity: Bool {
        let minRate = 1024.0 // 1 KB/s
        let minTotal: UInt64 = 1024 // 1 KB
        return downloadRate >= minRate
            || uploadRate >= minRate
            || totalDownload >= minTotal
            || totalUpload >= minTotal
    }

    /// Combined instantaneous rate, used as the default "current network
    /// usage" sort key.
    public var currentTotalRate: Double { downloadRate + uploadRate }

    /// Combined session total, used for the "Total" sort column.
    public var totalBytes: UInt64 { totalDownload + totalUpload }
}
