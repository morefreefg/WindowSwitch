import AppKit
import SwiftUI
import WindowSwitchCore
import os
import ServiceManagement

@main struct WindowSwitchEntry {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private lazy var controller = SwitchController(preferences: preferences)
    private let hotkeys = HotkeyMonitor()
    private lazy var dockFocus = DockFocusController(service: controller.service, onActivation: { [weak self] in self?.controller.cancel() })
    private let library = LibraryPanelController()
    private let nativeSwitcher = NativeAppSwitcherObserver()
    private let permissionGuide = PermissionGuideController()
    private let updates = UpdateController()
    private var setupWindow: NSWindow?
    private var setupPrompted = false
    private var settingsOnly = false
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let settingsNavigation = PreferencesNavigation()
    private lazy var settingsToolbar = PreferencesToolbar(navigation: settingsNavigation)
    private var permissionTimer: Timer?
    private var loginItemError = ""
    private var maintenancePermission = false
    private let logger = Logger(subsystem: "io.github.morefreefg.WindowSwitch", category: "application")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        let arguments = ProcessInfo.processInfo.arguments
        settingsOnly = arguments.contains("--settings-only") || arguments.contains("--smoke-test")
        if arguments.contains("--verify-fixture") {
            Task { await FunctionalVerifier.run() }
            return
        }
        if arguments.contains("--update-feed-smoke") {
            Task {
                let probe = UpdateFeedProbe(); let result = await probe.run()
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/codex-windowswitch/update-feed.json"))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if arguments.contains("--diagnose") { diagnose(); return }
        if arguments.contains("--input-parity-smoke") {
            let checks = controller.validateInputState()
            let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/codex-windowswitch/input-parity.json"))
            }
            NSApp.terminate(nil); return
        }
        if arguments.contains("--setup-smoke") {
            makeMenu(); showSetup(); refreshHooks()
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                if CGPreflightScreenCaptureAccess(), let window = setupWindow {
                    try? captureSettingsWindow(window, to: "/tmp/codex-windowswitch/setup.png")
                } else if let view = setupWindow?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/codex-windowswitch/setup.png"))
                }
                let snapshot: [String: Any] = ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(),
                    "ready": permissionsReady, "wizardVisible": setupWindow?.isVisible == true, "hooksStopped": !hotkeys.running,
                    "maintenanceStopped": !maintenancePermission]
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted,.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/codex-windowswitch/setup.json"))
                }
                setupWindow?.close(); NSApp.terminate(nil)
            }
            return
        }
        if arguments.contains("--benchmark-discovery") {
            Task {
                let data = await controller.service.benchmarkDiscovery(iterations: 8)
                try? data.write(to: URL(fileURLWithPath: "/tmp/codex-windowswitch/discovery-benchmark.json"))
                NSApp.terminate(nil)
            }
            return
        }
        if arguments.contains("--authorization-smoke") {
            settingsOnly = true
            showSettings()
            permissionGuide.showAccessibility()
            Task {
                try? await Task.sleep(for: .seconds(2))
                let result = permissionGuide.validationSnapshot()
                if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? json.write(to: URL(fileURLWithPath: "/tmp/codex-windowswitch/authorization-report.json"))
                }
                permissionGuide.close(); NSApp.terminate(nil)
            }
            return
        }
        if arguments.contains("--smoke-test") {
            let settingsMode = ProcessInfo.processInfo.environment["WINDOWSWITCH_SMOKE_SETTINGS"] == "1"
            if settingsMode { showSettings() } else { controller.showDemo() }
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                let output = ProcessInfo.processInfo.environment["WINDOWSWITCH_SMOKE_OUTPUT"] ?? "/tmp/codex-windowswitch/smoke.png"
                do {
                    if settingsMode, let window = settingsWindow {
                        try captureSettingsWindow(window, to: output)
                        if ProcessInfo.processInfo.environment["WINDOWSWITCH_SMOKE_SETTINGS_TABS"] == "1" {
                            try await validateSettingsHeader(window, output: output)
                        }
                    } else { try controller.renderDemo(to: output) }
                    print("SMOKE_RENDERED \(output)")
                }
                catch { logger.error("Smoke render failed: \(error)") }
                controller.cancel()
                NSApp.terminate(nil)
            }
            return
        }
        // Only a normal launch installs global input hooks. Diagnostics and smoke tests are inert.
        hotkeys.handler = { [weak self] type, event in self?.controller.handle(type: type, event: event) ?? false }
        hotkeys.onInterruption = { [weak self] in self?.controller.resetInput() }
        controller.onSettings = { [weak self] in self?.showSettings() }
        controller.onRecentDocuments = { [weak self] bundle in self?.library.showDocuments(bundleID: bundle) }
        nativeSwitcher.onSelection = { [weak self] pid, visible in
            guard let self else { return }
            controller.nativeApplicationSelected(pid: pid, visible: visible,
                                                 listFrame: nativeSwitcher.switcherFrame,
                                                 selectedAppFrame: nativeSwitcher.selectedAppFrame)
        }
        makeMenu()
        controller.prepareInterface()
        refreshHooks()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHooks() }
        }
        // 首次启动必定走一遍向导：权限齐备不代表用户见过授权引导
        if !permissionsReady || !UserDefaults.standard.bool(forKey: "hasCompletedSetup") { showSetup() }
        else if settingsOnly { showSettings() }
        UserDefaults.standard.set(true, forKey: "hasLaunched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopBackgroundPreloading()
        Task { await controller.service.stopBackgroundMaintenance() }
        permissionTimer?.invalidate(); hotkeys.stop(); dockFocus.stop(); nativeSwitcher.stop(); permissionGuide.close(); controller.cancel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if permissionsReady { showSettings() } else { showSetup() }; return true
    }

    private func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "WindowSwitch")
        let menu = NSMenu()
        menu.addItem(withTitle: "WindowSwitch 设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "授权向导…", action: #selector(showSetup), keyEquivalent: "").target = self
        menu.addItem(withTitle: "切换窗口", action: #selector(showWindows), keyEquivalent: "").target = self
        menu.addItem(withTitle: "最近文档…", action: #selector(showDocuments), keyEquivalent: "").target = self
        menu.addItem(withTitle: "开始使用（检测旧工具冲突）", action: #selector(resumeAfterSetup), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "暂停／恢复快捷键", action: #selector(toggleHotkeys), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Dock 单屏聚焦开关", action: #selector(toggleDockFocus), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 WindowSwitch", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu; statusItem = item
    }

    func refreshHooks() {
        let policy: NSApplication.ActivationPolicy = preferences.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        statusItem?.isVisible = preferences.showMenuBarIcon
        if settingsOnly {
            preferences.runtimeStatus = "当前仅显示设置；可从菜单栏选择“开始使用”。"
            return
        }
        guard permissionsReady, setupWindow?.isVisible != true else {
            hotkeys.stop(); dockFocus.stop(); nativeSwitcher.stop(); controller.resetInput()
            controller.stopBackgroundPreloading()
            if maintenancePermission { maintenancePermission = false; Task { await controller.service.stopBackgroundMaintenance() } }
            preferences.runtimeStatus = "请先完成授权向导。已授权的项目不会重复申请。"
            statusItem?.button?.toolTip = "WindowSwitch · 需要授权"
            if !permissionsReady && !setupPrompted { showSetup() }
            return
        }
        if preferences.runInBackground, SMAppService.mainApp.status == .notRegistered {
            do { try SMAppService.mainApp.register() } catch { loginItemError = error.localizedDescription }
        }
        setupPrompted = false
        updates.start()
        let trusted = AXIsProcessTrusted()
        if trusted != maintenancePermission {
            maintenancePermission = trusted
            Task {
                if trusted { await controller.service.startBackgroundMaintenance(); await controller.warmInterface() }
                else { await controller.service.stopBackgroundMaintenance() }
            }
        }
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let keyboardAvailable = InputHookPolicy.permitsKeyboard(runningBundleIDs: runningIDs)
        controller.refreshBackgroundPreloading(permitted: trusted && preferences.enabled && keyboardAvailable)
        let dockAvailable = InputHookPolicy.permitsDockClicks(runningApplicationNames: Set(NSWorkspace.shared.runningApplications.compactMap { $0.executableURL?.lastPathComponent }))
        var failures: [String] = []
        if !loginItemError.isEmpty { failures.append(loginItemError) }
        if !keyboardAvailable { failures.append("HyperSwitch 正在运行，新版快捷键暂缓启用。退出旧版后自动接入。") }
        if !dockAvailable { failures.append("独立 DockFocus 正在运行，继续由它处理 Dock 点击。") }
        if trusted && preferences.enabled && keyboardAvailable {
            if !hotkeys.start() { failures.append("快捷键监听未能启动，请检查系统权限后重新打开应用。") }
        }
        else {
            let wasRunning = hotkeys.running
            hotkeys.stop()
            if wasRunning || !preferences.enabled { controller.resetInput() }
        }
        dockFocus.enabled = preferences.dockFocusEnabled
        if trusted && preferences.dockFocusEnabled && dockAvailable {
            if !dockFocus.start() { failures.append("Dock 单屏聚焦未能启动；当前系统权限或单窗口接口不可用。") }
        }
        else { dockFocus.stop() }
        Task { await controller.service.setSingleWindowFocus(preferences.singleWindowFocus) }
        if trusted && preferences.enabled && keyboardAvailable && preferences.applicationSwitcher && preferences.nativeAppEnhancement {
            if !nativeSwitcher.start() { failures.append(nativeSwitcher.lastError ?? "原生应用切换器观察未能启动。") }
        } else { nativeSwitcher.stop() }
        let newStatus = failures.joined(separator: "\n")
        if preferences.runtimeStatus != newStatus { preferences.runtimeStatus = newStatus }
        statusItem?.button?.toolTip = trusted ? "WindowSwitch\(preferences.enabled ? "" : " · 快捷键已暂停")" : "WindowSwitch · 需要辅助功能权限"
    }

    @objc private func showSettings() {
        controller.cancel()
        if settingsWindow == nil {
            let view = PreferencesView(preferences: preferences, navigation: settingsNavigation, updates: updates, refresh: { [weak self] in self?.refreshHooks() },
                                       preview: { [weak self] in self?.controller.showDemo() }, permissionGuide: permissionGuide)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "WindowSwitch Preferences"; window.isReleasedWhenClosed = false; window.delegate = self
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            window.toolbarStyle = .unifiedCompact
            window.toolbar = settingsToolbar.makeToolbar()
            window.contentView = NSHostingView(rootView: view); window.center(); settingsWindow = window
        }
        settingsWindow?.titlebarAppearsTransparent = true
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") { settingsWindow?.orderFrontRegardless() }
        else { NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil) }
    }
    private func captureSettingsWindow(_ window: NSWindow, to path: String) throws {
        // Capture our complete window, including the toolbar and traffic lights.
        // A contentView bitmap cannot catch titlebar layout regressions.
        guard window.windowNumber > 0,
              let image = WSCreateWindowPreview(UInt32(window.windowNumber), .zero, 4, true, nil),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WindowSwitch.SettingsCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not capture the complete settings window"])
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func validateSettingsHeader(_ window: NSWindow, output: String) async throws {
        guard let control = settingsToolbar.control else {
            throw NSError(domain: "WindowSwitch.SettingsCapture", code: 2)
        }
        var checks: [[String: Any]] = []
        for (index, title) in PreferencesToolbar.titles.enumerated() {
            settingsToolbar.select(index)
            try await Task.sleep(for: .milliseconds(200))
            let path = (output as NSString).deletingPathExtension + "-\(index).png"
            try captureSettingsWindow(window, to: path)
            let headerHeight = window.frame.height - window.contentLayoutRect.height
            let segmentFrame: CGRect? = control.convert(control.bounds, to: nil)
            let closeFrame = window.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: nil) }
            let alignment = segmentFrame.flatMap { segment in closeFrame.map { abs(segment.midY - $0.midY) } }
            func scrollCount(_ view: NSView) -> Int { (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + scrollCount($1) } }
            checks.append(["pane": title, "scrollViews": window.contentView.map(scrollCount) ?? -1, "selectionMatches": settingsNavigation.selected == index && control.selectedSegment == index,
                           "headerHeight": headerHeight, "trafficLightAlignment": alignment ?? -1,
                           "compact": headerHeight <= 50, "aligned": alignment.map { $0 <= 4 } ?? false,
                           "image": path])
        }
        let passed = checks.allSatisfy { $0["selectionMatches"] as? Bool == true
            && $0["compact"] as? Bool == true && $0["aligned"] as? Bool == true && $0["scrollViews"] as? Int == 0 }
        let report: [String: Any] = ["passed": passed, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: (output as NSString).deletingPathExtension + ".json"))
    }

    private var permissionsReady: Bool {
        PermissionReadiness(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess(), previewsEnabled: preferences.showPreviews).canStart
    }
    @objc private func showSetup() {
        controller.cancel(); hotkeys.stop(); dockFocus.stop(); nativeSwitcher.stop()
        if setupWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "WindowSwitch 设置向导"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: SetupWizard(preferences: preferences, guide: permissionGuide, finish: { [weak self] in
                guard let self, self.permissionsReady else { return }
                self.setupWindow?.close(); self.setupWindow = nil; self.permissionGuide.close()
                UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
                self.settingsOnly = false; self.refreshHooks()
            }))
            window.center(); setupWindow = window
        }
        setupPrompted = true
        if ProcessInfo.processInfo.arguments.contains("--setup-smoke") { setupWindow?.orderFrontRegardless() }
        else { NSApp.activate(ignoringOtherApps: true); setupWindow?.makeKeyAndOrderFront(nil) }
    }
    @objc private func checkForUpdates() { controller.cancel(); updates.checkForUpdates() }
    @objc private func showWindows() { if permissionsReady && setupWindow?.isVisible != true { controller.begin() } else { showSetup() } }
    @objc private func showDocuments() { library.showDocuments() }
    @objc private func toggleHotkeys() { preferences.enabled.toggle(); refreshHooks() }
    @objc private func toggleDockFocus() { preferences.dockFocusEnabled.toggle(); refreshHooks() }
    @objc private func resumeAfterSetup() { settingsOnly = false; refreshHooks() }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === setupWindow { setupWindow = nil; permissionGuide.close() }
        if !preferences.runInBackground && !settingsOnly { NSApp.terminate(nil) }
    }

    private func diagnose() {
        Task {
            var query = WindowQuery(); query.ownPID = ProcessInfo.processInfo.processIdentifier
            query.includeMinimized = true
            let windows = await controller.service.discover(query)
            let object: [String: Any] = [
                "accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
                "dockFocusDefaultEnabled": preferences.dockFocusEnabled,
                "windowCount": windows.count, "windows": windows.map {
                    ["id": $0.id, "pid": $0.pid, "app": $0.appName, "title": $0.title,
                     "minimized": $0.isMinimized, "onScreen": $0.isOnScreen] as [String: Any]
                }]
            if let json = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: json, encoding: .utf8) { print(text) }
            NSApp.terminate(nil)
        }
    }
}
