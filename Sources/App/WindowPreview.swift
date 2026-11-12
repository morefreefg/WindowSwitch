import AppKit
import QuartzCore
import SwiftUI
import WindowSwitchCore

enum SwitcherTheme {
    static func isDark(_ theme: String) -> Bool {
        if theme == "light" { return false }
        if theme == "dark" || theme == "classic" { return true }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

struct SwitcherBackground: NSViewRepresentable {
    let theme: String
    let color: NSColor
    let blurry: Bool
    func makeNSView(context: Context) -> SwitcherBackgroundView { SwitcherBackgroundView() }
    func updateNSView(_ view: SwitcherBackgroundView, context: Context) {
        let classic = theme == "classic"
        let dark = SwitcherTheme.isDark(theme)
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
        view.configure(classic: classic, dark: dark, color: color, blurry: blurry)
    }
}

final class SwitcherBackgroundView: NSView {
    private let effect = NSVisualEffectView()
    private var classic = false
    private var color = NSColor.black.withAlphaComponent(0.35)
    private var dark = false
    private var blurry = false
    private var configured = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.wantsLayer = true; effect.blendingMode = .behindWindow; effect.state = .active
        effect.autoresizingMask = [.width, .height]; addSubview(effect)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(classic: Bool, dark: Bool, color: NSColor, blurry: Bool) {
        guard !configured || self.classic != classic || self.dark != dark || self.color != color || self.blurry != blurry else { return }
        configured = true
        self.classic = classic; self.color = color
        self.dark = dark; self.blurry = blurry
        effect.isHidden = classic
        effect.material = dark ? .dark : .light
        effect.layer?.cornerRadius = 10; effect.layer?.masksToBounds = true
        WSConfigureSwitcherMaterial(effect, dark)
        window?.hasShadow = classic
        if let window { WSConfigureClassicWindowBlur(window, classic && blurry) }
        needsDisplay = true
    }
    override func layout() { super.layout(); effect.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.hasShadow = classic
        if let window { WSConfigureClassicWindowBlur(window, classic && blurry) }
        WSConfigureSwitcherMaterial(effect, dark)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard classic else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 25, yRadius: 25).fill()
    }
}

struct WindowPreview: NSViewRepresentable {
    let item: WindowItem
    let image: NSImage?
    let selected: Bool
    let dark: Bool
    let classic: Bool
    let showIcons: Bool
    let centerIcon: Bool
    let spaceNumber: Int?
    let onClose: () -> Void
    func makeNSView(context: Context) -> WindowPreviewView { WindowPreviewView() }
    func updateNSView(_ view: WindowPreviewView, context: Context) {
        view.update(item: item, image: image, selected: selected, dark: dark, classic: classic,
                    showIcons: showIcons, centerIcon: centerIcon, spaceNumber: spaceNumber, onClose: onClose)
    }
}

final class WindowPreviewView: NSView {
    private struct RenderState: Equatable {
        let id: String
        let title: String
        let frame: CGRect
        let hidden: Bool
        let onScreen: Bool
        let image: ObjectIdentifier?
        let selected: Bool
        let dark: Bool
        let classic: Bool
        let showIcons: Bool
        let centerIcon: Bool
        let space: Int?
    }
    private var renderedState: RenderState?
    private static let icons: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 128; cache.totalCostLimit = 16_000_000
        return cache
    }()
    private let highlight = CAGradientLayer()
    private let screenshot = CALayer()
    private let screenshotImage = CALayer()
    private let icon = CALayer()
    private let title = CATextLayer()
    private let space = CATextLayer()
    private let close = NSButton()
    private var closeAction: (() -> Void)?
    private var closeTask: Task<Void, Never>?
    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private var centeredIcon = true
    private var selected = false
    private var imageSize = CGSize.zero
    private var originalWindowSize = CGSize.zero
    private var imageIdentity: ObjectIdentifier?
    private var renderedWindowID: String?
    private var iconKey = ""
    private var classic = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        for child in [highlight, screenshot, icon, title, space] {
            child.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                             "backgroundColor": NSNull(), "opacity": NSNull()]
            layer.addSublayer(child)
        }
        screenshot.addSublayer(screenshotImage)
        screenshotImage.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        screenshotImage.contentsGravity = .resize
        screenshotImage.minificationFilter = .linear
        screenshotImage.magnificationFilter = .linear
        screenshot.shadowColor = NSColor.black.cgColor
        screenshot.shadowOpacity = 0.4
        screenshot.shadowRadius = 4
        screenshot.shadowOffset = CGSize(width: 1, height: -1)
        screenshot.anchorPoint = CGPoint(x: 0.5, y: 0)
        screenshot.zPosition = 2
        icon.contentsGravity = .resizeAspect
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.4
        icon.shadowRadius = 10
        icon.shadowOffset = CGSize(width: 1, height: -1)
        icon.zPosition = 99
        icon.minificationFilter = .trilinear
        title.anchorPoint = CGPoint(x: 0.5, y: 0)
        title.alignmentMode = .center
        title.truncationMode = .end
        title.contentsGravity = .center
        title.fontSize = 13
        title.zPosition = 10
        title.isWrapped = false
        space.fontSize = 30; space.alignmentMode = .center; space.foregroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.7).cgColor
        space.zPosition = 3
        close.title = ""; close.isBordered = false; close.wantsLayer = true
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭窗口")
        close.contentTintColor = .secondaryLabelColor
        close.imageScaling = .scaleProportionallyUpOrDown
        close.target = self; close.action = #selector(closeWindow); close.isHidden = true
        close.setAccessibilityLabel("关闭窗口"); addSubview(close)
        close.layer?.zPosition = 99
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(item: WindowItem, image: NSImage?, selected: Bool, dark: Bool, classic: Bool,
                showIcons: Bool, centerIcon: Bool, spaceNumber: Int?, onClose: @escaping () -> Void) {
        closeAction = onClose
        let state = RenderState(id: item.id, title: item.title, frame: item.frame,
            hidden: item.isHidden, onScreen: item.isOnScreen, image: image.map(ObjectIdentifier.init),
            selected: selected, dark: dark, classic: classic, showIcons: showIcons, centerIcon: centerIcon, space: spaceNumber)
        guard state != renderedState else { return }
        renderedState = state
        let wasSelected = self.selected
        self.selected = selected; self.centeredIcon = centerIcon; self.classic = classic
        closeAction = onClose; originalWindowSize = item.frame.size
        space.string = spaceNumber.map(String.init)
        space.isHidden = spaceNumber == nil
        if !selected { hideCloseBox() }
        else if !wasSelected && hovering { scheduleCloseBox() }
        let opacity: Float = selected || (!item.isHidden && item.isOnScreen) ? 1 : 0.7
        screenshot.opacity = opacity; icon.opacity = opacity
        icon.isHidden = !showIcons
        title.string = item.title
        title.font = dark ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 14)
        title.foregroundColor = (dark ? NSColor.white : NSColor(calibratedWhite: 0.1, alpha: 1)).cgColor
        title.zPosition = dark ? 1001 : 10
        title.shadowColor = NSColor.black.cgColor
        title.shadowOpacity = dark ? 1 : 0
        title.shadowRadius = 1
        title.shadowOffset = CGSize(width: 1, height: -1)
        highlight.cornerRadius = classic ? 8 : 6
        highlight.backgroundColor = selected && !classic ? (dark ? NSColor(calibratedWhite: 0.7, alpha: 0.3) : NSColor.black.withAlphaComponent(0.1)).cgColor : nil
        highlight.colors = classic && selected ? [NSColor.white.withAlphaComponent(0.2).cgColor, NSColor.white.withAlphaComponent(0.6).cgColor] : nil
        if imageIdentity != image.map(ObjectIdentifier.init) {
            let sameWindow = renderedWindowID == item.id
            imageIdentity = image.map(ObjectIdentifier.init)
            renderedWindowID = item.id
            if let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                // A preview arriving or improving for the same window cross-fades instead of popping.
                if sameWindow, window?.isVisible == true, window?.alphaValue ?? 0 > 0 {
                    let fade = CATransition()
                    fade.type = .fade; fade.duration = 0.18
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    screenshotImage.add(fade, forKey: "contents")
                }
                screenshotImage.contents = cgImage
                imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            } else { screenshotImage.contents = nil; imageSize = .zero }
        }
        let pixels = Int((centerIcon ? 64 : 48) * (NSScreen.screens.contains { $0.backingScaleFactor > 1.1 } ? 2 : 1))
        let key = "\(item.documentURL?.path ?? item.bundleID):\(pixels)"
        if key != iconKey {
            iconKey = key
            let image: NSImage?
            if let url = item.documentURL { image = NSWorkspace.shared.icon(forFile: url.path) }
            else if let url = NSRunningApplication(processIdentifier: item.pid)?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) {
                let bundle = Bundle(url: url)
                let filename = bundle?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
                let path = filename.flatMap { name in
                    bundle?.path(forResource: name, ofType: nil)
                        ?? bundle?.path(forResource: (name as NSString).deletingPathExtension,
                                        ofType: (name as NSString).pathExtension.isEmpty ? "icns" : (name as NSString).pathExtension)
                }
                image = path.flatMap(NSImage.init(contentsOfFile:)) ?? NSWorkspace.shared.icon(forFile: url.path)
            } else { image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) }
            if let cached = Self.icons.object(forKey: key as NSString) { icon.contents = cached }
            else if let source = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                    let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                bitmap.interpolationQuality = .high
                bitmap.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                if let rendered = bitmap.makeImage() {
                    Self.icons.setObject(rendered, forKey: key as NSString, cost: pixels * pixels * 4)
                    icon.contents = rendered
                }
            }
        }
        setAccessibilityLabel("\(item.appName)，\(item.title)")
        needsLayout = true
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        for child in [title, screenshot, screenshotImage, icon] { child.contentsScale = scale }
        let width = bounds.width, height = bounds.height
        let preferred = title.preferredFrameSize()
        let titleHeight = SwitcherLayout.evenCeiling(preferred.height)
        let titleWidth = SwitcherLayout.evenCeiling(min(preferred.width, max(0, width - 26)))
        title.bounds = CGRect(x: 0, y: 0, width: titleWidth, height: titleHeight + 2)
        title.position = CGPoint(x: width / 2, y: 4)
        screenshot.bounds = CGRect(x: 0, y: 0, width: max(0, width - 18), height: max(0, height - 24 - titleHeight))
        screenshot.position = CGPoint(x: CGFloat(Int(width) / 2), y: titleHeight + 12)
        screenshot.shadowPath = CGPath(rect: screenshot.bounds, transform: nil)
        let displayed: CGSize
        if imageSize.width > 0 && imageSize.height > 0 {
            let fit = min(screenshot.bounds.width / imageSize.width, screenshot.bounds.height / imageSize.height)
            displayed = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
            screenshotImage.backgroundColor = nil
        } else {
            let fit = originalWindowSize.width > 0 && originalWindowSize.height > 0
                ? min(screenshot.bounds.width / originalWindowSize.width, screenshot.bounds.height / originalWindowSize.height) : 0
            displayed = CGSize(width: originalWindowSize.width * fit, height: originalWindowSize.height * fit)
            screenshotImage.backgroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        }
        screenshotImage.frame = CGRect(x: CGFloat(Int((screenshot.bounds.width - displayed.width) / 2)), y: 0,
                                       width: displayed.width, height: displayed.height)
        let iconSize: CGFloat = width > 180 ? 64 : 32
        icon.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        if centeredIcon {
            icon.contentsGravity = .resizeAspect
            icon.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            icon.position = CGPoint(x: width / 2, y: CGFloat(Int(height / 2) + 4))
        } else {
            icon.contentsGravity = .bottomRight
            icon.anchorPoint = CGPoint(x: 1, y: 0)
            icon.position = CGPoint(x: Int(width / 2 + displayed.width / 2 + 6), y: Int(screenshot.position.y - 6))
        }
        highlight.frame = bounds
        space.bounds = CGRect(origin: .zero, size: space.preferredFrameSize())
        space.contentsGravity = .center
        space.contentsScale = scale
        space.position = CGPoint(x: width / 2, y: height / 2 + 4)
        close.frame = CGRect(x: Int(width / 2 - displayed.width / 2 - 10),
                             y: Int(height / 2 + displayed.height / 2) - 17, width: 30, height: 30)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; scheduleCloseBox() }
    override func mouseExited(with event: NSEvent) { hovering = false; hideCloseBox() }
    override func mouseMoved(with event: NSEvent) { if hovering { scheduleCloseBox() } }
    private func scheduleCloseBox() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.hovering, self.selected else { return }
            self.close.isHidden = false
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.4; pulse.duration = 10; pulse.repeatCount = 3
            pulse.isRemovedOnCompletion = false
            self.close.layer?.add(pulse, forKey: "opacity")
        }
    }
    private func hideCloseBox() { closeTask?.cancel(); closeTask = nil; close.isHidden = true; close.layer?.removeAllAnimations() }
    @objc private func closeWindow() { closeAction?() }
}
