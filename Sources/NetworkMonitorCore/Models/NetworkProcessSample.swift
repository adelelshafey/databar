import Foundation

/// One raw reading for a single process, as parsed directly from a data source
/// (e.g. `nettop`). Byte counts are cumulative counters, not deltas.
public struct NetworkProcessSample: Equatable, Hashable, Sendable {
    public let name: String
    public let pid: Int32
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(name: String, pid: Int32, bytesIn: UInt64, bytesOut: UInt64) {
        self.name = name
        self.pid = pid
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}
