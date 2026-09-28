#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Checks the private presentation ABI. This does not detect a physical Touch Bar.
FOUNDATION_EXPORT BOOL PBTouchBarSupported(void);

/// Call on the main thread, from a running .app bundle. YES means the request was
/// sent successfully; macOS controls whether the bar is currently visible.
/// Preserve the Control Strip unless the user explicitly chooses a wider layout.
FOUNDATION_EXPORT BOOL PBPresentTouchBar(NSTouchBar *bar, BOOL preserveControlStrip);
FOUNDATION_EXPORT void PBDismissTouchBar(NSTouchBar *bar);

/// Registers one app-owned button for reopening the bar after dismissal.
/// These functions must also be called on the main thread.
FOUNDATION_EXPORT BOOL PBInstallControlStripItem(NSCustomTouchBarItem *item);
FOUNDATION_EXPORT void PBRemoveControlStripItem(NSCustomTouchBarItem *item);

NS_ASSUME_NONNULL_END
