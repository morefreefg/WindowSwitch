import Foundation

/// Pixel requirements for a static preview, independent of capture backend.
public nonisolated struct ThumbnailRequest: Equatable, Sendable {
    public let pixelSize: CGSize
    public let quality: Int

    public init(contentSize: CGSize, backingScale: CGFloat, quality: Int, background: Bool = false) {
        let width = contentSize.width.isFinite ? max(1, contentSize.width) : 1
        let height = contentSize.height.isFinite ? max(1, contentSize.height) : 1
        self.quality = background || quality == 2 ? 2 : 4
        let scale: CGFloat
        if background || self.quality == 2 {
            scale = min(1, (background ? 150 : 200) / max(width, height))
        } else {
            scale = backingScale.isFinite ? min(3, max(1, backingScale)) : 1
        }
        let limit: CGFloat = background ? 150 : (self.quality == 2 ? 200 : 4096)
        pixelSize = CGSize(width: min(limit, ceil(width * scale)), height: min(limit, ceil(height * scale)))
    }

    public func satisfies(_ requested: Self) -> Bool {
        quality >= requested.quality && pixelSize.width >= requested.pixelSize.width && pixelSize.height >= requested.pixelSize.height
    }
}

public nonisolated struct ThumbnailStamp: Sendable {
    public let windowSize: CGSize
    public let request: ThumbnailRequest
    public init(windowSize: CGSize, request: ThumbnailRequest) { self.windowSize = windowSize; self.request = request }
    public func satisfies(windowSize: CGSize, request: ThumbnailRequest) -> Bool {
        self.windowSize == windowSize && self.request.satisfies(request)
    }
}
