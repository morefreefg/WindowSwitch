import Foundation
import CoreGraphics
import Testing
@testable import WindowSwitchCore

private func item(_ id: String, app: String = "App", title: String = "Document") -> WindowItem {
    WindowItem(id: id, windowID: UInt32(id), pid: 1, appName: app, bundleID: "test.app", title: title, frame: .zero)
}

@Suite struct SelectionTests {
    @Test func firstPressSkipsCurrentWindowAndWraps() {
        var selection = SwitchSelection()
        selection.start([item("1"), item("2"), item("3")])
        #expect(selection.selected?.id == "2")
        selection.move(2)
        #expect(selection.selected?.id == "1")
        selection.move(-1)
        #expect(selection.selected?.id == "3")
    }
    @Test func reverseFirstPressStartsAtLastWindow() {
        var selection = SwitchSelection()
        selection.start([item("1"), item("2"), item("3")], reverse: true)
        #expect(selection.selected?.id == "3")
    }
    @Test func rowNavigationDoesNotWrapPastGridBoundary() {
        var selection = SwitchSelection()
        selection.start((1...5).map { item(String($0)) }, advance: false)
        selection.moveRow(-1, columns: 3)
        #expect(selection.selected?.id == "1")
        selection.moveRow(1, columns: 3)
        #expect(selection.selected?.id == "4")
        selection.moveRow(1, columns: 3)
        #expect(selection.selected?.id == "4")
    }
    @Test func singleAndEmptySessionsAreSafe() {
        var selection = SwitchSelection()
        selection.start([]); selection.move(-10)
        #expect(selection.selected == nil)
        selection.start([item("1")]); selection.move(100)
        #expect(selection.selected?.id == "1")
    }
    @Test func filteredSelectionAndRemovalRemainValid() {
        var selection = SwitchSelection()
        selection.start([item("1", app: "Safari"), item("2", title: "项目计划"), item("3", title: "项目代码")])
        selection.search = "项目"
        #expect(selection.filtered.count == 2)
        selection.remove("2")
        #expect(selection.selected?.id == "3")
        selection.search = "safari"
        #expect(selection.selected?.id == "1")
        selection.remove("1")
        #expect(selection.selected == nil)
    }
    @Test func removesApplicationAndEverySiblingWithoutLosingOtherSelection() {
        var selection = SwitchSelection()
        let first = WindowItem(id: "first", windowID: 1, pid: 42, appName: "App", bundleID: "app", title: "One", frame: .zero)
        let sibling = WindowItem(id: "sibling", windowID: 2, pid: 42, appName: "App", bundleID: "app", title: "Two", frame: .zero)
        let other = item("3")
        selection.start([first, sibling, other])
        selection.removeApplication(pid: 42)
        #expect(selection.items.map(\.id) == ["3"])
        #expect(selection.selected?.id == "3")
    }
}
