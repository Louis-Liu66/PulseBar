#import "TouchBarBridge.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

// API declarations and placement semantics were checked against MTMR and Pock:
// https://github.com/Toxblh/MTMR/blob/master/MTMR/CBridge/TouchBarPrivateApi.h
// https://github.com/Toxblh/MTMR/blob/master/MTMR/TouchBarController.swift
// https://github.com/pock/pock/blob/main/Pock/Private/TouchBarHelper.swift
// This bridge is an independent implementation. No third-party source is bundled.
// These are private APIs: runtime ABI checks avoid known incompatible signatures,
// but Apple does not promise their availability or behavior in future macOS.

typedef void (*PBSetPresenceFunction)(NSTouchBarItemIdentifier, BOOL);
typedef void (*PBSetCloseBoxFunction)(BOOL);
typedef void (*PBObjectMessage)(id, SEL, id);
typedef void (*PBPresentMessage)(id, SEL, NSTouchBar *, NSTouchBarItemIdentifier);
typedef void (*PBPlacementMessage)(id, SEL, NSTouchBar *, long long,
                                   NSTouchBarItemIdentifier);

static PBSetPresenceFunction PBSetPresence;
static PBSetCloseBoxFunction PBSetCloseBox;
static NSCustomTouchBarItem *PBInstalledItem;
static NSTouchBar *PBPresentedBar;
static id PBTerminationObserver;

static void PBLoadFramework(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Retain the handle for the process lifetime; function pointers use it.
        void *framework = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
                                 RTLD_LAZY | RTLD_LOCAL);
        if (!framework) return;
        PBSetPresence = (PBSetPresenceFunction)dlsym(framework, "DFRElementSetControlStripPresenceForIdentifier");
        PBSetCloseBox = (PBSetCloseBoxFunction)dlsym(framework, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    });
}

static const char *PBUnqualifiedType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL PBMatchesType(const char *type, char expected) {
    return type && PBUnqualifiedType(type)[0] == expected;
}

// All dynamic calls below validate argument types, not just selector existence.
static BOOL PBHasMethod(Class cls, NSString *name, const char *arguments) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getClassMethod(cls, selector);
    if (!method || ![cls respondsToSelector:selector]) return NO;
    unsigned count = (unsigned)strlen(arguments);
    if (method_getNumberOfArguments(method) != count + 2) return NO;
    char type[64] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (!PBMatchesType(type, 'v')) return NO;
    for (unsigned i = 0; i < count; i++) {
        method_getArgumentType(method, i + 2, type, sizeof(type));
        if (!PBMatchesType(type, arguments[i])) return NO;
    }
    return YES;
}

static NSString *PBDismissSelectorName(void) {
    if (PBHasMethod(NSTouchBar.class, @"dismissSystemModalTouchBar:", "@"))
        return @"dismissSystemModalTouchBar:";
    if (PBHasMethod(NSTouchBar.class, @"dismissSystemModalFunctionBar:", "@"))
        return @"dismissSystemModalFunctionBar:";
    return nil;
}

static NSString *PBPresentationSelectorName(BOOL preserveControlStrip) {
    // The no-placement form leaves the native Control Strip available. Placement
    // 1 is the full-width form used by MTMR/Pock. Never infer a value for placement 0.
    NSString *modern = preserveControlStrip
        ? @"presentSystemModalTouchBar:systemTrayItemIdentifier:"
        : @"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:";
    NSString *legacy = preserveControlStrip
        ? @"presentSystemModalFunctionBar:systemTrayItemIdentifier:"
        : @"presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:";
    const char *signature = preserveControlStrip ? "@@" : "@q@";
    if (PBHasMethod(NSTouchBar.class, modern, signature)) return modern;
    if (PBHasMethod(NSTouchBar.class, legacy, signature)) return legacy;
    return nil;
}

static void PBObserveTermination(void) {
    if (PBTerminationObserver) return;
    PBTerminationObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationWillTerminateNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            (void)notification;
            if (PBPresentedBar) PBDismissTouchBar(PBPresentedBar);
            if (PBInstalledItem) PBRemoveControlStripItem(PBInstalledItem);
        }];
}

BOOL PBTouchBarSupported(void) {
    PBLoadFramework();
    return PBDismissSelectorName() != nil && PBPresentationSelectorName(YES) != nil;
}

BOOL PBPresentTouchBar(NSTouchBar *bar, BOOL preserveControlStrip) {
    if (!NSThread.isMainThread || !bar) return NO;
    PBLoadFramework();
    NSString *selectorName = PBPresentationSelectorName(preserveControlStrip);
    if (!selectorName || !PBDismissSelectorName()) return NO;
    @try {
        PBObserveTermination();
        if (PBPresentedBar && PBPresentedBar != bar) PBDismissTouchBar(PBPresentedBar);
        // Keep the system close button. Never synthesize Escape or require
        // Accessibility permission; the M2 MacBook Pro also has physical Escape.
        if (PBSetCloseBox) PBSetCloseBox(YES);
        SEL selector = NSSelectorFromString(selectorName);
        NSTouchBarItemIdentifier identifier = PBInstalledItem.identifier;
        if (preserveControlStrip) {
            ((PBPresentMessage)objc_msgSend)(NSTouchBar.class, selector, bar, identifier);
        } else {
            ((PBPlacementMessage)objc_msgSend)(NSTouchBar.class, selector, bar, 1LL, identifier);
        }
        PBPresentedBar = bar;
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"PulseBar: Touch Bar presentation failed (%@).", exception.name);
        return NO;
    }
}

void PBDismissTouchBar(NSTouchBar *bar) {
    if (!NSThread.isMainThread || !bar) return;
    NSString *selectorName = PBDismissSelectorName();
    if (!selectorName) return;
    @try {
        ((PBObjectMessage)objc_msgSend)(NSTouchBar.class,
                                       NSSelectorFromString(selectorName), bar);
        if (PBPresentedBar == bar) PBPresentedBar = nil;
    } @catch (NSException *exception) {
        NSLog(@"PulseBar: Touch Bar dismissal failed (%@).", exception.name);
    }
}

BOOL PBInstallControlStripItem(NSCustomTouchBarItem *item) {
    if (!NSThread.isMainThread || !item || item.identifier.length == 0) return NO;
    PBLoadFramework();
    if (!PBSetPresence ||
        !PBHasMethod(NSTouchBarItem.class, @"addSystemTrayItem:", "@") ||
        !PBHasMethod(NSTouchBarItem.class, @"removeSystemTrayItem:", "@")) return NO;
    if (PBInstalledItem && PBInstalledItem != item) return NO;
    @try {
        PBObserveTermination();
        if (!PBInstalledItem) {
            ((PBObjectMessage)objc_msgSend)(NSTouchBarItem.class,
                                           NSSelectorFromString(@"addSystemTrayItem:"), item);
            PBInstalledItem = item;
        }
        PBSetPresence(item.identifier, YES);
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"PulseBar: Control Strip registration failed (%@).", exception.name);
        if (PBInstalledItem == item) PBRemoveControlStripItem(item);
        return NO;
    }
}

void PBRemoveControlStripItem(NSCustomTouchBarItem *item) {
    if (!NSThread.isMainThread || !item || PBInstalledItem != item) return;
    @try {
        if (PBSetPresence) PBSetPresence(item.identifier, NO);
        if (PBHasMethod(NSTouchBarItem.class, @"removeSystemTrayItem:", "@")) {
            ((PBObjectMessage)objc_msgSend)(NSTouchBarItem.class,
                                           NSSelectorFromString(@"removeSystemTrayItem:"), item);
        }
        PBInstalledItem = nil;
    } @catch (NSException *exception) {
        NSLog(@"PulseBar: Control Strip removal failed (%@).", exception.name);
    }
}
