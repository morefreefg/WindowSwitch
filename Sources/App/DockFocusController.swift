import AppKit
import ApplicationServices
import Darwin
import os
import WindowSwitchCore

/// Symbols are optional: macOS can change these private APIs in a future release.
nonisolated enum SingleWindowActivation {
    struct FocusResult: Sendable {
        var accepted = false
        var stage = "symbols"
        let pid: Int32
        let windowID: UInt32
        var processCode: Int32?
        var frontCode: Int32?
        var postDownCode: Int32?
        var postUpCode: Int32?
        var raiseCode: Int32?

        var evidence: [String: String] {
            ["activationAccepted": "\(accepted)", "activationStage": stage,
             "activationPID": "\(pid)", "activationWindowID": "\(windowID)",
             "GetProcessForPID": processCode.map(String.init) ?? "not-called",
             "SLPSSetFrontProcess": frontCode.map(String.init) ?? "not-called",
             "SLPSPostDown": postDownCode.map(String.init) ?? "not-called",
             "SLPSPostUp": postUpCode.map(String.init) ?? "not-called",
             "AXRaise": raiseCode.map(String.init) ?? "not-called"]
        }
    }
    private typealias AXWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias ProcessFunction = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias FrontFunction = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostFunction = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private static let axWindow = symbol("_AXUIElementGetWindow", as: AXWindowFunction.self)
    private static let process = symbol("GetProcessForPID", as: ProcessFunction.self)
    private static let front = symbol("_SLPSSetFrontProcessWithOptions", as: FrontFunction.self)
    private static let post = symbol("SLPSPostEventRecordTo", as: PostFunction.self)

    static var available: Bool { process != nil && front != nil && post != nil }

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let axWindow, axWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func element(pid: Int32, windowID: UInt32) -> AXUIElement? {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.1)
        for window in DockAX.windows(root) where self.windowID(for: window) == windowID {
            AXUIElementSetMessagingTimeout(window, 0.1)
            return window
        }
        return nil
    }

    static func focus(pid: Int32, windowID: UInt32, element: AXUIElement? = nil) -> Bool {
        focusDetailed(pid: pid, windowID: windowID, element: element).accepted
    }

    static func focusDetailed(pid: Int32, windowID: UInt32, element: AXUIElement? = nil) -> FocusResult {
        var result = FocusResult(pid: pid, windowID: windowID)
        guard let process, let front, let post else { return result }
        result.stage = "window-identity"
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        guard rows.contains(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                && ($0[kCGWindowNumber as String] as? UInt32) == windowID
        }) else { return result }
        var psn = ProcessSerialNumber()
        result.stage = "process"
        let processResult = process(pid, &psn)
        result.processCode = processResult
        guard processResult == noErr else { return result }
        result.stage = "set-front"
        let frontResult = front(&psn, windowID, 0x200)
        result.frontCode = frontResult.rawValue
        guard frontResult == .success else { return result }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var id = windowID
        withUnsafeBytes(of: &id) { value in
            for (index, byte) in value.enumerated() { bytes[0x3c + index] = byte }
        }
        for index in 0..<0x10 { bytes[0x20 + index] = 0xff }
        bytes[0x08] = 0x01
        let first = post(&psn, &bytes)
        result.postDownCode = first.rawValue
        bytes[0x08] = 0x02
        let second = post(&psn, &bytes)
        result.postUpCode = second.rawValue
        result.stage = "post-records"
        guard first == .success, second == .success else { return result }
        if let target = element ?? self.element(pid: pid, windowID: windowID) {
            result.raiseCode = AXUIElementPerformAction(target, kAXRaiseAction as CFString).rawValue
        }
        result.stage = "completed"
        result.accepted = true
        return result
    }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        let paths: [String?] = [nil,
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "/System/Library/Frameworks/Carbon.framework/Carbon"]
        for path in paths {
            let handle = path.map { dlopen($0, RTLD_LAZY | RTLD_LOCAL) } ?? dlopen(nil, RTLD_LAZY)
            if let handle, let address = dlsym(handle, name) {
                // Loaded system frameworks remain open for these process-lifetime function pointers.
                return unsafeBitCast(address, to: T.self)
            }
            if let handle { dlclose(handle) }
        }
        return nil
    }
}

nonisolated enum DockAX {
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func windows(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPoint = value(element, kAXPositionAttribute),
              let rawSize = value(element, kAXSizeAttribute),
              CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(rawPoint, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        var point = frame.origin
        var size = frame.size
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s)
        let movedAgain = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p)
        return moved == .success && resized == .success && movedAgain == .success
    }
}

private nonisolated struct DockWindow: Sendable {
    let id: UInt32
    let frame: CGRect
    static func visible(pid: Int32) -> [DockWindow] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard row[kCGWindowOwnerPID as String] as? Int32 == pid,
                  row[kCGWindowLayer as String] as? Int == 0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 50, frame.height > 50 else { return nil }
            return DockWindow(id: id, frame: frame)
        }
    }
    func belongs(to display: CGRect, among displays: [CGRect]) -> Bool {
        let mine = Self.overlap(frame, display)
        return mine > 0 && displays.allSatisfy {
            $0 == display || Self.overlap(frame, $0) <= mine
        }
    }
    static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

private nonisolated struct DockApplication: Sendable {
    let pid: Int32
    let bundleID: String
    let path: String
    let hidden: Bool
}

private nonisolated struct DockPlan: Sendable {
    let application: DockApplication
    let display: CGRect
    let visible: CGRect
    let displays: [CGRect]
    let windowID: UInt32?
    let script: String?
}

/// The transport lock guards cross-thread flags/snapshots; event state is confined
/// to its dedicated run loop. It never runs a Process or blocks the keyboard tap.
private nonisolated final class DockMouseWorker: @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let plan: DockPlan
        let down: CGEvent
        let location: CGPoint
        let began: Date
    }
    private struct Click { let down: CGEvent; let up: CGEvent }
    private let lock = NSLock()
    private var enabled = true
    private var stopping = false
    private var loop: CFRunLoop?
    private var applications: [DockApplication] = []
    private var displays: [(frame: CGRect, visible: CGRect)] = []
    private var pending: Pending?
    private var executing: [UUID: Click] = [:]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let execute: @Sendable (DockPlan, UUID, DockMouseWorker) -> Void
    private static let marker: Int64 = 0x5744_4F43_4B
    private static let scripts = [
        "com.google.Chrome": "tell application id \"com.google.Chrome\" to make new window",
        "com.google.Chrome.canary": "tell application id \"com.google.Chrome.canary\" to make new window",
        "com.microsoft.edgemac": "tell application id \"com.microsoft.edgemac\" to make new window",
        "com.brave.Browser": "tell application id \"com.brave.Browser\" to make new window",
        "com.apple.Safari": "tell application id \"com.apple.Safari\" to make new document",
        "com.apple.finder": "tell application id \"com.apple.finder\" to make new Finder window"]

    init(execute: @escaping @Sendable (DockPlan, UUID, DockMouseWorker) -> Void) { self.execute = execute }

    func update(applications: [DockApplication], displays: [(CGRect, CGRect)]) {
        lock.withLock { self.applications = applications; self.displays = displays }
    }
    func setEnabled(_ value: Bool) {
        lock.withLock { enabled = value }
        if !value { schedule { self.flush() } }
    }
    func start() -> Bool {
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<DockMouseWorker>.fromOpaque(context).takeUnretainedValue()
                    .handle(type, event).map { Unmanaged.passUnretained($0) }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        Thread { self.run() }.start()
        return true
    }
    func stop() {
        lock.withLock { stopping = true; enabled = false }
        schedule {
            self.flush()
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
    func complete(_ id: UUID, success: Bool) {
        schedule {
            guard let click = self.executing.removeValue(forKey: id) else { return }
            if !success { Self.replay([click.down, click.up], refreshTimestamp: true) }
        }
    }
    private func run() {
        let current = CFRunLoopGetCurrent()
        let shouldStop = lock.withLock { loop = current; return stopping }
        guard !shouldStop, let tap, let source else {
            if let tap { CFMachPortInvalidate(tap) }
            return
        }
        CFRunLoopAddSource(current, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
        CFRunLoopRemoveSource(current, source, .commonModes)
        lock.withLock { loop = nil }
    }
    private func schedule(_ operation: @escaping @Sendable () -> Void) {
        guard let current = lock.withLock({ loop }) else { return }
        CFRunLoopPerformBlock(current, CFRunLoopMode.commonModes.rawValue, operation)
        CFRunLoopWakeUp(current)
    }
    private func flush() {
        if let pending { Self.replay([pending.down]); self.pending = nil }
        for click in executing.values { Self.replay([click.down, click.up]) }
        executing.removeAll()
    }
    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            flush()
            if let tap, !lock.withLock({ stopping }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return event }
        guard lock.withLock({ enabled && !stopping }) else { flush(); return event }
        switch type {
        case .leftMouseDown:
            if let pending { Self.replay([pending.down]); self.pending = nil }
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            guard event.flags.intersection(modifiers).isEmpty,
                  executing.count < 4, let plan = plan(at: event.location),
                  let down = event.copy() else { return event }
            let id = UUID()
            pending = Pending(id: id, plan: plan, down: down, location: event.location, began: Date())
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.6) {
                self.schedule {
                    guard self.pending?.id == id, let waiting = self.pending else { return }
                    self.pending = nil
                    Self.replay([waiting.down])
                }
            }
            return nil
        case .leftMouseDragged:
            guard let pending else { return event }
            guard hypot(event.location.x - pending.location.x, event.location.y - pending.location.y) >= 5 else { return nil }
            self.pending = nil
            if let drag = event.copy() { Self.replay([pending.down, drag]) }
            else { Self.replay([pending.down]); return event }
            return nil
        case .leftMouseUp:
            guard let pending else { return event }
            self.pending = nil
            guard let up = event.copy() else { Self.replay([pending.down]); return event }
            if Date().timeIntervalSince(pending.began) > 0.6 {
                Self.replay([pending.down, up])
            } else {
                executing[pending.id] = Click(down: pending.down, up: up)
                execute(pending.plan, pending.id, self)
            }
            return nil
        default: return event
        }
    }
    private func plan(at point: CGPoint) -> DockPlan? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(160))
        let snapshot = lock.withLock { (applications, displays) }
        guard let display = snapshot.1.first(where: { $0.frame.contains(point) }) else { return nil }
        // One AX hit test replaces a serial walk over every Dock icon.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.02)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var item = hit else { return nil }
        var dockPID: Int32 = 0
        AXUIElementGetPid(item, &dockPID)
        guard snapshot.0.contains(where: { $0.pid == dockPID && $0.bundleID == "com.apple.dock" }) else { return nil }
        for _ in 0..<4 {
            guard ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(item, 0.02)
            if DockAX.value(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem" { break }
            guard let parent = DockAX.value(item, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            item = unsafeDowncast(parent, to: AXUIElement.self)
        }
        guard ContinuousClock.now < deadline,
              DockAX.value(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              let url = DockAX.value(item, kAXURLAttribute) as? URL,
              let application = snapshot.0.first(where: {
                  $0.path == url.standardizedFileURL.resolvingSymlinksInPath().path
              }) else { return nil }
        let displays = snapshot.1.map(\.frame)
        return DockPlan(application: application, display: display.frame, visible: display.visible,
                        displays: displays, windowID: nil, script: Self.scripts[application.bundleID])
    }
    private static func replay(_ events: [CGEvent], refreshTimestamp: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        for (index, event) in events.enumerated() {
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            if refreshTimestamp { event.timestamp = now + UInt64(index) }
            event.post(tap: .cghidEventTap)
        }
    }
}

private actor DockFocusExecutor {
    private var scriptRunning = false
    private let service: WindowService
    init(service: WindowService) { self.service = service }

    func execute(_ plan: DockPlan) async -> Bool {
        let instances = await Self.currentInstances(plan.application)
        guard !instances.isEmpty, !Task.isCancelled else { return false }
        var query = WindowQuery()
        query.ownPID = ProcessInfo.processInfo.processIdentifier
        query.allowedPIDs = Set(instances.map(\.pid))
        query.currentPID = instances.first?.pid
        query.allScreens = false; query.screenBounds = plan.display
        query.includeMinimized = true; query.includeHidden = true
        var windows = await service.discover(query, cachedOnly: true)
        let hidden = Set(instances.filter(\.hidden).map(\.pid))
        func eligible(_ item: WindowItem) -> Bool {
            (item.isOnScreen || item.isMinimized || hidden.contains(item.pid)) && item.windowID != nil
                && DockWindow(id: item.windowID ?? 0, frame: item.frame).belongs(to: plan.display, among: plan.displays)
        }
        if !windows.contains(where: eligible) {
            for app in instances { await service.refreshApplicationInventory(pid: app.pid) }
            windows = await service.discover(query, cachedOnly: true)
        }
        if let target = windows.first(where: eligible) {
            let protected = DockDisplayStack.snapshot(excluding: plan.display, displays: plan.displays)
            return await focusExactly(target, protecting: protected)
        }
        guard let script = plan.script else { return false }
        // mistake the same newly created window for both requests.
        while scriptRunning {
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
        }
        guard !Task.isCancelled else { return false }
        scriptRunning = true
        defer { scriptRunning = false }
        guard !(await Self.currentInstances(plan.application)).isEmpty, !Task.isCancelled else { return false }
        let existing = instances.flatMap { DockWindow.visible(pid: $0.pid) }
        let before = Set(existing.map(\.id))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.placing(script, for: plan, like: existing.first)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while process.isRunning {
            if Task.isCancelled || ContinuousClock.now >= deadline {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return false
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return false
            }
        }
        guard process.terminationStatus == 0 else { return false }
        for _ in 0..<40 {
            guard !Task.isCancelled else { return false }
            if let pair = instances.compactMap({ app in DockWindow.visible(pid: app.pid).first(where: { !before.contains($0.id) }).map { (app, $0) } }).first {
                let (app, fresh) = pair
                guard let element = SingleWindowActivation.element(pid: app.pid, windowID: fresh.id) else { return false }
                if !fresh.belongs(to: plan.display, among: plan.displays) {
                    let width = min(fresh.frame.width, plan.visible.width)
                    let height = min(fresh.frame.height, plan.visible.height)
                    guard DockAX.setFrame(element, CGRect(x: plan.visible.midX - width / 2,
                        y: plan.visible.midY - height / 2, width: width, height: height)) else { return false }
                }
                let item = WindowItem(id: "ax:\(app.pid):\(fresh.id)", windowID: fresh.id, pid: app.pid,
                    appName: "", bundleID: app.bundleID, title: "", frame: fresh.frame)
                return await focusExactly(item)
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }
    /// Chromium places a new window next to its last active one, often on another
    /// display; moving it afterwards shows it sliding across. Passing bounds to
    /// `make new window` creates it on the clicked display from the first frame.
    private static let boundsAtCreation: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser"]
    private static func placing(_ script: String, for plan: DockPlan, like reference: DockWindow?) -> String {
        guard boundsAtCreation.contains(plan.application.bundleID) else { return script }
        let area = plan.visible
        let size = reference?.frame.size ?? CGSize(width: area.width * 0.8, height: area.height * 0.8)
        let width = min(size.width, area.width).rounded(.down)
        let height = min(size.height, area.height).rounded(.down)
        let left = (area.midX - width / 2).rounded(.down)
        let top = (area.midY - height / 2).rounded(.down)
        let bounds = [left, top, left + width, top + height].map { String(Int($0)) }.joined(separator: ", ")
        return script + " with properties {bounds:{\(bounds)}}"
    }
    private func focusExactly(_ target: WindowItem, protecting stacks: [DockDisplayStack] = []) async -> Bool {
        guard let id = target.windowID else { return false }
        // A single click owns the entire restore/activate/verification sequence.
        // AppKit can temporarily refuse AX requests during miniaturization.
        // Keep the same validated target through that transition; normal clicks
        // still return on their first successful activation.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
        for _ in 0..<8 {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            let accepted = await service.perform(.focus, on: target)
            if accepted, await service.frontmostWindowID() == id,
               DockWindow.visible(pid: target.pid).contains(where: { $0.id == id }) {
                // Restoring a hidden/minimized AppKit window can raise its sibling
                // windows asynchronously. Raise only the previously visible cover
                // on each other display, then keep the clicked window focused.
                try? await Task.sleep(for: .milliseconds(30))
                var restored = false
                for stack in stacks where stack.isCovered(by: target.pid) {
                    if stack.restore() { restored = true }
                }
                if restored { _ = await service.perform(.focus, on: target) }
                if stacks.allSatisfy({ !$0.isCovered(by: target.pid) }),
                   await service.frontmostWindowID() == id { return true }
            }
            if await service.isWindowMissing(target) { break }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
        }
        return false
    }
    @MainActor private static func currentInstances(_ application: DockApplication) -> [DockApplication] {
        NSWorkspace.shared.runningApplications.compactMap { running in
            guard !running.isTerminated, running.bundleIdentifier == application.bundleID,
                  running.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == application.path else { return nil }
            return DockApplication(pid: running.processIdentifier, bundleID: application.bundleID,
                                   path: application.path, hidden: running.isHidden)
        }
    }
}

/// Preserve only occlusion introduced by this activation, without reordering
/// unrelated windows or adding an artificial activation to the MRU history.
private nonisolated struct DockDisplayStack: Sendable {
    let pid: Int32
    let id: UInt32
    let display: CGRect
    let displays: [CGRect]
    private struct Row { let pid: Int32; let window: DockWindow }
    private static func rows() -> [Row] {
        let values = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return values.compactMap { row in
            guard row[kCGWindowLayer as String] as? Int == 0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 50, frame.height > 50 else { return nil }
            return Row(pid: pid, window: DockWindow(id: id, frame: frame))
        }
    }
    static func snapshot(excluding clicked: CGRect, displays: [CGRect]) -> [Self] {
        let rows = rows()
        return displays.filter { $0 != clicked }.compactMap { display in
            guard let top = rows.first(where: { $0.window.belongs(to: display, among: displays) }) else { return nil }
            return Self(pid: top.pid, id: top.window.id, display: display, displays: displays)
        }
    }
    func isCovered(by targetPID: Int32) -> Bool {
        guard pid != targetPID else { return false }
        let rows = Self.rows()
        guard let position = rows.firstIndex(where: { $0.pid == pid && $0.window.id == id }) else { return false }
        return rows.prefix(position).contains { $0.pid == targetPID && $0.window.belongs(to: display, among: displays) }
    }
    func restore() -> Bool {
        guard let element = SingleWindowActivation.element(pid: pid, windowID: id) else { return false }
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }
}

@MainActor
final class DockFocusController {
    private let onActivation: (() -> Void)?
    var enabled = true {
        didSet {
            guard oldValue != enabled else { return }
            if enabled { _ = start() } else { stop() }
        }
    }
    private var worker: DockMouseWorker?
    private let executor: DockFocusExecutor
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation = UUID()

    init(service: WindowService, onActivation: (() -> Void)? = nil) {
        executor = DockFocusExecutor(service: service); self.onActivation = onActivation
    }

    func focus(application: NSRunningApplication, on screen: NSScreen) async -> Bool {
        guard let bundleID = application.bundleIdentifier, let url = application.bundleURL else { return false }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        func frame(_ value: CGRect) -> CGRect { CGRect(x: value.minX, y: height - value.maxY, width: value.width, height: value.height) }
        let app = DockApplication(pid: application.processIdentifier, bundleID: bundleID,
            path: url.standardizedFileURL.resolvingSymlinksInPath().path, hidden: application.isHidden)
        return await executor.execute(DockPlan(application: app, display: frame(screen.frame), visible: frame(screen.visibleFrame),
            displays: NSScreen.screens.map { frame($0.frame) }, windowID: nil, script: nil))
    }

    func start() -> Bool {
        guard enabled else { return false }
        guard worker == nil else { return true }
        guard AXIsProcessTrusted(), SingleWindowActivation.available else { return false }
        let executor = executor
        let token = UUID()
        generation = token
        let newWorker = DockMouseWorker { [weak self] plan, id, sender in
            Task { @MainActor in
                guard let self, self.enabled, self.generation == token else {
                    sender.complete(id, success: false)
                    return
                }
                self.onActivation?()
                self.tasks[id] = Task { [weak self] in
                    let success = await executor.execute(plan)
                    sender.complete(id, success: success)
                    self?.tasks[id] = nil
                }
            }
        }
        worker = newWorker
        refreshSnapshot()
        newWorker.setEnabled(enabled)
        guard newWorker.start() else { worker = nil; return false }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSnapshot() }
            }
            observers.append((center, token))
        }
        let center = NotificationCenter.default
        let screenObserver = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSnapshot() }
        }
        observers.append((center, screenObserver))
        return true
    }

    func stop() {
        generation = UUID()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        worker?.stop()
        worker = nil
    }

    private func refreshSnapshot() {
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> DockApplication? in
            guard !app.isTerminated, let url = app.bundleURL,
                  let bundle = app.bundleIdentifier else { return nil }
            return DockApplication(pid: app.processIdentifier, bundleID: bundle,
                path: url.standardizedFileURL.resolvingSymlinksInPath().path, hidden: app.isHidden)
        }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let displays = NSScreen.screens.map { screen in
            let f = screen.frame
            let v = screen.visibleFrame
            return (CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height),
                    CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height))
        }
        worker?.update(applications: applications, displays: displays)
    }
}
