#import "NativeSpaceBridge.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <AppKit/AppKit.h>

// intentionally unused; the observed pointer/integer argument ABI is preserved.
typedef int32_t (*WSBlurConnection)(void);
typedef void (*WSBlurRadius)(int32_t, int32_t, uintptr_t);
typedef void (*WSNewFilter)(int32_t, CFStringRef, void **);
typedef void (*WSAddFilter)(int32_t, int32_t, void *, int32_t);
typedef void (*WSRemoveFilter)(int32_t, int32_t, void *);
typedef void (*WSReleaseFilter)(int32_t, void *);
typedef void (*WSFilterValues)(int32_t, void *, CFDictionaryRef);
static WSBlurConnection blurConnection;
static WSBlurRadius blurRadius;
static WSNewFilter newFilter;
static WSAddFilter addFilter;
static WSRemoveFilter removeFilter;
static WSReleaseFilter releaseFilter;
static WSFilterValues filterValues;

@interface WSClassicBlurState : NSObject
@property(nonatomic) void *filter;
@property(nonatomic) int32_t windowID;
@property(nonatomic) BOOL enabled;
@end
@implementation WSClassicBlurState
- (void)dealloc {
    if (_filter && blurConnection) {
        int32_t cid = blurConnection();
        if (removeFilter) removeFilter(cid, _windowID, _filter);
        if (releaseFilter) releaseFilter(cid, _filter);
    }
}
@end

void WSConfigureClassicWindowBlur(NSWindow *window, BOOL enabled) {
    if (!window) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        if (!sky) return;
        blurConnection = (WSBlurConnection)dlsym(sky, "SLSMainConnectionID");
        blurRadius = (WSBlurRadius)dlsym(sky, "CGSSetWindowBackgroundBlurRadius");
        newFilter = (WSNewFilter)dlsym(sky, "CGSNewCIFilterByName");
        addFilter = (WSAddFilter)dlsym(sky, "CGSAddWindowFilter");
        removeFilter = (WSRemoveFilter)dlsym(sky, "CGSRemoveWindowFilter");
        releaseFilter = (WSReleaseFilter)dlsym(sky, "CGSReleaseCIFilter");
        filterValues = (WSFilterValues)dlsym(sky, "CGSSetCIFilterValuesFromDictionary");
    });
    if (!blurConnection) return;
    static char stateKey;
    WSClassicBlurState *state = objc_getAssociatedObject(window, &stateKey);
    if (!state && !enabled) return;
    if (!state) {
        state = [WSClassicBlurState new];
        state.windowID = (int32_t)window.windowNumber;
        objc_setAssociatedObject(window, &stateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.enabled == enabled) return;
    state.enabled = enabled;
    int32_t cid = blurConnection();
    if (blurRadius) blurRadius(cid, state.windowID, enabled ? 3 : 0);
    if (enabled && !state.filter && newFilter && addFilter && filterValues) {
        void *filter = NULL;
        newFilter(cid, CFSTR("CIGaussianBlur"), &filter);
        if (filter) {
            filterValues(cid, filter, (__bridge CFDictionaryRef)@{@"inputRadius": @((float)1.0f)});
            addFilter(cid, state.windowID, filter, 1);
            state.filter = filter;
        }
    } else if (!enabled && state.filter) {
        if (removeFilter) removeFilter(cid, state.windowID, state.filter);
        if (releaseFilter) releaseFilter(cid, state.filter);
        state.filter = NULL;
    }
}

void WSConfigureSwitcherMaterial(NSVisualEffectView *view, BOOL dark) {
    SEL selector = NSSelectorFromString(@"_setInternalMaterialType:");
    if ([view respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(view, selector, dark ? 4 : 0);
    }
    if (view.window) {
        typedef int (*BackdropBleed)(int, double);
        static BackdropBleed bleed;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            void *image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
            if (image) {
                bleed = (BackdropBleed)dlsym(image, "CGSWindowSetBackdropBackgroundBleed");
                if (!bleed) bleed = (BackdropBleed)dlsym(image, "SLSWindowSetBackdropBackgroundBleed");
            }
        });
        if (bleed) bleed((int)view.window.windowNumber, 0.0);
    }
}

@interface NSObject (WSPrivateSpaceOperation)
- (instancetype)initWithWindows:(NSArray<NSNumber *> *)windows spaceID:(uint64_t)spaceID;
@end

// The lookup strategy follows yabai's MIT-licensed macho_dlsym.h. See
// Docs/ThirdPartyNotices.md. Bounds and executable-address checks are added here.
static void *WSFindSkyLightSymbol(const char *name) {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !strstr(path, "/SkyLight.framework/") || !strstr(path, "/SkyLight")) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64 || header->sizeofcmds > 16 * 1024 * 1024) continue;
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        const uint8_t *end = cursor + header->sizeofcmds;
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        uint64_t executableStart = 0, executableEnd = 0;
        for (uint32_t j = 0; j < header->ncmds; ++j) {
            if ((size_t)(end - cursor) < sizeof(struct load_command)) break;
            const struct load_command *command = (const void *)cursor;
            if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) break;
            if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)cursor;
                if (!strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname))) linkedit = segment;
                if (segment->initprot & VM_PROT_EXECUTE) {
                    executableStart = segment->vmaddr;
                    executableEnd = segment->vmaddr + segment->vmsize;
                }
            } else if (command->cmd == LC_SYMTAB && command->cmdsize >= sizeof(struct symtab_command)) {
                symtab = (const void *)cursor;
            }
            cursor += command->cmdsize;
        }
        if (!linkedit || !symtab || !executableStart) continue;
        uint64_t symbolsEnd = (uint64_t)symtab->symoff + (uint64_t)symtab->nsyms * sizeof(struct nlist_64);
        uint64_t stringsEnd = (uint64_t)symtab->stroff + symtab->strsize;
        uint64_t fileEnd = linkedit->fileoff + linkedit->filesize;
        if (symtab->symoff < linkedit->fileoff || symbolsEnd > fileEnd ||
            symtab->stroff < linkedit->fileoff || stringsEnd > fileEnd) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        uintptr_t base = (uintptr_t)(linkedit->vmaddr + slide - linkedit->fileoff);
        const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
        const char *strings = (const void *)(base + symtab->stroff);
        size_t length = strlen(name);
        for (uint32_t j = 0; j < symtab->nsyms; ++j) {
            uint32_t offset = symbols[j].n_un.n_strx;
            if (offset >= symtab->strsize || length >= symtab->strsize - offset) continue;
            if (symbols[j].n_value < executableStart || symbols[j].n_value >= executableEnd) continue;
            if (!memcmp(strings + offset, name, length + 1)) return (void *)(symbols[j].n_value + slide);
        }
    }
    return NULL;
}

BOOL WSSubmitSpaceMove(uint32_t windowID, uint64_t spaceID) {
    if (!windowID || !spaceID) return NO;
    typedef int64_t (*SubmitOperation)(void *);
    static SubmitOperation submit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        submit = (SubmitOperation)WSFindSkyLightSymbol("__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    });
    Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    SEL selector = NSSelectorFromString(@"initWithWindows:spaceID:");
    if (!submit || !cls || !class_getInstanceMethod(cls, selector)) return NO;
    @try {
        id operation = [[cls alloc] initWithWindows:@[@(windowID)] spaceID:spaceID];
        if (!operation) return NO;
        submit((__bridge void *)operation);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
