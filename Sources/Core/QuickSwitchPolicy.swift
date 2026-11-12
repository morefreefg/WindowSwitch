import Foundation

/// Candidates preserve their supplied recent-window order. A quick gesture chooses the
/// runner-up on the pointer's display, independently of the full-list filters.
public nonisolated enum QuickSwitchPolicy {
    public static func candidates(_ windows: [WindowItem], screen: CGRect, screens: [CGRect]) -> [WindowItem] {
        windows.filter { item in
            guard item.windowID != nil, item.isOnScreen, !item.isMinimized, !item.isHidden else { return false }
            let intersection = screen.intersection(item.frame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return false }
            let area = intersection.width * intersection.height
            return screens.allSatisfy { other in
                let overlap = other.intersection(item.frame)
                return overlap.isNull || area >= overlap.width * overlap.height
            }
        }
    }

    /// Activation order for a quick tap among the pointer display's `local` candidates.
    /// - Focus on this display: every other window, most recent first.
    /// - Focus on another display: this display's most recent window first, so one tap lands
    ///   where the user is pointing instead of skipping to the runner-up.
    /// - Focus unknown, or held by a non-listed window of `local[0]`'s app: the runner-up.
    public static func orderedTargets(_ local: [WindowItem], focusedWindowID: UInt32?, focusedPID: Int32?) -> [WindowItem] {
        if let focusedWindowID, local.contains(where: { $0.windowID == focusedWindowID }) {
            return local.filter { $0.windowID != focusedWindowID }
        }
        if focusedWindowID != nil, let focusedPID, let first = local.first, first.pid != focusedPID { return local }
        return Array(local.dropFirst())
    }

    /// When the pointer display offers nothing to switch to, a quick tap goes back to the
    /// most recent other visible window on any display (recency order is preserved).
    public static func fallbackTargets(_ windows: [WindowItem], focusedWindowID: UInt32?, focusedPID: Int32?) -> [WindowItem] {
        windows.filter { item in
            guard item.windowID != nil, item.isOnScreen, !item.isMinimized, !item.isHidden else { return false }
            if let focusedWindowID { return item.windowID != focusedWindowID }
            return item.pid != focusedPID
        }
    }

    public static func target(_ windows: [WindowItem], screen: CGRect, screens: [CGRect]) -> WindowItem? {
        let local = candidates(windows, screen: screen, screens: screens)
        return local.count >= 2 ? local[1] : nil
    }
}
