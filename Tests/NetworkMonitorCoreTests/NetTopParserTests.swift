import XCTest
@testable import NetworkMonitorCore

final class NetTopParserTests: XCTestCase {

    // MARK: - Normal rows

    func testSingleNormalRow() {
        let csv = """
        ,bytes_in,bytes_out,
        Chrome.1234,8200000,420000,
        """
        let samples = NetTopParser.parseSingleSample(csv)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].name, "Chrome")
        XCTAssertEqual(samples[0].pid, 1234)
        XCTAssertEqual(samples[0].bytesIn, 8_200_000)
        XCTAssertEqual(samples[0].bytesOut, 420_000)
    }

    // MARK: - Multiple processes (real nettop -P -x -L 1 capture, trimmed)

    func testMultipleProcessesFromRealCapture() {
        let csv = """
        ,bytes_in,bytes_out,
        launchd.1,0,0,
        syslogd.381,0,34396,
        apsd.387,7081,30704,
        mDNSResponder.478,1302907,211474,
        LogiPluginServi.1742,30049,10316,
        Claude Helper.48732,1133327,2147931,
        Telegram.82954,181449,40856,
        com.twingate.ma.2980,56183745,11259614,
        node.73297,3800,2286,
        """
        let samples = NetTopParser.parseSingleSample(csv)
        XCTAssertEqual(samples.count, 9)

        let byPID = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
        XCTAssertEqual(byPID[1]?.name, "launchd")
        XCTAssertEqual(byPID[478]?.name, "mDNSResponder")
        XCTAssertEqual(byPID[478]?.bytesIn, 1_302_907)
        XCTAssertEqual(byPID[2980]?.name, "com.twingate.ma")
        XCTAssertEqual(byPID[2980]?.bytesIn, 56_183_745)
    }

    // MARK: - Missing / empty values

    func testMissingByteFieldsAreSkippedNotCrashing() {
        let csv = """
        ,bytes_in,bytes_out,
        Chrome.1234,8200000,420000,
        BrokenRow.5555,,
        AnotherGood.999,100,200,
        """
        let samples = NetTopParser.parseSingleSample(csv)
        let names = samples.map { $0.name }
        XCTAssertEqual(names, ["Chrome", "AnotherGood"])
    }

    func testEmptyOutputProducesNoSamples() {
        XCTAssertEqual(NetTopParser.parseSingleSample(""), [])
        XCTAssertEqual(NetTopParser.parseSingleSample("   \n  \n"), [])
    }

    func testHeaderOnlyOutputProducesEmptyList() {
        let csv = ",bytes_in,bytes_out,\n"
        XCTAssertEqual(NetTopParser.parseSingleSample(csv), [])
    }

    // MARK: - Process names containing spaces / parens / dots

    func testProcessNamesWithSpacesAndPunctuation() {
        let csv = """
        ,bytes_in,bytes_out,
        Google Chrome H.77643,2364198,2675025,
        Code Helper (Pl.13988,0,500,
        GitHub Desktop .20193,10,20,
        com.docker.back.987,5081,4072,
        """
        let samples = NetTopParser.parseSingleSample(csv)
        let byPID = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })

        XCTAssertEqual(byPID[77643]?.name, "Google Chrome H")
        XCTAssertEqual(byPID[13988]?.name, "Code Helper (Pl")
        // nettop truncates to 15 chars, which can leave a trailing space
        // before ".pid"; the parser trims it for a cleaner display name.
        XCTAssertEqual(byPID[20193]?.name, "GitHub Desktop")
        // Name itself contains dots; PID must still be parsed as the
        // trailing numeric component only.
        XCTAssertEqual(byPID[987]?.name, "com.docker.back")
    }

    // MARK: - Different byte units (defensive: nettop is run with -x, but
    // parsing should not crash on human-readable suffixes either)

    func testHumanReadableByteUnits() {
        let csv = """
        ,bytes_in,bytes_out,
        Suffixed.1,12.4M,820K,
        Gigs.2,1.2G,3B,
        """
        let samples = NetTopParser.parseSingleSample(csv)
        let byPID = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })

        XCTAssertEqual(byPID[1]?.bytesIn, UInt64(12.4 * 1024 * 1024))
        XCTAssertEqual(byPID[1]?.bytesOut, UInt64(820 * 1024))
        XCTAssertEqual(byPID[2]?.bytesIn, UInt64(1.2 * 1024 * 1024 * 1024))
        XCTAssertEqual(byPID[2]?.bytesOut, 3)
    }

    // MARK: - Processes appearing / disappearing across samples

    func testProcessesAppearingAndDisappearingAcrossSamples() {
        let csv = """
        ,bytes_in,bytes_out,
        A.1,100,100,
        B.2,200,200,
        ,bytes_in,bytes_out,
        A.1,150,120,
        C.3,50,50,
        """
        let blocks = NetTopParser.parseSamples(csv)
        XCTAssertEqual(blocks.count, 2)

        let firstNames = Set(blocks[0].map { $0.name })
        let secondNames = Set(blocks[1].map { $0.name })
        XCTAssertEqual(firstNames, ["A", "B"])
        XCTAssertEqual(secondNames, ["A", "C"]) // B disappeared, C appeared
    }

    // MARK: - Counter reset (a lower value than before is a parser-level
    // non-concern; the parser just reports what it sees, verbatim)

    func testCounterResetIsReportedVerbatim() {
        let csv = """
        ,bytes_in,bytes_out,
        A.1,1000,1000,
        ,bytes_in,bytes_out,
        A.1,10,10,
        """
        let blocks = NetTopParser.parseSamples(csv)
        XCTAssertEqual(blocks[0][0].bytesIn, 1000)
        XCTAssertEqual(blocks[1][0].bytesIn, 10)
    }

    // MARK: - Invalid lines

    func testInvalidLinesAreSkipped() {
        let csv = """
        ,bytes_in,bytes_out,
        this is not a csv row at all
        ,,,
        NoNumbers.42,abc,def,
        Chrome.1234,8200000,420000,
        """
        let samples = NetTopParser.parseSingleSample(csv)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].name, "Chrome")
    }

    func testRowWithoutPIDIsSkipped() {
        let csv = """
        ,bytes_in,bytes_out,
        NoPIDHere,100,200,
        Chrome.1234,8200000,420000,
        """
        let samples = NetTopParser.parseSingleSample(csv)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].name, "Chrome")
    }

    func testNegativeOrGarbagePIDIsSkipped() {
        let csv = """
        ,bytes_in,bytes_out,
        Weird.-5,100,200,
        Chrome.1234,8200000,420000,
        """
        let samples = NetTopParser.parseSingleSample(csv)
        XCTAssertEqual(samples.count, 1)
    }

    // MARK: - macOS output variations (extra "interface" column present)

    func testExtraInterfaceColumnVariation() {
        let csv = """
        ,interface,bytes_in,bytes_out,
        launchd.1,,0,0,
        apsd.387,en0,7081,30704,
        """
        // Our parser only ever requests bytes_in,bytes_out via -J, so this
        // documents that if an extra leading column were ever introduced,
        // rows are still non-crashing (though columns would need to be
        // requested explicitly to be parsed correctly). This test just
        // guards against a crash/hang on unexpected column counts.
        XCTAssertNoThrow(NetTopParser.parseSingleSample(csv))
    }

    func testDefaultColumnHeaderVariationIsRecognizedAsHeader() {
        let csv = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,
        17:24:51.650983,launchd.1,,,0,0,0,
        """
        // The "time,..." header form should be recognized as a header line
        // (not mis-parsed as a process row) even though it lacks a leading
        // comma before "time".
        let blocks = NetTopParser.parseSamples(csv)
        XCTAssertEqual(blocks.count, 1)
    }

    func testTrailingWhitespaceAndBlankLinesAreIgnored() {
        let csv = """

        ,bytes_in,bytes_out,
        Chrome.1234,8200000,420000,


        """
        let samples = NetTopParser.parseSingleSample(csv)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].name, "Chrome")
    }
}
