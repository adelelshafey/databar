import Foundation

enum Formatting {
    private static let countFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    /// e.g. "12.4 MB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 KB/s" }
        let bytes = Int64(bytesPerSecond.rounded())
        return countFormatter.string(fromByteCount: bytes) + "/s"
    }

    /// e.g. "1.42 GB"
    static func total(_ bytes: UInt64) -> String {
        countFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}
