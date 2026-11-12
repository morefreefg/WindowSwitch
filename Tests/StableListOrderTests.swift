import Foundation
import Testing
@testable import WindowSwitchCore

@Suite struct StableListOrderTests {
    private func item(_ id: String, title: String = "Window") -> WindowItem {
        WindowItem(id: id, windowID: nil, pid: 1, appName: "App", bundleID: "test", title: title,
                   frame: .zero, isMinimized: false, isHidden: false, isOnScreen: true)
    }
    @Test func shownWindowsKeepTheirPlacesAndNewOnesAreAppended() {
        let a = item("a"), b = item("b"), c = item("c")
        #expect(StableListOrder.merge(shown: [a, b], latest: [c, a, b]).map(\.id) == ["a", "b", "c"])
    }
    @Test func recencyReorderDoesNotMoveAnOpenList() {
        let a = item("a"), b = item("b"), c = item("c")
        #expect(StableListOrder.merge(shown: [a, b, c], latest: [c, b, a]).map(\.id) == ["a", "b", "c"])
    }
    @Test func closedWindowsLeaveAndDataRefreshes() {
        let a = item("a"), b = item("b"), renamed = item("b", title: "Renamed")
        let merged = StableListOrder.merge(shown: [a, b], latest: [renamed])
        #expect(merged.map(\.id) == ["b"])
        #expect(merged.first?.title == "Renamed")
    }
}
