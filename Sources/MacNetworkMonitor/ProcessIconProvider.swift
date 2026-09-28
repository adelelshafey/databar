import AppKit
import Darwin

/// Resolves a process icon the way Activity Monitor / TripMode do: the
/// running GUI app's real icon when there is one, otherwise the Finder icon
/// for its executable on disk, otherwise a generic executable icon. Results
/// are cached by pid since icon lookups are comparatively expensive and a
/// process's icon never changes for the life of that pid.
@MainActor
final class ProcessIconProvider {
    static let shared = ProcessIconProvider()

    private var cache: [Int32: NSImage] = [:]
    private let genericIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for pid: Int32) -> NSImage {
        if let cached = cache[pid] { return cached }
        let image = resolveIcon(for: pid)
        cache[pid] = image
        return image
    }

    /// Drops cached icons for pids that are no longer being tracked, so a
    /// long-running session doesn't accumulate icons for every process
    /// that's ever appeared.
    func trim(keeping livePIDs: Set<Int32>) {
        cache = cache.filter { livePIDs.contains($0.key) }
    }

    private func resolveIcon(for pid: Int32) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        if let path = executablePath(for: pid) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return genericIcon
    }

    private func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
