import XCTest
@testable import NetworkMonitorCore

final class RateCalculatorTests: XCTestCase {

    private let mb: UInt64 = 1024 * 1024

    // The exact example from the spec:
    // previous = 100 MB, current = 120 MB, elapsed = 2s -> rate = 10 MB/s
    func testSpecExample() {
        let result = RateCalculator.delta(previous: 100 * mb, current: 120 * mb, elapsedSeconds: 2)
        XCTAssertEqual(result.deltaBytes, 20 * mb)
        XCTAssertEqual(result.rate, 10 * Double(mb), accuracy: 0.001)
        XCTAssertFalse(result.wasReset)
    }

    func testZeroElapsedProducesZeroRateButStillTracksDelta() {
        let result = RateCalculator.delta(previous: 100, current: 300, elapsedSeconds: 0)
        XCTAssertEqual(result.deltaBytes, 200)
        XCTAssertEqual(result.rate, 0)
        XCTAssertFalse(result.wasReset)
    }

    func testNegativeElapsedIsTreatedAsZero() {
        let result = RateCalculator.delta(previous: 100, current: 300, elapsedSeconds: -1)
        XCTAssertEqual(result.rate, 0)
    }

    func testEqualCountersMeanZeroDelta() {
        let result = RateCalculator.delta(previous: 500, current: 500, elapsedSeconds: 1)
        XCTAssertEqual(result.deltaBytes, 0)
        XCTAssertEqual(result.rate, 0)
        XCTAssertFalse(result.wasReset)
    }

    // Counter reset: current < previous (process restarted, counter
    // wrapped, or pid reused) must never underflow or produce a bogus spike.
    func testCounterResetIsDetectedAndDoesNotUnderflow() {
        let result = RateCalculator.delta(previous: 1_000_000, current: 100, elapsedSeconds: 1)
        XCTAssertEqual(result.deltaBytes, 0)
        XCTAssertEqual(result.rate, 0)
        XCTAssertTrue(result.wasReset)
    }

    func testResetToExactlyZero() {
        let result = RateCalculator.delta(previous: 500, current: 0, elapsedSeconds: 1)
        XCTAssertTrue(result.wasReset)
        XCTAssertEqual(result.deltaBytes, 0)
    }

    func testFractionalElapsedSeconds() {
        // 500 bytes over half a second = 1000 bytes/sec
        let result = RateCalculator.delta(previous: 0, current: 500, elapsedSeconds: 0.5)
        XCTAssertEqual(result.rate, 1000, accuracy: 0.001)
    }

    func testRateHelperDirectly() {
        XCTAssertEqual(RateCalculator.rate(deltaBytes: 2048, elapsedSeconds: 1), 2048)
        XCTAssertEqual(RateCalculator.rate(deltaBytes: 2048, elapsedSeconds: 2), 1024)
        XCTAssertEqual(RateCalculator.rate(deltaBytes: 2048, elapsedSeconds: 0), 0)
    }
}
