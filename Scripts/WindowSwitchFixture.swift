import AppKit

/// Disposable windows for the real WindowSwitch regression harness. No documents
/// are opened, no save panels are presented, and every action is recorded locally.
@main
struct WindowSwitchFixtureEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let sentinel = ProcessInfo.processInfo.arguments.contains("--sentinel")
    private var windows: [String: NSWindow] = [:]
    private var counter = 0
    private var actionCounts: [String: Int] = [:]
    private var launchReady = false
    private var activationObserved = false
    private var captureChild: NSPanel?
    private var session: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--session"), args.indices.contains(index + 1) else { return "manual" }
        return args[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        if sentinel {
            create(id: "Sentinel", screen: min(1, NSScreen.screens.count - 1), offset: 100)
        } else {
            create(id: "A", screen: 0, offset: 60)
            create(id: "B", screen: min(1, NSScreen.screens.count - 1), offset: 100)
            create(id: "C", screen: 0, offset: 180)
            if ProcessInfo.processInfo.arguments.contains("--capture-child"), let parent = windows["A"] {
                let child = NSPanel(contentRect: CGRect(x: parent.frame.minX + 40, y: parent.frame.minY + 60,
                                                       width: 160, height: 100),
                                    styleMask: [.titled], backing: .buffered, defer: false)
                child.title = "WSChildOverlay"; child.backgroundColor = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
                child.isOpaque = true; child.hidesOnDeactivate = false
                child.isReleasedWhenClosed = false
                let fill = NSView(frame: child.contentView?.bounds ?? .zero)
                fill.wantsLayer = true; fill.layer?.backgroundColor = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).cgColor
                fill.autoresizingMask = [.width, .height]; child.contentView = fill
                parent.beginSheet(child); captureChild = child
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        launchReady = true
        writeState()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        activationObserved = true
        writeState()
    }

    private func makeMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        menu.addItem(app)
        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "New Tab Marker", action: #selector(newTab), keyEquivalent: "t").target = self
        fileMenu.addItem(withTitle: "Open Marker", action: #selector(openMarker), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu
        menu.addItem(file)
        NSApp.mainMenu = menu
    }

    private func create(id: String, screen index: Int, offset: CGFloat) {
        guard !NSScreen.screens.isEmpty else { return }
        let screen = NSScreen.screens[max(0, min(index, NSScreen.screens.count - 1))]
        let area = screen.visibleFrame
        let width = min(600, area.width - 40)
        let height = min(380, area.height - 40)
        let frame = CGRect(x: min(area.minX + offset, area.maxX - width),
                           y: max(area.minY + 20, area.maxY - height - offset), width: width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = "WSFixture_\(id)"
        window.minSize = NSSize(width: 180, height: 120)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        let label = NSTextField(wrappingLabelWithString: "WindowSwitch fixture · \(id)\nDisposable test window\nCommand-N / Command-T / Command-O")
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        if let content = window.contentView {
            content.addSubview(label)
            let activate = NSButton(title: "Activate Test App", target: self, action: #selector(activateFixture))
            activate.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(activate)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
                activate.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                activate.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
        }
        window.backgroundColor = sentinel ? NSColor.systemOrange : NSColor.windowBackgroundColor
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        writeState()
    }

    @objc private func activateFixture() {
        NSApp.activate(ignoringOtherApps: true)
        (windows["A"] ?? windows.values.first)?.makeKeyAndOrderFront(nil)
        writeState()
    }

    @objc private func newWindow() {
        counter += 1
        actionCounts["newWindow", default: 0] += 1
        create(id: "N\(counter)", screen: 0, offset: 120)
        writeState()
    }
    @objc private func newTab() {
        actionCounts["newTab", default: 0] += 1
        if let window = NSApp.keyWindow, let id = window.identifier?.rawValue {
            window.title = "WSFixture_\(id)_T\(actionCounts["newTab", default: 0])"
        }
        writeState()
    }
    @objc private func openMarker() {
        actionCounts["openFile", default: 0] += 1
        writeState()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let id = window.identifier?.rawValue { windows[id] = nil }
        writeState()
    }
    func windowDidMove(_ notification: Notification) { writeState() }
    func windowDidResize(_ notification: Notification) { writeState() }
    func windowDidMiniaturize(_ notification: Notification) { writeState() }
    func windowDidDeminiaturize(_ notification: Notification) { writeState() }
    func windowDidEnterFullScreen(_ notification: Notification) { writeState() }
    func windowDidExitFullScreen(_ notification: Notification) { writeState() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func writeState() {
        let object: [String: Any] = [
            "bundleID": Bundle.main.bundleIdentifier ?? "", "pid": ProcessInfo.processInfo.processIdentifier,
            "session": session, "sentinel": sentinel, "actionCounts": actionCounts,
            "hasCaptureChild": captureChild != nil,
            "captureChildVisible": captureChild?.isVisible ?? false,
            "captureChildWindowID": captureChild?.windowNumber ?? 0,
            "launchReady": launchReady, "activationObserved": activationObserved,
            "expectedWindowCount": sentinel ? 1 : 3,
            "windows": windows.sorted { $0.key < $1.key }.map { id, window in
                ["id": id, "title": window.title, "visible": window.isVisible,
                 "minimized": window.isMiniaturized, "fullscreen": window.styleMask.contains(.fullScreen),
                 "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height]] as [String: Any]
            }]
        let directory = URL(fileURLWithPath: "/tmp/codex-windowswitch", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("fixture-state-\(ProcessInfo.processInfo.processIdentifier).json"), options: .atomic)
    }
}
