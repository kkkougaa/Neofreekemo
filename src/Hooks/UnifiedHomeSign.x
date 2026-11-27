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

// B's picture fades out, then its bar item goes.
static void HSPairRemove(NSString* why) {
    UIBarButtonItem* ours = gPairItem;
    if (!ours) return;
    UIViewController* holder = gPairHolder;
    gPairItem = nil;
    gPairHolder = nil;
    gPairAvatarItem = nil;
    gPairContainer = nil;
    gPairPlacement = @"none";
    HSLog([NSString stringWithFormat:@"pair taken off (%@)", why]);
    void (^drop)(void) = ^{
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

// The size of X's own avatar picture in its button; 28 when it cannot be read.
static CGFloat HSAvatarSizeIn(UIView* container) {
    Class avatarClass = objc_getClass("TUIAvatarImageView");
    if (avatarClass) {
        for (UIView* sub in container.subviews) {
            if (![sub isKindOfClass:avatarClass]) continue;
            CGFloat size = MIN(CGRectGetWidth(sub.bounds), CGRectGetHeight(sub.bounds));
            if (size >= 16 && size <= 36) return size;
        }
    }
    return 28;
}

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
        UIButton* side = [UIButton buttonWithType:UIButtonTypeCustom];
        side.frame = CGRectMake(0, 0, 36, 36);
        [side.widthAnchor constraintEqualToConstant:36].active = YES;
        [side.heightAnchor constraintEqualToConstant:36].active = YES;
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
    CGRect frame = CGRectMake((36 - size) / 2, (36 - size) / 2, size, size);
    if (!CGRectEqualToRect(picture.frame, frame)) picture.frame = frame;
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
