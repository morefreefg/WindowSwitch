import AppKit
import ApplicationServices

/// Observes Dock's actual AXProcessSwitcherList. It never installs an event tap or sends input.
@MainActor
final class NativeAppSwitcherObserver: NSObject {
    var onSelection: ((Int32?, Bool) -> Void)?
    private(set) var lastError: String?
    private(set) var isRunning = false
    /// Accessibility coordinates: origin at the upper-left of the main display.
    private(set) var switcherFrame: CGRect?
    private(set) var selectedAppFrame: CGRect?

    private var observer: AXObserver?
    private var dockElement: AXUIElement?
    private var switcherList: AXUIElement?
    private var workspaceNotificationsInstalled = false
    private var visible = false
    private var selectedPID: Int32?

    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else {
            lastError = "需要辅助功能权限才能观察原生应用切换器"
            return false
        }
        if isRunning { return true }
        if !workspaceNotificationsInstalled {
            let center = NSWorkspace.shared.notificationCenter
            center.addObserver(self, selector: #selector(workspaceChanged(_:)),
                               name: NSWorkspace.didLaunchApplicationNotification, object: nil)
            center.addObserver(self, selector: #selector(workspaceChanged(_:)),
                               name: NSWorkspace.didTerminateApplicationNotification, object: nil)
            workspaceNotificationsInstalled = true
        }
        return attachDock()
    }

    func stop() {
        detachDock()
        if workspaceNotificationsInstalled {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            workspaceNotificationsInstalled = false
        }
    }

    isolated deinit { stop() }

    private func attachDock() -> Bool {
        detachDock()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            lastError = "未找到 Dock 进程"
            return false
        }
        var created: AXObserver?
        let status = AXObserverCreate(dock.processIdentifier, { _, element, notification, context in
            guard let context else { return }
            // The source is registered only with CFRunLoopGetMain().
            MainActor.assumeIsolated {
                let owner = Unmanaged<NativeAppSwitcherObserver>.fromOpaque(context).takeUnretainedValue()
                owner.received(element: element, notification: notification as String)
            }
        }, &created)
        guard status == .success, let created else {
            lastError = "创建 Dock 辅助功能观察器失败：\(status.rawValue)"
            return false
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let focused = AXObserverAddNotification(created, application, kAXFocusedUIElementChangedNotification as CFString, context)
        let destroyed = AXObserverAddNotification(created, application, kAXUIElementDestroyedNotification as CFString, context)
        guard focused == .success, destroyed == .success else {
            AXObserverRemoveNotification(created, application, kAXFocusedUIElementChangedNotification as CFString)
            AXObserverRemoveNotification(created, application, kAXUIElementDestroyedNotification as CFString)
            lastError = "Dock 不支持所需 AX 通知：focus=\(focused.rawValue)，destroy=\(destroyed.rawValue)"
            return false
        }
        observer = created
        dockElement = application
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        isRunning = true
        lastError = nil
        if let focused = elementAttribute(application, kAXFocusedUIElementAttribute), isProcessSwitcher(focused) {
            observeList(focused)
        }
        return true
    }

    private func detachDock() {
        if let observer {
            if let list = switcherList {
                AXObserverRemoveNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString)
                AXObserverRemoveNotification(observer, list, kAXUIElementDestroyedNotification as CFString)
            }
            if let dockElement {
                AXObserverRemoveNotification(observer, dockElement, kAXFocusedUIElementChangedNotification as CFString)
                AXObserverRemoveNotification(observer, dockElement, kAXUIElementDestroyedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockElement = nil
        switcherList = nil
        switcherFrame = nil
        selectedAppFrame = nil
        isRunning = false
        emit(pid: nil, visible: false)
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.dock" else { return }
        if notification.name == NSWorkspace.didLaunchApplicationNotification { _ = attachDock() }
        else { detachDock() }
    }

    private func received(element: AXUIElement, notification: String) {
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            if isProcessSwitcher(element) { observeList(element) }
            else if let dockElement, let focused = elementAttribute(dockElement, kAXFocusedUIElementAttribute),
                    isProcessSwitcher(focused) { observeList(focused) }
        case kAXSelectedChildrenChangedNotification:
            if let list = switcherList, CFEqual(list, element) { refreshSelection() }
        case kAXUIElementDestroyedNotification:
            if let list = switcherList, CFEqual(list, element) {
                switcherList = nil
                emit(pid: nil, visible: false)
            } else if switcherList != nil { refreshSelection() }
        default: break
        }
    }

    private func observeList(_ list: AXUIElement) {
        guard let observer else { return }
        if let current = switcherList, CFEqual(current, list) {
            refreshSelection()
            return
        }
        if let current = switcherList {
            AXObserverRemoveNotification(observer, current, kAXSelectedChildrenChangedNotification as CFString)
            AXObserverRemoveNotification(observer, current, kAXUIElementDestroyedNotification as CFString)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let selected = AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString, context)
        guard selected == .success || selected == .notificationAlreadyRegistered else {
            lastError = "无法观察原生切换器选择：\(selected.rawValue)"
            switcherList = nil
            emit(pid: nil, visible: false)
            return
        }
        // Root destruction notifications already cover descendants; this is an additional direct subscription.
        _ = AXObserverAddNotification(observer, list, kAXUIElementDestroyedNotification as CFString, context)
        switcherList = list
        refreshSelection()
    }

    private func refreshSelection() {
        guard let list = switcherList else { return }
        switcherFrame = frame(of: list)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(list, kAXSelectedChildrenAttribute as CFString, &value)
        guard status == .success else {
            if status == .invalidUIElement {
                switcherList = nil
                emit(pid: nil, visible: false)
            }
            return
        }
        guard let selected = value as? [AXUIElement], let button = selected.first,
              let title = stringAttribute(button, kAXTitleAttribute) else {
            emit(pid: nil, visible: true)
            return
        }
        selectedAppFrame = frame(of: button)
        emit(pid: resolveApplication(title: title)?.processIdentifier, visible: true)
    }

    private func resolveApplication(title: String) -> NSRunningApplication? {
        // Dock's AX element belongs to Dock, so AXUIElementGetPid(button) is not the selected application's PID.
        let matches = NSWorkspace.shared.runningApplications.filter { app in
            var names = Set([app.localizedName].compactMap { $0 })
            if let url = app.bundleURL {
                let displayName = FileManager.default.displayName(atPath: url.path)
                names.insert(displayName)
                names.insert((displayName as NSString).deletingPathExtension)
                if let bundle = Bundle(url: url) {
                    for key in ["CFBundleDisplayName", "CFBundleName"] {
                        if let name = bundle.object(forInfoDictionaryKey: key) as? String { names.insert(name) }
                    }
                }
            }
            return names.contains(title)
        }
        // An ambiguous title is kept unresolved instead of switching to an arbitrary application.
        return matches.count == 1 ? matches.first : nil
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = unsafeDowncast(positionValue, to: AXValue.self)
        let size = unsafeDowncast(sizeValue, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func emit(pid: Int32?, visible newVisible: Bool) {
        if !newVisible { switcherFrame = nil; selectedAppFrame = nil }
        guard newVisible != visible || pid != selectedPID else { return }
        selectedPID = pid
        visible = newVisible
        onSelection?(pid, newVisible)
    }

    private func isProcessSwitcher(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXRoleAttribute) == kAXListRole
            && stringAttribute(element, kAXSubroleAttribute) == "AXProcessSwitcherList"
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
