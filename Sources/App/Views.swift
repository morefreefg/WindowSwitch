import AppKit
import SwiftUI
import WindowSwitchCore

struct SwitcherView: View {
    @Bindable var controller: SwitchController
    @Environment(\.colorScheme) private var systemTheme
    var body: some View {
        let layout = controller.switcherLayout
        let dark = controller.preferences.theme == "system" ? systemTheme == .dark : SwitcherTheme.isDark(controller.preferences.theme)
        ZStack(alignment: .topLeading) {
            SwitcherBackground(theme: controller.preferences.theme, color: NSColor(controller.preferences.backgroundColor),
                                       blurry: controller.preferences.backgroundBlur)
            ForEach(Array(controller.displayedWindows.enumerated()), id: \.element.id) { index, item in
                let rect = layout.itemFrame(at: index)
                windowCell(item, dark: dark)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: layout.panelFrame.height - rect.maxY)
            }
        }
        .frame(width: layout.panelFrame.width, height: layout.panelFrame.height)
        .clipped()
    }

    private func windowCell(_ item: WindowItem, dark: Bool) -> some View {
        let selected = (!controller.nativeSession || controller.browsingApplicationWindows)
            && controller.displayedSelection.selected?.id == item.id
        return WindowPreview(item: item, image: controller.preferences.showPreviews ? item.windowID.flatMap { controller.thumbnails[$0] } : nil,
                                     selected: selected, dark: dark, classic: controller.preferences.theme == "classic",
                                     showIcons: controller.preferences.showAppIcons && !controller.nativeSession,
                                     centerIcon: controller.preferences.iconScale >= 1,
                                     spaceNumber: item.windowID.flatMap { controller.spaceNumbers[$0] },
                                     onClose: { controller.selectWindow(item.id); controller.perform(.close) })
            .contentShape(Rectangle())
            .onTapGesture { controller.choose(item.id) }
            .onContinuousHover { phase in if case .active = phase { controller.hover(item.id) } }
        .contextMenu {
            ApplicationActionsMenu(bundleID: item.bundleID, onStatus: { controller.message = $0 }, onAction: { controller.cancel() })
            Button("切换到窗口") { controller.choose(item.id) }
            Button("最小化／恢复") { controller.selectWindow(item.id); controller.perform(.minimize) }
            Button("全屏／退出全屏") { controller.selectWindow(item.id); controller.perform(.toggleFullscreen) }
            Button("关闭窗口") { controller.selectWindow(item.id); controller.perform(.close) }
            Button("拉回当前桌面") { controller.selectWindow(item.id); controller.perform(.bringToCurrentSpace) }
            Divider()
            Button("新建窗口") { controller.selectWindow(item.id); controller.perform(.newWindow) }
            Button("新建标签页") { controller.selectWindow(item.id); controller.perform(.newTab) }
            Button("最近文档…") { controller.cancel(); controller.onRecentDocuments?(item.bundleID) }
            Menu("窗口布局") {
                Button("左半屏") { controller.selectWindow(item.id); controller.perform(.snapLeft) }
                Button("右半屏") { controller.selectWindow(item.id); controller.perform(.snapRight) }
                Button("最大化") { controller.selectWindow(item.id); controller.perform(.maximize) }
                Button("居中") { controller.selectWindow(item.id); controller.perform(.center) }
                Button("居中缩放") { controller.selectWindow(item.id); controller.perform(.compact) }
                Button("恢复布局") { controller.selectWindow(item.id); controller.perform(.restore) }
            }
            Menu("移到桌面") {
                ForEach(SpaceService.destinations(), id: \.ordinal) { space in
                    Button(space.name) {
                        if let id = item.windowID { Task { _ = await SpaceService.move(windowID: id, toOrdinal: space.ordinal) } }
                    }
                }
            }
            Divider()
            Button("隐藏应用") { controller.selectWindow(item.id); controller.perform(.hideApplication) }
            Button("退出应用") { controller.selectWindow(item.id); controller.perform(.quitApplication) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.appName)，\(item.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
