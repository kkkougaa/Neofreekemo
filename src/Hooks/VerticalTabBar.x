//
//  VerticalTabBar.x
//  NeoFreeBird
//
//  The Liquid Glass tab bar as a column on the right, like X lays it out on a
//  foldable iPhone.
//

#import "HookHelpers.h"

// X 12.44 (XServiceLibraries, XNavigation.TabBarController) already draws the
// tab bar as a vertical column; it decides where the column goes in a helper
// that reads, in this order:
//   1. its own `allowsVerticalSidebar` (a Bool passed to its init),
//   2. `-[UITraitCollection verticalBarEdge]` of the controller's view, iOS
//      27.1 and later only (1 = leading, 2 = trailing, anything else = none),
//   3. the view's safe area inset on that side, taken as the column's room (0
//      means no column).
// The FAB goes in the column, at the end set by `sidebarFABPlacement`
// (Optional<TabBarSidebarFABPlacement>: top = 0, bottom = 1, nil = 2).
// Scroll hiding stays X's own.

static NSString* const kVTBController = @"_TtC11XNavigation16TabBarController";

// Room for the column in portrait, where the window has no side inset.
// Landscape on a Dynamic Island iPhone gives 59 to 62.
static const CGFloat kVTBColumnRoom = 62.0;

static const unsigned char kVTBFABBottom = 1;

static BOOL gVTBTraitHooked = NO;
static NSInteger gVTBLastEdge = -1;

static BOOL VTBOn(void) {
    return NFBLiquidGlassEnabled() && !is_iPad() && [BHTSettings boolForKey:@"vertical_tab_bar"];
}

// Writes one byte of a Swift stored property, by its ObjC ivar name. Only for
// one byte Bools and small enums, and only when the ivar sits inside the
// instance.
static BOOL VTBSetByte(id object, const char* name, unsigned char value) {
    Class cls = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < (ptrdiff_t)sizeof(void*) || (size_t)offset >= class_getInstanceSize(cls)) return NO;
    unsigned char* slot = (unsigned char*)(__bridge void*)object + offset;
    if (*slot != value) *slot = value;
    return YES;
}

static int VTBByte(id object, const char* name) {
    Class cls = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar) return -1;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < (ptrdiff_t)sizeof(void*) || (size_t)offset >= class_getInstanceSize(cls)) return -1;
    return *((unsigned char*)(__bridge void*)object + offset);
}

static void VTBPrepare(UIViewController* controller) {
    if (!VTBOn()) return;
    VTBSetByte(controller, "allowsVerticalSidebar", 1);
    VTBSetByte(controller, "sidebarFABPlacement", kVTBFABBottom);
}

// X takes the column's room from the safe area on its side. The window gives
// none on the right in portrait, so the controller adds it, only as much as
// is missing.
static void VTBUpdateRoom(UIViewController* controller) {
    if (!controller.isViewLoaded) return;
    UIEdgeInsets extra = controller.additionalSafeAreaInsets;
    CGFloat want = 0;
    if (VTBOn() && gVTBTraitHooked) {
        CGFloat base = controller.view.safeAreaInsets.right - extra.right;
        want = MAX(0, kVTBColumnRoom - MAX(0, base));
    }
    if (fabs(extra.right - want) > 0.5) {
        extra.right = want;
        controller.additionalSafeAreaInsets = extra;
    }
}

%group VTBTraits

%hook UITraitCollection

- (NSInteger)verticalBarEdge {
    NSInteger edge = %orig;
    gVTBLastEdge = edge;
    return VTBOn() ? 2 : edge;
}

%end

%end

%group VTBController

%hook _TtC11XNavigation16TabBarController

- (void)viewDidLoad {
    VTBPrepare((UIViewController*)self);
    %orig;
}

- (void)viewWillLayoutSubviews {
    VTBPrepare((UIViewController*)self);
    VTBUpdateRoom((UIViewController*)self);
    %orig;
}

%end

%end

NSString* NFBVerticalTabBarDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"on=%d glass=%d traitHook=%d lastSystemEdge=%ld", VTBOn(), NFBLiquidGlassEnabled(),
                      gVTBTraitHooked, (long)gVTBLastEdge];
    UIWindow* window = nil;
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* candidate in ((UIWindowScene*)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    Class cls = NSClassFromString(kVTBController);
    UIViewController* found = nil;
    if (window && cls) {
        NSMutableArray<UIViewController*>* queue = [NSMutableArray array];
        if (window.rootViewController) [queue addObject:window.rootViewController];
        while (queue.count && !found) {
            UIViewController* next = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([next isKindOfClass:cls]) {
                found = next;
                break;
            }
            [queue addObjectsFromArray:next.childViewControllers];
            if (next.presentedViewController) [queue addObject:next.presentedViewController];
        }
    }
    if (!found) {
        [out appendString:@" controller=none"];
        return out;
    }
    [out appendFormat:@" allows=%d hosting=%d arrangement=%d fab=%d displaysFAB=%d barHidden=%d",
                      VTBByte(found, "allowsVerticalSidebar"), VTBByte(found, "isHostingVerticalSidebar"),
                      VTBByte(found, "appliedColumnArrangement"), VTBByte(found, "sidebarFABPlacement"),
                      VTBByte(found, "displaysFAB"), VTBByte(found, "isBarHidden")];
    [out appendFormat:@" safe=%@ extra=%@", NSStringFromUIEdgeInsets(found.view.safeAreaInsets),
                      NSStringFromUIEdgeInsets(found.additionalSafeAreaInsets)];
    Ivar barIvar = class_getInstanceVariable(cls, "barView");
    id bar = barIvar ? object_getIvar(found, barIvar) : nil;
    if ([bar isKindOfClass:UIView.class]) {
        UIView* barView = bar;
        [out appendFormat:@" bar=%@", NSStringFromCGRect([barView convertRect:barView.bounds toView:window])];
    }
    return out;
}

%ctor {
    if (!NFBLiquidGlassEnabled() || is_iPad()) return;
    Class controller = NSClassFromString(kVTBController);
    if (controller && class_getInstanceVariable(controller, "allowsVerticalSidebar") &&
        class_getInstanceVariable(controller, "sidebarFABPlacement")) {
        %init(VTBController);
    }
    // Only iOS 27.1 and later have it; X does not ask below that.
    if (class_getInstanceMethod(UITraitCollection.class, NSSelectorFromString(@"verticalBarEdge"))) {
        %init(VTBTraits);
        gVTBTraitHooked = YES;
    }
}
