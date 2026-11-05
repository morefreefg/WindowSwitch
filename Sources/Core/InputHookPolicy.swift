import Foundation

/// Each input stream has one owner. Existing tools stay in charge until exited.
public nonisolated enum InputHookPolicy {
    public static func permitsKeyboard(runningBundleIDs: Set<String>) -> Bool {
        !runningBundleIDs.contains("com.bahoom.HyperSwitch")
    }
    public static func permitsDockClicks(runningApplicationNames: Set<String>) -> Bool {
        !runningApplicationNames.contains("DockFocus")
    }
}
