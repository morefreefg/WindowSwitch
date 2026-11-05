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

    public static func target(_ windows: [WindowItem], screen: CGRect, screens: [CGRect]) -> WindowItem? {
        let local = candidates(windows, screen: screen, screens: screens)
        return local.count >= 2 ? local[1] : nil
    }
}
