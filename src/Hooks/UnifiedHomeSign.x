//
//  UnifiedHomeSign.x
//  NeoFreeBird
//
//  7.3.151: a standing sign that the A/B unified mode is in use
//  (UnifiedTimeline.x has the mode itself).
//
//  After the dock's "통합 계정" circle is chosen, the account avatar at the
//  leading end of the home navigation bar is still A's alone. While the mode is
//  active, B's small picture sits on that avatar's lower trailing corner, as on
//  the dock's unified circle (AccountBubbles.x: 0.47 of the avatar, round, a
//  border). It is taken off as soon as the mode is not active.
//
//  The avatar button, X 12.44 (XAppLibraries dump):
//    _TtC11TwitterDash26TabRootAvatarBarButtonItem   ivar containerView
//    _TtC11TwitterDashP33_…26TabRootAvatarContainerView
//        ivars avatarView / badgeView, -layoutSubviews, -hitTest:withEvent:
//    _TtC11TwitterDash19DashAvatarImageView : TUIAvatarImageView  -setAccount:
//  The shake dump's NAV BAR tree ends at NavigationButtonBar.ItemWrapperView
//  with nothing under it because DebugDump.x skips "TwitterDash" classes.
//
//  Every tab root has such a button, so the sign is put only on the one whose
//  navigation controller's root is the home screen
//  (TwitterHomeFeatureImplementation.HomeTimelineContainerViewController, as
//  the shake dump's window tree shows it). Nothing else is searched for: a
//  view that is not that container class never gets the sign.
//
//  On-device UI only; nothing here talks to X's servers.
//
//  7.3.151, later the same version: the home button shows the pair the
//  notifications tab shows (UnifiedNotifications.x): A's picture, X's own and
//  untouched, and B's picture next to it at the same size (measured from X's
//  avatar view), as a bar button item of ours put right after X's avatar item
//  in the home root's navigationItem.leftBarButtonItems. On home it is a plain
//  pair: both in full colour, no highlight, no switching; a tap on B's picture
//  does what X's avatar does (-didTapAvatar on X's item). It fades in and out
//  with the mode. The small picture on A's corner described above is now only
//  the fallback, for when X's avatar item cannot be found or the bar does not
//  show our item. This file's hook on the avatar buttons' layoutSubviews also
//  tells UnifiedNotifications.x when the notifications tab's button was laid out.
//
//  7.3.152: B's picture is exactly the size of X's A picture (X's avatar is
//  now found however deep it sits and measured as drawn), and one glass
//  capsule goes round the two instead of a glass circle round each: X's own
//  bar platter when it will share one between the two items, else one of ours.
//

#import "HookHelpers.h"

extern BOOL NFBUnifiedIsActive(void);
extern BOOL NFBUnifiedDockPair(id* outA, id* outB);
extern UIColor* NFBUnifiedBColor(void);

extern void NFBUnifiedNotificationsAvatarLaidOut(UIView* container);

NSString* NFBUnifiedHomeSignDebugText(void);

static const NSInteger kHomeSignTag = 0x4E4648;  // "NFH"
static const void* kHomeSignIsHomeKey = &kHomeSignIsHomeKey;
static const void* kHomeSignSeenKey = &kHomeSignSeenKey;

// All of this is main thread only.
static BOOL gSignWanted = NO;          // the mode is active and B is known
static NSString* gSignBID;             // B's user ID the picture belongs to
static NSString* gSignLabel;           // VoiceOver
static UIImage* gSignImage;
static BOOL gSignImageReal = NO;       // NO: the letter placeholder
static CFAbsoluteTime gSignImageTriedAt = 0;
static CFAbsoluteTime gSignEvaluatedAt = 0;
static BOOL gSignEvaluatePending = NO;
static BOOL gSignLatePending = NO;
static BOOL gSignHookContainer = NO;
static BOOL gSignHookAccount = NO;
static NSHashTable<UIView*>* gSignContainers;  // weak
static NSString* gSignContainerClass;
static NSString* gSignAvatarClass;
static NSString* gSignRootClass;       // root of the last container's navigation controller
static NSMutableArray<NSString*>* gSignLog;

// The home pair (B's picture as a second bar item).
static UIBarButtonItem* gPairItem;               // ours
static __weak UIViewController* gPairHolder;     // whose navigationItem holds it
static __weak UIBarButtonItem* gPairAvatarItem;  // X's avatar item it follows
static __weak UIView* gPairContainer;            // X's avatar button view
static CFAbsoluteTime gPairPlacedAt = 0;
static BOOL gPairFailed = NO;
static BOOL gPairNotFoundLogged = NO;
static NSString* gPairPlacement = @"none";
static CGFloat gPairPictureSize = 0;
// 7.3.152: one glass capsule behind both pictures (see "The capsule" below).
static const CGFloat kPairPad = 4.0;             // glass past the pictures, every side
static UIVisualEffectView* gPairCapsule;
static NSLayoutConstraint* gPairWidth;
static NSLayoutConstraint* gPairHeight;
static BOOL gPairPlaceQueued = NO;
static NSString* gPairCapsuleNote = @"-";
static NSString* gPairBackgroundNote = @"-";
static const void* kHSHidBackgroundKey = &kHSHidBackgroundKey;    // on a bar item: its own hidesSharedBackground
static const void* kHSSharedBackgroundKey = &kHSSharedBackgroundKey;  // on a bar item: its own sharesBackground
// How the two pictures get one glass: 0 = asked X's bar to put both items on
// one platter, not seen yet; 1 = X's bar did; 2 = it did not, a capsule of ours.
static NSInteger gPairGlassMode = 0;
static BOOL gPairGlassCheckQueued = NO;

static void HSLog(NSString* line) {
    static NSDateFormatter* formatter;
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss";
    }
    if (!gSignLog) gSignLog = [NSMutableArray array];
    [gSignLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
    while (gSignLog.count > 12) [gSignLog removeObjectAtIndex:0];
}

// MARK: - Helpers (local copies; each Unified file keeps its own)

static id HSGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static long long HSNumber(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2) return 0;
    char type = signature.methodReturnType[0];
    @try {
        if (type == 'q' || type == 'Q' || type == 'l' || type == 'L') {
            return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
        }
    } @catch (__unused NSException* exception) {
    }
    return 0;
}

static NSString* HSUserID(id account) {
    if (!account) return nil;
    id user = HSGetter(account, @"user");
    for (id source in @[ account, user ?: [NSNull null] ]) {
        if (source == [NSNull null]) continue;
        for (NSString* name in @[ @"userID", @"userId", @"userIDString" ]) {
            long long number = HSNumber(source, name);
            if (number > 0) return [NSString stringWithFormat:@"%lld", number];
            id value = HSGetter(source, name);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
            if ([value isKindOfClass:[NSNumber class]] && [value longLongValue] > 0) {
                return [NSString stringWithFormat:@"%lld", [value longLongValue]];
            }
        }
    }
    return nil;
}

static NSString* HSUsername(id account) {
    if (!account) return nil;
    id user = HSGetter(account, @"user");
    for (id source in @[ account, user ?: [NSNull null] ]) {
        if (source == [NSNull null]) continue;
        for (NSString* name in @[ @"username", @"screenName", @"displayUsername" ]) {
            id value = HSGetter(source, name);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return [value hasPrefix:@"@"] ? value : [@"@" stringByAppendingString:value];
            }
        }
    }
    return nil;
}

// B's picture: the file AccountBubbles.x keeps by user ID, else that account's
// avatar if one is on screen, else nil.
static UIImage* HSStoredPicture(NSString* userID, BOOL lookOnScreen) {
    if (userID.length == 0) return nil;
    NSURL* base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSString* path = [[base URLByAppendingPathComponent:@"NFBAccountAvatars"]
                         URLByAppendingPathComponent:[userID stringByAppendingString:@".img"]].path;
    NSData* data = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    UIImage* stored = data.length ? [UIImage imageWithData:data] : nil;
    if (stored || !lookOnScreen) return stored;
    __block UIImage* found = nil;
    NSString* wanted = [@"TUIAvatarImageView." stringByAppendingString:userID];
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            EnumerateSubviewsRecursively(window, ^(UIView* view) {
                if (!found && [view.accessibilityIdentifier isEqualToString:wanted] &&
                    [view isKindOfClass:[UIImageView class]] && ((UIImageView*)view).image) {
                    found = ((UIImageView*)view).image;
                }
            });
        }
    }
    return found;
}

// A "B" in a circle until the picture is found.
static UIImage* HSLetterPicture(UIColor* color) {
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        [(color ?: [UIColor systemOrangeColor]) setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 28, 28)] fill];
        NSDictionary* attributes = @{
            NSFontAttributeName : [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName : UIColor.whiteColor
        };
        NSString* letter = @"B";
        CGSize size = [letter sizeWithAttributes:attributes];
        [letter drawAtPoint:CGPointMake((28 - size.width) / 2, (28 - size.height) / 2) withAttributes:attributes];
    }];
}

// MARK: - The sign on one avatar button

// Whether this button's navigation controller starts at the home screen.
// `found` says whether a navigation controller was reached at all.
static BOOL HSContainerIsHome(UIView* container, BOOL* found) {
    *found = NO;
    UIResponder* responder = container;
    NSInteger budget = 40;
    while (responder && budget-- > 0) {
        if ([responder isKindOfClass:[UINavigationController class]]) {
            UIViewController* root = ((UINavigationController*)responder).viewControllers.firstObject;
            if (!root) return NO;
            *found = YES;
            NSString* name = NSStringFromClass([root class]);
            gSignRootClass = name;
            return [name containsString:@"HomeTimelineContainerViewController"];
        }
        responder = responder.nextResponder;
    }
    return NO;
}

// MARK: - The home pair

@interface NFBHomePairTarget : NSObject
+ (instancetype)shared;
- (void)tapped:(UIButton*)button;
@end

@implementation NFBHomePairTarget

+ (instancetype)shared {
    static NFBHomePairTarget* target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        target = [NFBHomePairTarget new];
    });
    return target;
}

// B's picture on home is part of X's avatar button as far as taps go.
- (void)tapped:(__unused UIButton*)button {
    UIBarButtonItem* avatarItem = gPairAvatarItem;
    SEL tap = NSSelectorFromString(@"didTapAvatar");
    if (!avatarItem || ![avatarItem respondsToSelector:tap]) return;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(avatarItem, tap);
    } @catch (__unused NSException* exception) {
    }
}

@end

static void HSRestoreSharedBackground(UIBarButtonItem* item);

// B's picture fades out, then its bar item goes.
static void HSPairRemove(NSString* why) {
    UIBarButtonItem* ours = gPairItem;
    if (!ours) return;
    UIViewController* holder = gPairHolder;
    UIBarButtonItem* avatarItem = gPairAvatarItem;
    UIVisualEffectView* capsule = gPairCapsule;
    gPairItem = nil;
    gPairHolder = nil;
    gPairAvatarItem = nil;
    gPairContainer = nil;
    gPairCapsule = nil;
    gPairWidth = nil;
    gPairHeight = nil;
    gPairPlacement = @"none";
    gPairCapsuleNote = @"-";
    gPairGlassMode = 0;
    HSLog([NSString stringWithFormat:@"pair taken off (%@)", why]);
    void (^drop)(void) = ^{
        // The capsule goes and the bar's own glass round X's avatar comes back.
        [capsule removeFromSuperview];
        HSRestoreSharedBackground(avatarItem);
        NSMutableArray<UIBarButtonItem*>* items = [holder.navigationItem.leftBarButtonItems mutableCopy];
        if ([items containsObject:ours]) {
            [items removeObject:ours];
            holder.navigationItem.leftBarButtonItems = items;
        }
    };
    UIView* side = ours.customView;
    if (!side.window) {
        drop();
        return;
    }
    side.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.2
                     animations:^{
                         side.alpha = 0.0;
                         capsule.alpha = 0.0;
                     }
                     completion:^(__unused BOOL finished) {
                         drop();
                     }];
}

// X's avatar bar item whose view is this button, and the controller whose
// navigation item holds it. nil when it cannot be told.
static UIBarButtonItem* HSAvatarItemFor(UIView* container, UIViewController** outHolder) {
    Class itemClass = objc_getClass("_TtC11TwitterDash26TabRootAvatarBarButtonItem");
    if (!itemClass) return nil;
    UINavigationController* navigation = nil;
    UIResponder* responder = container;
    NSInteger budget = 40;
    while (responder && budget-- > 0) {
        if ([responder isKindOfClass:[UINavigationController class]]) {
            navigation = (UINavigationController*)responder;
            break;
        }
        responder = responder.nextResponder;
    }
    UIViewController* root = navigation.viewControllers.firstObject;
    if (!root) return nil;
    NSMutableArray<UIViewController*>* holders = [NSMutableArray arrayWithObject:root];
    [holders addObjectsFromArray:root.childViewControllers];
    for (UIViewController* holder in holders) {
        for (UIBarButtonItem* item in holder.navigationItem.leftBarButtonItems) {
            if ([item isKindOfClass:itemClass] && item.customView == container) {
                if (outHolder) *outHolder = holder;
                return item;
            }
        }
    }
    return nil;
}

// X's avatar picture inside its button, however deep it sits.
static UIView* HSAvatarViewIn(UIView* view, NSInteger depth) {
    Class avatarClass = objc_getClass("TUIAvatarImageView");
    if (!avatarClass || depth > 4) return nil;
    for (UIView* sub in view.subviews) {
        if ([sub isKindOfClass:avatarClass]) return sub;
        UIView* found = HSAvatarViewIn(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

// Where X's avatar picture is drawn, in its button's coordinates (a scale on
// it counts); CGRectNull when it cannot be read.
static CGRect HSAvatarRectIn(UIView* container) {
    UIView* avatar = HSAvatarViewIn(container, 0);
    if (!avatar || avatar.hidden) return CGRectNull;
    CGRect rect = [avatar convertRect:avatar.bounds toView:container];
    CGFloat size = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect));
    if (size < 16 || size > 64) return CGRectNull;
    return rect;
}

// The size of X's own avatar picture in its button; 28 when it cannot be read.
// (7.3.151 only looked at direct subviews of 16...36pt and fell back to 28, so
// B's picture came out smaller than A's.)
static CGFloat HSAvatarSizeIn(UIView* container) {
    CGRect rect = HSAvatarRectIn(container);
    if (CGRectIsNull(rect)) return 28;
    return round(MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 2) / 2;
}

// MARK: - The capsule (7.3.152)
//
// Both pictures are the same size and one glass capsule goes round the two.
//
// X 12.44 draws its navigation bar itself (XServiceLibraries dump: XNavigation's
// LiquidNavigationBarView; every group of bar items is a
// LiquidNavigationBarItemGroupView with ivars `glass` and `slots`, the platter
// seen round each item). Its binary reads UIBarButtonItem's `sharesBackground`
// and `hidesSharedBackground` (both selectors are in XServiceLibraries, with a
// Swift `sharesPlatterWithNeighbours`), and in 7.3.151 our item and X's avatar
// item came out as two groups, a circle each.
//
// 1. Both items are told to share (`sharesBackground` YES; X's item gets its
//    own value back when the pair goes) before ours is put in the bar. When
//    the two then sit in the same ItemGroupView, X's own platter is the
//    capsule and nothing else is done.
// 2. When after 0.8s they are still in different groups (or the bar is not
//    that one), both platters are switched off (`hidesSharedBackground`) and
//    a capsule of ours is put at the back of the nearest view that holds both
//    items, sized from the two pictures.

// Liquid Glass when the app has it on (iOS 26), a thin blur otherwise.
static UIVisualEffect* HSGlassEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (NFBLiquidGlassEnabled() && glassClass) {
        id effect = [[glassClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
}

// Sets a BOOL property of a bar item, remembering under `key` what it was.
// NO when this iOS has no such property.
static BOOL HSSetItemFlag(UIBarButtonItem* item, NSString* getter, NSString* setter, const void* key, BOOL value) {
    SEL get = NSSelectorFromString(getter);
    SEL set = NSSelectorFromString(setter);
    if (!item || ![item respondsToSelector:get] || ![item respondsToSelector:set]) return NO;
    BOOL now = ((BOOL (*)(id, SEL))objc_msgSend)(item, get);
    if (!objc_getAssociatedObject(item, key)) {
        objc_setAssociatedObject(item, key, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (now != value) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, set, value);
    return YES;
}

static void HSRestoreItemFlag(UIBarButtonItem* item, NSString* setter, const void* key) {
    NSNumber* was = item ? objc_getAssociatedObject(item, key) : nil;
    if (!was) return;
    SEL set = NSSelectorFromString(setter);
    if ([item respondsToSelector:set]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, set, was.boolValue);
    objc_setAssociatedObject(item, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL HSShareBackground(UIBarButtonItem* item) {
    return HSSetItemFlag(item, @"sharesBackground", @"setSharesBackground:", kHSSharedBackgroundKey, YES);
}

__attribute__((unused)) static BOOL HSHideSharedBackground(UIBarButtonItem* item) {
    return HSSetItemFlag(item, @"hidesSharedBackground", @"setHidesSharedBackground:", kHSHidBackgroundKey, YES);
}

// X's item as X had it.
static void HSRestoreSharedBackground(UIBarButtonItem* item) {
    HSRestoreItemFlag(item, @"setHidesSharedBackground:", kHSHidBackgroundKey);
    HSRestoreItemFlag(item, @"setSharesBackground:", kHSSharedBackgroundKey);
}

// X's bar's group view (one glass platter) this view sits in; nil in any other bar.
static UIView* HSGroupViewOf(UIView* view) {
    for (UIView* up = view.superview; up && ![up isKindOfClass:[UIWindow class]]; up = up.superview) {
        if ([NSStringFromClass([up class]) containsString:@"LiquidNavigationBarItemGroupView"]) return up;
    }
    return nil;
}

static void HSPlaceCapsuleSoon(void);

// Mode 0 -> 1 or 2 (see above). YES when a capsule of ours is to be drawn.
static BOOL HSPairWantsOwnCapsule(UIView* container, UIView* side) {
    if (gPairGlassMode == 2) return YES;
    UIView* groupA = HSGroupViewOf(container);
    UIView* groupB = HSGroupViewOf(side);
    if (groupA && groupA == groupB) {
        if (gPairGlassMode != 1) {
            gPairGlassMode = 1;
            HSLog(@"glass: X's bar put both pictures on one platter");
        }
        gPairCapsuleNote = [NSString stringWithFormat:@"X's own platter %@", NSStringFromCGRect(groupA.frame)];
        return NO;
    }
    if (CFAbsoluteTimeGetCurrent() - gPairPlacedAt < 0.8) {
        // The bar may still be regrouping: looked at once more afterwards.
        if (!gPairGlassCheckQueued) {
            gPairGlassCheckQueued = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                gPairGlassCheckQueued = NO;
                HSPlaceCapsuleSoon();
            });
        }
        return NO;
    }
    // 7.3.154: no capsule of ours. On the device X's bar did give the two
    // one platter, this check did not see it (the items' views are not inside
    // the group view), and 0.8s later our capsule came up over the pictures.
    gPairCapsuleNote = @"asked X's bar to share one platter; the group view was not seen from here";
    return NO;
}

// The capsule's frame from where the two pictures are now. Nothing of X's is
// moved; the capsule is only ever inserted once per parent (never reordered
// afterwards, so no layout is fought over).
static void HSPlaceCapsule(void) {
    UIBarButtonItem* ours = gPairItem;
    UIView* container = gPairContainer;
    UIView* side = ours.customView;
    UIView* picture = [side viewWithTag:2];
    if (!ours || !picture || !container.window || container.window != side.window) return;
    if (!HSPairWantsOwnCapsule(container, side)) {
        UIVisualEffectView* stale = gPairCapsule;
        if (stale) {
            gPairCapsule = nil;
            [stale removeFromSuperview];
        }
        return;
    }
    UIView* ancestor = side.superview;
    while (ancestor && ![ancestor isKindOfClass:[UIWindow class]] && ![container isDescendantOfView:ancestor]) {
        ancestor = ancestor.superview;
    }
    if (!ancestor || [ancestor isKindOfClass:[UIWindow class]]) {
        gPairCapsuleNote = @"no shared parent below the window";
        return;
    }
    CGRect aRect = HSAvatarRectIn(container);
    if (CGRectIsNull(aRect)) {
        CGFloat size = gPairPictureSize > 0 ? gPairPictureSize : 28;
        aRect = CGRectMake(CGRectGetMidX(container.bounds) - size / 2, CGRectGetMidY(container.bounds) - size / 2, size, size);
    }
    CGRect a = [container convertRect:aRect toView:ancestor];
    CGRect b = [side convertRect:picture.frame toView:ancestor];
    CGRect frame = CGRectInset(CGRectUnion(a, b), -kPairPad, -kPairPad);
    if (CGRectGetHeight(frame) > 80 || CGRectGetWidth(frame) > 220 || CGRectGetWidth(frame) < CGRectGetHeight(frame)) {
        // Not side by side in one bar (mid transition, or a layout this was not written for).
        gPairCapsuleNote = [NSString stringWithFormat:@"odd frame %@, left as it was", NSStringFromCGRect(frame)];
        return;
    }
    UIVisualEffectView* capsule = gPairCapsule;
    if (!capsule) {
        capsule = [[UIVisualEffectView alloc] initWithEffect:HSGlassEffect()];
        capsule.userInteractionEnabled = NO;
        capsule.clipsToBounds = YES;
        capsule.isAccessibilityElement = NO;
        if ([capsule.effect isKindOfClass:[UIBlurEffect class]]) capsule.contentView.backgroundColor = [UIColor tertiarySystemFillColor];
        gPairCapsule = capsule;
        capsule.alpha = 0.0;
        [UIView animateWithDuration:0.2
                         animations:^{
                             capsule.alpha = 1.0;
                         }];
    }
    if (capsule.superview != ancestor) {
        [ancestor insertSubview:capsule atIndex:0];
        HSLog([NSString stringWithFormat:@"capsule put in %@", NSStringFromClass([ancestor class])]);
    }
    if (!CGRectEqualToRect(capsule.frame, frame)) capsule.frame = frame;
    CGFloat radius = CGRectGetHeight(frame) / 2;
    if (capsule.layer.cornerRadius != radius) capsule.layer.cornerRadius = radius;
    gPairCapsuleNote = [NSString stringWithFormat:@"%@ in %@", NSStringFromCGRect(frame), NSStringFromClass([ancestor class])];
}

// After the bar has put the items where they go.
static void HSPlaceCapsuleSoon(void) {
    if (gPairPlaceQueued || !gPairItem) return;
    gPairPlaceQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gPairPlaceQueued = NO;
        @try {
            HSPlaceCapsule();
        } @catch (__unused NSException* exception) {
        }
    });
}

// B's side of the pair: tells the capsule when the bar lays it out.
@interface NFBHomePairSide : UIButton
@end

@implementation NFBHomePairSide

- (void)layoutSubviews {
    [super layoutSubviews];
    HSPlaceCapsuleSoon();
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    HSPlaceCapsuleSoon();
}

@end

// YES when B's picture stands next to this (home) button as a bar item, so
// the corner sign is not needed. Bar items are only changed on `recheck`
// (state changes, never from inside the button's layout).
static BOOL HSPairEnsure(UIView* container, BOOL recheck) {
    if (gPairFailed) return NO;
    UIBarButtonItem* ours = gPairItem;
    if (!recheck) return ours != nil && gPairContainer == container;
    UIViewController* holder = nil;
    UIBarButtonItem* avatarItem = HSAvatarItemFor(container, &holder);
    if (!avatarItem || !holder) {
        if (ours && gPairContainer == container) HSPairRemove(@"X's avatar item not found");
        if (!gPairNotFoundLogged) {
            gPairNotFoundLogged = YES;
            HSLog(@"pair: X's avatar item not found in leftBarButtonItems, corner sign instead");
        }
        return NO;
    }
    if (ours && (gPairHolder != holder || gPairAvatarItem != avatarItem)) {
        HSPairRemove(@"the avatar item changed");
        ours = nil;
    }
    if (ours && container.window && !ours.customView.window && [holder.navigationItem.leftBarButtonItems containsObject:ours] &&
        CFAbsoluteTimeGetCurrent() - gPairPlacedAt > 1.5) {
        // The bar does not show our item: the corner sign from now on.
        gPairFailed = YES;
        HSPairRemove(@"the bar did not show it");
        HSLog(@"pair: fallback to the corner sign");
        return NO;
    }
    BOOL created = NO;
    if (!ours) {
        UIButton* side = [NFBHomePairSide buttonWithType:UIButtonTypeCustom];
        side.frame = CGRectMake(0, 0, 36, 36);
        gPairWidth = [side.widthAnchor constraintEqualToConstant:36];
        gPairHeight = [side.heightAnchor constraintEqualToConstant:36];
        gPairWidth.active = YES;
        gPairHeight.active = YES;
        UIImageView* picture = [[UIImageView alloc] initWithFrame:CGRectMake(4, 4, 28, 28)];
        picture.tag = 2;
        picture.contentMode = UIViewContentModeScaleAspectFill;
        picture.clipsToBounds = YES;
        picture.layer.borderWidth = 1.5;
        picture.backgroundColor = [UIColor systemGray4Color];
        picture.userInteractionEnabled = NO;
        [side addSubview:picture];
        [side addTarget:[NFBHomePairTarget shared] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        ours = [[UIBarButtonItem alloc] initWithCustomView:side];
        gPairItem = ours;
        gPairPlacedAt = CFAbsoluteTimeGetCurrent();
        created = YES;
        // Before it goes into the bar: one platter for the two (see "The capsule").
        gPairGlassMode = 0;
        BOOL sharedOurs = HSShareBackground(ours);
        BOOL sharedTheirs = HSShareBackground(avatarItem);
        gPairBackgroundNote = [NSString stringWithFormat:@"sharesBackground ours=%@ X's=%@ (X's own value was %@)",
                                                         sharedOurs ? @"set" : @"no such property", sharedTheirs ? @"set" : @"no such property",
                                                         objc_getAssociatedObject(avatarItem, kHSSharedBackgroundKey) ?: @"-"];
        HSLog(@"pair put next to the home avatar (second bar item)");
    }
    UINavigationItem* item = holder.navigationItem;
    if (![item.leftBarButtonItems containsObject:ours]) {
        NSMutableArray<UIBarButtonItem*>* items = [item.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
        NSUInteger at = [items indexOfObjectIdenticalTo:avatarItem];
        [items insertObject:ours atIndex:at == NSNotFound ? items.count : at + 1];
        item.leftBarButtonItems = items;
        gPairPlacedAt = CFAbsoluteTimeGetCurrent();
    }
    gPairHolder = holder;
    gPairAvatarItem = avatarItem;
    gPairContainer = container;
    gPairPlacement = @"second bar item";
    UIView* side = ours.customView;
    UIImageView* picture = (UIImageView*)[side viewWithTag:2];
    // The same size as X's A picture; always whole and in full colour here.
    CGFloat size = HSAvatarSizeIn(container);
    gPairPictureSize = size;
    // Our item is as big as X's avatar button (so the two take the same room
    // in the bar), never less than the picture plus the capsule's margin; the
    // picture stays in its middle whatever size the bar gives it.
    CGFloat box = size + 2 * kPairPad;
    CGFloat boxWidth = MIN(MAX(box, CGRectGetWidth(container.bounds)), 64);
    CGFloat boxHeight = MIN(MAX(box, CGRectGetHeight(container.bounds)), 64);
    if (gPairWidth.constant != boxWidth) gPairWidth.constant = boxWidth;
    if (gPairHeight.constant != boxHeight) gPairHeight.constant = boxHeight;
    if (!side.superview) side.frame = CGRectMake(0, 0, boxWidth, boxHeight);
    picture.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                               UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    if (CGRectGetWidth(picture.bounds) != size) picture.bounds = CGRectMake(0, 0, size, size);
    CGPoint middle = CGPointMake(CGRectGetMidX(side.bounds), CGRectGetMidY(side.bounds));
    if (!CGPointEqualToPoint(picture.center, middle)) picture.center = middle;
    HSPlaceCapsuleSoon();
    if (picture.layer.cornerRadius != size / 2) picture.layer.cornerRadius = size / 2;
    if (picture.image != gSignImage) picture.image = gSignImage;
    picture.layer.borderColor = (NFBUnifiedBColor() ?: [UIColor systemOrangeColor]).CGColor;
    side.accessibilityLabel = gSignLabel;
    if (created) {
        // The mode came on: B's picture fades in.
        side.alpha = 0.0;
        [UIView animateWithDuration:0.2
                         animations:^{
                             side.alpha = 1.0;
                         }];
    }
    return YES;
}

static UIImageView* HSSignIn(UIView* container) {
    for (UIView* sub in container.subviews) {
        if (sub.tag == kHomeSignTag && [sub isKindOfClass:[UIImageView class]]) return (UIImageView*)sub;
    }
    return nil;
}

// Puts the sign on, keeps it in place, or takes it off. `recheck` (state
// changes) looks the home question up again and refreshes the look; a plain
// layout pass only reads what is cached.
static void HSApply(UIView* container, BOOL recheck) {
    UIImageView* sign = HSSignIn(container);
    BOOL show = gSignWanted && gSignImage != nil;
    if (show) {
        NSNumber* home = objc_getAssociatedObject(container, kHomeSignIsHomeKey);
        if (recheck || !home) {
            BOOL found = NO;
            BOOL isHome = HSContainerIsHome(container, &found);
            home = found ? @(isHome) : nil;
            objc_setAssociatedObject(container, kHomeSignIsHomeKey, home, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        show = home.boolValue;
    }
    if (!show) {
        if (gPairItem && (!gSignWanted || gPairContainer == container)) {
            HSPairRemove(gSignWanted ? @"not the home button" : @"mode not active");
        }
        if (sign) {
            [sign removeFromSuperview];
            HSLog(@"sign taken off");
        }
        return;
    }
    // The pair first; the corner sign only when the pair cannot be had.
    BOOL paired = NO;
    @try {
        paired = HSPairEnsure(container, recheck);
    } @catch (__unused NSException* exception) {
        gPairFailed = YES;
        paired = NO;
    }
    if (paired) {
        if (sign) {
            [sign removeFromSuperview];
            HSLog(@"corner sign taken off (pair shown)");
        }
        // X's button was laid out: the capsule follows the two pictures.
        HSPlaceCapsuleSoon();
        return;
    }

    // X's own avatar inside the button (DashAvatarImageView : TUIAvatarImageView).
    static Class avatarClass;
    if (!avatarClass) avatarClass = objc_getClass("TUIAvatarImageView");
    CGRect bounds = container.bounds;
    CGRect base = bounds;
    if (avatarClass) {
        for (UIView* sub in container.subviews) {
            if (sub == sign || ![sub isKindOfClass:avatarClass]) continue;
            if (!gSignAvatarClass) gSignAvatarClass = NSStringFromClass([sub class]);
            if (!sub.hidden && sub.frame.size.width >= 16 && sub.frame.size.height >= 16) base = sub.frame;
            break;
        }
    }
    CGFloat size = MIN(base.size.width, base.size.height);
    if (size < 16 || size > 80) {
        // Not laid out yet, or not the small button this was written for.
        if (sign) {
            [sign removeFromSuperview];
            HSLog([NSString stringWithFormat:@"sign taken off, avatar size %.0f", size]);
        }
        return;
    }
    // The dock's proportions: 0.47 of the avatar, 2pt past its corner, but
    // never outside the button itself (the glass platter around it is round).
    CGFloat side = round(size * 0.47);
    BOOL rtl = container.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat x = rtl ? MAX(CGRectGetMinX(base) - 2.0, CGRectGetMinX(bounds))
                    : MIN(CGRectGetMaxX(base) + 2.0, CGRectGetMaxX(bounds)) - side;
    CGFloat y = MIN(CGRectGetMaxY(base) + 2.0, CGRectGetMaxY(bounds)) - side;
    CGRect frame = CGRectMake(x, y, side, side);

    BOOL created = NO;
    if (!sign) {
        sign = [[UIImageView alloc] initWithFrame:frame];
        sign.tag = kHomeSignTag;
        // Never takes a touch: the button's own hit area and tap stay as they are.
        sign.userInteractionEnabled = NO;
        sign.contentMode = UIViewContentModeScaleAspectFill;
        sign.clipsToBounds = YES;
        sign.backgroundColor = [UIColor systemGray4Color];
        sign.layer.borderWidth = 1.5;
        // Read out next to the button; with no action of its own a double tap
        // lands on the button underneath.
        sign.isAccessibilityElement = YES;
        sign.accessibilityTraits = UIAccessibilityTraitImage;
        [container addSubview:sign];
        created = YES;
    }
    if (!CGRectEqualToRect(sign.frame, frame)) sign.frame = frame;
    if (sign.layer.cornerRadius != side / 2.0) sign.layer.cornerRadius = side / 2.0;
    if (sign.image != gSignImage) sign.image = gSignImage;
    if (created || recheck) {
        sign.layer.borderColor = (NFBUnifiedBColor() ?: [UIColor systemOrangeColor]).CGColor;
        sign.accessibilityLabel = gSignLabel;
    }
    if (container.subviews.lastObject != sign) [container bringSubviewToFront:sign];
    if (created) {
        HSLog([NSString stringWithFormat:@"sign put on %@ %@ in %@", NSStringFromClass([container class]),
                                         NSStringFromCGRect(frame), NSStringFromCGRect(bounds)]);
    }
}

// MARK: - State

// Reads the mode again and brings every known button in line with it.
static void HSEvaluate(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    gSignEvaluatedAt = now;
    id a = nil;
    id b = nil;
    BOOL wanted = NO;
    @try {
        wanted = NFBUnifiedIsActive() && NFBUnifiedDockPair(&a, &b) && a != nil && b != nil;
    } @catch (__unused NSException* exception) {
        wanted = NO;
    }
    NSString* bID = wanted ? HSUserID(b) : nil;
    if (wanted && bID.length == 0) {
        // B cannot be told: no sign rather than a wrong one.
        wanted = NO;
        if (gSignWanted) HSLog(@"B's user ID not readable, sign off");
    }
    BOOL sameB = (bID == gSignBID) || [bID isEqualToString:gSignBID];
    if (wanted != gSignWanted || (wanted && !sameB)) {
        HSLog([NSString stringWithFormat:@"mode %@ (A %@, B %@)", wanted ? @"active: sign on" : @"not active: sign off",
                                         HSUsername(a) ?: @"-", HSUsername(b) ?: @"-"]);
        if (!sameB) {
            gSignImage = nil;
            gSignImageReal = NO;
            gSignImageTriedAt = 0;
        }
    }
    gSignWanted = wanted;
    gSignBID = wanted ? bID : nil;
    if (wanted) {
        gSignLabel = [NSString stringWithFormat:@"통합 계정, %@, %@", HSUsername(a) ?: @"A", HSUsername(b) ?: @"B"];
        if (!gSignImageReal && (gSignImage == nil || now - gSignImageTriedAt > 5.0)) {
            // The first try also looks at the avatars on screen; later ones only at the file.
            UIImage* picture = HSStoredPicture(bID, gSignImage == nil);
            gSignImageTriedAt = now;
            if (picture) {
                gSignImage = picture;
                gSignImageReal = YES;
                HSLog(@"B's picture found");
            } else if (!gSignImage) {
                gSignImage = HSLetterPicture(NFBUnifiedBColor());
                HSLog(@"B's picture not stored yet, letter shown");
            }
        }
    } else {
        gSignImage = nil;
        gSignImageReal = NO;
        gSignImageTriedAt = 0;
    }
    for (UIView* container in gSignContainers.allObjects) {
        HSApply(container, YES);
    }
}

// Several changes in a row (the defaults notification comes in bursts) are
// answered once.
static void HSScheduleEvaluate(void) {
    if (gSignEvaluatePending) return;
    gSignEvaluatePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gSignEvaluatePending = NO;
        HSEvaluate();
    });
}

// The account in use is changing: once now, once after X has settled.
static void HSAccountChanged(void) {
    HSScheduleEvaluate();
    if (gSignLatePending) return;
    gSignLatePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gSignLatePending = NO;
        HSEvaluate();
    });
}

// From the button's layoutSubviews: a flag, a tag lookup, a frame compare.
static void HSContainerLaidOut(UIView* container) {
    if (![NSThread isMainThread]) return;
    // The notifications tab's button is UnifiedNotifications.x's (it is never
    // a home button, so nothing below touches it).
    NFBUnifiedNotificationsAvatarLaidOut(container);
    if (!objc_getAssociatedObject(container, kHomeSignSeenKey)) {
        objc_setAssociatedObject(container, kHomeSignSeenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gSignContainers) gSignContainers = [NSHashTable weakObjectsHashTable];
        [gSignContainers addObject:container];
        if (!gSignContainerClass) {
            gSignContainerClass = NSStringFromClass([container class]);
            HSLog([NSString stringWithFormat:@"avatar button found: %@", gSignContainerClass]);
        }
        HSScheduleEvaluate();
    } else if (CFAbsoluteTimeGetCurrent() - gSignEvaluatedAt > 2.0) {
        // In case a change came with no notification.
        HSScheduleEvaluate();
    }
    HSApply(container, NO);
}

// MARK: - Debug text (DebugDump.x)

NSString* NFBUnifiedHomeSignDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"hooks: avatar button layoutSubviews=%@ avatar setAccount:=%@%c", gSignHookContainer ? @"hooked" : @"not found",
                      gSignHookAccount ? @"hooked" : @"not found", 10];
    if (![NSThread isMainThread]) {
        [out appendFormat:@"(not on the main thread, state not read)%c", 10];
        return out;
    }
    NSUInteger alive = 0, home = 0, shown = 0;
    for (UIView* container in gSignContainers.allObjects) {
        alive++;
        if ([objc_getAssociatedObject(container, kHomeSignIsHomeKey) boolValue]) home++;
        UIImageView* sign = HSSignIn(container);
        if (sign) {
            shown++;
            [out appendFormat:@"sign %@ in %@ window=%d%c", NSStringFromCGRect(sign.frame), NSStringFromCGRect(container.bounds),
                              container.window != nil, 10];
        }
    }
    [out appendFormat:@"avatar button: %@ (alive %lu, home %lu) avatar=%@ lastRoot=%@%c", gSignContainerClass ?: @"not seen",
                      (unsigned long)alive, (unsigned long)home, gSignAvatarClass ?: @"-", gSignRootClass ?: @"-", 10];
    [out appendFormat:@"sign: wanted=%d shown=%lu picture=%@ activeNow=%d%c", gSignWanted, (unsigned long)shown,
                      gSignImage ? (gSignImageReal ? @"stored" : @"letter") : @"none", NFBUnifiedIsActive(), 10];
    UIBarButtonItem* pair = gPairItem;
    [out appendFormat:@"pair shown=%d placement=%@ inWindow=%d size=%.0f fellBack=%d (corner sign shown=%lu)%c", pair != nil,
                      pair ? gPairPlacement : (shown ? @"corner sign (fallback)" : @"none"), pair.customView.window != nil,
                      gPairPictureSize, gPairFailed, (unsigned long)shown, 10];
    [out appendFormat:@"glass mode %ld (0 asked, 1 X's one platter, 2 our capsule) capsule: %@; bar glass: %@; X's avatar rect %@ in button %@%c", (long)gPairGlassMode, gPairCapsuleNote, gPairBackgroundNote,
                      NSStringFromCGRect(HSAvatarRectIn(gPairContainer)), NSStringFromCGRect(((UIView*)gPairContainer).bounds), 10];
    if (alive == 0) {
        // Nothing was hooked or laid out: what sits in the navigation bars now,
        // to find the button's class in another X version.
        NSMutableOrderedSet<NSString*>* names = [NSMutableOrderedSet orderedSet];
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow* window in ((UIWindowScene*)scene).windows) {
                EnumerateSubviewsRecursively(window, ^(UIView* view) {
                    if (names.count >= 12) return;
                    NSString* name = NSStringFromClass([view class]);
                    if (![name containsString:@"Avatar"] && ![name containsString:@"ItemWrapperView"]) return;
                    UIView* up = view.superview;
                    while (up && ![up isKindOfClass:[UINavigationBar class]]) up = up.superview;
                    if (!up) return;
                    [names addObject:[NSString stringWithFormat:@"%@ %@ < %@", name, NSStringFromCGSize(view.bounds.size),
                                                                NSStringFromClass([view.superview class])]];
                });
            }
        }
        [out appendFormat:@"candidates in navigation bars: %@%c",
                          names.count ? [names.array componentsJoinedByString:@" | "] : @"(none)", 10];
    }
    for (NSString* line in gSignLog) {
        [out appendFormat:@"  %@%c", line, 10];
    }
    return out;
}

// MARK: - Hooks

%group UnifiedHomeSignContainer

// The tab roots' avatar button view (private Swift class of TwitterDash, 12.44).
%hook _TtC11TwitterDashP33_2246CBD3DAA393F61FAC58CEE75589B426TabRootAvatarContainerView

- (void)layoutSubviews {
    %orig;
    HSContainerLaidOut((UIView*)self);
}

%end

%end

%group UnifiedHomeSignAccount

// The button's avatar is handed its account again when the account in use changes.
%hook _TtC11TwitterDash19DashAvatarImageView

- (void)setAccount:(id)account {
    %orig;
    if ([NSThread isMainThread]) {
        HSAccountChanged();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            HSAccountChanged();
        });
    }
}

%end

%end

%ctor {
    // Installed only when 12.44's classes and methods are there.
    Class container = objc_getClass("_TtC11TwitterDashP33_2246CBD3DAA393F61FAC58CEE75589B426TabRootAvatarContainerView");
    if (container && class_getInstanceMethod(container, @selector(layoutSubviews)) != NULL) {
        %init(UnifiedHomeSignContainer);
        gSignHookContainer = YES;
    }
    Class avatar = objc_getClass("_TtC11TwitterDash19DashAvatarImageView");
    if (avatar && class_getInstanceMethod(avatar, NSSelectorFromString(@"setAccount:")) != NULL) {
        %init(UnifiedHomeSignAccount);
        gSignHookAccount = YES;
    }
    BOOL hookContainer = gSignHookContainer;
    BOOL hookAccount = gSignHookAccount;
    dispatch_async(dispatch_get_main_queue(), ^{
        HSLog([NSString stringWithFormat:@"hooks: avatar button %@, setAccount: %@", hookContainer ? @"hooked" : @"not found",
                                         hookAccount ? @"hooked" : @"not found"]);
    });
    if (!gSignHookContainer) return;

    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification* note) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            HSScheduleEvaluate();
                        });
                    }];
    // queue:nil, never the main queue (7.3.79, 7.3.86); the work hops to main itself.
    [center addObserverForName:NSUserDefaultsDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification* note) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            HSScheduleEvaluate();
                        });
                    }];
}
