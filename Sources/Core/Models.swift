import Foundation

public nonisolated enum SwitchMode: String, Codable, Sendable, CaseIterable {
    case windows, currentApplication, applications
}

public nonisolated struct WindowItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let windowID: UInt32?
    public let pid: Int32
    public let appName: String
    public let bundleID: String
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
    public let isHidden: Bool
    public let isOnScreen: Bool
    public let isFullscreen: Bool
    public let documentURL: URL?

    public init(id: String, windowID: UInt32?, pid: Int32, appName: String, bundleID: String,
                title: String, frame: CGRect, isMinimized: Bool = false, isHidden: Bool = false,
                isOnScreen: Bool = true, isFullscreen: Bool = false, documentURL: URL? = nil) {
        self.id = id; self.windowID = windowID; self.pid = pid; self.appName = appName
        self.bundleID = bundleID; self.title = title; self.frame = frame
        self.isMinimized = isMinimized; self.isHidden = isHidden
        self.isOnScreen = isOnScreen; self.isFullscreen = isFullscreen
        self.documentURL = documentURL
    }
}

public nonisolated struct WindowQuery: Sendable, Equatable {
    public var mode: SwitchMode = .windows
    public var currentPID: Int32?
    public var includeMinimized = false
    public var includeHidden = true
    public var includePalettes = false
    public var allSpaces = true
    public var allScreens = true
    public var screenBounds: CGRect?
    public var excludedBundleIDs: Set<String> = []
    public var excludedWindowRules: [WindowRule] = []
    public var ownPID: Int32 = 0
    public var allowedPIDs: Set<Int32>?
    public init() {}
}

public nonisolated enum WindowAction: String, Sendable {
    case focus, close, minimize, toggleFullscreen, hideApplication, quitApplication
    case center, snapLeft, snapRight, maximize, compact, restore, newWindow, newTab
    case bringToCurrentSpace, forceQuitApplication, openFile
}
