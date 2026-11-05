import Foundation

public nonisolated enum WindowGrouping {
    /// Input is already filtered to eligible displays/spaces and ordered by MRU.
    public static func onePerApplication(_ windows: [WindowItem]) -> [WindowItem] {
        var seen: Set<String> = []
        return windows.filter { window in
            let key = window.bundleID.isEmpty ? "pid:\(window.pid)" : "bundle:\(window.bundleID)"
            return seen.insert(key).inserted
        }
    }
}
