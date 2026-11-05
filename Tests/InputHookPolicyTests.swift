import Testing
import WindowSwitchCore

struct InputHookPolicyTests {
    @Test func existingHyperSwitchOwnsKeyboard() {
        #expect(!InputHookPolicy.permitsKeyboard(runningBundleIDs: ["com.bahoom.HyperSwitch"]))
        #expect(InputHookPolicy.permitsDockClicks(runningApplicationNames: ["com.bahoom.HyperSwitch"]))
    }
    @Test func existingDockFocusOwnsDockClicks() {
        #expect(!InputHookPolicy.permitsDockClicks(runningApplicationNames: ["DockFocus"]))
        #expect(InputHookPolicy.permitsKeyboard(runningBundleIDs: ["DockFocus"]))
    }
    @Test func unrelatedApplicationsDoNotDisableFeatures() {
        let applications: Set<String> = ["com.apple.dock", "io.github.morefreefg.WindowSwitch"]
        #expect(InputHookPolicy.permitsKeyboard(runningBundleIDs: applications))
        #expect(InputHookPolicy.permitsDockClicks(runningApplicationNames: applications))
    }
}
