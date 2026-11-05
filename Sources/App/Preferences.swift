import AppKit
import Observation
import WindowSwitchCore

nonisolated enum ShortcutModifier: String, CaseIterable, Codable, Identifiable {
    case option, command, control
    var id: String { rawValue }
    var label: String { switch self { case .option: "⌥ Option"; case .command: "⌘ Command"; case .control: "⌃ Control" } }
    var flag: CGEventFlags { switch self { case .option: .maskAlternate; case .command: .maskCommand; case .control: .maskControl } }
}

@Observable final class Preferences {
    private let defaults: UserDefaults
    private var restoringDefaults = false
    var runtimeStatus = ""
    var preloadStatus = ""
    var allWindowsEnabled: Bool { didSet { save() } }
    var currentWindowEnabled: Bool { didSet { save() } }
    var reverseWithShift: Bool { didSet { save() } }
    var runInBackground: Bool { didSet { save() } }
    var showDockIcon: Bool { didSet { save() } }
    var showMenuBarIcon: Bool { didSet { save() } }
    var hideAnimation: String { didSet { save() } }
    var fadeInDuration: Double { didSet { save() } }
    var fadeOutDuration: Double { didSet { save() } }
    var backgroundPreloadEnabled: Bool { didSet { save() } }
    var backgroundPreloadThumbnails: Bool { didSet { save() } }
    var backgroundPreloadInterval: Double { didSet { save() } }
    var backgroundRGB: String { didSet { save() } }
    var singleWindowFocus: Bool { didSet { save() } }
    var enabled: Bool { didSet { save() } }
    var dockFocusEnabled: Bool { didSet { save() } }
    var windowModifier: ShortcutModifier { didSet { save() } }
    var currentModifier: ShortcutModifier { didSet { save() } }
    var applicationSwitcher: Bool { didSet { save() } }
    var applicationModifier: ShortcutModifier { didSet { save() } }
    var nativeAppEnhancement: Bool { didSet { save() } }
    var applicationInitialDelay: Double { didSet { save() } }
    var applicationSubsequentDelay: Double { didSet { save() } }
    var openDefaultWindow: Bool { didSet { save() } }
    var applicationAutoActivate: Bool { didSet { save() } }
    var applicationAutoActivateDelay: Double { didSet { save() } }
    var scrollWindowActions: Bool { didSet { save() } }
    var includeMinimized: Bool { didSet { save() } }
    var includeHidden: Bool { didSet { save() } }
    var allSpaces: Bool { didSet { save() } }
    var allScreens: Bool { didSet { save() } }
    var oneWindowPerApp: Bool { didSet { save() } }
    var includePalettes: Bool { didSet { save() } }
    var thumbnailSize: Double { didSet { save() } }
    var showPreviews: Bool { didSet { save() } }
    var showDelay: Double { didSet { save() } }
    var quickSwitchOnMouseScreen: Bool { didSet { save() } }
    var quickHoldDelay: Double { didSet { save() } }
    var excludedApplications: String { didSet { save() } }
    var screenChoice: String { didSet { save() } }
    var windowRules: [WindowRule] { didSet { save() } }
    var hoverPreview: Bool { didSet { save() } }
    var hoverDelay: Double { didSet { save() } }
    var backgroundOpacity: Double { didSet { save() } }
    var showAppIcons: Bool { didSet { save() } }
    var iconScale: Double { didSet { save() } }
    var previewQuality: Int { didSet { save() } }
    var backgroundBlur: Bool { didSet { save() } }
    var theme: String { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["enabled": true, "dockFocusEnabled": true, "singleWindowFocus": true, "windowModifier": "command", "currentModifier": "option",
            "applicationSwitcher": true, "applicationModifier": "command", "nativeAppEnhancement": true,
            "applicationInitialDelay": 500.0, "applicationSubsequentDelay": 300.0, "openDefaultWindow": true,
            "applicationAutoActivate": false, "applicationAutoActivateDelay": 500.0, "scrollWindowActions": true,
            "includeMinimized": false,
            "includeHidden": true, "allSpaces": true, "allScreens": true, "includePalettes": false, "oneWindowPerApp": true,
            "thumbnailSize": 185.0, "showPreviews": true, "showDelay": 80.0,
            "quickSwitchOnMouseScreen": true, "quickHoldDelay": 200.0,
            "excludedApplications": "", "screenChoice": "active", "hoverPreview": false,
            "hoverDelay": 800.0, "backgroundOpacity": 0.35, "showAppIcons": true,
            "iconScale": 1.0, "previewQuality": 4, "backgroundBlur": false, "theme": "system"])
        defaults.register(defaults: ["allWindowsEnabled": true, "currentWindowEnabled": true, "reverseWithShift": true,
            "runInBackground": true, "showDockIcon": false, "showMenuBarIcon": true,
            "hideAnimation": "fade", "backgroundRGB": "0,0,0",
            "fadeInDuration": 100.0, "fadeOutDuration": 200.0,
            "backgroundPreloadEnabled": false, "backgroundPreloadThumbnails": true,
            "backgroundPreloadInterval": 30.0])
        allWindowsEnabled = defaults.bool(forKey: "allWindowsEnabled")
        currentWindowEnabled = defaults.bool(forKey: "currentWindowEnabled")
        reverseWithShift = defaults.bool(forKey: "reverseWithShift")
        runInBackground = defaults.bool(forKey: "runInBackground")
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
        hideAnimation = defaults.string(forKey: "hideAnimation") ?? "fade"
        fadeInDuration = defaults.double(forKey: "fadeInDuration")
        fadeOutDuration = defaults.double(forKey: "fadeOutDuration")
        backgroundPreloadEnabled = defaults.bool(forKey: "backgroundPreloadEnabled")
        backgroundPreloadThumbnails = defaults.bool(forKey: "backgroundPreloadThumbnails")
        backgroundPreloadInterval = defaults.double(forKey: "backgroundPreloadInterval")
        backgroundRGB = defaults.string(forKey: "backgroundRGB") ?? "0.08,0.08,0.08"
        enabled = defaults.bool(forKey: "enabled")
        singleWindowFocus = defaults.bool(forKey: "singleWindowFocus")
        dockFocusEnabled = defaults.bool(forKey: "dockFocusEnabled")
        windowModifier = ShortcutModifier(rawValue: defaults.string(forKey: "windowModifier") ?? "") ?? .command
        currentModifier = ShortcutModifier(rawValue: defaults.string(forKey: "currentModifier") ?? "") ?? .option
        applicationSwitcher = defaults.bool(forKey: "applicationSwitcher")
        applicationModifier = ShortcutModifier(rawValue: defaults.string(forKey: "applicationModifier") ?? "") ?? .command
        nativeAppEnhancement = defaults.bool(forKey: "nativeAppEnhancement")
        applicationInitialDelay = defaults.double(forKey: "applicationInitialDelay")
        applicationSubsequentDelay = defaults.double(forKey: "applicationSubsequentDelay")
        openDefaultWindow = defaults.bool(forKey: "openDefaultWindow")
        applicationAutoActivate = defaults.bool(forKey: "applicationAutoActivate")
        applicationAutoActivateDelay = defaults.double(forKey: "applicationAutoActivateDelay")
        scrollWindowActions = defaults.bool(forKey: "scrollWindowActions")
        includeMinimized = defaults.bool(forKey: "includeMinimized")
        includeHidden = defaults.bool(forKey: "includeHidden")
        allSpaces = defaults.bool(forKey: "allSpaces"); allScreens = defaults.bool(forKey: "allScreens")
        oneWindowPerApp = defaults.bool(forKey: "oneWindowPerApp")
        includePalettes = defaults.bool(forKey: "includePalettes")
        thumbnailSize = defaults.double(forKey: "thumbnailSize")
        showPreviews = defaults.bool(forKey: "showPreviews")
        showDelay = defaults.double(forKey: "showDelay")
        quickSwitchOnMouseScreen = defaults.bool(forKey: "quickSwitchOnMouseScreen")
        quickHoldDelay = defaults.double(forKey: "quickHoldDelay")
        excludedApplications = defaults.string(forKey: "excludedApplications") ?? ""
        screenChoice = defaults.string(forKey: "screenChoice") ?? "mouse"
        windowRules = defaults.data(forKey: "windowRules").flatMap { try? JSONDecoder().decode([WindowRule].self, from: $0) } ?? []
        hoverPreview = defaults.bool(forKey: "hoverPreview"); hoverDelay = defaults.double(forKey: "hoverDelay")
        backgroundOpacity = defaults.double(forKey: "backgroundOpacity")
        showAppIcons = defaults.bool(forKey: "showAppIcons"); iconScale = defaults.double(forKey: "iconScale")
        previewQuality = defaults.integer(forKey: "previewQuality"); backgroundBlur = defaults.bool(forKey: "backgroundBlur")
        theme = defaults.string(forKey: "theme") ?? "dark"
    }

    private func save() {
        guard !restoringDefaults else { return }
        defaults.set(allWindowsEnabled, forKey: "allWindowsEnabled"); defaults.set(currentWindowEnabled, forKey: "currentWindowEnabled")
        defaults.set(reverseWithShift, forKey: "reverseWithShift"); defaults.set(runInBackground, forKey: "runInBackground")
        defaults.set(showDockIcon, forKey: "showDockIcon"); defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon")
        defaults.set(hideAnimation, forKey: "hideAnimation"); defaults.set(backgroundRGB, forKey: "backgroundRGB")
        defaults.set(fadeInDuration, forKey: "fadeInDuration"); defaults.set(fadeOutDuration, forKey: "fadeOutDuration")
        defaults.set(backgroundPreloadEnabled, forKey: "backgroundPreloadEnabled")
        defaults.set(backgroundPreloadThumbnails, forKey: "backgroundPreloadThumbnails")
        defaults.set(backgroundPreloadInterval, forKey: "backgroundPreloadInterval")
        defaults.set(enabled, forKey: "enabled"); defaults.set(windowModifier.rawValue, forKey: "windowModifier")
        defaults.set(dockFocusEnabled, forKey: "dockFocusEnabled")
        defaults.set(singleWindowFocus, forKey: "singleWindowFocus")
        defaults.set(currentModifier.rawValue, forKey: "currentModifier")
        defaults.set(applicationSwitcher, forKey: "applicationSwitcher")
        defaults.set(applicationModifier.rawValue, forKey: "applicationModifier")
        defaults.set(nativeAppEnhancement, forKey: "nativeAppEnhancement")
        defaults.set(applicationInitialDelay, forKey: "applicationInitialDelay")
        defaults.set(applicationSubsequentDelay, forKey: "applicationSubsequentDelay")
        defaults.set(openDefaultWindow, forKey: "openDefaultWindow")
        defaults.set(applicationAutoActivate, forKey: "applicationAutoActivate")
        defaults.set(applicationAutoActivateDelay, forKey: "applicationAutoActivateDelay")
        defaults.set(scrollWindowActions, forKey: "scrollWindowActions")
        defaults.set(includeMinimized, forKey: "includeMinimized"); defaults.set(includeHidden, forKey: "includeHidden")
        defaults.set(allSpaces, forKey: "allSpaces"); defaults.set(allScreens, forKey: "allScreens")
        defaults.set(oneWindowPerApp, forKey: "oneWindowPerApp")
        defaults.set(includePalettes, forKey: "includePalettes"); defaults.set(thumbnailSize, forKey: "thumbnailSize")
        defaults.set(showPreviews, forKey: "showPreviews"); defaults.set(showDelay, forKey: "showDelay")
        defaults.set(quickSwitchOnMouseScreen, forKey: "quickSwitchOnMouseScreen")
        defaults.set(quickHoldDelay, forKey: "quickHoldDelay")
        defaults.set(excludedApplications, forKey: "excludedApplications"); defaults.set(screenChoice, forKey: "screenChoice")
        defaults.set(try? JSONEncoder().encode(windowRules), forKey: "windowRules")
        defaults.set(hoverPreview, forKey: "hoverPreview"); defaults.set(hoverDelay, forKey: "hoverDelay")
        defaults.set(backgroundOpacity, forKey: "backgroundOpacity")
        defaults.set(showAppIcons, forKey: "showAppIcons"); defaults.set(iconScale, forKey: "iconScale")
        defaults.set(previewQuality, forKey: "previewQuality"); defaults.set(backgroundBlur, forKey: "backgroundBlur")
        defaults.set(theme, forKey: "theme")
    }
    func restoreDefaults() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        defaults.removePersistentDomain(forName: identifier)
        let fresh = Preferences(defaults: defaults)
        restoringDefaults = true
        let flags: [ReferenceWritableKeyPath<Preferences, Bool>] = [\.allWindowsEnabled, \.currentWindowEnabled,
            \.reverseWithShift, \.runInBackground, \.showDockIcon, \.showMenuBarIcon, \.singleWindowFocus,
            \.enabled, \.dockFocusEnabled, \.applicationSwitcher, \.nativeAppEnhancement, \.openDefaultWindow,
            \.applicationAutoActivate, \.scrollWindowActions, \.includeMinimized, \.includeHidden, \.allSpaces,
            \.allScreens, \.oneWindowPerApp, \.includePalettes, \.showPreviews, \.hoverPreview, \.showAppIcons, \.backgroundBlur, \.quickSwitchOnMouseScreen,
            \.backgroundPreloadEnabled, \.backgroundPreloadThumbnails]
        for key in flags { self[keyPath: key] = fresh[keyPath: key] }
        let numbers: [ReferenceWritableKeyPath<Preferences, Double>] = [\.applicationInitialDelay, \.applicationSubsequentDelay,
            \.applicationAutoActivateDelay, \.thumbnailSize, \.showDelay, \.hoverDelay, \.backgroundOpacity, \.iconScale, \.quickHoldDelay,
            \.fadeInDuration, \.fadeOutDuration, \.backgroundPreloadInterval]
        for key in numbers { self[keyPath: key] = fresh[keyPath: key] }
        let strings: [ReferenceWritableKeyPath<Preferences, String>] = [\.hideAnimation, \.backgroundRGB,
            \.excludedApplications, \.screenChoice, \.theme]
        for key in strings { self[keyPath: key] = fresh[keyPath: key] }
        windowModifier = fresh.windowModifier; currentModifier = fresh.currentModifier
        applicationModifier = fresh.applicationModifier; windowRules = fresh.windowRules; previewQuality = fresh.previewQuality
        restoringDefaults = false; save()
    }

    func query(mode: SwitchMode, currentPID: Int32?, screen: NSScreen?) -> WindowQuery {
        var query = WindowQuery()
        query.mode = mode; query.currentPID = currentPID; query.ownPID = ProcessInfo.processInfo.processIdentifier
        query.includeMinimized = includeMinimized; query.includeHidden = includeHidden
        query.includePalettes = includePalettes; query.allSpaces = allSpaces; query.allScreens = allScreens
        query.excludedBundleIDs = Set(excludedApplications.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
        query.excludedWindowRules = windowRules
        if mode == .currentApplication { query.includeMinimized = true; query.allSpaces = true }
        if mode == .applications { query.includeMinimized = true; query.allSpaces = true; query.allScreens = true }
        if let screen {
            let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            query.screenBounds = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                                        width: screen.frame.width, height: screen.frame.height)
        }
        return query
    }
}
