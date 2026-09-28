import Foundation

/// Pure counter-delta-over-elapsed-time rate math, kept free of any
/// `nettop`/process concerns so it can be unit tested in isolation.
public enum RateCalculator {

    /// Result of comparing a previous and current cumulative counter.
    public struct DeltaResult: Equatable {
        /// Bytes transferred since the previous sample. Always >= 0.
        public let deltaBytes: UInt64
        /// Bytes per second implied by that delta and the elapsed time.
        public let rate: Double
        /// True if the counter went backwards (process restarted, counter
        /// wrapped, etc.) and the delta was therefore treated as a fresh
        /// baseline (0) rather than a huge bogus spike.
        public let wasReset: Bool

        public init(deltaBytes: UInt64, rate: Double, wasReset: Bool) {
            self.deltaBytes = deltaBytes
            self.rate = rate
            self.wasReset = wasReset
        }
    }

    /// Computes the delta and rate between two cumulative counter readings.
    ///
    /// - Parameters:
    ///   - previous: The counter value at the previous sample.
    ///   - current: The counter value now.
    ///   - elapsedSeconds: Wall-clock time between the two samples.
    /// - Returns: The delta bytes and the implied rate. If `current` is less
    ///   than `previous` (a counter reset), the delta is reported as 0
    ///   instead of underflowing/spiking.
    public static func delta(previous: UInt64, current: UInt64, elapsedSeconds: Double) -> DeltaResult {
        guard current >= previous else {
            return DeltaResult(deltaBytes: 0, rate: 0, wasReset: true)
        }
        let deltaBytes = current - previous
        let rate = self.rate(deltaBytes: deltaBytes, elapsedSeconds: elapsedSeconds)
        return DeltaResult(deltaBytes: deltaBytes, rate: rate, wasReset: false)
    }

    /// bytes / seconds, guarding against a zero or negative interval.
    public static func rate(deltaBytes: UInt64, elapsedSeconds: Double) -> Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(deltaBytes) / elapsedSeconds
    }
}
