#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

BOOL WSRequestAccessibilityPermission(void);

typedef struct {
    BOOL symbolsAvailable;
    BOOL primaryImageReturned;
    uint32_t inputWidth;
    uint32_t inputHeight;
    uint32_t outputWidth;
    uint32_t outputHeight;
    uint32_t composedChildren;
    BOOL usedAXChildFallback;
} WSCaptureEvidence;

/// Does not request permission. NULL lets the caller use ScreenCaptureKit.
CGImageRef _Nullable WSCreateWindowPreview(uint32_t windowID, CGSize maxPixelSize,
    int interpolationQuality, BOOL allowRetina, WSCaptureEvidence * _Nullable evidence) CF_RETURNS_RETAINED;
