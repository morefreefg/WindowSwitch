import AppKit
import Observation

@Observable final class PreferencesNavigation {
    var selected = 0
}

/// Native preferences tabs: selectable toolbar items with symbols, as in the
/// system's own Settings windows. AppKit draws the Liquid Glass selection.
final class PreferencesToolbar: NSObject, NSToolbarDelegate {
    static let titles = ["General", "App Switcher", "Appearance", "Performance", "Updates", "About"]
    private static let symbols = ["gearshape", "rectangle.on.rectangle", "paintpalette", "gauge.with.dots.needle.67percent",
                                  "arrow.triangle.2.circlepath", "info.circle"]
    private static let identifiers = titles.indices.map { NSToolbarItem.Identifier("WindowSwitch.Pane.\($0)") }
    private let navigation: PreferencesNavigation
    private weak var toolbar: NSToolbar?

    init(navigation: PreferencesNavigation) { self.navigation = navigation }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "WindowSwitch.Preferences")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = Self.identifiers[navigation.selected]
        self.toolbar = toolbar
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.identifiers }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let index = Self.identifiers.firstIndex(of: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = Self.titles[index]
        item.image = NSImage(systemSymbolName: Self.symbols[index], accessibilityDescription: Self.titles[index])
        item.target = self; item.action = #selector(selectPane(_:)); item.tag = index
        return item
    }
    var selectedIndex: Int? { toolbar?.selectedItemIdentifier.flatMap { Self.identifiers.firstIndex(of: $0) } }
    func select(_ index: Int) {
        guard Self.titles.indices.contains(index) else { return }
        toolbar?.selectedItemIdentifier = Self.identifiers[index]
        navigation.selected = index
    }
    @objc private func selectPane(_ sender: NSToolbarItem) { select(sender.tag) }
}
