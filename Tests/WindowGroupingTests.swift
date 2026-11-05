import Foundation
import Testing
@testable import WindowSwitchCore

@Suite struct WindowGroupingTests {
    private func window(_ id: String, app: String, pid: Int32 = 1) -> WindowItem {
        WindowItem(id: id, windowID: UInt32(id), pid: pid, appName: "App", bundleID: app, title: "Window", frame: .zero)
    }
    @Test func keepsTheMostRecentWindowAndAppOrder() {
        let windows = [window("1", app: "feishu"), window("2", app: "chrome", pid: 2), window("3", app: "feishu"), window("4", app: "terminal", pid: 3)]
        #expect(WindowGrouping.onePerApplication(windows).map(\.id) == ["1", "2", "4"])
    }
    @Test func groupsSeparateInstancesOfTheSameApp() {
        #expect(WindowGrouping.onePerApplication([window("1", app: "feishu"), window("2", app: "feishu", pid: 2)]).count == 1)
    }
    @Test func appsWithoutBundleIDsUseProcessIdentity() {
        let windows = [window("1", app: ""), window("2", app: "", pid: 2), window("3", app: "")]
        #expect(WindowGrouping.onePerApplication(windows).map(\.id) == ["1", "2"])
    }
}
