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
        toolbar.displayMode = .iconOnly
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
        // A plain bordered toolbar segmented control: AppKit gives it the native
        // Liquid Glass platter and sliding selection on macOS 26+. No custom glass.
        let segments = NSSegmentedControl(labels: Self.titles, trackingMode: .selectOne,
                                          target: self, action: #selector(selectPane(_:)))
        segments.selectedSegment = navigation.selected
        segments.segmentStyle = .automatic
        if #available(macOS 27.0, *) { segments.role = .tabs }
        segments.sizeToFit()
        control = segments
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Preferences"
        item.view = segments
        return item
    }
    func select(_ index: Int) {
        guard Self.titles.indices.contains(index) else { return }
        control?.selectedSegment = index
        navigation.selected = index
    }
    @objc private func selectPane(_ sender: NSSegmentedControl) {
        guard Self.titles.indices.contains(sender.selectedSegment) else { return }
        navigation.selected = sender.selectedSegment
    }
}
