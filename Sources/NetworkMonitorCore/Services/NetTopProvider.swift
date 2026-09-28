import Foundation

/// Thread-safe accumulator for data arriving from a pipe's readabilityHandler.
/// Reading incrementally (rather than `readDataToEndOfFile()` after the
/// process exits) avoids the classic deadlock where a child process blocks
/// writing to a full pipe buffer while nothing is draining it.
private final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var collected: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Thread-safe "run this only once" latch, used to guard against both the
/// termination handler and the watchdog timer trying to resume the same
/// continuation.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Returns whether the flag had *already* been set before this call.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasAlreadyFired = fired
        fired = true
        return wasAlreadyFired
    }
}

/// Fetches a single-sample, per-process CSV snapshot from `/usr/bin/nettop`
/// and parses it. One short-lived `nettop` process is spawned per call
/// (never a long-running/streaming one) so callers control exactly how
/// often it runs, and a watchdog guarantees it can never hang around
/// indefinitely.
public final class NetTopProvider: NetworkDataProvider, @unchecked Sendable {
    private let executablePath: String
    private let watchdogTimeout: TimeInterval

    public init(executablePath: String = "/usr/bin/nettop", watchdogTimeout: TimeInterval = 5) {
        self.executablePath = executablePath
        self.watchdogTimeout = watchdogTimeout
    }

    public func fetchSamples() async throws -> [NetworkProcessSample] {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw NetworkDataProviderError.toolNotFound(path: executablePath)
        }

        let output = try await runNetTop()
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkDataProviderError.emptyOutput
        }
        return NetTopParser.parseSingleSample(output)
    }

    private func runNetTop() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            // -P: per-process summary only (no per-connection rows)
            // -x: raw byte counts (no "1.2M" style human suffixes)
            // -L 1: CSV logging mode, exactly one sample, then exit
            // -J: only include the two byte-count columns we need
            process.arguments = ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutAccumulator = PipeAccumulator()
            let stderrAccumulator = PipeAccumulator()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stdoutAccumulator.append(chunk) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { stderrAccumulator.append(chunk) }
            }

            let onceFlag = OnceFlag()
            @Sendable func resumeOnce(_ result: Result<String, Error>) {
                let alreadyDone = onceFlag.testAndSet()
                guard !alreadyDone else { return }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            process.terminationHandler = { finishedProcess in
                // Give the readability handlers a moment to drain any final
                // chunk that arrived right at process exit.
                let status = finishedProcess.terminationStatus
                if status != 0 {
                    let stderrString = String(data: stderrAccumulator.collected, encoding: .utf8) ?? ""
                    resumeOnce(.failure(NetworkDataProviderError.nonZeroExit(status: status, stderr: stderrString)))
                    return
                }
                let stdoutString = String(data: stdoutAccumulator.collected, encoding: .utf8) ?? ""
                resumeOnce(.success(stdoutString))
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(NetworkDataProviderError.launchFailed(error.localizedDescription)))
                return
            }

            // Watchdog: nettop should finish in well under a second for a
            // single sample. If it somehow hangs (e.g. system under extreme
            // load), kill it rather than let short-lived processes pile up.
            DispatchQueue.global().asyncAfter(deadline: .now() + watchdogTimeout) {
                if process.isRunning {
                    process.terminate()
                    resumeOnce(.failure(NetworkDataProviderError.launchFailed("nettop timed out after \(self.watchdogTimeout)s")))
                }
            }
        }
    }
}
