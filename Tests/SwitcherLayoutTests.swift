import CoreGraphics
import Testing
@testable import WindowSwitchCore

@Suite struct SwitcherLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let visible = CGRect(x: 0, y: 0, width: 1920, height: 1050)

    @Test func configured185PointWidthAndFourItems() {
        let layout = SwitcherLayout(count: 4, preferredWidth: 185, screenFrame: screen, visibleFrame: visible)
        #expect(layout.itemSize == CGSize(width: 184, height: 130))
        #expect(layout.panelFrame == CGRect(x: 562, y: 455, width: 796, height: 170))
        #expect(layout.itemFrame(at: 0) == CGRect(x: 30, y: 20, width: 184, height: 130))
        #expect(layout.itemFrame(at: 3).minX == 582)
    }

    @Test func wrapsAtScreenWidthLimitWithTenPointRowGap() {
        let layout = SwitcherLayout(count: 13, preferredWidth: 185, screenFrame: screen, visibleFrame: visible)
        #expect(layout.columns == 10 && layout.rows == 2)
        #expect(layout.gridSize == CGSize(width: 1840, height: 270))
        #expect(layout.panelFrame.size == CGSize(width: 1900, height: 310))
        #expect(layout.itemFrame(at: 0).minY == 160)
        #expect(layout.itemFrame(at: 10).minY == 20)
    }

    @Test func aspectRatioCapsAtPoint62AndColumnsAt2000Points() {
        let portrait = SwitcherLayout(count: 2, preferredWidth: 185,
                                             screenFrame: CGRect(x: -1080, y: 0, width: 1080, height: 1920),
                                             visibleFrame: CGRect(x: -1080, y: 0, width: 1080, height: 1890))
        #expect(portrait.itemSize == CGSize(width: 184, height: 142))
        #expect(portrait.panelFrame.midX == -540)
        let wide = SwitcherLayout(count: 20, preferredWidth: 185,
                                         screenFrame: CGRect(x: 0, y: 0, width: 5120, height: 1440),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 5120, height: 1410))
        #expect(wide.columns == 10)
    }

    @Test func nativePreviewUsesAXCoordinatesAndListClamping() {
        let layout = SwitcherLayout(count: 3, preferredWidth: 185, screenFrame: screen, visibleFrame: visible,
                                            nativeListFrame: CGRect(x: 600, y: 400, width: 700, height: 180),
                                            selectedApplicationFrame: CGRect(x: 620, y: 410, width: 100, height: 100))
        #expect(layout.panelFrame == CGRect(x: 600, y: 240, width: 572, height: 150))
        #expect(layout.inset == CGPoint(x: 10, y: 10))
    }
}
