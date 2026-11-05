import Foundation
import Testing
@testable import WindowSwitchCore

@Suite struct ThumbnailRequestTests {
    @Test func highUsesDisplayPixelsWhileLowStaysCapped() {
        let content = CGSize(width: 302, height: 186)
        let high = ThumbnailRequest(contentSize: content, backingScale: 2, quality: 4)
        let low = ThumbnailRequest(contentSize: content, backingScale: 2, quality: 2)
        #expect(high.pixelSize == CGSize(width: 604, height: 372))
        #expect(low.pixelSize.width == 200)
        #expect(high.satisfies(low))
        #expect(!low.satisfies(high))
    }
    @Test func backgroundAlwaysUsesSmallPlaceholder() {
        let background = ThumbnailRequest(contentSize: CGSize(width: 302, height: 186), backingScale: 3, quality: 4, background: true)
        #expect(background.pixelSize.width == 150)
        #expect(background.quality == 2)
        let high = ThumbnailRequest(contentSize: CGSize(width: 302, height: 186), backingScale: 1, quality: 4)
        #expect(!background.satisfies(high))
    }
    @Test func qualitySizeAndDisplayScaleInvalidateInsufficientCache() {
        let content = CGSize(width: 167, height: 100), window = CGSize(width: 1200, height: 800)
        let low = ThumbnailRequest(contentSize: content, backingScale: 1, quality: 2)
        let high = ThumbnailRequest(contentSize: content, backingScale: 1, quality: 4)
        let stamp = ThumbnailStamp(windowSize: window, request: low)
        #expect(!stamp.satisfies(windowSize: window, request: high))
        let retina = ThumbnailRequest(contentSize: content, backingScale: 2, quality: 4)
        let highStamp = ThumbnailStamp(windowSize: window, request: high)
        #expect(!highStamp.satisfies(windowSize: window, request: retina))
        #expect(!highStamp.satisfies(windowSize: CGSize(width: 1300, height: 800), request: high))
        #expect(highStamp.satisfies(windowSize: window, request: low))
        let enlarged = ThumbnailRequest(contentSize: CGSize(width: 302, height: 186), backingScale: 1, quality: 4)
        #expect(!high.satisfies(enlarged))
    }
}
