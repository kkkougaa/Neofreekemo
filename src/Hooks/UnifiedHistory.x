//
//  UnifiedHistory.x
//  NeoFreeBird
//
//  7.3.151: the account switch of the activity history screen (bookmarks,
//  videos, articles, likes) in A/B unified mode.
//
//  What the 12.44 dump proves about that screen:
//  - it is XActivityHistory's ActivityHistoryContainerViewController (on screen
//    as T1TwitterSwift's private subclass), with Swift ivars `account`,
//    `dependencies`, `pageViewControllers`, `bookmarksPage`, `animatedNavButton`
//    (the search / info button) and a lazy LegacySegmentedViewController child;
//  - X builds it with +[T1ActivityHistoryBridge
//    makeActivityHistoryViewControllerWithAccount:initialTab:] (@32@0:8@16q24);
//  - its pages keep their own `account` (ActivityHistoryPageViewController,
//    ActivityHistoryBookmarksPageViewController, the data provider), the likes
//    page holds a T1URTViewController (`account` getter).
//  The Swift ivars carry no type in the dump, so nothing here trusts them
//  blindly: an ivar is only used as an object when its first word is a live
//  heap object of a registered class, and every account is compared by user ID.
//
//  The switch looks and behaves like the notifications tab's (see the MARK
//  below): the two accounts' pictures side by side, a glass highlight behind
//  the one in use, a tap anywhere on the pair toggles A <-> B. It sits at X's
//  own avatar bar button when the history screen has one (our bar item with
//  B's picture right after X's), else as a self-contained pair that is the
//  last left bar item, so X's bar lays the search field out to the right of
//  it. 0.7s after the screen appeared the place is checked; a switch that is
//  not on screen where intended is taken away again and the screen's
//  controller / view tree is kept for the dump instead.
//
//  Choosing B: X's own screen is built for B's account with the factory above
//  and every account reference that can be reached from it (the screen, its
//  pages, their data providers and lists) is read back. Only if at least one
//  can be read and all of them are B's does it replace A's screen in the
//  navigation stack (A's own screen is kept and put back on A). Nothing of a
//  live screen is mutated. The references are read again after it is shown,
//  on every tab change and whenever one of its lists receives rows; anything
//  that is not B's hides it and brings A's screen back.
//  Requests: choosing B makes X load B's bookmarks / likes as B. Nothing is
//  built, loaded or polled before that choice.
//
//  Never mixed: like / repost / bookmark / reply buttons inside B's history
//  are stopped here until UnifiedTimeline.x says it sends them as B
//  (NFBUnifiedHistoryReactionsWired); a tweet opened from it gets B's account
//  if X passed A's. All of this exists only while unified mode is active: found
//  inactive, A's screen comes back at once and the switch goes.
//

#import "HookHelpers.h"
#import <malloc/malloc.h>

extern BOOL NFBUnifiedIsActive(void);
extern BOOL NFBUnifiedDockPair(id* outA, id* outB);
extern UIColor* NFBUnifiedBColor(void);
extern void NFBShowNotice(NSString* text);
extern UIFont* NFBXFont(CGFloat size, UIFontWeight weight);

BOOL NFBUnifiedHistoryIsBView(UIView* view);

static const NSInteger kHistoryDropTag = 0x4E4648;  // "NFH"
static const void* kHistoryReinstallKey = &kHistoryReinstallKey;

static UIViewController* gHBScreen;                  // B's history screen, in the navigation stack
static UIViewController* gHAScreen;                  // A's own screen it replaced (put back on A)
static NSString* gHBOwner;                           // B's user ID when it was built
static NSMutableSet<NSNumber*>* gHBStatusIDs;        // tweets seen in B's history lists
static __weak UIViewController* gHShownScreen;       // the history screen that appeared last
static NSMutableArray<NSString*>* gHLog;
static NSString* gHVerified = @"-";
static NSString* gHPlaceNote = @"not installed";
static NSString* gHTreeNote = @"(history screen not seen yet)";
static NSString* gHBridgeNote = @"X has not called the factory yet";
static BOOL gHPlaceOK;
static NSUInteger gHPlaceFailures;
static BOOL gHReactionsWired;
static NSUInteger gHReactionsStopped;
static NSUInteger gHOpenedAsB;
static NSUInteger gHCleanups;
static BOOL gHOwnBuild;
static BOOL gHHaveInitialTab;
static long long gHLastInitialTab;
static CFMutableSetRef gHClassSet;
static CFAbsoluteTime gHClassSetAt;

// MARK: - Small helpers

static NSObject* UHLock(void) {
    static NSObject* lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    return lock;
}

static void UHLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized(UHLock()) {
        if (!gHLog) gHLog = [NSMutableArray array];
        [gHLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        while (gHLog.count > 40) [gHLog removeObjectAtIndex:0];
    }
}

// An object-returning getter, only if the object has it and it returns an object.
static id UHGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        if (![object respondsToSelector:@selector(methodSignatureForSelector:)]) return nil;
        NSMethodSignature* signature = [object methodSignatureForSelector:selector];
        if (!signature || signature.methodReturnType[0] != '@') return nil;
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static long long UHNumber(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    @try {
        if (![object respondsToSelector:@selector(methodSignatureForSelector:)]) return 0;
        const char* type = [object methodSignatureForSelector:selector].methodReturnType;
        if (!type) return 0;
        if (type[0] == 'q' || type[0] == 'Q' || type[0] == 'l' || type[0] == 'L' || type[0] == 'i' || type[0] == 'I') {
            return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
        }
        if (type[0] == '@') {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
        }
    } @catch (__unused NSException* exception) {
    }
    return 0;
}

static BOOL UHIsAccount(id object) {
    Class accountClass = objc_getClass("TFNTwitterAccount");
    @try {
        return object && accountClass && [object isKindOfClass:accountClass];
    } @catch (__unused NSException* exception) {
        return NO;
    }
}

// A TFNTwitterAccount's user ID (-userID, q), nil for anything else.
static NSString* UHAccountID(id account) {
    if (!UHIsAccount(account)) return nil;
    long long userID = UHNumber(account, @"userID");
    return userID > 0 ? [NSString stringWithFormat:@"%lld", userID] : nil;
}

static id UHCurrentAccount(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) return nil;
    id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
    return UHGetter(host, @"currentAccount");
}

// A and B, only while unified mode is active, A is the account in use and B is
// the B of the settings; never the same account twice.
static BOOL UHPair(id* outA, id* outB) {
    @try {
        if (!NFBUnifiedIsActive()) return NO;
        id a = nil;
        id b = nil;
        if (!NFBUnifiedDockPair(&a, &b) || !a || !b) return NO;
        NSString* aID = UHAccountID(a);
        NSString* bID = UHAccountID(b);
        NSString* currentID = UHAccountID(UHCurrentAccount());
        NSString* savedB = [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
        if (!aID || !bID || !currentID || [aID isEqualToString:bID]) return NO;
        if (![aID isEqualToString:currentID] || ![bID isEqualToString:savedB]) return NO;
        if (outA) *outA = a;
        if (outB) *outB = b;
        return YES;
    } @catch (__unused NSException* exception) {
        return NO;
    }
}

static Class UHContainerClass(void) {
    return objc_getClass("_TtC16XActivityHistory38ActivityHistoryContainerViewController");
}

static BOOL UHIsContainer(id controller) {
    Class containerClass = UHContainerClass();
    return containerClass && [controller isKindOfClass:containerClass];
}

static BOOL UHIsInside(UIViewController* controller, UIViewController* ancestor) {
    for (UIViewController* parent = controller; parent; parent = parent.parentViewController) {
        if (parent == ancestor) return YES;
    }
    return NO;
}

// MARK: - Reading Swift ivars safely

// Every registered class, to tell an object from any other heap block.
static void UHLoadClasses(BOOL fresh) {
    if (gHClassSet && (!fresh || CFAbsoluteTimeGetCurrent() - gHClassSetAt < 5)) return;
    unsigned int count = 0;
    __unsafe_unretained Class* classes = objc_copyClassList(&count);
    if (!classes) return;
    CFMutableSetRef set = CFSetCreateMutable(kCFAllocatorDefault, (CFIndex)count, NULL);
    for (unsigned int i = 0; i < count; i++) {
        CFSetAddValue(set, (__bridge const void*)classes[i]);
    }
    free(classes);
    if (gHClassSet) CFRelease(gHClassSet);
    gHClassSet = set;
    gHClassSetAt = CFAbsoluteTimeGetCurrent();
}

// The object an ivar holds. The dump gives Swift ivars no type, so the first
// word of the ivar is only taken as an object when it points at a live heap
// block whose class is a registered one; nil otherwise.
static id UHIvarObject(id object, const char* name) {
    if (!object) return nil;
    Class cls = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar) return nil;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < (ptrdiff_t)sizeof(void*) || (size_t)offset + sizeof(void*) > class_getInstanceSize(cls)) return nil;
    uintptr_t raw = 0;
    memcpy(&raw, (uint8_t*)(__bridge void*)object + offset, sizeof(raw));
    if (raw == 0 || (raw & 7) != 0 || (raw >> 56) != 0 || malloc_size((const void*)raw) < 16) return nil;
    UHLoadClasses(NO);
    if (!gHClassSet) return nil;
    id candidate = (__bridge id)(void*)raw;
    Class found = object_getClass(candidate);
    if (!found || !CFSetContainsValue(gHClassSet, (__bridge const void*)found)) return nil;
    return candidate;
}

// The account `holder` keeps: its `account` getter or ivar; when that is a
// wrapper and not a TFNTwitterAccount, the wrapper's own `account`.
static id UHHeldAccount(id holder) {
    if (!holder) return nil;
    @try {
        id held = UHGetter(holder, @"account") ?: (UHIvarObject(holder, "account") ?: UHIvarObject(holder, "_account"));
        if (!held || UHIsAccount(held)) return held;
        id inner = UHGetter(held, @"account") ?: (UHIvarObject(held, "account") ?: UHIvarObject(held, "_account"));
        return UHIsAccount(inner) ? inner : nil;
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

// MARK: - Verifying whose screen it is

static void UHCollect(UIViewController* controller, int depth, NSMutableSet<NSValue*>* seen, NSMutableArray<NSDictionary*>* refs) {
    if (!controller || depth > 7 || refs.count > 60) return;
    NSValue* key = [NSValue valueWithNonretainedObject:controller];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSString* name = NSStringFromClass([controller class]);
    if ([name containsString:@"NFBRecent"]) return;  // our own page (HistoryTabs.x): no account
    NSString* accountID = UHAccountID(UHHeldAccount(controller));
    if (accountID) [refs addObject:@{@"where" : name, @"id" : accountID}];
    // What the dump shows these screens keep besides their children.
    static const char* const held[] = {"dataProvider", "bookmarksPage", "favoritesViewController", "currentContentVC",
                                       "historyPage",  "offlineVideosPage"};
    for (size_t i = 0; i < sizeof(held) / sizeof(held[0]); i++) {
        id object = UHIvarObject(controller, held[i]);
        if (!object) continue;
        if ([object isKindOfClass:[UIViewController class]]) {
            UHCollect(object, depth + 1, seen, refs);
            continue;
        }
        NSString* heldID = UHAccountID(UHHeldAccount(object));
        if (heldID) {
            [refs addObject:@{@"where" : [NSString stringWithFormat:@"%@.%s", name, held[i]], @"id" : heldID}];
        }
    }
    for (UIViewController* child in controller.childViewControllers) {
        UHCollect(child, depth + 1, seen, refs);
    }
}

static UIViewController* UHSegmented(UIViewController* screen) {
    Class segmentedClass = objc_getClass("_TtC10TFNUISwift29LegacySegmentedViewController");
    if (!segmentedClass) return nil;
    for (UIViewController* child in screen.childViewControllers) {
        if ([child isKindOfClass:segmentedClass]) return child;
    }
    return nil;
}

// Reads back every account reference reachable from `screen`. YES only when
// at least one could be read and every one of them is `wantedID`.
static BOOL UHVerify(UIViewController* screen, NSString* wantedID, NSString** outNote) {
    NSMutableArray<NSDictionary*>* refs = [NSMutableArray array];
    NSMutableSet<NSValue*>* seen = [NSMutableSet set];
    NSString* ownID = nil;
    @try {
        UHLoadClasses(YES);
        ownID = UHAccountID(UHHeldAccount(screen));
        UHCollect(screen, 0, seen, refs);
        // Pages X has made but is not showing: -cachedPageViewControllersIn: (@24@0:8@16).
        UIViewController* segmented = UHSegmented(screen);
        SEL cached = NSSelectorFromString(@"cachedPageViewControllersIn:");
        if (segmented && [screen respondsToSelector:cached]) {
            id pages = ((id (*)(id, SEL, id))objc_msgSend)(screen, cached, segmented);
            if ([pages isKindOfClass:[NSArray class]]) {
                for (id page in (NSArray*)pages) {
                    if ([page isKindOfClass:[UIViewController class]]) UHCollect(page, 1, seen, refs);
                }
            }
        }
    } @catch (NSException* exception) {
        if (outNote) *outNote = [NSString stringWithFormat:@"reading accounts threw %@", exception.name];
        return NO;
    }
    BOOL allWanted = refs.count > 0;
    NSMutableArray<NSString*>* pages = [NSMutableArray array];
    for (NSDictionary* ref in refs) {
        if (![ref[@"id"] isEqualToString:wantedID]) allWanted = NO;
        if ([ref[@"where"] isEqualToString:NSStringFromClass([screen class])]) continue;
        [pages addObject:[NSString stringWithFormat:@"%@=%@", ref[@"where"], ref[@"id"]]];
    }
    if (outNote) {
        *outNote = [NSString stringWithFormat:@"controller=%@ pages=%@", ownID ?: @"unreadable",
                                              pages.count ? [pages componentsJoinedByString:@", "] : @"(none readable yet)"];
    }
    return allWanted;
}

// MARK: - B's screen: valid, back to A

static BOOL UHBValid(void) {
    UIViewController* b = gHBScreen;
    if (!b || !gHBOwner) return NO;
    id pairB = nil;
    if (!UHPair(NULL, &pairB)) return NO;
    if (![UHAccountID(pairB) isEqualToString:gHBOwner]) return NO;
    id held = UHHeldAccount(b);
    return !held || [UHAccountID(held) isEqualToString:gHBOwner];
}

static BOOL UHBOnTop(void) {
    UIViewController* b = gHBScreen;
    if (!b || !b.isViewLoaded || !b.view.window) return NO;
    UINavigationController* navigation = b.navigationController;
    return !navigation || navigation.topViewController == b;
}

static void UHSyncSwitch(UIViewController* screen);
static void UHRemoveSwitch(UIViewController* screen);

// A's own screen goes back where B's was (or B's is closed), at once.
static void UHBackToA(NSString* why, NSString* notice) {
    UIViewController* b = gHBScreen;
    if (!b) return;
    UIViewController* a = gHAScreen;
    // The switch on B's screen goes with it (X's avatar button as X made it).
    @try {
        UHRemoveSwitch(b);
    } @catch (__unused NSException* exception) {
    }
    gHBScreen = nil;
    gHAScreen = nil;
    gHBOwner = nil;
    [gHBStatusIDs removeAllObjects];
    NSString* how = @"it was no longer in a navigation stack";
    @try {
        UINavigationController* navigation = b.navigationController;
        NSMutableArray<UIViewController*>* stack = [navigation.viewControllers mutableCopy];
        NSUInteger index = stack ? [stack indexOfObjectIdenticalTo:b] : NSNotFound;
        if (navigation && index != NSNotFound) {
            if (a && [stack indexOfObjectIdenticalTo:a] == NSNotFound) {
                stack[index] = a;
                [navigation setViewControllers:stack animated:NO];
                how = @"A's own screen put back";
            } else if (stack.count > 1) {
                [stack removeObjectAtIndex:index];
                [navigation setViewControllers:stack animated:NO];
                how = @"B's screen closed";
            } else {
                // Nothing to put in its place: it shows and takes nothing any more.
                if (b.isViewLoaded) {
                    b.view.hidden = YES;
                    b.view.userInteractionEnabled = NO;
                }
                how = @"B's screen hidden (nothing to put back)";
            }
        }
    } @catch (NSException* exception) {
        how = [NSString stringWithFormat:@"putting A back threw %@", exception.name];
        if (b.isViewLoaded) {
            b.view.hidden = YES;
            b.view.userInteractionEnabled = NO;
        }
    }
    UHLog([NSString stringWithFormat:@"history: back to A (%@): %@", why, how]);
    if (notice.length) NFBShowNotice(notice);
    @try {
        if (a) UHSyncSwitch(a);
    } @catch (__unused NSException* exception) {
    }
}

// B's screen is only B's while unified is active for the pair it was built for.
static void UHCheck(NSString* where) {
    UIViewController* b = gHBScreen;
    if (!b) return;
    if (!b.navigationController && !b.parentViewController && !(b.isViewLoaded && b.view.window)) {
        // X dropped it (popped, or the whole tab was rebuilt): nothing is kept.
        UHRemoveSwitch(b);
        gHBScreen = nil;
        gHAScreen = nil;
        gHBOwner = nil;
        [gHBStatusIDs removeAllObjects];
        UHLog([NSString stringWithFormat:@"history: B's screen was closed by X; forgotten (%@)", where]);
        return;
    }
    if (!UHBValid()) {
        gHCleanups++;
        UHBackToA([NSString stringWithFormat:@"unified mode not active for this pair, %@", where],
                  @"통합 모드가 꺼져서 지금 계정의 이전내역으로 돌아왔어요");
    }
}

static void UHCheckSoon(NSString* where) {
    static BOOL queued;
    if (queued || !gHBScreen) return;
    queued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        queued = NO;
        @try {
            UHCheck(where);
        } @catch (__unused NSException* exception) {
        }
    });
}

// The accounts are read again while B's screen is shown (pages are made late).
static void UHRecheck(NSString* when) {
    UIViewController* b = gHBScreen;
    if (!b) return;
    UHCheck(when);
    if (gHBScreen != b) return;
    NSString* note = nil;
    if (UHVerify(b, gHBOwner, &note)) {
        if (![note isEqualToString:gHVerified]) {
            gHVerified = note;
            UHLog([NSString stringWithFormat:@"history: B still verified (%@), accounts: %@", when, note]);
        }
        return;
    }
    UHLog([NSString stringWithFormat:@"history: not shown: an account in B's screen is not B's (%@), found %@", when, note ?: @"-"]);
    UHBackToA(@"verification failed", @"이 X 버전에서는 B의 이전내역을 열 수 없어요");
}

static void UHRecheckAfter(NSTimeInterval delay, NSString* when) {
    __weak UIViewController* weakScreen = gHBScreen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController* screen = weakScreen;
        if (!screen || screen != gHBScreen) return;
        @try {
            UHRecheck(when);
        } @catch (__unused NSException* exception) {
        }
    });
}

// MARK: - Pictures and names

static UIColor* UHAColor(void) {
    return [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1];
}

// The file the dock keeps (Application Support/NFBAccountAvatars/<id>.img),
// else a picture of that user on screen, else a letter in a circle.
static UIImage* UHAccountPicture(id account, NSString* letter, UIColor* color) {
    static NSCache<NSString*, UIImage*>* cache;
    if (!cache) cache = [NSCache new];
    NSString* userID = UHAccountID(account) ?: letter;
    UIImage* image = [cache objectForKey:userID];
    if (image) return image;
    NSURL* base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSString* path = [[base URLByAppendingPathComponent:@"NFBAccountAvatars"]
                         URLByAppendingPathComponent:[userID stringByAppendingString:@".img"]].path;
    NSData* data = path ? [NSData dataWithContentsOfFile:path] : nil;
    __block UIImage* found = data.length ? [UIImage imageWithData:data] : nil;
    if (!found) {
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
    }
    if (found) {
        [cache setObject:found forKey:userID];
        return found;
    }
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28)];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext* context) {
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 28, 28)] fill];
        NSDictionary* attributes = @{NSFontAttributeName : NFBXFont(14, UIFontWeightBold), NSForegroundColorAttributeName : [UIColor whiteColor]};
        CGSize size = [letter sizeWithAttributes:attributes];
        [letter drawAtPoint:CGPointMake((28 - size.width) / 2, (28 - size.height) / 2) withAttributes:attributes];
    }];
}

static NSString* UHHandle(id account, NSString* fallback) {
    id name = UHGetter(account, @"username");
    if (![name isKindOfClass:[NSString class]] || [name length] == 0) return fallback;
    return [name hasPrefix:@"@"] ? name : [@"@" stringByAppendingString:name];
}

// MARK: - The A | B switch (the same look and behaviour as the notifications tab's)
//
// The two accounts' pictures side by side, A left and B right (B's with its
// colour ring), a glass highlight behind the one in use that springs over on a
// switch, the other one slightly smaller and dimmed, no text. A tap anywhere
// on the pair toggles the account.
// - At X's own avatar button, when the history screen has one
//   (_TtC11TwitterDash26TabRootAvatarBarButtonItem in the screen's or its
//   navigation root's leftBarButtonItems): X's avatar stays X's and is A's
//   side; B's picture is a bar item of ours right after it; X's avatar is
//   never moved or resized (a highlight behind it, its alpha while B is in
//   use). On that one button, while unified is active, X's -didTapAvatar is
//   replaced by the toggle.
// - Otherwise (a pushed screen with a back button): a self-contained pair,
//   the last left bar item, so the search field is laid out to its right.

// 7.3.152: both pictures are always the same size; the one not in use is only dimmed.
static const CGFloat kHUnselectedScale = 1.0;
static const CGFloat kHUnselectedAlpha = 0.6;
static const CGFloat kHPairWidth = 80;
static const CGFloat kHPairHeight = 40;
static const NSInteger kHAvatarHighlightTag = 0x4E464B;  // "NFK", in X's avatar container
static const void* kHistoryAppearedKey = &kHistoryAppearedKey;

static BOOL gHOnB;                               // which picture is shown as the one in use
static BOOL gHTogglePending;                     // a tap is being carried out
static UIBarButtonItem* gHBItem;                 // ours (B's picture), next to X's avatar item
static __weak UIBarButtonItem* gHAvatarItem;     // X's avatar item of the history screen
static __weak UIViewController* gHAvatarHolder;  // whose navigationItem holds both
static __weak UIViewController* gHSwitchScreen;  // the history screen the switch is on
static BOOL gHAvatarFailed;
static BOOL gHAvatarHooked;
static NSString* gHMode = @"none";

// Liquid Glass when the app has it on (iOS 26), a thin blur otherwise.
static UIVisualEffect* UHHighlightEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (NFBLiquidGlassEnabled() && glassClass) {
        id effect = [[glassClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
}

static UIVisualEffectView* UHMakeHighlight(void) {
    UIVisualEffectView* highlight = [[UIVisualEffectView alloc] initWithEffect:UHHighlightEffect()];
    highlight.clipsToBounds = YES;
    highlight.userInteractionEnabled = NO;
    // No glass: a tinted capsule over the blur.
    if ([highlight.effect isKindOfClass:[UIBlurEffect class]]) highlight.contentView.backgroundColor = [UIColor tertiarySystemFillColor];
    return highlight;
}

static void UHToggle(NSString* from);

// The self-contained pair (no avatar button of X's on the screen).
@interface NFBHistoryPairControl : UIView
- (void)refresh;
- (void)place;
- (void)tapped:(UIButton*)button;
@end

@implementation NFBHistoryPairControl {
    UIVisualEffectView* _highlight;
    NSArray<UIButton*>* _sides;
    NSArray<UIImageView*>* _pictures;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:CGRectMake(0, 0, kHPairWidth, kHPairHeight)];
    if (self) {
        self.tag = kHistoryDropTag;
        _highlight = UHMakeHighlight();
        _highlight.bounds = CGRectMake(0, 0, 36, 36);
        _highlight.layer.cornerRadius = 18;
        [self addSubview:_highlight];
        NSMutableArray<UIButton*>* sides = [NSMutableArray array];
        NSMutableArray<UIImageView*>* pictures = [NSMutableArray array];
        for (NSInteger i = 0; i < 2; i++) {
            UIButton* side = [UIButton buttonWithType:UIButtonTypeCustom];
            side.tag = i + 1;
            side.frame = CGRectMake(kHPairWidth / 2 * i, 0, kHPairWidth / 2, kHPairHeight);
            [side addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            UIImageView* picture = [[UIImageView alloc] initWithFrame:CGRectMake((kHPairWidth / 2 - 28) / 2, (kHPairHeight - 28) / 2, 28, 28)];
            picture.contentMode = UIViewContentModeScaleAspectFill;
            picture.clipsToBounds = YES;
            picture.layer.cornerRadius = 14;
            picture.userInteractionEnabled = NO;
            [side addSubview:picture];
            [self addSubview:side];
            [sides addObject:side];
            [pictures addObject:picture];
        }
        _sides = sides;
        _pictures = pictures;
        [self refresh];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kHPairWidth, kHPairHeight);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(kHPairWidth, kHPairHeight);
}

// Where the highlight sits and which picture is the one in use.
- (void)place {
    BOOL onB = gHOnB;
    _highlight.center = CGPointMake(kHPairWidth / 4 * (onB ? 3 : 1), kHPairHeight / 2);
    for (NSInteger i = 0; i < 2; i++) {
        BOOL selected = (i == 1) == onB;
        _pictures[i].alpha = selected ? 1.0 : kHUnselectedAlpha;
        _pictures[i].transform = selected ? CGAffineTransformIdentity : CGAffineTransformMakeScale(kHUnselectedScale, kHUnselectedScale);
        _sides[i].accessibilityTraits = selected ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
    }
}

- (void)refresh {
    id a = nil;
    id b = nil;
    if (!UHPair(&a, &b)) {
        self.hidden = YES;
        return;
    }
    self.hidden = NO;
    UIColor* bColor = NFBUnifiedBColor() ?: [UIColor systemOrangeColor];
    _pictures[0].image = UHAccountPicture(a, @"A", UHAColor());
    _pictures[1].image = UHAccountPicture(b, @"B", bColor);
    _pictures[1].layer.borderWidth = 1.5;
    _pictures[1].layer.borderColor = bColor.CGColor;
    _sides[0].accessibilityLabel = [NSString stringWithFormat:@"%@ 이전내역", UHHandle(a, @"A")];
    _sides[1].accessibilityLabel = [NSString stringWithFormat:@"%@ 이전내역", UHHandle(b, @"B")];
    [self place];
}

- (void)tapped:(UIButton*)button {
    UHToggle(button.tag == 2 ? @"B side" : @"A side");
}

@end

@interface NFBHistoryAvatarTarget : NSObject
+ (instancetype)shared;
- (void)tappedB:(UIButton*)button;
@end

@implementation NFBHistoryAvatarTarget

+ (instancetype)shared {
    static NFBHistoryAvatarTarget* target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        target = [NFBHistoryAvatarTarget new];
    });
    return target;
}

- (void)tappedB:(__unused UIButton*)button {
    UHToggle(@"B side");
}

@end

// X's avatar picture inside its button (DashAvatarImageView : TUIAvatarImageView),
// however deep it sits.
static UIView* UHAvatarInDepth(UIView* view, NSInteger depth) {
    Class avatarClass = objc_getClass("TUIAvatarImageView");
    if (!avatarClass || depth > 4) return nil;
    for (UIView* sub in view.subviews) {
        if ([sub isKindOfClass:avatarClass]) return sub;
        UIView* found = UHAvatarInDepth(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIView* UHAvatarIn(UIView* container) {
    return UHAvatarInDepth(container, 0);
}

// X's avatar button view of the history screen, only if it is that class.
static UIView* UHAvatarContainer(void) {
    UIBarButtonItem* item = gHAvatarItem;
    UIView* container = item.customView;
    return [NSStringFromClass([container class]) containsString:@"TabRootAvatarContainerView"] ? container : nil;
}

static NFBHistoryPairControl* UHPairOf(UIViewController* screen) {
    for (UIBarButtonItem* bar in screen.navigationItem.leftBarButtonItems) {
        if (bar.customView.tag == kHistoryDropTag && [bar.customView isKindOfClass:[NFBHistoryPairControl class]]) {
            return (NFBHistoryPairControl*)bar.customView;
        }
    }
    return nil;
}

// Which picture is the one in use: dimming, VoiceOver. At X's avatar button
// both pictures keep their size and X's own glass platter (7.3.152).
static void UHApplyState(void) {
    BOOL onB = gHOnB;
    [UHPairOf(gHSwitchScreen) place];
    UIBarButtonItem* ours = gHBItem;
    if (!ours) return;
    UIView* side = ours.customView;
    UIView* bPicture = [side viewWithTag:2];
    bPicture.alpha = onB ? 1.0 : kHUnselectedAlpha;
    side.accessibilityTraits = onB ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
    // X's avatar keeps its frame; only dimmed while B is the one in use.
    UHAvatarIn(UHAvatarContainer()).alpha = onB ? kHUnselectedAlpha : 1.0;
}

static NSLayoutConstraint* gHSideWidth;
static NSLayoutConstraint* gHSideHeight;

// B's picture takes exactly the size X's own A picture is drawn at in that bar
// (28 until it can be read), and our item the size of X's avatar button, so
// X's bar gives both the same glass circle.
static void UHSizeBPicture(void) {
    UIBarButtonItem* ours = gHBItem;
    UIView* side = ours.customView;
    UIView* picture = [side viewWithTag:2];
    if (!picture) return;
    UIView* container = UHAvatarContainer();
    UIView* avatar = UHAvatarIn(container);
    CGRect aRect = avatar ? [avatar convertRect:avatar.bounds toView:container] : CGRectZero;
    CGFloat size = round(MIN(CGRectGetWidth(aRect), CGRectGetHeight(aRect)) * 2) / 2;
    if (size < 16 || size > 64) size = 28;
    CGFloat box = size + 8;
    CGFloat boxWidth = MIN(MAX(box, CGRectGetWidth(container.bounds)), 64);
    CGFloat boxHeight = MIN(MAX(box, CGRectGetHeight(container.bounds)), 64);
    if (gHSideWidth.constant != boxWidth) gHSideWidth.constant = boxWidth;
    if (gHSideHeight.constant != boxHeight) gHSideHeight.constant = boxHeight;
    if (!side.superview) side.frame = CGRectMake(0, 0, boxWidth, boxHeight);
    if (CGRectGetWidth(picture.bounds) != size) picture.bounds = CGRectMake(0, 0, size, size);
    CGPoint middle = CGPointMake(CGRectGetMidX(side.bounds), CGRectGetMidY(side.bounds));
    if (!CGPointEqualToPoint(picture.center, middle)) picture.center = middle;
    if (picture.layer.cornerRadius != size / 2) picture.layer.cornerRadius = size / 2;
}

// Ours goes; X's avatar button is as X made it again.
static void UHRemoveAvatarSwitch(void) {
    UIBarButtonItem* ours = gHBItem;
    UIViewController* holder = gHAvatarHolder;
    UIView* container = UHAvatarContainer();
    if (ours && holder) {
        NSMutableArray<UIBarButtonItem*>* items = [holder.navigationItem.leftBarButtonItems mutableCopy];
        if ([items containsObject:ours]) {
            [items removeObject:ours];
            holder.navigationItem.leftBarButtonItems = items;
        }
    }
    for (UIView* sub in [container.subviews copy]) {
        if (sub.tag == kHAvatarHighlightTag) [sub removeFromSuperview];
    }
    UIView* avatar = UHAvatarIn(container);
    if (avatar && avatar.alpha < 1.0) avatar.alpha = 1.0;
    gHBItem = nil;
    gHAvatarItem = nil;
    gHAvatarHolder = nil;
    gHSideWidth = nil;
    gHSideHeight = nil;
}

// X's avatar bar item of the history screen: in the leftBarButtonItems of the
// screen or of the root of its navigation stack, and only when that root is
// (or holds) the history screen. nil when it cannot be told.
static UIBarButtonItem* UHFindAvatarItem(UIViewController* screen, UIViewController** outHolder) {
    Class itemClass = objc_getClass("_TtC11TwitterDash26TabRootAvatarBarButtonItem");
    UIViewController* root = screen.navigationController.viewControllers.firstObject;
    if (!itemClass || !root || !UHIsInside(screen, root)) return nil;
    for (UIViewController* holder in @[ screen, root ]) {
        for (UIBarButtonItem* item in holder.navigationItem.leftBarButtonItems) {
            if ([item isKindOfClass:itemClass]) {
                if (outHolder) *outHolder = holder;
                return item;
            }
        }
    }
    return nil;
}

static BOOL UHInstallAvatarSwitch(UIViewController* screen) {
    UIViewController* holder = nil;
    UIBarButtonItem* avatarItem = UHFindAvatarItem(screen, &holder);
    if (!avatarItem || !holder) return NO;
    if (![NSStringFromClass([avatarItem.customView class]) containsString:@"TabRootAvatarContainerView"]) return NO;
    if (gHBItem && (gHAvatarHolder != holder || gHAvatarItem != avatarItem)) UHRemoveAvatarSwitch();
    id b = nil;
    if (!UHPair(NULL, &b)) return NO;
    UIBarButtonItem* ours = gHBItem;
    if (!ours) {
        UIButton* side = [UIButton buttonWithType:UIButtonTypeCustom];
        side.frame = CGRectMake(0, 0, 36, 36);
        gHSideWidth = [side.widthAnchor constraintEqualToConstant:36];
        gHSideHeight = [side.heightAnchor constraintEqualToConstant:36];
        gHSideWidth.active = YES;
        gHSideHeight.active = YES;
        UIImageView* picture = [[UIImageView alloc] initWithFrame:CGRectMake(4, 4, 28, 28)];
        picture.tag = 2;
        picture.contentMode = UIViewContentModeScaleAspectFill;
        picture.clipsToBounds = YES;
        picture.layer.cornerRadius = 14;
        picture.layer.borderWidth = 1.5;
        picture.userInteractionEnabled = NO;
        picture.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                   UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [side addSubview:picture];
        [side addTarget:[NFBHistoryAvatarTarget shared] action:@selector(tappedB:) forControlEvents:UIControlEventTouchUpInside];
        ours = [[UIBarButtonItem alloc] initWithCustomView:side];
        gHBItem = ours;
    }
    UINavigationItem* item = holder.navigationItem;
    if (![item.leftBarButtonItems containsObject:ours]) {
        NSMutableArray<UIBarButtonItem*>* items = [item.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
        NSUInteger at = [items indexOfObjectIdenticalTo:avatarItem];
        [items insertObject:ours atIndex:at == NSNotFound ? items.count : at + 1];
        item.leftBarButtonItems = items;
    }
    gHAvatarItem = avatarItem;
    gHAvatarHolder = holder;
    UIView* side = ours.customView;
    UIImageView* picture = (UIImageView*)[side viewWithTag:2];
    UIColor* bColor = NFBUnifiedBColor() ?: [UIColor systemOrangeColor];
    picture.image = UHAccountPicture(b, @"B", bColor);
    picture.layer.borderColor = bColor.CGColor;
    side.accessibilityLabel = [NSString stringWithFormat:@"%@ 이전내역", UHHandle(b, @"B")];
    UHSizeBPicture();
    return YES;
}

static void UHRemovePair(UIViewController* screen) {
    if (!screen) return;
    UINavigationItem* item = screen.navigationItem;
    NSMutableArray<UIBarButtonItem*>* items = [NSMutableArray array];
    BOOL had = NO;
    for (UIBarButtonItem* bar in item.leftBarButtonItems) {
        if (bar.customView.tag == kHistoryDropTag) {
            had = YES;
        } else {
            [items addObject:bar];
        }
    }
    if (had) item.leftBarButtonItems = items;
}

// The last left item: X's bar lays the search field out to the right of it.
static void UHInstallPair(UIViewController* screen) {
    NFBHistoryPairControl* existing = UHPairOf(screen);
    if (existing) {
        [existing refresh];
        return;
    }
    NFBHistoryPairControl* control = [[NFBHistoryPairControl alloc] initWithFrame:CGRectZero];
    [control.widthAnchor constraintEqualToConstant:kHPairWidth].active = YES;
    [control.heightAnchor constraintEqualToConstant:kHPairHeight].active = YES;
    UIBarButtonItem* bar = [[UIBarButtonItem alloc] initWithCustomView:control];
    UINavigationItem* item = screen.navigationItem;
    item.leftItemsSupplementBackButton = YES;
    NSMutableArray<UIBarButtonItem*>* items = [item.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:bar];
    item.leftBarButtonItems = items;
}

static void UHRemoveSwitch(UIViewController* screen) {
    UHRemovePair(screen);
    if (!screen || gHSwitchScreen == screen || !gHSwitchScreen || gHAvatarHolder == screen) {
        UHRemoveAvatarSwitch();
        gHMode = @"none";
    }
}

// Whether `screen` is a history screen the switch belongs on right now.
static BOOL UHShouldShow(UIViewController* screen) {
    if (!screen || !UHIsContainer(screen) || screen == gHAScreen) return NO;
    if (gHPlaceFailures >= 3 && !gHPlaceOK) return NO;
    id a = nil;
    if (!UHPair(&a, NULL)) return NO;
    if (screen == gHBScreen) return UHBValid();
    // X's own screen: only the one of the account in use (A).
    id held = UHHeldAccount(screen);
    return !held || [UHAccountID(held) isEqualToString:UHAccountID(a)];
}

// Whether the switch is on `screen` in the place it should have.
static BOOL UHHasSwitch(UIViewController* screen) {
    UIViewController* holder = nil;
    UIBarButtonItem* avatar = (!gHAvatarFailed && gHAvatarHooked) ? UHFindAvatarItem(screen, &holder) : nil;
    if (avatar) {
        return gHBItem && gHAvatarItem == avatar && gHAvatarHolder == holder && gHSwitchScreen == screen &&
               [holder.navigationItem.leftBarButtonItems containsObject:gHBItem];
    }
    return UHPairOf(screen) != nil;
}

// At X's avatar button when the screen has one (and its tap can be taken
// over); the self-contained pair otherwise, once the screen has appeared (X
// fills a tab root's bar items late).
static void UHInstall(UIViewController* screen) {
    if (!gHTogglePending) gHOnB = gHBScreen != nil && screen == gHBScreen;
    BOOL atAvatar = NO;
    @try {
        atAvatar = !gHAvatarFailed && gHAvatarHooked && UHInstallAvatarSwitch(screen);
    } @catch (NSException* exception) {
        UHLog([NSString stringWithFormat:@"avatar switch threw %@", exception.name]);
        UHRemoveAvatarSwitch();
        gHAvatarFailed = YES;
    }
    if (atAvatar) {
        UHRemovePair(screen);
        gHSwitchScreen = screen;
        gHMode = @"avatar bar (second bar item)";
        UHApplyState();
        return;
    }
    if (!objc_getAssociatedObject(screen, kHistoryAppearedKey)) return;
    if (gHBItem) UHRemoveAvatarSwitch();
    UHInstallPair(screen);
    gHSwitchScreen = screen;
    gHMode = @"pair, last left bar item";
    UHApplyState();
}

static void UHSyncSwitch(UIViewController* screen) {
    if (!screen) return;
    if (UHShouldShow(screen)) {
        UHInstall(screen);
    } else {
        UHRemoveSwitch(screen);
    }
}

// MARK: - Where the search field is (found at runtime, logged)

// Visible views in the top of the window, breadth first.
static void UHScanTop(UIWindow* window, void (^block)(UIView* view, CGRect frame)) {
    if (!window) return;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 3000) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view.hidden || view.alpha < 0.01) continue;
        CGRect frame = [view convertRect:view.bounds toView:window];
        if (view != window && CGRectGetMinY(frame) > 220) continue;
        if (view != window && !CGRectIsEmpty(frame)) block(view, frame);
        [queue addObjectsFromArray:view.subviews];
    }
}

// X's search views as the dump names them (TFNNavigationBarSearchView and its
// TFNSearchBar / XDSSearchCapsule, XNavigation's LiquidNavigationBarSearchFieldView)
// and UIKit's own.
static BOOL UHIsSearchField(UIView* view) {
    if ([view isKindOfClass:[UISearchBar class]] || [view isKindOfClass:[UISearchTextField class]]) return YES;
    static const char* const names[] = {"TFNNavigationBarSearchView", "_TtC11XNavigation34LiquidNavigationBarSearchFieldView",
                                        "TFNSearchBar", "XDSSearchCapsule"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Class searchClass = objc_getClass(names[i]);
        if (searchClass && [view isKindOfClass:searchClass]) return YES;
    }
    return NO;
}

static BOOL UHSameRow(CGRect a, CGRect b) {
    return CGRectGetMinY(a) < CGRectGetMaxY(b) && CGRectGetMinY(b) < CGRectGetMaxY(a);
}

// The search field next to the control: the navigation controller's own
// -navigationBarSearchView (T1TabNavigationController), else a search view in
// the control's row, else the screen's `animatedNavButton` (its search button).
static UIView* UHFindAnchor(UIViewController* screen, CGRect controlFrame, NSString** outKind) {
    UIWindow* window = screen.view.window;
    UIView* fromNavigation = UHGetter(screen.navigationController, @"navigationBarSearchView");
    if ([fromNavigation isKindOfClass:[UIView class]] && fromNavigation.window && !fromNavigation.hidden &&
        fromNavigation.alpha > 0.01 && CGRectGetWidth(fromNavigation.bounds) > 40) {
        if (outKind) *outKind = @"navigation controller's navigationBarSearchView";
        return fromNavigation;
    }
    __block UIView* best = nil;
    __block CGFloat bestWidth = 0;
    __block BOOL bestInRow = NO;
    UHScanTop(window, ^(UIView* view, CGRect frame) {
        if (CGRectGetWidth(frame) < 40 || !UHIsSearchField(view)) return;
        BOOL inRow = UHSameRow(frame, controlFrame);
        if (bestInRow && !inRow) return;
        if ((inRow && !bestInRow) || CGRectGetWidth(frame) > bestWidth) {
            best = view;
            bestWidth = CGRectGetWidth(frame);
            bestInRow = inRow;
        }
    });
    if (best) {
        if (outKind) *outKind = @"search view in the top of the window";
        return best;
    }
    id button = UHIvarObject(screen, "animatedNavButton");
    if ([button isKindOfClass:[UIView class]] && ((UIView*)button).window && !((UIView*)button).hidden) {
        if (outKind) *outKind = @"no search field; the screen's animatedNavButton (search button)";
        return button;
    }
    return nil;
}

static void UHDescribeChildren(UIViewController* controller, int depth, NSMutableString* out, NSUInteger* lines) {
    if (depth > 4 || *lines > 24) return;
    for (UIViewController* child in controller.childViewControllers) {
        if (*lines > 24) return;
        (*lines)++;
        [out appendFormat:@"%@%@%@\n", [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0],
                          NSStringFromClass([child class]), child.isViewLoaded && child.view.window ? @"" : @" (off screen)"];
        UHDescribeChildren(child, depth + 1, out, lines);
    }
}

static NSString* UHBarItems(NSArray<UIBarButtonItem*>* items) {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (UIBarButtonItem* bar in items) {
        [names addObject:[NSString stringWithFormat:@"%@(%@)", NSStringFromClass([bar class]),
                                                    bar.customView ? NSStringFromClass([bar.customView class]) : @"-"]];
    }
    return names.count ? [names componentsJoinedByString:@", "] : @"(none)";
}

// The live controller and view class tree of the history screen, for the dump.
static NSString* UHTree(UIViewController* screen) {
    NSMutableString* out = [NSMutableString string];
    NSMutableArray<NSString*>* parents = [NSMutableArray array];
    for (UIViewController* parent = screen; parent && parents.count < 8; parent = parent.parentViewController) {
        [parents addObject:NSStringFromClass([parent class])];
    }
    [out appendFormat:@"controllers: %@\n", [parents componentsJoinedByString:@" < "]];
    NSUInteger lines = 0;
    UHDescribeChildren(screen, 1, out, &lines);
    UINavigationItem* item = screen.navigationItem;
    [out appendFormat:@"navigation item: left=%@ | title=%@ | right=%@\n", UHBarItems(item.leftBarButtonItems),
                      item.titleView ? NSStringFromClass([item.titleView class]) : @"-", UHBarItems(item.rightBarButtonItems)];
    [out appendFormat:@"navigation controller: %@ bar=%@ navigationBarSearchView=%@\n",
                      NSStringFromClass([screen.navigationController class]) ?: @"-",
                      NSStringFromClass([screen.navigationController.navigationBar class]) ?: @"-",
                      NSStringFromClass([UHGetter(screen.navigationController, @"navigationBarSearchView") class]) ?: @"-"];
    __block NSUInteger views = 0;
    UHScanTop(screen.view.window, ^(UIView* view, CGRect frame) {
        if (views >= 60 || CGRectGetMinY(frame) > 170 || CGRectGetWidth(frame) < 20 || CGRectGetHeight(frame) < 14) return;
        NSString* name = NSStringFromClass([view class]);
        if ([name isEqualToString:@"UIView"] || [name isEqualToString:@"UIImageView"] || [name isEqualToString:@"UILabel"]) return;
        views++;
        [out appendFormat:@"top: %@ %@\n", name, NSStringFromCGRect(frame)];
    });
    return out;
}

static void UHCheckPlace(UIViewController* screen);

static void UHCheckPlaceAfter(UIViewController* screen, NSTimeInterval delay) {
    __weak UIViewController* weakScreen = screen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            UHCheckPlace(weakScreen);
        } @catch (NSException* exception) {
            UHLog([NSString stringWithFormat:@"place check threw %@", exception.name]);
        }
    });
}

// 0.7s after the screen appeared: the switch must be on screen where it was
// meant to be. At the avatar: our item shown, in X's avatar's row and after
// it; if not, it is taken away and the pair is tried. The pair: shown and left
// of the search field; if not, it is taken away again (no guessed place).
static void UHCheckPlace(UIViewController* screen) {
    if (!screen || !screen.isViewLoaded || !screen.view.window) return;
    gHTreeNote = UHTree(screen);
    UIWindow* window = screen.view.window;
    NSString* why = nil;
    if (gHBItem && gHSwitchScreen == screen) {
        UIView* side = gHBItem.customView;
        UIView* container = UHAvatarContainer();
        CGRect sideFrame = CGRectZero;
        CGRect avatarFrame = CGRectZero;
        if (!side.window) {
            why = @"X's navigation bar did not show our item";
        } else if (!container.window) {
            why = @"X's avatar button is not on screen";
        } else {
            sideFrame = [side convertRect:side.bounds toView:window];
            avatarFrame = [container convertRect:container.bounds toView:window];
            if (!UHSameRow(sideFrame, avatarFrame) || CGRectGetMidX(sideFrame) <= CGRectGetMidX(avatarFrame)) {
                why = @"our item did not land right after X's avatar";
            }
        }
        NSString* found = [NSString stringWithFormat:@"ours %@ after X's avatar %@ (%@)", NSStringFromCGRect(sideFrame),
                                                     NSStringFromCGRect(avatarFrame), NSStringFromClass([container class]) ?: @"-"];
        if (!why) {
            UHSizeBPicture();
            NSString* note = [@"avatar bar (second bar item): " stringByAppendingString:found];
            if (!gHPlaceOK || ![note isEqualToString:gHPlaceNote]) UHLog([@"switch placed: " stringByAppendingString:note]);
            gHPlaceOK = YES;
            gHPlaceNote = note;
            return;
        }
        UHLog([NSString stringWithFormat:@"switch place check failed (avatar bar): %@; %@", why, found]);
        if (gHPlaceOK) return;  // it has been proven before; a passing state of X's bar
        // Not at the avatar on this X: the self-contained pair instead.
        gHAvatarFailed = YES;
        UHRemoveAvatarSwitch();
        UHSyncSwitch(screen);
        UHCheckPlaceAfter(screen, 0.7);
        return;
    }
    NFBHistoryPairControl* control = UHPairOf(screen);
    if (!control) return;
    NSString* kind = nil;
    CGRect controlFrame = CGRectZero;
    CGRect anchorFrame = CGRectZero;
    UIView* anchor = nil;
    if (!control.window) {
        why = @"X's navigation bar did not show the item";
    } else {
        controlFrame = [control convertRect:control.bounds toView:window];
        anchor = UHFindAnchor(screen, controlFrame, &kind);
        if (!anchor) {
            why = @"no search field (and no search button) found on the screen";
        } else {
            anchorFrame = [anchor convertRect:anchor.bounds toView:window];
            if (CGRectGetMaxX(controlFrame) > CGRectGetMinX(anchorFrame) + 2 || !UHSameRow(controlFrame, anchorFrame)) {
                why = @"the item did not land left of the search field";
            }
        }
    }
    NSString* found = [NSString stringWithFormat:@"left of %@ %@ (%@), pair %@", anchor ? NSStringFromClass([anchor class]) : @"-",
                                                 NSStringFromCGRect(anchorFrame), kind ?: @"-", NSStringFromCGRect(controlFrame)];
    if (!why) {
        if (!gHPlaceOK || ![found isEqualToString:gHPlaceNote]) UHLog([@"switch placed: " stringByAppendingString:found]);
        gHPlaceOK = YES;
        gHPlaceNote = found;
        return;
    }
    UHLog([NSString stringWithFormat:@"switch place check failed (pair): %@; %@", why, found]);
    if (gHPlaceOK) return;  // it has been proven before; a passing state of X's bar
    gHPlaceFailures++;
    gHPlaceNote = [NSString stringWithFormat:@"not placed (%@): %@", why, found];
    if (screen == gHBScreen) UHBackToA(@"the switch could not be placed", nil);
    // Not put back by the layout hook; the next appearance tries again (3 times at most).
    objc_setAssociatedObject(screen, kHistoryReinstallKey, @6, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UHRemoveSwitch(screen);
}

// MARK: - Choosing an account

static void UHFail(NSString* why) {
    UHLog([NSString stringWithFormat:@"history: not shown: %@", why]);
    NFBShowNotice(@"이 X 버전에서는 B의 이전내역을 열 수 없어요");
}

// Builds X's own history screen for B, proves it is B's, and puts it where
// A's screen `aScreen` is. This is what makes X load B's bookmarks / likes as
// B: it only ever runs from the user's tap on the switch.
static void UHSwitchToB(UIViewController* aScreen) {
    if (gHBScreen) UHBackToA(@"B chosen on another history screen", nil);
    id b = nil;
    if (!UHPair(NULL, &b)) {
        UHSyncSwitch(aScreen);
        return;
    }
    NSString* bID = UHAccountID(b);
    UINavigationController* navigation = aScreen.navigationController;
    Class containerClass = UHContainerClass();
    Class bridge = objc_getClass("T1ActivityHistoryBridge");
    SEL make = NSSelectorFromString(@"makeActivityHistoryViewControllerWithAccount:initialTab:");
    if (!navigation || [navigation.viewControllers indexOfObjectIdenticalTo:aScreen] == NSNotFound) {
        UHFail(@"A's history screen is not in a navigation stack");
        return;
    }
    if (!containerClass || !bridge || !class_getClassMethod(bridge, make)) {
        UHFail([NSString stringWithFormat:@"X's factory is missing (container=%d bridge=%d selector=%d)", containerClass != Nil,
                                          bridge != Nil, bridge && class_getClassMethod(bridge, make) != NULL]);
        return;
    }
    // The tab value X itself passed last time, or the enum's first case.
    long long tab = gHHaveInitialTab ? gHLastInitialTab : 0;
    UIViewController* made = nil;
    gHOwnBuild = YES;
    @try {
        made = ((id (*)(id, SEL, id, long long))objc_msgSend)((id)bridge, make, b, tab);
    } @catch (NSException* exception) {
        gHOwnBuild = NO;
        UHFail([NSString stringWithFormat:@"X's factory threw %@", exception.name]);
        return;
    }
    gHOwnBuild = NO;
    if (![made isKindOfClass:[UIViewController class]] || ![made isKindOfClass:containerClass]) {
        UHFail([NSString stringWithFormat:@"X's factory returned %@", made ? NSStringFromClass([made class]) : @"nothing"]);
        return;
    }
    // Before its view (and so anything it loads) exists.
    UHLoadClasses(YES);
    id held = UHHeldAccount(made);
    if (held && ![UHAccountID(held) isEqualToString:bID]) {
        UHFail([NSString stringWithFormat:@"the screen built for B holds account %@", UHAccountID(held) ?: @"(no id)"]);
        return;
    }
    NSString* note = nil;
    @try {
        made.hidesBottomBarWhenPushed = aScreen.hidesBottomBarWhenPushed;
        if (aScreen.isViewLoaded) made.view.frame = aScreen.view.frame;
        [made.view layoutIfNeeded];
    } @catch (NSException* exception) {
        UHFail([NSString stringWithFormat:@"loading B's screen threw %@", exception.name]);
        return;
    }
    if (!UHVerify(made, bID, &note)) {
        UHFail([NSString stringWithFormat:@"its accounts could not be proven to be B's (%@), found %@", bID, note ?: @"-"]);
        return;
    }
    long long aIndex = UHNumber(UHSegmented(aScreen), @"selectedIndex");
    @try {
        NSMutableArray<UIViewController*>* stack = [navigation.viewControllers mutableCopy];
        NSUInteger index = [stack indexOfObjectIdenticalTo:aScreen];
        if (index == NSNotFound) {
            UHFail(@"A's history screen left the navigation stack");
            return;
        }
        stack[index] = made;
        [navigation setViewControllers:stack animated:NO];
        if ([navigation.viewControllers indexOfObjectIdenticalTo:made] == NSNotFound) {
            UHFail(@"X's navigation controller did not take B's screen");
            return;
        }
    } @catch (NSException* exception) {
        UHFail([NSString stringWithFormat:@"replacing the screen threw %@", exception.name]);
        return;
    }
    gHBScreen = made;
    gHAScreen = aScreen;
    gHBOwner = bID;
    gHVerified = note ?: @"-";
    if (!gHBStatusIDs) gHBStatusIDs = [NSMutableSet set];
    [gHBStatusIDs removeAllObjects];
    UHLog([NSString stringWithFormat:@"history: switched to B, verified accounts: %@", note]);
    @try {
        UHInstall(made);
        // The same tab as A's screen was on.
        UIViewController* segmented = UHSegmented(made);
        SEL select = NSSelectorFromString(@"setSelectedIndex:animated:");
        long long tabs = UHNumber(segmented, @"numberOfTabs");
        if (segmented && [segmented respondsToSelector:select] && aIndex > 0 && aIndex < tabs &&
            tabs == UHNumber(UHSegmented(aScreen), @"numberOfTabs") && UHNumber(segmented, @"selectedIndex") != aIndex) {
            ((void (*)(id, SEL, long long, BOOL))objc_msgSend)(segmented, select, aIndex, NO);
        }
    } @catch (NSException* exception) {
        UHLog([NSString stringWithFormat:@"history: after the switch: %@", exception.name]);
    }
    UHRecheckAfter(0.6, @"0.6s after the switch");
    UHRecheckAfter(2.0, @"2s after the switch");
}

// The one way the account is switched, whichever picture was tapped: the
// highlight springs over at once, the screen follows on the next turn.
static void UHToggle(NSString* from) {
    UIViewController* screen = gHSwitchScreen;
    if (!screen || gHTogglePending) return;
    if (!UHPair(NULL, NULL)) {
        UHCheck(@"switch tapped");
        UHSyncSwitch(screen);
        return;
    }
    BOOL toB = screen != gHBScreen;
    gHTogglePending = YES;
    gHOnB = toB;
    UHLog([NSString stringWithFormat:@"switch: %@ (tap on %@)", toB ? @"B" : @"A", from]);
    [[UISelectionFeedbackGenerator new] selectionChanged];
    [UIView animateWithDuration:0.55
                          delay:0
         usingSpringWithDamping:0.68
          initialSpringVelocity:0.6
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         UHApplyState();
                     }
                     completion:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (toB) {
                UHSwitchToB(screen);
            } else {
                UHBackToA(@"A chosen at the switch", nil);
            }
        } @catch (NSException* exception) {
            UHLog([NSString stringWithFormat:@"switch threw %@", exception.name]);
        }
        gHTogglePending = NO;
        // What is really shown now (B could not be opened: back on A's picture).
        BOOL nowB = gHBScreen != nil;
        if (nowB != gHOnB) {
            gHOnB = nowB;
            [UIView animateWithDuration:0.3
                             animations:^{
                                 UHApplyState();
                             }];
        }
    });
}

// X's avatar button was tapped. YES (and the account toggles instead of X's
// account list) only for the history screen's own button, the one our item
// sits next to, while that screen is on screen and unified is active; every
// other avatar button, and this one at any other time, keeps X's own tap.
static BOOL UHAvatarTapToggles(id item) {
    if (!gHBItem || !item || item != gHAvatarItem) return NO;
    UIViewController* holder = gHAvatarHolder;
    UIViewController* screen = gHSwitchScreen;
    if (!holder || !screen || !UHIsContainer(screen) || !screen.isViewLoaded || !screen.view.window) return NO;
    if (![holder.navigationItem.leftBarButtonItems containsObject:gHBItem]) return NO;
    if (!UHPair(NULL, NULL)) return NO;
    UHToggle(@"X avatar");
    return YES;
}

// MARK: - The history screen appears / is laid out

static void UHAppeared(UIViewController* screen) {
    gHShownScreen = screen;
    objc_setAssociatedObject(screen, kHistoryAppearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UHCheckSoon(@"a history screen appeared");
    UHSyncSwitch(screen);
    if (screen == gHBScreen) UHRecheckAfter(0.3, @"B's screen appeared");
    UHCheckPlaceAfter(screen, 0.7);
}

// X's tab navigation rewrites the bar items of its root screen; ours is put
// back a few times at most (never in a loop against X).
static void UHLaidOut(UIViewController* screen) {
    if (screen == gHBScreen && !UHBValid()) {
        UHCheckSoon(@"B's screen laid out");
        return;
    }
    if (!screen.view.window) return;
    if (UHHasSwitch(screen)) {
        if (gHBItem && gHSwitchScreen == screen) UHSizeBPicture();
        return;
    }
    if (!UHShouldShow(screen)) return;
    NSInteger count = [objc_getAssociatedObject(screen, kHistoryReinstallKey) integerValue];
    if (count >= 6) return;
    objc_setAssociatedObject(screen, kHistoryReinstallKey, @(count + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UHInstall(screen);
}

// MARK: - For UnifiedTimeline.x

// A view inside B's history while it is the screen being looked at and still
// B's (the pair, the screen's account and the nearest list's account, by user
// ID): what is tapped there is B's.
BOOL NFBUnifiedHistoryIsBView(UIView* view) {
    @try {
        UIViewController* b = gHBScreen;
        if (!b || !view || !b.isViewLoaded || ![view isDescendantOfView:b.view]) return NO;
        if (!UHBValid()) {
            UHCheckSoon(@"a view asked");
            return NO;
        }
        if (!UHBOnTop()) return NO;
        BOOL sawAccount = NO;
        for (UIResponder* responder = view; responder && responder != b; responder = responder.nextResponder) {
            if (![responder isKindOfClass:[UIViewController class]]) continue;
            // Our own recently-viewed page (HistoryTabs.x) is not B's list.
            if ([NSStringFromClass([responder class]) containsString:@"NFBRecent"]) return NO;
            if (sawAccount) continue;
            NSString* heldID = UHAccountID(UHHeldAccount(responder));
            if (!heldID) continue;
            if (![heldID isEqualToString:gHBOwner]) return NO;
            sawAccount = YES;
        }
        return YES;
    } @catch (__unused NSException* exception) {
        return NO;
    }
}

// A tweet of B's history lists, while B's history is the screen being looked at.
BOOL NFBUnifiedHistoryIsBStatus(long long statusID) {
    @try {
        return statusID > 0 && gHBScreen && [gHBStatusIDs containsObject:@(statusID)] && UHBValid() && UHBOnTop();
    } @catch (__unused NSException* exception) {
        return NO;
    }
}

// UnifiedTimeline.x calls this once it treats NFBUnifiedHistoryIsBView() as a
// B screen (reactions there go out as B); until then they are stopped here.
void NFBUnifiedHistoryReactionsWired(void) {
    gHReactionsWired = YES;
}

// A reaction button inside B's history: X's own path may pick the account in
// use, so it is stopped unless UnifiedTimeline.x sends it as B. NO for every
// view outside B's history (X's own handling, untouched).
static BOOL UHStopInlineAction(id actionsView) {
    UIViewController* b = gHBScreen;
    if (!b || !b.isViewLoaded || ![actionsView isKindOfClass:[UIView class]] || ![(UIView*)actionsView isDescendantOfView:b.view]) {
        return NO;
    }
    BOOL valid = UHBValid();
    BOOL isB = valid && NFBUnifiedHistoryIsBView((UIView*)actionsView);
    if (isB && gHReactionsWired) return NO;
    gHReactionsStopped++;
    if (!valid) {
        NFBShowNotice(@"계정 설정이 바뀌어서 막았어요");
        UHCheckSoon(@"a reaction was tapped");
    } else if (!isB) {
        NFBShowNotice(@"B 계정 이전내역 화면이라 여기서는 반응을 막았어요");
    } else {
        NFBShowNotice(@"B 계정 이전내역이에요. 여기서는 반응을 막아뒀어요. 게시물을 열어서 반응해 주세요");
    }
    return YES;
}

// A tweet opened from B's history: X's own code there holds B's account; if it
// passed A's anyway, B's goes in instead.
static id UHAccountForTweetScreen(id account, long long statusID, id viewModel) {
    @try {
        if (!gHBScreen || !UHBValid() || !UHBOnTop()) return account;
        NSString* accountID = UHAccountID(account);
        if (!accountID || ![accountID isEqualToString:UHAccountID(UHCurrentAccount())]) return account;
        BOOL known = NO;
        for (NSNumber* candidate in @[ @(statusID), @(UHNumber(viewModel, @"statusID")),
                                       @(UHNumber(UHGetter(viewModel, @"representedStatus"), @"statusID")) ]) {
            if (candidate.longLongValue > 0 && [gHBStatusIDs containsObject:candidate]) known = YES;
        }
        id b = nil;
        if (!known || !UHPair(NULL, &b) || !b) return account;
        gHOpenedAsB++;
        UHLog([NSString stringWithFormat:@"tweet %lld from B's history: X passed A, opened as B", statusID]);
        return b;
    } @catch (__unused NSException* exception) {
        return account;
    }
}

// Rows arriving in a list inside B's history: the list's own account is read
// first (not B's: the screen is hidden and A's comes back), then the tweets
// are remembered as B's.
static void UHSawSections(id controller, NSArray* sections) {
    UIViewController* b = gHBScreen;
    if (!b || ![controller isKindOfClass:[UIViewController class]] || !UHIsInside((UIViewController*)controller, b)) return;
    NSString* heldID = UHAccountID(UHHeldAccount(controller));
    if (heldID && gHBOwner && ![heldID isEqualToString:gHBOwner]) {
        if (b.isViewLoaded) b.view.hidden = YES;
        UHLog([NSString stringWithFormat:@"history: not shown: list %@ inside B's screen holds account %@",
                                         NSStringFromClass([controller class]), heldID]);
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (gHBScreen == b) UHBackToA(@"a list was not B's", @"이 X 버전에서는 B의 이전내역을 열 수 없어요");
            } @catch (__unused NSException* exception) {
            }
        });
        return;
    }
    if (![sections isKindOfClass:[NSArray class]]) return;
    if (!gHBStatusIDs) gHBStatusIDs = [NSMutableSet set];
    if (gHBStatusIDs.count > 4000) [gHBStatusIDs removeAllObjects];
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) continue;
        for (id item in (NSArray*)section) {
            id model = unwrapDataViewItem(item);
            long long statusID = UHNumber(model, @"statusID");
            if (statusID > 0) [gHBStatusIDs addObject:@(statusID)];
            long long shown = UHNumber(UHGetter(model, @"representedStatus"), @"statusID");
            if (shown > 0) [gHBStatusIDs addObject:@(shown)];
        }
    }
}

// MARK: - Dump

NSString* NFBUnifiedHistoryDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    @try {
        UHCheck(@"dump");
        id a = nil;
        id b = nil;
        BOOL pair = UHPair(&a, &b);
        Class bridge = objc_getClass("T1ActivityHistoryBridge");
        SEL make = NSSelectorFromString(@"makeActivityHistoryViewControllerWithAccount:initialTab:");
        Class containerClass = UHContainerClass();
        Class segmentedClass = objc_getClass("_TtC10TFNUISwift29LegacySegmentedViewController");
        Class inlineClass = objc_getClass("TTAStatusInlineActionsView");
        [out appendFormat:@"active=%d A=%@ B=%@ glass=%d\n", pair, UHAccountID(a) ?: @"-", UHAccountID(b) ?: @"-", NFBLiquidGlassEnabled()];
        [out appendFormat:@"found: container=%d (account ivar=%d animatedNavButton ivar=%d cachedPages=%d didSelect=%d) "
                          @"bridge=%d factory=%d segmented=%d (setSelectedIndex:animated:=%d) TFNTwitterAccount=%d "
                          @"inline taps=%d tabNav navigationBarSearchView=%d\n",
                          containerClass != Nil, containerClass && class_getInstanceVariable(containerClass, "account") != NULL,
                          containerClass && class_getInstanceVariable(containerClass, "animatedNavButton") != NULL,
                          containerClass && [containerClass instancesRespondToSelector:NSSelectorFromString(@"cachedPageViewControllersIn:")],
                          containerClass &&
                              [containerClass instancesRespondToSelector:NSSelectorFromString(@"segmentedViewController:didSelectViewController:atIndex:previousIndex:trigger:")],
                          bridge != Nil, bridge && class_getClassMethod(bridge, make) != NULL, segmentedClass != Nil,
                          segmentedClass && [segmentedClass instancesRespondToSelector:NSSelectorFromString(@"setSelectedIndex:animated:")],
                          objc_getClass("TFNTwitterAccount") != Nil,
                          inlineClass && [inlineClass instancesRespondToSelector:NSSelectorFromString(@"didTapInlineActionButton:")],
                          [objc_getClass("T1TabNavigationController") instancesRespondToSelector:NSSelectorFromString(@"navigationBarSearchView")]];
        [out appendFormat:@"factory seen from X: %@\n", gHBridgeNote];
        [out appendFormat:@"switch: mode=%@ onB=%d place=%@ (failures %lu, avatar tap hook=%d, avatar place failed=%d)\n", gHMode, gHOnB,
                          gHPlaceNote, (unsigned long)gHPlaceFailures, gHAvatarHooked, gHAvatarFailed];
        UIViewController* shown = gHBScreen;
        [out appendFormat:@"B history on screen=%d valid=%d onTop=%d owner=%@ accounts: %@\n", shown != nil, UHBValid(), UHBOnTop(),
                          gHBOwner ?: @"-", shown ? gHVerified : @"-"];
        [out appendFormat:@"B tweets known=%lu opened as B here=%lu | inline actions: wired=%d stopped=%lu | mode-inactive clean-ups=%lu\n",
                          (unsigned long)gHBStatusIDs.count, (unsigned long)gHOpenedAsB, gHReactionsWired,
                          (unsigned long)gHReactionsStopped, (unsigned long)gHCleanups];
        [out appendFormat:@"-- history screen tree (last seen) --\n%@", gHTreeNote];
        if (![gHTreeNote hasSuffix:@"\n"]) [out appendString:@"\n"];
    } @catch (NSException* exception) {
        [out appendFormat:@"(debug text threw %@)\n", exception.name];
    }
    @synchronized(UHLock()) {
        [out appendFormat:@"%@\n", gHLog.count ? [gHLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

// MARK: - Hooks

// How X gives the screen its account: remembered for the dump, and the tab
// value X passes is reused when B's screen is built.
%hook T1ActivityHistoryBridge

+ (id)makeActivityHistoryViewControllerWithAccount:(id)account initialTab:(long long)initialTab {
    id made = %orig;
    @try {
        if (!gHOwnBuild) {
            gHLastInitialTab = initialTab;
            gHHaveInitialTab = YES;
            gHBridgeNote = [NSString stringWithFormat:@"account %@ initialTab %lld -> %@", UHAccountID(account) ?: @"(not an account)",
                                                      initialTab, made ? NSStringFromClass([made class]) : @"nil"];
        }
    } @catch (__unused NSException* exception) {
    }
    return made;
}

%end

%hook _TtC16XActivityHistory38ActivityHistoryContainerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try {
        UHAppeared((UIViewController*)self);
    } @catch (NSException* exception) {
        UHLog([NSString stringWithFormat:@"history appeared: threw %@", exception.name]);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    @try {
        if (gHBScreen || gHShownScreen == (UIViewController*)self) UHLaidOut((UIViewController*)self);
    } @catch (__unused NSException* exception) {
    }
}

// Another tab of B's history: its page may only have been made now.
- (void)segmentedViewController:(id)segmented
        didSelectViewController:(id)selected
                        atIndex:(long long)index
                  previousIndex:(long long)previousIndex
                        trigger:(long long)trigger {
    %orig;
    if ((UIViewController*)self == gHBScreen) UHRecheckAfter(0.2, @"tab changed");
}

%end

// Both this hook and UnifiedTimeline.x's run. Here only the taps inside B's
// history are looked at, and only to stop them; everything else is X's.
%hook TTAStatusInlineActionsView

- (void)didTapInlineActionButton:(id)button {
    if (gHBScreen && UHStopInlineAction(self)) return;
    %orig;
}

- (void)didTapInlineActionButton:(id)button withPrompt:(id)prompt menuItem:(long long)menuItem {
    if (gHBScreen && UHStopInlineAction(self)) return;
    %orig;
}

- (void)inlineActionButtonDidRecognizeLongPressBegan:(id)button {
    if (gHBScreen && UHStopInlineAction(self)) return;
    %orig;
}

- (void)didTriggerAlternateActionInInlineActionButton:(id)button {
    if (gHBScreen && UHStopInlineAction(self)) return;
    %orig;
}

%end

%hook T1ConversationContainerViewController

- (id)initWithAccount:(id)account
                    statusID:(long long)statusID
     statusNavigationContext:(id)navigationContext
               scribeContext:(id)scribeContext
    sourceNavigationMetadata:(id)sourceMetadata
  overrideNavigationMetadata:(id)overrideMetadata
 shouldIncludeReferrerParams:(BOOL)referrer
shouldStartQuickPromoteOnOpen:(BOOL)quickPromote
           excludedStatusIDs:(id)excluded {
    if (!gHBScreen) return %orig;
    return %orig(UHAccountForTweetScreen(account, statusID, nil), statusID, navigationContext, scribeContext, sourceMetadata,
                 overrideMetadata, referrer, quickPromote, excluded);
}

- (id)initWithAccount:(id)account
                    viewModel:(id)viewModel
      statusNavigationContext:(id)navigationContext
                scribeContext:(id)scribeContext
     sourceNavigationMetadata:(id)sourceMetadata
   overrideNavigationMetadata:(id)overrideMetadata
  shouldIncludeReferrerParams:(BOOL)referrer
shouldNotifyDisplayLatestEdit:(BOOL)notifyEdit
shouldStartQuickPromoteOnOpen:(BOOL)quickPromote
            excludedStatusIDs:(id)excluded {
    if (!gHBScreen) return %orig;
    return %orig(UHAccountForTweetScreen(account, UHNumber(viewModel, @"statusID"), viewModel), viewModel, navigationContext,
                 scribeContext, sourceMetadata, overrideMetadata, referrer, notifyEdit, quickPromote, excluded);
}

%end

%hook TFNItemsDataViewController

- (void)setSections:(NSArray*)sections restoreScrollPosition:(BOOL)restoreScrollPosition {
    %orig;
    if (!gHBScreen) return;
    @try {
        UHSawSections(self, sections);
    } @catch (__unused NSException* exception) {
    }
}

- (void)updateSections:(NSArray*)sections
    reconfigureItemIdentifiers:(NSArray*)identifiers
              withRowAnimation:(long long)animation
                    completion:(id)completion {
    %orig;
    if (!gHBScreen) return;
    @try {
        UHSawSections(self, sections);
    } @catch (__unused NSException* exception) {
    }
}

%end

%group UnifiedHistoryAvatarButton

// The tab roots' avatar bar button (private Swift class of TwitterDash, 12.44).
// UnifiedNotifications.x hooks the same method for its own button; each acts
// only on the item its own bar item sits next to and calls %orig otherwise.
%hook _TtC11TwitterDash26TabRootAvatarBarButtonItem

- (void)didTapAvatar {
    if (UHAvatarTapToggles(self)) return;
    %orig;
}

%end

%end

%ctor {
    %init;
    // Only when 12.44's class and method are there; without the hook X's
    // avatar button is left alone and the self-contained pair is used.
    Class avatarItem = objc_getClass("_TtC11TwitterDash26TabRootAvatarBarButtonItem");
    if (avatarItem && class_getInstanceMethod(avatarItem, NSSelectorFromString(@"didTapAvatar")) != NULL) {
        %init(UnifiedHistoryAvatarButton);
        gHAvatarHooked = YES;
    }
    // Unified mode or the pair changed (settings, the dock, another account in
    // use): B's history goes back to A's at once and the switch follows.
    // queue:nil, then main (a main queue observer stalls the launch, see CLAUDE.md).
    void (^changed)(NSNotification*) = ^(__unused NSNotification* note) {
        static BOOL queued;
        if (queued || (!gHBScreen && !gHShownScreen)) return;
        queued = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            queued = NO;
            @try {
                UHCheck(@"settings or app state changed");
                UIViewController* shown = gHShownScreen;
                if (shown && shown.isViewLoaded && shown.view.window) UHSyncSwitch(shown);
            } @catch (__unused NSException* exception) {
            }
        });
    };
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil usingBlock:changed];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:changed];
}
