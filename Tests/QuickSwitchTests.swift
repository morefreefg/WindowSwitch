import Foundation
import Testing
@testable import WindowSwitchCore

@Suite struct QuickSwitchTests {
    private let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    private func item(_ id: UInt32, frame: CGRect, onScreen: Bool = true, minimized: Bool = false, hidden: Bool = false) -> WindowItem {
        WindowItem(id: "\(id)", windowID: id, pid: Int32(id), appName: "App", bundleID: "test.\(id)",
                   title: "Window", frame: frame, isMinimized: minimized, isHidden: hidden, isOnScreen: onScreen)
    }
    @Test func twoApplicationsToggleByFrontToBackOrder() {
        let a = item(1, frame: left), b = item(2, frame: left), c = item(3, frame: left)
        #expect(QuickSwitchPolicy.target([a, b, c], screen: left, screens: [left, right])?.id == b.id)
        #expect(QuickSwitchPolicy.target([b, a, c], screen: left, screens: [left, right])?.id == a.id)
        #expect(QuickSwitchPolicy.target([a, b, c], screen: left, screens: [left, right])?.id == b.id)
    }
    @Test func pointerDisplayWinsOverGlobalForegroundAndCrossSpaceSettings() {
        let elsewhere = item(1, frame: left), a = item(2, frame: right), b = item(3, frame: right)
        let otherSpace = item(4, frame: right, onScreen: false)
        let hidden = item(5, frame: right, hidden: true), minimized = item(6, frame: right, minimized: true)
        #expect(QuickSwitchPolicy.target([elsewhere, otherSpace, hidden, minimized, a, b], screen: right,
                                        screens: [left, right])?.id == b.id)
    }
    @Test func straddlingWindowBelongsToDisplayWithLargestIntersection() {
        let spanning = item(1, frame: CGRect(x: 1800, y: 0, width: 900, height: 800))
        let a = item(2, frame: left), b = item(3, frame: left)
        #expect(QuickSwitchPolicy.candidates([spanning, a, b], screen: left, screens: [left, right]).map(\.id) == [a.id, b.id])
    }
    @Test func noRunnerUpDoesNotJumpToAnotherDisplay() {
        #expect(QuickSwitchPolicy.target([item(1, frame: left), item(2, frame: right)], screen: left,
                                        screens: [left, right]) == nil)
    }
    @Test func focusOnAnotherDisplayTargetsPointerDisplaysMostRecentWindow() {
        let a = item(2, frame: right), b = item(3, frame: right)
        // Focused window 1 lives on the left display; pointer is on the right.
        #expect(QuickSwitchPolicy.orderedTargets([a, b], focusedWindowID: 1, focusedPID: 1).map(\.id) == [a.id, b.id])
        // Focus on the pointer display toggles to the other window.
        #expect(QuickSwitchPolicy.orderedTargets([a, b], focusedWindowID: 2, focusedPID: 2).map(\.id) == [b.id])
        #expect(QuickSwitchPolicy.orderedTargets([b, a], focusedWindowID: 2, focusedPID: 2).map(\.id) == [b.id])
        // Unknown focus, or an unlisted window of the first app (a palette), keeps the runner-up.
        #expect(QuickSwitchPolicy.orderedTargets([a, b], focusedWindowID: nil, focusedPID: nil).map(\.id) == [b.id])
        #expect(QuickSwitchPolicy.orderedTargets([a, b], focusedWindowID: 99, focusedPID: 2).map(\.id) == [b.id])
        // A lone window on the pointer display is reachable when focus is elsewhere.
        #expect(QuickSwitchPolicy.orderedTargets([a], focusedWindowID: 1, focusedPID: 1).map(\.id) == [a.id])
        #expect(QuickSwitchPolicy.orderedTargets([a], focusedWindowID: 2, focusedPID: 2).isEmpty)
    }
    @Test func emptyPointerDisplayFallsBackToMostRecentVisibleWindowAnywhere() {
        let current = item(1, frame: left), previous = item(2, frame: right), older = item(3, frame: right)
        let minimized = item(4, frame: right, minimized: true)
        // Pointer display (left) holds only the focused window: nothing local to switch to.
        #expect(QuickSwitchPolicy.orderedTargets([current], focusedWindowID: 1, focusedPID: 1).isEmpty)
        #expect(QuickSwitchPolicy.fallbackTargets([current, minimized, previous, older], focusedWindowID: 1, focusedPID: 1)
            .map(\.id) == [previous.id, older.id])
        // Unknown focused window: skip the frontmost app's windows.
        #expect(QuickSwitchPolicy.fallbackTargets([current, previous], focusedWindowID: nil, focusedPID: 1).map(\.id) == [previous.id])
    }
    @Test func successfulPairTogglesEvenWhenCompositorOrderDoesNotChange() {
        let a = item(1, frame: left), b = item(2, frame: left), c = item(3, frame: left)
        let staleOrder = [a, b, c]
        var recency = WindowRecency()
        recency.record(pid: a.pid, windowID: 1)
        recency.record(pid: b.pid, windowID: 2)
        #expect(QuickSwitchPolicy.target(recency.ordered(staleOrder), screen: left, screens: [left, right])?.id == a.id)
        recency.record(pid: a.pid, windowID: 1)
        #expect(QuickSwitchPolicy.target(recency.ordered(staleOrder), screen: left, screens: [left, right])?.id == b.id)
        recency.record(pid: c.pid, windowID: 3)
        #expect(recency.ordered(staleOrder).map(\.id) == [c.id, a.id, b.id])
    }
}
