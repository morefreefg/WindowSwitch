import AppKit
import Combine
import PermissionFlow

/// Shows a real app-bundle drag source beside the system permission list.
/// Opening the guide never toggles a system permission or changes Dock preferences.
final class PermissionGuideController {
    private let flow: PermissionFlowController
    private var poll: AnyCancellable?

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
        show(.accessibility)
    }
    func showScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { close(); return }
        show(.screenRecording)
    }

    private func show(_ pane: PermissionFlowPane) {
        poll?.cancel()
        let point = NSEvent.mouseLocation
        flow.authorize(pane: pane, suggestedAppURLs: [Bundle.main.bundleURL],
                       sourceFrameInScreen: CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
        poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            let granted = pane == .accessibility ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess()
            if granted { self.close() }
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
