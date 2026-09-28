import Foundation

public enum NetworkDataProviderError: Error, LocalizedError, Equatable {
    case toolNotFound(path: String)
    case launchFailed(String)
    case nonZeroExit(status: Int32, stderr: String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let path):
            return "nettop was not found at \(path)."
        case .launchFailed(let reason):
            return "Failed to launch nettop: \(reason)"
        case .nonZeroExit(let status, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "nettop exited with status \(status)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .emptyOutput:
            return "nettop produced no output."
        }
    }
}

/// Abstraction over "a thing that can hand us a fresh snapshot of
/// per-process cumulative network byte counters". `nettop` is the v1
/// implementation; this protocol exists so it can later be swapped for a
/// native API (e.g. NEFilterDataProvider / libpcap) without touching
/// anything above it.
public protocol NetworkDataProvider: Sendable {
    func fetchSamples() async throws -> [NetworkProcessSample]
}
