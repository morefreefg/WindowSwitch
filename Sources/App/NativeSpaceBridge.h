#import <Foundation/Foundation.h>

/// Submits a dynamically discovered system operation. Success means submitted;
/// Swift independently verifies WindowServer membership before reporting success.
BOOL WSSubmitSpaceMove(uint32_t windowID, uint64_t spaceID);
@class NSVisualEffectView;
@class NSWindow;
void WSConfigureSwitcherMaterial(NSVisualEffectView *view, BOOL dark);
void WSConfigureClassicWindowBlur(NSWindow *window, BOOL enabled);
