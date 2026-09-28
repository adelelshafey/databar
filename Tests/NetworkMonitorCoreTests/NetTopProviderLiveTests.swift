import XCTest
@testable import NetworkMonitorCore

/// Exercises the real `/usr/bin/nettop` on whatever Mac runs the test suite
/// (per the project's "debug against actual output, don't invent formats"
/// requirement). Skips itself gracefully if nettop isn't present rather
/// than failing CI on a machine without it.
final class NetTopProviderLiveTests: XCTestCase {

    func testLiveNetTopProducesParseableSamples() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop") else {
            throw XCTSkip("nettop not available on this machine")
        }

        let provider = NetTopProvider()
        let samples = try await provider.fetchSamples()

        // Any running macOS system has at least launchd (pid 1) with an
        // entry in nettop's per-process summary.
        XCTAssertFalse(samples.isEmpty, "expected at least one process row from live nettop")

        for sample in samples {
            XCTAssertFalse(sample.name.isEmpty)
            XCTAssertGreaterThan(sample.pid, 0)
        }

        // pid 1 (launchd) should always be present.
        XCTAssertTrue(samples.contains { $0.pid == 1 })
    }

    func testMissingExecutableThrowsToolNotFound() async {
        let provider = NetTopProvider(executablePath: "/usr/bin/definitely-not-nettop")
        do {
            _ = try await provider.fetchSamples()
            XCTFail("expected toolNotFound error")
        } catch let error as NetworkDataProviderError {
            XCTAssertEqual(error, .toolNotFound(path: "/usr/bin/definitely-not-nettop"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
