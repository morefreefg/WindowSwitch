import Foundation
import Testing
@testable import WindowSwitchCore

@Suite struct WindowRecencyTests {
    private func window(_ id: UInt32, pid: Int32 = 1) -> WindowItem {
        WindowItem(id: "\(pid):\(id)", windowID: id, pid: pid, appName: "App", bundleID: "test.app", title: "Window",
                   frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    @Test func quickThenFullSwitchKeepsPreviousAppThird() {
        let terminal = window(1, pid: 1), chrome = window(2, pid: 2), other = window(3, pid: 3), old = window(4, pid: 4)
        var history = WindowRecency()
        history.record(pid: terminal.pid, windowID: 1)
        history.record(pid: chrome.pid, windowID: 2)
        history.record(pid: other.pid, windowID: 3)
        #expect(history.ordered([old, terminal, other, chrome]).map(\.id) == [other.id, chrome.id, terminal.id, old.id])
    }
    @Test func repeatedInventoryReadsDoNotChangeRecency() {
        let a = window(1), b = window(2), c = window(3)
        var history = WindowRecency()
        history.record(pid: 1, windowID: 1); history.record(pid: 1, windowID: 2)
        let expected = [b.id, a.id, c.id]
        #expect(history.ordered([c, a, b]).map(\.id) == expected)
        #expect(history.ordered([a, c, b]).map(\.id) == expected)
        let changed = history.record(pid: 1, windowID: 2)
        #expect(!changed)
    }
    @Test func windowsOfOneAppHaveIndependentRanks() {
        let a = window(1), b = window(2), other = window(3, pid: 2)
        var history = WindowRecency()
        history.record(pid: 1, windowID: 1); history.record(pid: 2, windowID: 3); history.record(pid: 1, windowID: 2)
        #expect(history.ordered([a, b, other]).map(\.id) == [b.id, other.id, a.id])
        history.remove(pid: 1, windowID: 2)
        #expect(history.ordered([a, other]).map(\.id) == [other.id, a.id])
    }
    @Test func processIdentityAndUnknownWindowOrderRemainStable() {
        let a = window(1, pid: 1), reused = window(1, pid: 2), b = window(2, pid: 2)
        var history = WindowRecency()
        history.record(pid: 1, windowID: 1)
        #expect(history.ordered([b, reused, a]).map(\.id) == [a.id, b.id, reused.id])
        history.removeProcess(1)
        #expect(history.ordered([b, reused, a]).map(\.id) == [b.id, reused.id, a.id])
    }
}
