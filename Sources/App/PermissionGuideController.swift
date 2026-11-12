import AppKit
import Combine
import PermissionFlow

/// Shows a real app-bundle drag source beside the system permission list.
/// Opening the guide never toggles a system permission or changes Dock preferences.
final class PermissionGuideController {
    private let flow: PermissionFlowController
    private var poll: AnyCancellable?
    /// Where to come back after macOS's "Quit & Reopen": "setup" or "settings:<pane>".
    var resumeTarget: (() -> String?)?
    private static let resumeKey = "permissionRelaunchResume"

    /// Returns where a permission request was made if the app was relaunched shortly after it.
    static func consumeRelaunchResume() -> String? {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: resumeKey) }
        guard let value = defaults.dictionary(forKey: resumeKey), let target = value["target"] as? String,
              let date = value["date"] as? Date, Date().timeIntervalSince(date) < 600 else { return nil }
        return target
    }

    init() {
        PermissionStatusRegistry.register(provider: ScreenPreviewPermissionStatus(), for: .screenRecording)
        flow = PermissionFlow.makeController(configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false,
            localeIdentifier: "zh-Hans"
        ))
    }

    func showAccessibility() {
        guard !AXIsProcessTrusted() else { close(); return }
        _ = WSRequestAccessibilityPermission()
        show(.accessibility)
    }
    func showScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { close(); return }
        show(.screenRecording)
        // 同步调用会在主线程转出 main queue 并驱动嵌套 runloop，SwiftUI 在其中重算 body 会触发 MainActor 执行器断言
        DispatchQueue.global(qos: .userInitiated).async { _ = CGRequestScreenCaptureAccess() }
    }

    private func show(_ pane: PermissionFlowPane) {
        poll?.cancel()
        // Screen Recording usually takes effect only after the system's "Quit & Reopen";
        // remember the window so the relaunched app continues where the request was made.
        if let target = resumeTarget?() {
            UserDefaults.standard.set(["target": target, "date": Date()], forKey: Self.resumeKey)
        }
        let point = NSEvent.mouseLocation
        flow.authorize(pane: pane, suggestedAppURLs: [Bundle.main.bundleURL],
                       sourceFrameInScreen: CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
        poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            let granted = pane == .accessibility ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess()
            // Granted without a relaunch: nothing to resume on a later launch.
            if granted { UserDefaults.standard.removeObject(forKey: Self.resumeKey); self.close() }
        }
    }

    func close() { poll?.cancel(); poll = nil; flow.closePanel() }

    /// Opt-in build verification; this inspects only this app's own helper views.
    func validationSnapshot() -> [String: Any] {
        let panels = NSApp.windows.filter { $0.isVisible && $0.level == .floating }
        func containsDragSource(_ view: NSView) -> Bool {
            String(describing: type(of: view)).contains("AppDragSourceView") || view.subviews.contains(where: containsDragSource)
        }
        return ["accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
                "floatingPanels": panels.count,
                "nativeAppDragSource": panels.contains { $0.contentView.map(containsDragSource) ?? false },
                "packageResources": PermissionFlowResources.packageBundle != nil]
    }
}

private nonisolated struct ScreenPreviewPermissionStatus: PermissionStatusProviding {
    var capability: PermissionStatusCapability { .preflightSupported }
    func authorizationState() -> PermissionAuthorizationState {
        CGPreflightScreenCaptureAccess() ? .granted : .notGranted
    }
}
