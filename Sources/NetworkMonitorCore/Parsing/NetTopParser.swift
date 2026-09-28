import Foundation

/// Parses the CSV produced by `nettop -P -x -L <n> -J bytes_in,bytes_out`.
///
/// Expected shape (per sample):
/// ```
/// ,bytes_in,bytes_out,
/// launchd.1,0,0,
/// Google Chrome H.77643,2364198,2675025,
/// ```
///
/// The parser is intentionally defensive: `nettop`'s exact column layout can
/// vary slightly across macOS versions and flags, so it never assumes a fixed
/// number of columns or trusts the header. Unparseable lines are skipped
/// rather than thrown, so a single malformed row never brings down a sample.
public enum NetTopParser {

    /// Splits a full `nettop` CSV blob (potentially containing multiple
    /// concatenated samples, each starting with its own header line) into
    /// one array of samples per block, in order.
    public static func parseSamples(_ output: String) -> [[NetworkProcessSample]] {
        var blocks: [[NetworkProcessSample]] = []
        var current: [NetworkProcessSample] = []
        var sawAnyLineInBlock = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if isHeaderLine(line) {
                if sawAnyLineInBlock {
                    blocks.append(current)
                }
                current = []
                sawAnyLineInBlock = true
                continue
            }

            if let sample = parseRow(line) {
                current.append(sample)
            }
            // Malformed rows are silently skipped (requirement: never crash
            // on unexpected/invalid lines).
        }

        if sawAnyLineInBlock {
            blocks.append(current)
        }

        return blocks
    }

    /// Convenience for callers that only ever request a single sample
    /// (`-L 1`): returns the last complete block, or an empty array.
    public static func parseSingleSample(_ output: String) -> [NetworkProcessSample] {
        parseSamples(output).last ?? []
    }

    // MARK: - Line classification

    private static func isHeaderLine(_ line: String) -> Bool {
        // Header lines look like ",bytes_in,bytes_out," or
        // ",interface,bytes_in,bytes_out," or the default-column header
        // ("time,,interface,state,bytes_in,...").  They never represent a
        // real process row because a process row's first field is always
        // "name.pid" (no leading comma, and never literally "time").
        guard let firstField = line.split(separator: ",", omittingEmptySubsequences: false).first else {
            return false
        }
        if line.hasPrefix(",") { return true }
        if firstField == "time" { return true }
        return false
    }

    // MARK: - Row parsing

    /// A trailing ".<digits>" is the PID; everything before it is the
    /// (possibly truncated to 15 chars, possibly containing spaces or dots)
    /// process name.
    private static let nameAndPIDRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^(.+)\.(\d+)$"#)
    }()

    private static func parseRow(_ line: String) -> NetworkProcessSample? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Need at least: name.pid, bytes_in, bytes_out
        guard fields.count >= 3 else { return nil }

        let nameField = fields[0]
        guard !nameField.isEmpty else { return nil }

        guard let (name, pid) = splitNameAndPID(nameField) else { return nil }

        // Columns after the name are positional per the -J list we request
        // (bytes_in, bytes_out, [interface]); we only ever ask for
        // bytes_in,bytes_out so they are fields[1] and fields[2].
        guard let bytesIn = parseByteCount(fields[1]),
              let bytesOut = parseByteCount(fields[2]) else {
            return nil
        }

        return NetworkProcessSample(name: name, pid: pid, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    private static func splitNameAndPID(_ field: String) -> (name: String, pid: Int32)? {
        let range = NSRange(field.startIndex..<field.endIndex, in: field)
        guard let match = nameAndPIDRegex.firstMatch(in: field, range: range),
              let nameRange = Range(match.range(at: 1), in: field),
              let pidRange = Range(match.range(at: 2), in: field) else {
            return nil
        }
        let name = String(field[nameRange]).trimmingCharacters(in: .whitespaces)
        guard let pid = Int32(field[pidRange]), !name.isEmpty else { return nil }
        return (name, pid)
    }

    /// Parses a byte count. Normally `nettop -x` prints plain integers, but
    /// this is defensive against human-readable suffixes (K/M/G/T) in case
    /// of a `nettop` invocation without `-x`, or a future macOS variation.
    private static func parseByteCount(_ field: String) -> UInt64? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let plain = UInt64(trimmed) {
            return plain
        }

        // Suffixed form, e.g. "12.4M", "820K", "1.2G", "3B".
        let suffixes: [Character: Double] = [
            "B": 1,
            "K": 1024,
            "M": 1024 * 1024,
            "G": 1024 * 1024 * 1024,
            "T": 1024 * 1024 * 1024 * 1024
        ]
        guard let last = trimmed.last, let multiplier = suffixes[Character(last.uppercased())] else {
            return nil
        }
        let numberPart = String(trimmed.dropLast())
        guard let value = Double(numberPart), value >= 0 else { return nil }
        return UInt64(value * multiplier)
    }
}
