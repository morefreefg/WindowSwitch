import Foundation
import CoreGraphics

public nonisolated struct SwitcherLayout: Sendable {
    public let itemSize: CGSize
    public let columns: Int
    public let capacity: Int
    public let rows: Int
    public let gridSize: CGSize
    public let panelFrame: CGRect
    public let inset: CGPoint

    public init(count: Int, preferredWidth: Double, screenFrame: CGRect, visibleFrame: CGRect,
                nativeListFrame: CGRect? = nil, selectedApplicationFrame: CGRect? = nil) {
        let configuredWidth = Int(preferredWidth == 0 ? 220 : preferredWidth)
        let width = max(2, configuredWidth - configuredWidth % 2)
        let ratio = min(visibleFrame.height / max(1, visibleFrame.width), 0.62)
        let rawHeight = Int(ratio * Double(width - 18) + 40)
        let height = max(2, rawHeight - rawHeight % 2)
        itemSize = CGSize(width: width, height: height)
        let fractionalColumns = Double(min(Int(screenFrame.width - 80), 2000)) / Double(width)
        let maxPerRow = max(1, Int(fractionalColumns))
        capacity = max(0, Int(screenFrame.height / Double(height) * fractionalColumns))
        let count = min(count, capacity)
        columns = min(max(0, count), maxPerRow)
        rows = count > 0 ? (count + maxPerRow - 1) / maxPerRow : 0
        gridSize = CGSize(width: columns * width, height: max(0, rows * height + max(0, rows - 1) * 10))
        if let list = nativeListFrame, let selected = selectedApplicationFrame {
            inset = CGPoint(x: 10, y: 10)
            let panelWidth = gridSize.width + 20
            let panelHeight = gridSize.height + 20
            let desiredX = selected.midX - panelWidth / 2
            let x = panelWidth > list.width ? list.midX - panelWidth / 2 : max(list.minX, min(desiredX, list.maxX - panelWidth))
            let integral = CGRect(x: x, y: list.minY - panelHeight - 10, width: panelWidth, height: panelHeight).integral
            panelFrame = CGRect(origin: integral.origin,
                                size: CGSize(width: Self.evenCeiling(integral.width), height: Self.evenCeiling(integral.height)))
        } else {
            inset = CGPoint(x: 30, y: 20)
            let size = CGSize(width: gridSize.width + 60, height: min(screenFrame.height, gridSize.height + 40))
            panelFrame = CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2,
                                width: size.width, height: size.height)
        }
    }

    /// Coordinates in the unflipped AppKit content view (grid anchor is top-left).
    public func itemFrame(at index: Int) -> CGRect {
        guard columns > 0 else { return .zero }
        let column = index % columns, row = index / columns
        return CGRect(x: inset.x + Double(column) * itemSize.width,
                      y: panelFrame.height - inset.y - itemSize.height - Double(row) * (itemSize.height + 10),
                      width: itemSize.width, height: itemSize.height)
    }

    public static func evenCeiling(_ number: Double) -> Double {
        let integer = Int(number)
        return Double(integer + integer % 2)
    }
}
