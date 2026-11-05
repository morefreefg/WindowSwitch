import AppKit
import Observation

@Observable final class PreferencesNavigation {
    var selected = 0
}

/// Own the titlebar explicitly: SwiftUI's automatic tab promotion gives the
/// fixed-size preferences window an oversized header on newer macOS releases.
final class PreferencesToolbar: NSObject, NSToolbarDelegate {
    static let titles = ["General", "App Switcher", "Appearance", "Performance", "Updates", "About"]
    private static let tabsID = NSToolbarItem.Identifier("WindowSwitch.PreferenceTabs")
    private let navigation: PreferencesNavigation
    private(set) var control: NSSegmentedControl?

    init(navigation: PreferencesNavigation) { self.navigation = navigation }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "WindowSwitch.Preferences")
        toolbar.delegate = self
        toolbar.displayMode = .labelOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = [Self.tabsID]
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tabsID, .flexibleSpace]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.tabsID else { return nil }
        let segments = NSSegmentedControl(labels: Self.titles, trackingMode: .selectOne,
                                          target: self, action: #selector(selectPane(_:)))
        segments.selectedSegment = navigation.selected
        segments.font = .systemFont(ofSize: 12)
        segments.segmentStyle = .capsule
        segments.segmentDistribution = .fit
        if #available(macOS 27.0, *) { segments.role = .tabs }
        for (index, width) in [64.0, 90, 88, 98, 72, 58].enumerated() { segments.setWidth(width, forSegment: index) }
        let tabSize = NSSize(width: ceil(segments.fittingSize.width), height: 26)
        segments.frame = CGRect(origin: .zero, size: tabSize)
        control = segments
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Preferences"
        item.isBordered = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: segments.frame)
            glass.style = .regular; glass.cornerRadius = 13
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.contentView = segments
            segments.autoresizingMask = [.width, .height]
            item.view = glass
        } else { item.view = segments }
        if let view = item.view {
            view.widthAnchor.constraint(equalToConstant: tabSize.width).isActive = true
            view.heightAnchor.constraint(equalToConstant: tabSize.height).isActive = true
        }
        item.minSize = tabSize
        item.maxSize = tabSize
        return item
    }
    @objc private func selectPane(_ sender: NSSegmentedControl) {
        guard Self.titles.indices.contains(sender.selectedSegment) else { return }
        navigation.selected = sender.selectedSegment
    }
}
