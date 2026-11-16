import Foundation

/// One key press owns one release. A later press must not hold up an earlier switch.
@MainActor public final class ShortcutKeyRelease {
    public let eventDriven: Bool
    public private(set) var isReleased: Bool
    public private(set) var isCancelled = false

    public init(isHeld: Bool, eventDriven: Bool = true) {
        self.isReleased = !isHeld
        self.eventDriven = eventDriven
    }

    public func release() { isReleased = true }
    public func cancel() { isCancelled = true }

    public func shouldWait(elapsed: TimeInterval, timeout: TimeInterval = 0.25) -> Bool {
        !isReleased && !isCancelled && elapsed < timeout
    }
}
