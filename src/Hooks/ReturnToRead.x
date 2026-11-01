//
//  ReturnToRead.x
//  NeoFreeBird
//
//  A status-bar tap scrolls the timeline to the top. Remember where the reader
//  was, and if the bar is tapped again within the window while still at the
//  top, spring back there instead.
//
//  7.3.20 hooked -[UIScrollView setContentOffset:animated:], which never worked:
//  UIKit's scroll-to-top uses a private animation path, and when the list is
//  already at the top UIKit does not call into the scroll view at all, so the
//  second tap was never seen. The status-bar tap itself is caught here instead
//  (-[UIStatusBarManager handleTapAction:]), before UIKit picks a scroll view.

#import "HookHelpers.h"

extern UIWindow* NFBKeyWindow(void);

static const void* kReadOffsetKey = &kReadOffsetKey;
static const void* kReadHeightKey = &kReadHeightKey;
static const void* kReadAtKey = &kReadAtKey;
static const NSTimeInterval kReturnWindow = 10.0;
static const CGFloat kAtTopSlack = 8.0;
static const CGFloat kWorthSaving = 40.0;

static BOOL ReturnReadOn(void) {
    return [BHTSettings boolForKey:@"kemo_return_read"];
}

static BOOL IsTimelineScroller(UIScrollView* scroll) {
    if (scroll.bounds.size.height < 200 || [scroll isKindOfClass:[UITextView class]]) {
        return NO;
    }
    NSString* name = NSStringFromClass(scroll.class);
    BOOL tableLike = [scroll isKindOfClass:[UITableView class]] ||
                     [scroll isKindOfClass:[UICollectionView class]] ||
                     [name containsString:@"TableView"] || [name containsString:@"CollectionView"];
    if (!tableLike) {
        return NO;
    }
    UIResponder* responder = scroll;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            NSString* controller = NSStringFromClass(responder.class);
            if ([controller containsString:@"Settings"] || [controller containsString:@"Search"] ||
                [controller containsString:@"Compose"]) {
                return NO;
            }
            if ([controller containsString:@"Timeline"] || [controller containsString:@"Home"] ||
                [controller containsString:@"URT"] || [controller containsString:@"ItemsData"] ||
                [controller containsString:@"Profile"]) {
                return YES;
            }
        }
        responder = responder.nextResponder;
    }
    return NO;
}

static BOOL IsShowing(UIView* view) {
    for (UIView* v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) {
            return NO;
        }
    }
    return YES;
}

static UIViewController* TopController(UIViewController* controller) {
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

// The timeline the reader is looking at: the largest on-screen, scrolls-to-top
// timeline list inside the frontmost presented controller.
static UIScrollView* VisibleTimeline(UIWindow* window) {
    UIView* root = TopController(window.rootViewController).view ?: window;
    CGRect screen = window.bounds;
    UIScrollView* best = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view.hidden || view.alpha < 0.01) {
            continue;
        }
        if ([view isKindOfClass:[UIScrollView class]]) {
            UIScrollView* scroll = (UIScrollView*)view;
            if (scroll.scrollsToTop && IsTimelineScroller(scroll)) {
                CGRect frame = [scroll convertRect:scroll.bounds toView:window];
                CGRect seen = CGRectIntersection(frame, screen);
                CGFloat area = CGRectIsNull(seen) ? 0 : seen.size.width * seen.size.height;
                if (area > bestArea && IsShowing(scroll)) {
                    bestArea = area;
                    best = scroll;
                }
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return bestArea >= screen.size.width * screen.size.height * 0.25 ? best : nil;
}

static void ClearSaved(UIScrollView* scroll) {
    objc_setAssociatedObject(scroll, kReadOffsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scroll, kReadHeightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scroll, kReadAtKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LightTap(void) {
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        return;
    }
    UIImpactFeedbackGenerator* tap =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tap impactOccurred];
}

// Returns YES when the tap was used to go back, so the stock scroll-to-top is skipped.
static BOOL HandleStatusBarTap(void) {
    if (!ReturnReadOn()) {
        return NO;
    }
    UIWindow* window = NFBKeyWindow();
    UIScrollView* scroll = window ? VisibleTimeline(window) : nil;
    if (!scroll) {
        return NO;
    }
    CGFloat top = -scroll.adjustedContentInset.top;
    CGFloat y = scroll.contentOffset.y;

    NSValue* saved = objc_getAssociatedObject(scroll, kReadOffsetKey);
    NSNumber* savedHeight = objc_getAssociatedObject(scroll, kReadHeightKey);
    NSDate* savedAt = objc_getAssociatedObject(scroll, kReadAtKey);
    BOOL fresh = savedAt && -[savedAt timeIntervalSinceNow] <= kReturnWindow;

    if (y <= top + kAtTopSlack) {
        if (!saved || !fresh) {
            ClearSaved(scroll);
            return NO;
        }
        CGPoint back = saved.CGPointValue;
        // New posts loaded above while at the top push the old spot down by the
        // same amount.
        CGFloat grown = scroll.contentSize.height - savedHeight.doubleValue;
        if (savedHeight && grown > 0 && grown < 50000) {
            back.y += grown;
        }
        CGFloat maxY = scroll.contentSize.height + scroll.adjustedContentInset.bottom -
                       CGRectGetHeight(scroll.bounds);
        back.y = MAX(top, MIN(back.y, MAX(top, maxY)));
        ClearSaved(scroll);
        if (back.y <= top + kWorthSaving) {
            return NO;
        }
        LightTap();
        [scroll setContentOffset:back animated:YES];
        return YES;
    }

    if (y > top + kWorthSaving) {
        objc_setAssociatedObject(scroll, kReadOffsetKey, [NSValue valueWithCGPoint:scroll.contentOffset],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(scroll, kReadHeightKey, @(scroll.contentSize.height),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(scroll, kReadAtKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return NO;
}

%hook UIStatusBarManager

- (void)handleTapAction:(id)action {
    BOOL wentBack = NO;
    @try {
        wentBack = HandleStatusBarTap();
    } @catch (__unused NSException* exception) {
        wentBack = NO;
    }
    if (!wentBack) {
        %orig;
    }
}

%end
