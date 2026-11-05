#import "NativeCaptureBridge.h"
#import <dlfcn.h>
#import <math.h>
#import <ApplicationServices/ApplicationServices.h>

typedef int32_t (*WSMainConnection)(void);
typedef int32_t (*WSWindowBounds)(int32_t, uint32_t, CGRect *);
typedef CGImageRef (*WSCreateImage)(CGRect, CFArrayRef, uint32_t);
typedef void (*WSImageCaching)(CGImageRef, uint32_t);
typedef int32_t (*WSWindowGroup)(int32_t, uint32_t, int32_t, uint32_t *, int32_t *, int32_t);
typedef void (*WSCopyChild)(CGContextRef, int32_t, uint32_t, int32_t, CGRect);

static WSMainConnection connection;
static WSWindowBounds getBounds;
static WSCreateImage createImage;
static WSImageCaching setCaching;
static WSWindowGroup windowGroup;
static WSCopyChild copyChild;
typedef AXError (*WSAXWindowID)(AXUIElementRef, uint32_t *);
static WSAXWindowID axWindowID;

static void WSLoadCaptureAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (cg) {
            createImage = (WSCreateImage)dlsym(cg, "CGWindowListCreateImageFromArray");
            setCaching = (WSImageCaching)dlsym(cg, "CGImageSetCachingFlags");
            copyChild = (WSCopyChild)dlsym(cg, "CGContextCopyWindowCaptureContentsToRect");
        }
        if (sky) {
            connection = (WSMainConnection)dlsym(sky, "_CGSDefaultConnection");
            if (!connection && cg) connection = (WSMainConnection)dlsym(cg, "_CGSDefaultConnection");
            if (!connection) connection = (WSMainConnection)dlsym(sky, "SLSMainConnectionID");
            if (!connection) connection = (WSMainConnection)dlsym(sky, "CGSMainConnectionID");
            getBounds = (WSWindowBounds)dlsym(sky, "CGSGetWindowBounds");
            if (!getBounds) getBounds = (WSWindowBounds)dlsym(sky, "SLSGetWindowBounds");
            windowGroup = (WSWindowGroup)dlsym(sky, "CGSGetWorkspaceWindowGroup");
            if (!windowGroup) windowGroup = (WSWindowGroup)dlsym(sky, "SLSGetWorkspaceWindowGroup");
            if (!copyChild) copyChild = (WSCopyChild)dlsym(sky, "CGContextCopyWindowCaptureContentsToRect");
        }
        void *hi = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL);
        if (hi) axWindowID = (WSAXWindowID)dlsym(hi, "_AXUIElementGetWindow");
    });
}

// Newer WindowServer versions can return no cross-process workspace group.
// AXSheets is a read-only, permission-checked fallback for the same children.
static uint32_t WSResolveSheetWindow(AXUIElementRef sheet, pid_t pid, uint32_t parent) {
    uint32_t child = 0;
    if (axWindowID(sheet, &child) == kAXErrorSuccess && child && child != parent) return child;
    CFTypeRef position = NULL, size = NULL;
    AXUIElementCopyAttributeValue(sheet, kAXPositionAttribute, &position);
    AXUIElementCopyAttributeValue(sheet, kAXSizeAttribute, &size);
    CGPoint origin = CGPointZero; CGSize dimensions = CGSizeZero;
    BOOL valid = position && size && CFGetTypeID(position) == AXValueGetTypeID() && CFGetTypeID(size) == AXValueGetTypeID()
        && AXValueGetValue(position, kAXValueCGPointType, &origin) && AXValueGetValue(size, kAXValueCGSizeType, &dimensions);
    if (position) CFRelease(position); if (size) CFRelease(size);
    if (!valid) return 0;
    CFArrayRef rows = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    uint32_t match = 0; int matches = 0;
    for (CFIndex i = 0; rows && i < CFArrayGetCount(rows); ++i) {
        CFDictionaryRef row = CFArrayGetValueAtIndex(rows, i);
        pid_t owner = 0; uint32_t number = 0; CGRect frame = CGRectZero;
        CFNumberRef ownerValue = CFDictionaryGetValue(row, kCGWindowOwnerPID);
        CFNumberRef idValue = CFDictionaryGetValue(row, kCGWindowNumber);
        CFDictionaryRef bounds = CFDictionaryGetValue(row, kCGWindowBounds);
        if (!ownerValue || !idValue || !bounds) continue;
        CFNumberGetValue(ownerValue, kCFNumberIntType, &owner); CFNumberGetValue(idValue, kCFNumberSInt32Type, &number);
        if (owner != pid || number == parent || !CGRectMakeWithDictionaryRepresentation(bounds, &frame)) continue;
        // AXSheet can describe its content, excluding the <=32pt title region.
        if (fabs(frame.origin.x - origin.x) <= 2 && fabs(frame.origin.y - origin.y) <= 32 &&
            fabs(frame.size.width - dimensions.width) <= 2 && fabs(frame.size.height - dimensions.height) <= 32) {
            match = number; matches += 1;
        }
    }
    if (rows) CFRelease(rows);
    return matches == 1 ? match : 0;
}

static CFArrayRef WSCopyAXSheetIDs(uint32_t windowID) {
    if (!axWindowID || !AXIsProcessTrusted()) return NULL;
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID);
    pid_t pid = 0;
    if (info && CFArrayGetCount(info)) {
        CFDictionaryRef row = CFArrayGetValueAtIndex(info, 0);
        CFNumberRef number = CFDictionaryGetValue(row, kCGWindowOwnerPID);
        if (number) CFNumberGetValue(number, kCFNumberIntType, &pid);
    }
    if (info) CFRelease(info);
    if (pid <= 0) return NULL;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.12);
    CFTypeRef windows = NULL;
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows);
    CFMutableArrayRef result = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (windows && CFGetTypeID(windows) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(windows); ++i) {
            AXUIElementRef element = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            if (!element || CFGetTypeID(element) != AXUIElementGetTypeID()) continue;
            AXUIElementSetMessagingTimeout(element, 0.12);
            uint32_t candidate = 0;
            if (axWindowID(element, &candidate) != kAXErrorSuccess || candidate != windowID) continue;
            CFTypeRef sheets = NULL;
            AXUIElementCopyAttributeValue(element, CFSTR("AXSheets"), &sheets);
            CFMutableArrayRef candidates = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
            if (sheets && CFGetTypeID(sheets) == CFArrayGetTypeID()) {
                for (CFIndex j = 0; j < CFArrayGetCount(sheets); ++j) {
                    CFArrayAppendValue(candidates, CFArrayGetValueAtIndex(sheets, j));
                }
            }
            CFTypeRef children = NULL;
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children);
            if (children && CFGetTypeID(children) == CFArrayGetTypeID()) {
                for (CFIndex j = 0; j < CFArrayGetCount(children); ++j) {
                    CFTypeRef value = CFArrayGetValueAtIndex(children, j);
                    if (!value || CFGetTypeID(value) != AXUIElementGetTypeID()) continue;
                    CFTypeRef role = NULL;
                    AXUIElementCopyAttributeValue((AXUIElementRef)value, kAXRoleAttribute, &role);
                    if (role && CFEqual(role, kAXSheetRole)) CFArrayAppendValue(candidates, value);
                    if (role) CFRelease(role);
                }
            }
            for (CFIndex j = 0; j < CFArrayGetCount(candidates); ++j) {
                AXUIElementRef sheet = (AXUIElementRef)CFArrayGetValueAtIndex(candidates, j);
                if (!sheet || CFGetTypeID(sheet) != AXUIElementGetTypeID()) continue;
                uint32_t child = WSResolveSheetWindow(sheet, pid, windowID);
                if (child) {
                    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &child);
                    if (!CFArrayContainsValue(result, CFRangeMake(0, CFArrayGetCount(result)), number)) CFArrayAppendValue(result, number);
                    CFRelease(number);
                }
            }
            CFRelease(candidates);
            if (children) CFRelease(children);
            if (sheets) CFRelease(sheets);
            break;
        }
    }
    if (windows) CFRelease(windows);
    CFRelease(app);
    return result;
}

CGImageRef WSCreateWindowPreview(uint32_t windowID, CGSize maxPixelSize,
    int quality, BOOL allowRetina, WSCaptureEvidence *evidence) {
    if (evidence) *evidence = (WSCaptureEvidence){0};
    WSLoadCaptureAPI();
    if (evidence) evidence->symbolsAvailable = connection && getBounds && createImage;
    if (!windowID || !connection || !getBounds || !createImage || !CGPreflightScreenCaptureAccess()) return NULL;
    CGRect parent = CGRectZero;
    int32_t cid = connection();
    if (getBounds(cid, windowID, &parent) != 0 || CGRectIsEmpty(parent) ||
        !isfinite(parent.size.width) || !isfinite(parent.size.height)) return NULL;
    double scale = 1;
    size_t width, height;
    if (maxPixelSize.width == 0) {
        width = (size_t)(parent.size.width * (allowRetina ? 2 : 1));
        height = (size_t)(parent.size.height * (allowRetina ? 2 : 1));
    } else {
        if (!isfinite(maxPixelSize.width) || !isfinite(maxPixelSize.height) ||
            maxPixelSize.width <= 0 || maxPixelSize.height <= 0) return NULL;
        float s = fminf((float)maxPixelSize.width / (float)parent.size.width,
                       (float)maxPixelSize.height / (float)parent.size.height);
        scale = s;
        width = (size_t)(s * (float)parent.size.width);
        height = (size_t)(s * (float)parent.size.height);
    }
    if (!width || !height || width > 8192 || height > 8192) return NULL;
    const void *rawID = (const void *)(uintptr_t)windowID;
    CFArrayRef ids = CFArrayCreate(kCFAllocatorDefault, &rawID, 1, NULL);
    CGImageRef source = createImage(CGRectNull, ids, 9);
    CFRelease(ids);
    // A refused/unavailable primary capture goes to the supported SCK path.
    // Do not attempt private child capture to evade a failed primary capture.
    if (!source) return NULL;
    if (evidence) {
        evidence->primaryImageReturned = YES;
        evidence->inputWidth = (uint32_t)CGImageGetWidth(source);
        evidence->inputHeight = (uint32_t)CGImageGetHeight(source);
    }
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, color, 0x2002);
    CGColorSpaceRelease(color);
    if (!bitmap) { CGImageRelease(source); return NULL; }
    CGContextSetShouldAntialias(bitmap, NO);
    CGContextSetAllowsAntialiasing(bitmap, NO);
    CGContextSetInterpolationQuality(bitmap, (CGInterpolationQuality)quality);
    if (setCaching) setCaching(source, 1);
    CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), source);
    CGContextFlush(bitmap);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{ CGImageRelease(source); });
    if (windowGroup && copyChild) {
        // Keep child-window enumeration bounded.
        const int capacity = 4096;
        uint32_t *children = calloc(capacity, sizeof(uint32_t));
        int32_t count = 0;
        if (children) {
            windowGroup(cid, windowID, 3, children, &count, 0);
            for (int i = 0; i < MIN(MAX(count, 0), capacity); ++i) {
                uint32_t child = children[i];
                CGRect frame = CGRectZero;
                if (!child || child == windowID || getBounds(cid, child, &frame) != 0 || CGRectIsEmpty(frame)) continue;
                CGRect rect = CGRectMake(scale * (parent.size.width - (frame.origin.x - parent.origin.x) - frame.size.width),
                                         scale * (parent.size.height - (frame.origin.y - parent.origin.y) - frame.size.height),
                                         (int)(scale * frame.size.width), (int)(scale * frame.size.height));
                rect = CGRectIntegral(rect);
                CGContextSetBlendMode(bitmap, kCGBlendModeNormal);
                copyChild(bitmap, cid, child, 0, rect);
                if (evidence) evidence->composedChildren += 1;
            }
            free(children);
        }
    }
    if (!evidence || evidence->composedChildren == 0) {
        CFArrayRef sheets = WSCopyAXSheetIDs(windowID);
        if (sheets) {
            for (CFIndex i = 0; i < CFArrayGetCount(sheets); ++i) {
                uint32_t child = 0; CGRect frame = CGRectZero;
                CFNumberGetValue(CFArrayGetValueAtIndex(sheets, i), kCFNumberSInt32Type, &child);
                if (!child || getBounds(cid, child, &frame) != 0 || CGRectIsEmpty(frame)) continue;
                const void *rawChild = (const void *)(uintptr_t)child;
                CFArrayRef array = CFArrayCreate(NULL, &rawChild, 1, NULL);
                CGImageRef childImage = createImage(CGRectNull, array, 9);
                CFRelease(array);
                if (!childImage) continue;
                CGRect rect = CGRectIntegral(CGRectMake(
                    scale * (parent.size.width - (frame.origin.x - parent.origin.x) - frame.size.width),
                    scale * (parent.size.height - (frame.origin.y - parent.origin.y) - frame.size.height),
                    (int)(scale * frame.size.width), (int)(scale * frame.size.height)));
                CGContextSetBlendMode(bitmap, kCGBlendModeNormal);
                CGContextDrawImage(bitmap, rect, childImage);
                CGImageRelease(childImage);
                if (evidence) { evidence->composedChildren += 1; evidence->usedAXChildFallback = YES; }
            }
            CFRelease(sheets);
        }
    }
    CGImageRef result = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    if (evidence) { evidence->outputWidth = (uint32_t)width; evidence->outputHeight = (uint32_t)height; }
    return result;
}
