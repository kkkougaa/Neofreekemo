//
//  ReturnToRead.x
//  NeoFreeBird
//
//  A status-bar tap scrolls the timeline to the top. Remember that offset, and
//  if the bar is tapped again within five seconds while already at the top,
//  spring back to it. Other scroll views are left alone.

#import "HookHelpers.h"

static const void* kReadOffsetKey = &kReadOffsetKey;
static const void* kReadAtKey = &kReadAtKey;
static const NSTimeInterval kReturnWindow = 5.0;

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
                     [name containsString:@"TFNTableView"] ||
                     [name containsString:@"TFNCollectionView"];
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
                [controller containsString:@"URT"] || [controller containsString:@"ItemsData"]) {
                return YES;
            }
        }
        responder = responder.nextResponder;
    }
    return NO;
}

static void LightTap(void) {
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        return;
    }
    UIImpactFeedbackGenerator* tap =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [tap impactOccurred];
}

%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    if (!ReturnReadOn() || !IsTimelineScroller(self)) {
        %orig;
        return;
    }
    CGFloat top = -self.adjustedContentInset.top;
    BOOL toTop = animated && offset.y <= top + 2.0;
    BOOL alreadyTop = self.contentOffset.y <= top + 8.0;
    NSValue* saved = objc_getAssociatedObject(self, kReadOffsetKey);
    NSDate* savedAt = objc_getAssociatedObject(self, kReadAtKey);
    BOOL fresh = savedAt && -[savedAt timeIntervalSinceNow] <= kReturnWindow;
    if (toTop && alreadyTop && saved && fresh) {
        CGPoint back = saved.CGPointValue;
        objc_setAssociatedObject(self, kReadOffsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kReadAtKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LightTap();
        %orig(back, YES);
        return;
    }
    if (toTop && self.contentOffset.y > top + 40.0) {
        objc_setAssociatedObject(self, kReadOffsetKey, [NSValue valueWithCGPoint:self.contentOffset],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kReadAtKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

%end
