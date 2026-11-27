//
//  UnifiedNotifications.x
//  NeoFreeBird
//
//  Step 0 of mixing B's notifications into A's notifications tab (A/B unified
//  mode): nothing is merged or shown yet. When A's notifications tab appears,
//  B's notifications screen is built off screen with X's own
//  -[T1NotificationsViewController initWithAccount:interactionsTimelineBridge:]
//  and -[T1URTNotificationsInteractionsTimelineBridge initWithAccount:], both
//  for B's account, so B's notifications load as B the way X loads them. The
//  sections its inner T1URTViewController receives are summarised for the dump
//  (item classes, and for the first items of each class the getters that look
//  useful), next to the same summary of A's on-screen list, to plan the merge.
//  At most once every 10 minutes; torn down after 20s or two section updates.
//  Read only: nothing here sends an action.
//
//  7.3.151, step 2 (the separated variant): A's list is never touched. B's rows
//  are NOT mixed into it: X keeps its own bookkeeping for the list (entries,
//  last-seen cursor, viewed cells) in Swift code the dump does not show, so
//  rows of another account in it could not be proven harmless to A's marks.
//  Instead an "A | B" switch (the two account pictures, a glass highlight
//  behind the one in use) sits at the notifications tab's avatar button while
//  unified is active: X's avatar is A's side, B's picture is a bar button item
//  of ours right after it, and a tap on either toggles the list (X's own tap
//  on that one button is replaced; other tabs' buttons are never touched).
//  Where that cannot be done the same control takes the title's place, or the
//  top of the list; all of it is taken off when unified is not active
//  (kemo_unified_notif_filter, "a" unless picked). On B, X's own notifications
//  screen for B (the same two inits as step 0, with B's account) is added as a
//  child of A's notifications screen and covers A's list. Everything in it is
//  X's own code holding B's account; on top of that:
//  - a tweet opened from it gets B's account if X passed A's
//    (T1ConversationContainerViewController inits),
//  - like / repost / reply buttons in it are stopped here until
//    UnifiedTimeline.x says it sends them as B (NFBUnifiedNotificationsReactionsWired),
//  - it takes no touch once the pair, the mode or the switch no longer says B.
//  Looking at it counts as B having checked notifications: X's own B screen is
//  really on screen, so X marks them seen the way it does for B's own tab, and
//  the dock's B number is hidden locally (NFBUnifiedNotificationsBadgeOverride)
//  until X's list gives a different one. The off-screen read of step 0 stays
//  silent and is skipped while B's screen is shown.
//  Also 7.3.151: everything here is inert unless unified mode is active (found
//  inactive, B's screens, the switch and what was learnt are dropped at once);
//  lists are summarised only when the dump is asked for; the off-screen
//  screen's "rows were viewed" calls (-[T1URTViewController
//  markAsViewedHelper:didViewCells:], -[TFNMarkAsViewedHelper _markAsViewed])
//  are dropped for that instance, so the silent read does not start X's
//  seen-marking; the 10-minute limit is kept across relaunches, and the user's
//  pull-to-refresh on A's list (-[T1URTViewController loadTop:] while the list
//  is being dragged) reads B again after 30s.
//

#import "HookHelpers.h"
#import <malloc/malloc.h>

extern void NFBShowNotice(NSString* text);
extern UIColor* NFBUnifiedBColor(void);
extern void NFBUnifiedGuardNote(NSSet<NSNumber*>* ids, id bAccount);
extern NSInteger NFBTabNotificationCount(UIWindow* window);  // HeaderBubble.x: the tab bar's notifications number, -1 unknown

NSInteger NFBUnifiedNotificationsBadgeOverride(id account);
static void UNUpdateBadgesSoon(void);

static NSString* const kNotifFilterKey = @"kemo_unified_notif_filter";  // "a" (or unset) / "b"
static NSString* const kNotifSeenKey = @"kemo_unified_notif_b_seen";    // {id, base}: B seen here, dock number then
static NSString* const kDockCountsKey = @"kemo_account_unread_counts";  // AccountBubbles.x's saved numbers
static const NSInteger kFilterTag = 0x4E4646;                           // "NFF"

static UIViewController* gBLive;  // B's notifications screen shown on screen (switch on B)
static UIView* gBLiveHost;
static __weak UIViewController* gBLiveParent;
static NSString* gBLiveOwner;
static NSString* gBLiveTop;
static NSUInteger gBLiveUpdates;
static NSArray* gBLiveSections;
static NSString* gBLiveListClass;
static NSString* const kNotifLastReadKey = @"kemo_unified_notif_last_read";  // when B was last read off screen
static NSUInteger gSilentViewedStopped;
static NSMutableSet<NSNumber*>* gBNotifStatusIDs;
static NSString* gNotifPairKey;
static NSString* gBSeenSignature;
static NSUInteger gBSeenBatches;
static BOOL gAVisible;
static BOOL gReactionsWired;
static NSUInteger gReactionsBlocked;
static NSUInteger gOpenedAsB;
static NSString* gFilterPlace = @"not installed";
static __weak UIView* gFilterView;

static const NSTimeInterval kNotifEvery = 10 * 60;
static const NSTimeInterval kNotifLife = 20;

static UIViewController* gBNotifController;
static UIView* gBNotifHost;
static NSUInteger gBNotifArrivals;
static CFAbsoluteTime gBNotifLast;
// 7.3.151: the lists' last sections are kept and only summarised when the dump
// is asked for (it was on every update, calling getters on X's view models).
static NSArray* gBNotifSections;
static NSString* gBNotifListClass;
static NSArray* gANotifSections;
static NSString* gANotifListClass;
static __weak UIViewController* gANotifController;
static NSMutableArray<NSString*>* gNotifLog;

// 7.3.151: this file's own lock (it was [NSObject class], shared with other files).
static NSObject* UNLock(void) {
    static NSObject* lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    return lock;
}

static void UNLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized(UNLock()) {
        if (!gNotifLog) gNotifLog = [NSMutableArray array];
        [gNotifLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        while (gNotifLog.count > 30) [gNotifLog removeObjectAtIndex:0];
    }
}

static id UNGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static long long UNNumber(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    @try {
        const char* type = [object methodSignatureForSelector:selector].methodReturnType;
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

static NSString* UNAccountID(id account) {
    long long userID = UNNumber(account, @"userID");
    if (userID <= 0) userID = UNNumber(UNGetter(account, @"user"), @"userID");
    return userID > 0 ? [NSString stringWithFormat:@"%lld", userID] : nil;
}

static id UNCurrentAccount(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) return nil;
    id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
    return UNGetter(host, @"currentAccount");
}

static id UNAccountForID(NSString* userID) {
    Class twitterClass = objc_getClass("TFNTwitter");
    if (!twitterClass || ![twitterClass respondsToSelector:@selector(sharedTwitter)] || userID.length == 0) return nil;
    id twitter = ((id (*)(id, SEL))objc_msgSend)(twitterClass, @selector(sharedTwitter));
    id accounts = UNGetter(twitter, @"accounts");
    if (![accounts isKindOfClass:[NSArray class]]) return nil;
    for (id account in accounts) {
        if ([UNAccountID(account) isEqualToString:userID]) return account;
    }
    return nil;
}

// The same rules as UnifiedTimeline.x: feature on, unified mode picked (unset
// = on), B set and not in use, and the account in use is A when A is set.
static BOOL UNActive(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if (![[defaults objectForKey:@"kemo_unified_exp"] boolValue]) return NO;
    id mode = [defaults objectForKey:@"kemo_unified_mode"];
    if (mode && ![mode boolValue]) return NO;
    NSString* bID = [defaults stringForKey:@"kemo_unified_b_id"];
    NSString* currentID = UNAccountID(UNCurrentAccount());
    if (bID.length == 0 || currentID.length == 0 || [bID isEqualToString:currentID]) return NO;
    NSString* aID = [defaults stringForKey:@"kemo_unified_a_id"];
    return aID.length == 0 || [aID isEqualToString:currentID];
}

// B's account, only if it really is B's and not the one in use.
static id UNBAccount(void) {
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
    id account = UNAccountForID(bID);
    if (!account || ![UNAccountID(account) isEqualToString:bID]) return nil;
    if (account == UNCurrentAccount()) return nil;
    return account;
}

static UIWindow* UNKeyWindow(void) {
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

// MARK: - Summaries

static BOOL UNLooksUseful(NSString* name) {
    if ([name containsString:@":"] || [name hasPrefix:@"_"] || [name hasPrefix:@"."]) return NO;
    for (NSString* bad in @[ @"set", @"init", @"dealloc", @"copy", @"mutableCopy", @"new", @"alloc", @"load", @"refresh",
                             @"mark", @"remove", @"delete", @"send", @"perform", @"dismiss", @"reset", @"clear", @"update",
                             @"start", @"stop", @"cancel", @"invalidate", @"fetch", @"request", @"retain", @"release",
                             @"autorelease" ]) {
        if ([name hasPrefix:bad]) return NO;
    }
    for (NSString* word in @[ @"ntry", @"ort", @"tatus", @"otif", @"ser", @"ime", @"ecipient", @"arget", @"ocial",
                              @"ID", @"Id" ]) {
        if ([name rangeOfString:word].location != NSNotFound) return YES;
    }
    return NO;
}

// Zero-argument getters of an object's class chain that look useful, with
// their values (object class or short text, numbers, BOOLs).
static NSString* UNDescribeGetters(id object) {
    NSMutableArray* parts = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    for (Class cls = [object class]; cls && cls != [NSObject class] && parts.count < 14; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method* methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count && parts.count < 14; i++) {
            SEL selector = method_getName(methods[i]);
            NSString* name = NSStringFromSelector(selector);
            if ([seen containsObject:name] || !UNLooksUseful(name)) continue;
            [seen addObject:name];
            if (method_getNumberOfArguments(methods[i]) != 2) continue;
            char type[64] = {0};
            method_getReturnType(methods[i], type, sizeof(type));
            NSString* value = nil;
            @try {
                if (type[0] == '@') {
                    id result = ((id (*)(id, SEL))objc_msgSend)(object, selector);
                    if (!result) {
                        value = @"nil";
                    } else if ([result isKindOfClass:[NSString class]]) {
                        NSString* text = result;
                        value = [NSString stringWithFormat:@"\"%@\"", text.length > 40 ? [[text substringToIndex:40] stringByAppendingString:@"…"] : text];
                    } else if ([result isKindOfClass:[NSNumber class]]) {
                        value = [result stringValue];
                    } else if ([result respondsToSelector:@selector(count)] && [result isKindOfClass:[NSArray class]]) {
                        value = [NSString stringWithFormat:@"%@[%lu]", NSStringFromClass([result class]), (unsigned long)[result count]];
                    } else {
                        value = NSStringFromClass([result class]);
                    }
                } else if (type[0] == 'q' || type[0] == 'Q' || type[0] == 'l' || type[0] == 'L') {
                    value = [NSString stringWithFormat:@"%lld", ((long long (*)(id, SEL))objc_msgSend)(object, selector)];
                } else if (type[0] == 'i' || type[0] == 'I') {
                    value = [NSString stringWithFormat:@"%d", ((int (*)(id, SEL))objc_msgSend)(object, selector)];
                } else if (type[0] == 'B' || type[0] == 'c') {
                    value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) ? @"YES" : @"NO";
                } else {
                    continue;
                }
            } @catch (__unused NSException* exception) {
                value = @"(threw)";
            }
            [parts addObject:[NSString stringWithFormat:@"%@=%@", name, value]];
        }
        free(methods);
    }
    return [parts componentsJoinedByString:@" "];
}

static NSString* UNSummarise(NSArray* sections) {
    NSMutableString* out = [NSMutableString string];
    NSMutableDictionary<NSString*, NSNumber*>* counts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSMutableArray*>* samples = [NSMutableDictionary dictionary];
    NSUInteger wrapped = 0;
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) continue;
        for (id item in section) {
            id model = unwrapDataViewItem(item);
            if (model != item) wrapped++;
            NSString* name = NSStringFromClass([model class]) ?: @"?";
            counts[name] = @(counts[name].integerValue + 1);
            NSMutableArray* list = samples[name];
            if (!list) samples[name] = list = [NSMutableArray array];
            if (list.count < 8) [list addObject:model];
        }
    }
    [out appendFormat:@"sections=%lu wrapped=%lu classes=%@\n", (unsigned long)sections.count, (unsigned long)wrapped,
                      [counts.description stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
    for (NSString* name in samples) {
        [out appendFormat:@"  %@:\n", name];
        for (id model in samples[name]) {
            NSString* getters = nil;
            @try {
                getters = UNDescribeGetters(model);
            } @catch (__unused NSException* exception) {
                getters = @"(threw)";
            }
            [out appendFormat:@"    %@\n", getters.length ? getters : @"(no useful getters)"];
        }
    }
    return out;
}

static BOOL UNIsInside(UIViewController* controller, UIViewController* ancestor) {
    for (UIViewController* parent = controller; parent; parent = parent.parentViewController) {
        if (parent == ancestor) return YES;
    }
    return NO;
}

// MARK: - When each row happened (diagnostics for a later time-ordered mix)

static BOOL UNIsNotificationModel(id item) {
    NSString* name = NSStringFromClass([item class]);
    return [name isEqualToString:@"TwitterURT.URTTimelineNotificationViewModel"] ||
           [name isEqualToString:@"_TtC10TwitterURT32URTTimelineNotificationViewModel"];
}

static BOOL UNIsStatusModel(id item) {
    return [NSStringFromClass([item class]) isEqualToString:@"URTTimelineStatusItemViewModel"];
}

// Where a Swift ivar lives in an object; NULL unless it lies inside the instance.
static void* UNIvarAddress(id object, const char* name) {
    if (!object) return NULL;
    Class cls = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar) return NULL;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset < (ptrdiff_t)sizeof(void*) || (size_t)offset + sizeof(int64_t) > class_getInstanceSize(cls)) return NULL;
    return (uint8_t*)(__bridge void*)object + offset;
}

// A notification row's time in ms since 1970: the view model's `notification`
// ivar (a TFSURTNotification, checked before it is used as an object) and its
// `timestampMilliseconds` ivar. The ivars are Swift's and carry no type in the
// dump, so the value is only taken when it reads as a plausible time; 0 and
// the reason otherwise.
static long long UNNotificationStamp(id model, NSString** shape) {
    void* address = UNIvarAddress(model, "notification");
    if (!address) {
        if (shape) *shape = @"no notification ivar";
        return 0;
    }
    uintptr_t raw = 0;
    memcpy(&raw, address, sizeof(raw));
    if (raw == 0 || (raw & 7) != 0 || (raw >> 56) != 0 || malloc_size((const void*)raw) < 16) {
        if (shape) *shape = @"notification ivar is not a heap object";
        return 0;
    }
    Class wanted = objc_getClass("TFSURTNotification");
    id notification = (__bridge id)(void*)raw;
    if (!wanted || object_getClass(notification) != wanted) {
        if (shape) *shape = @"notification ivar is not a TFSURTNotification";
        return 0;
    }
    void* field = UNIvarAddress(notification, "timestampMilliseconds");
    if (!field) {
        if (shape) *shape = @"no timestampMilliseconds ivar";
        return 0;
    }
    int64_t value = 0;
    memcpy(&value, field, sizeof(value));
    if (value > 1000000000000LL && value < 4000000000000LL) {
        if (shape) *shape = @"integer ms";
        return value;
    }
    double real = 0;
    memcpy(&real, field, sizeof(real));
    if (real > 1.0e12 && real < 4.0e12) {
        if (shape) *shape = @"double ms";
        return (long long)real;
    }
    if (real > 1.2e9 && real < 4.0e9) {
        if (shape) *shape = @"double s since 1970";
        return (long long)(real * 1000.0);
    }
    if (real > 2.0e8 && real <= 1.2e9) {
        if (shape) *shape = @"double s since 2001";
        return (long long)((real + 978307200.0) * 1000.0);
    }
    if (shape) *shape = [NSString stringWithFormat:@"unreadable value %lld", (long long)value];
    return 0;
}

// How many rows of a list can be dated, and whether X's order is by that date.
static NSString* UNDatedNote(NSArray* sections) {
    NSUInteger notifications = 0, notificationsDated = 0, statuses = 0, statusesDated = 0, breaks = 0;
    long long previous = LLONG_MAX;
    NSString* shape = @"-";
    @try {
        for (id section in sections) {
            if (![section isKindOfClass:[NSArray class]]) continue;
            for (id item in section) {
                id model = unwrapDataViewItem(item);
                long long stamp = 0;
                if (UNIsNotificationModel(model)) {
                    notifications++;
                    NSString* how = nil;
                    stamp = UNNotificationStamp(model, &how);
                    if (how) shape = how;
                    if (stamp > 0) notificationsDated++;
                } else if (UNIsStatusModel(model)) {
                    statuses++;
                    long long statusID = UNNumber(model, @"statusID");
                    if (statusID > (1LL << 41)) {
                        // A snowflake ID carries its time.
                        stamp = (statusID >> 22) + 1288834974657LL;
                        statusesDated++;
                    }
                } else {
                    continue;
                }
                if (stamp > 0) {
                    if (stamp > previous) breaks++;
                    previous = stamp;
                }
            }
        }
    } @catch (__unused NSException* exception) {
        shape = @"(threw)";
    }
    return [NSString stringWithFormat:@"  dated: notifications %lu/%lu (%@) statuses %lu/%lu, order breaks %lu\n",
                                      (unsigned long)notificationsDated, (unsigned long)notifications, shape,
                                      (unsigned long)statusesDated, (unsigned long)statuses, (unsigned long)breaks];
}

// MARK: - B's screen off screen

// X's own notifications screen for B; nil unless it was made and holds B's account.
static UIViewController* UNMakeBScreen(id b) {
    Class screenClass = objc_getClass("T1NotificationsViewController");
    Class bridgeClass = objc_getClass("T1URTNotificationsInteractionsTimelineBridge");
    SEL makeScreen = NSSelectorFromString(@"initWithAccount:interactionsTimelineBridge:");
    SEL makeBridge = NSSelectorFromString(@"initWithAccount:");
    if (!b || !screenClass || !bridgeClass || ![screenClass instancesRespondToSelector:makeScreen] ||
        ![bridgeClass instancesRespondToSelector:makeBridge]) {
        UNLog([NSString stringWithFormat:@"cannot make B screen (B=%d screen=%d bridge=%d)", b != nil, screenClass != nil,
                                         bridgeClass != nil]);
        return nil;
    }
    UIViewController* controller = nil;
    @try {
        id bridge = ((id (*)(id, SEL, id))objc_msgSend)([bridgeClass alloc], makeBridge, b);
        controller = ((id (*)(id, SEL, id, id))objc_msgSend)([screenClass alloc], makeScreen, b, bridge);
    } @catch (NSException* exception) {
        UNLog([NSString stringWithFormat:@"making B screen threw %@", exception.name]);
        return nil;
    }
    // Only B's: never read (or show) anything here under another account.
    if (![controller isKindOfClass:[UIViewController class]] ||
        ![UNAccountID(UNGetter(controller, @"account")) isEqualToString:UNAccountID(b)]) {
        UNLog(@"B screen not made, or not B's; stopped");
        return nil;
    }
    return controller;
}

static void UNTearDown(NSString* why) {
    UIViewController* controller = gBNotifController;
    if (!controller) return;
    @try {
        [controller beginAppearanceTransition:NO animated:NO];
        [controller.view removeFromSuperview];
        [controller endAppearanceTransition];
    } @catch (__unused NSException* exception) {
    }
    [gBNotifHost removeFromSuperview];
    gBNotifHost = nil;
    gBNotifController = nil;
    UNLog([NSString stringWithFormat:@"B screen closed (%@, %lu updates)", why, (unsigned long)gBNotifArrivals]);
}

static void UNReadB(BOOL pulled) {
    // 7.3.151: not while B's screen is shown on screen (it is the fresher read).
    // The 10 minutes hold across relaunches (the time is saved); the user's
    // own pull-to-refresh on A's list reads again after 30s.
    if (gBNotifController || gBLive || !UNActive()) return;
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if (gBNotifLast <= 0) {
        double saved = [defaults doubleForKey:kNotifLastReadKey];
        if (saved > 0 && saved <= CFAbsoluteTimeGetCurrent()) gBNotifLast = saved;
    }
    if (gBNotifLast > 0 && CFAbsoluteTimeGetCurrent() - gBNotifLast < (pulled ? 30 : kNotifEvery)) return;
    id b = UNBAccount();
    UIWindow* window = UNKeyWindow();
    if (!b || !window) {
        UNLog([NSString stringWithFormat:@"cannot read B (B=%d window=%d)", b != nil, window != nil]);
        return;
    }
    gBNotifLast = CFAbsoluteTimeGetCurrent();
    [defaults setDouble:gBNotifLast forKey:kNotifLastReadKey];
    UIViewController* controller = UNMakeBScreen(b);
    if (!controller) return;
    gBNotifHost = [[UIView alloc] initWithFrame:CGRectMake(-4000, 0, CGRectGetWidth(window.bounds), CGRectGetHeight(window.bounds))];
    gBNotifHost.userInteractionEnabled = NO;
    gBNotifHost.clipsToBounds = YES;
    gBNotifHost.accessibilityElementsHidden = YES;
    [window insertSubview:gBNotifHost atIndex:0];
    gBNotifController = controller;
    gBNotifArrivals = 0;
    @try {
        controller.view.frame = gBNotifHost.bounds;
        [controller beginAppearanceTransition:YES animated:NO];
        [gBNotifHost addSubview:controller.view];
        [controller endAppearanceTransition];
    } @catch (NSException* exception) {
        UNLog([NSString stringWithFormat:@"showing B screen threw %@", exception.name]);
        UNTearDown(@"threw");
        return;
    }
    UNLog(pulled ? @"B screen open off screen (A pulled to refresh)" : @"B screen open off screen");
    __weak UIViewController* weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNotifLife * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakController && weakController == gBNotifController) UNTearDown(@"time");
    });
}

// MARK: - The A | B switch and B's screen on screen (7.3.151)

static BOOL UNFilterIsB(void) {
    return [[[NSUserDefaults standardUserDefaults] stringForKey:kNotifFilterKey] isEqualToString:@"b"];
}

// What was learnt from B's list belongs to one (account in use, B) pair.
static void UNEnsurePair(void) {
    NSString* key = [NSString stringWithFormat:@"%@|%@", UNAccountID(UNCurrentAccount()) ?: @"-",
                                               [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"] ?: @"-"];
    if ([key isEqualToString:gNotifPairKey]) return;
    BOOL changed = gNotifPairKey != nil;
    gNotifPairKey = key;
    [gBNotifStatusIDs removeAllObjects];
    gBSeenSignature = nil;
    if (changed) UNLog(@"account pair changed; B's notification tweet ids cleared");
}

// The unread number the dock (AccountBubbles.x) last saved for an account.
static NSNumber* UNDockStored(NSString* accountID) {
    NSDictionary* counts = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDockCountsKey];
    id value = accountID.length ? counts[accountID] : nil;
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

// B's screen on screen is only B's while unified is on for this pair, the
// switch says B, and the screen still holds that B.
static BOOL UNLiveValid(void) {
    if (!gBLive || !gBLiveOwner || !gBLiveParent) return NO;
    if (!UNActive() || !UNFilterIsB()) return NO;
    id b = UNBAccount();
    return b && [UNAccountID(b) isEqualToString:gBLiveOwner] &&
           [UNAccountID(UNGetter(gBLive, @"account")) isEqualToString:gBLiveOwner];
}

static void UNRefreshFilter(void);

static void UNRemoveLive(NSString* why) {
    UIViewController* controller = gBLive;
    if (!controller) return;
    gBLive = nil;
    @try {
        [controller willMoveToParentViewController:nil];
        [controller.view removeFromSuperview];
        [controller removeFromParentViewController];
    } @catch (__unused NSException* exception) {
    }
    [gBLiveHost removeFromSuperview];
    gBLiveHost = nil;
    gBLiveParent = nil;
    gBLiveOwner = nil;
    gBLiveTop = nil;
    gBLiveSections = nil;
    UNLog([NSString stringWithFormat:@"B screen removed (%@, %lu updates)", why, (unsigned long)gBLiveUpdates]);
}

// Holds B's screen over A's list. Once it is no longer B's it takes no touch
// (the touch goes to A's own list underneath) and is taken away.
@interface NFBNotifBHost : UIView
@end

@implementation NFBNotifBHost

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    if (self != gBLiveHost || !UNLiveValid()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!UNLiveValid()) UNRemoveLive(@"no longer B's");
        });
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

// A's own list on screen (a table or collection view), not anything of B's.
static UIScrollView* UNListScrollView(UIView* view, int depth) {
    if (!view || depth > 12 || view == gBLiveHost || view.hidden) return nil;
    if (([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) && view.window &&
        CGRectGetHeight(view.bounds) > 200) {
        return (UIScrollView*)view;
    }
    for (UIView* sub in view.subviews) {
        UIScrollView* found = UNListScrollView(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

// B's screen covers what A's list shows between the bars.
static void UNLayoutLive(void) {
    UIViewController* parent = gBLiveParent;
    UIView* host = gBLiveHost;
    if (!parent || !host || host.superview != parent.view) return;
    CGRect frame = UIEdgeInsetsInsetRect(parent.view.bounds, parent.view.safeAreaInsets);
    UIScrollView* list = UNListScrollView(parent.view, 0);
    if (list && list.superview) {
        CGRect inParent = [list.superview convertRect:list.frame toView:parent.view];
        UIEdgeInsets insets = list.adjustedContentInset;
        CGRect visible = UIEdgeInsetsInsetRect(inParent, UIEdgeInsetsMake(insets.top, 0, insets.bottom, 0));
        if (CGRectGetHeight(visible) > 200 && CGRectGetWidth(visible) > 200) frame = visible;
    }
    if (!CGRectEqualToRect(host.frame, frame)) host.frame = frame;
    UIView* filter = gFilterView;
    UIView* floating = filter.superview == parent.view ? filter : nil;
    NSArray<UIView*>* subviews = parent.view.subviews;
    if (floating) {
        if (subviews.lastObject != floating || subviews.count < 2 || subviews[subviews.count - 2] != host) {
            [parent.view bringSubviewToFront:host];
            [parent.view bringSubviewToFront:floating];
        }
    } else if (subviews.lastObject != host) {
        [parent.view bringSubviewToFront:host];
    }
}

// B's screen is what the user is looking at: A's notifications tab is the
// visible screen of its navigation stack and B's screen is in a window.
static BOOL UNLiveOnTop(void) {
    UIViewController* parent = gBLiveParent;
    if (!parent || !gAVisible || !gBLiveHost.window) return NO;
    UINavigationController* navigation = parent.navigationController;
    return !navigation || UNIsInside(parent, navigation.topViewController);
}

// The newest row of a list: a tweet's ID or a notification's impression ID.
static NSString* UNTopSignature(NSArray* sections) {
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) continue;
        for (id item in section) {
            id model = unwrapDataViewItem(item);
            if (UNIsStatusModel(model)) {
                long long statusID = UNNumber(model, @"statusID");
                if (statusID > 0) return [NSString stringWithFormat:@"s%lld", statusID];
            } else if (UNIsNotificationModel(model)) {
                id impression = UNGetter(model, @"scribeItemImpressionID");
                if ([impression isKindOfClass:[NSString class]] && [impression length]) return [@"n" stringByAppendingString:impression];
            }
        }
    }
    return nil;
}

// B's notifications were really looked at (B's screen on screen in A's tab):
// once per new top row. X's own B screen is what tells X they were seen (its
// own T1URTViewController for B: markAsViewedHelper / lastSeenCursorUpdater);
// nothing is sent from here. The dock's B number is hidden locally until X's
// list gives a different one (NFBUnifiedNotificationsBadgeOverride).
static void UNEvaluateSeen(void) {
    if (!gBLiveTop || !UNLiveValid() || !UNLiveOnTop()) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    UNEnsurePair();
    if ([gBLiveTop isEqualToString:gBSeenSignature]) return;
    gBSeenSignature = gBLiveTop;
    gBSeenBatches++;
    NSNumber* stored = UNDockStored(gBLiveOwner);
    [[NSUserDefaults standardUserDefaults] setObject:@{@"id" : gBLiveOwner, @"base" : stored ?: @(-1)} forKey:kNotifSeenKey];
    UNLog([NSString stringWithFormat:@"B seen on screen (batch %lu, top %@); dock's B number %@ hidden locally",
                                     (unsigned long)gBSeenBatches, gBLiveTop, stored ?: @"(none)"]);
    UNUpdateBadgesSoon();
}

// The tweets in B's list (their own IDs and the ones they show): opened from
// B's screen they are B's, and A's records of them are kept from being written
// (UnifiedScribeGuard.x).
static void UNNoteBStatuses(NSArray* sections) {
    UNEnsurePair();
    if (!gBNotifStatusIDs) gBNotifStatusIDs = [NSMutableSet set];
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) continue;
        for (id item in section) {
            id model = unwrapDataViewItem(item);
            if (!UNIsStatusModel(model)) continue;
            long long statusID = UNNumber(model, @"statusID");
            if (statusID > 0) [gBNotifStatusIDs addObject:@(statusID)];
            long long shown = UNNumber(UNGetter(model, @"representedStatus"), @"statusID");
            if (shown > 0) [gBNotifStatusIDs addObject:@(shown)];
        }
    }
    id b = UNBAccount();
    if (b && gBNotifStatusIDs.count) NFBUnifiedGuardNote([gBNotifStatusIDs copy], b);
}

// The switch could not be honoured: back to A, so it never says B over A's list.
static void UNFilterFailed(NSString* why) {
    [[NSUserDefaults standardUserDefaults] setObject:@"a" forKey:kNotifFilterKey];
    UNLog([NSString stringWithFormat:@"switch back to A (%@)", why]);
    UNRefreshFilter();
    NFBShowNotice(@"B 계정 알림을 열지 못했어요");
}

static void UNShowLive(UIViewController* parent) {
    if (gBLive || !parent || !parent.isViewLoaded) return;
    id b = UNBAccount();
    UIViewController* controller = UNMakeBScreen(b);
    if (!controller) {
        UNFilterFailed(@"B screen not made");
        return;
    }
    if (gBNotifController) UNTearDown(@"B shown on screen");
    NFBNotifBHost* host = [[NFBNotifBHost alloc] initWithFrame:parent.view.bounds];
    host.backgroundColor = parent.view.backgroundColor ?: [UIColor systemBackgroundColor];
    host.clipsToBounds = YES;
    // B's colour along the top: this list is B's.
    UIView* line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(host.bounds), 2)];
    line.backgroundColor = NFBUnifiedBColor();
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    line.userInteractionEnabled = NO;
    [host addSubview:line];
    gBLive = controller;
    gBLiveHost = host;
    gBLiveParent = parent;
    gBLiveOwner = UNAccountID(b);
    gBLiveUpdates = 0;
    gBLiveTop = nil;
    @try {
        [parent addChildViewController:controller];
        [parent.view addSubview:host];
        UNLayoutLive();
        controller.view.frame = CGRectMake(0, 2, CGRectGetWidth(host.bounds), MAX(0, CGRectGetHeight(host.bounds) - 2));
        controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host insertSubview:controller.view belowSubview:line];
        [controller didMoveToParentViewController:parent];
    } @catch (NSException* exception) {
        UNRemoveLive([NSString stringWithFormat:@"showing threw %@", exception.name]);
        UNFilterFailed(@"showing threw");
        return;
    }
    UNLog(@"B screen shown on screen (switch on B)");
}

// Brings B's screen in line with the switch: shown over A's notifications
// screen `parent` while it says B and unified is on, gone otherwise.
static void UNSyncLive(UIViewController* parent) {
    if (gBLive && (!UNLiveValid() || (parent && gBLiveParent != parent))) UNRemoveLive(@"switch, pair or screen changed");
    if (!gBLive && parent && UNActive() && UNFilterIsB()) UNShowLive(parent);
}

// An account's picture, the way the other Unified files find it: the file the
// dock keeps (Application Support/NFBAccountAvatars/<id>.img), else a picture
// of that user on screen, else a letter in a circle.
static UIImage* UNAccountPicture(id account, NSString* letter, UIColor* color) {
    static NSCache<NSString*, UIImage*>* cache;
    if (!cache) cache = [NSCache new];
    NSString* userID = UNAccountID(account) ?: letter;
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
        NSDictionary* attributes = @{
            NSFontAttributeName : [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName : UIColor.whiteColor
        };
        CGSize size = [letter sizeWithAttributes:attributes];
        [letter drawAtPoint:CGPointMake((28 - size.width) / 2, (28 - size.height) / 2) withAttributes:attributes];
    }];
}

// "@handle" of an account, or nil.
static NSString* UNHandle(id account) {
    id user = UNGetter(account, @"user");
    for (id source in @[ account ?: [NSNull null], user ?: [NSNull null] ]) {
        if (source == [NSNull null]) continue;
        for (NSString* name in @[ @"username", @"screenName", @"displayUsername" ]) {
            id value = UNGetter(source, name);
            if ([value isKindOfClass:[NSString class]] && [value length]) {
                return [value hasPrefix:@"@"] ? value : [@"@" stringByAppendingString:value];
            }
        }
    }
    return nil;
}

// Liquid Glass when the app has it on (iOS 26), a thin blur otherwise.
static UIVisualEffect* UNHighlightEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (NFBLiquidGlassEnabled() && glassClass) {
        id effect = [[glassClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
}

static const CGFloat kFilterWidth = 104;
// The picture not in use is only dimmed (7.3.152: both pictures are always the
// same size; it was also shrunk to 0.9 before).
static const CGFloat kUnselectedScale = 1.0;
static const CGFloat kUnselectedAlpha = 0.6;
// At the avatar button our item is at least this much bigger than the picture, every side.
static const CGFloat kAvatarGlassPad = 4.0;
static const CGFloat kFilterHeight = 44;

// The A | B switch (7.3.151, second look): A's picture on the left, B's on the
// right (B's with its colour ring), a glass highlight behind the one in use
// that springs to the other on a tap, as the composer's account switch does.
// No text; each side is a 52x44 button.
static NSString* gBadgeColorSource = @"-";
static const NSInteger kBadgeOursTag = 0x4E464B;  // "NFK": a badge of ours (never read as X's)

// The badges' colour: the app's theme colour, from the helper the rest of the
// tweak uses (CurrentAccentColor(), HookHelpers.m: the tweak's own pick, a
// custom colour, or X's colour option), which is also what Theme.x feeds X's
// palette and so X's tab bar badge. With no theme picked at all, the key
// window's tint.
static UIColor* UNBadgeColor(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    UIColor* color = nil;
    if ([defaults objectForKey:@"bh_color_theme_selectedColor"] || [defaults objectForKey:@"T1ColorSettingsPrimaryColorOptionKey"]) {
        @try {
            color = CurrentAccentColor();
            gBadgeColorSource = @"theme (CurrentAccentColor)";
        } @catch (__unused NSException* exception) {
            color = nil;
        }
    }
    if (!color) {
        color = UNKeyWindow().tintColor;
        gBadgeColorSource = color ? @"key window tint" : @"system blue";
    }
    return color ?: [UIColor systemBlueColor];
}

// White or black, whichever reads on that colour (relative luminance).
static UIColor* UNInkOn(UIColor* color) {
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    UIColor* resolved = [color resolvedColorWithTraitCollection:UITraitCollection.currentTraitCollection];
    if (![resolved getRed:&red green:&green blue:&blue alpha:&alpha]) return [UIColor whiteColor];
    CGFloat (^linear)(CGFloat) = ^CGFloat(CGFloat channel) {
        return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);
    };
    CGFloat luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue);
    return luminance > 0.5 ? [UIColor blackColor] : [UIColor whiteColor];
}

// MARK: - The badge itself: X's own
//
// X's badge is TFNBadgeView (XServiceLibraries dump, 12.44: -initWithFrame:,
// count, overflowLimit, badgeColor, textColor, font, minimumBadgeHeight,
// borderWidth, borderColor, layoutStyle, hideWhenNotInUse, -sizeThatFits:), a
// plain view. Ours are instances of that class, so the number, its cap and
// the shape are X's own code. Each update they are set up from a TFNBadgeView
// found in the tab bar area of the key window (the notifications icon's badge
// is one, when X draws it with this class), so colour, font and border are
// what is on screen there; the last style read is kept. With none to read,
// the theme colour above is used. Only when the class is missing is a pill of
// our own drawn.

static NSDictionary<NSString*, id>* gXBadgeStyle;  // read off the tab bar's badge
static CFAbsoluteTime gXBadgeStyleAt;
static NSString* gBadgeStylePath = @"-";

static double UNDouble(id object, NSString* name, double fallback) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return fallback;
    @try {
        const char* type = [object methodSignatureForSelector:selector].methodReturnType;
        if (type[0] == 'd') return ((double (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
    }
    return fallback;
}

static void UNSetObject(id object, NSString* name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (object && value && [object respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static void UNSetDouble(id object, NSString* name, double value) {
    SEL selector = NSSelectorFromString(name);
    if (object && [object respondsToSelector:selector]) ((void (*)(id, SEL, double))objc_msgSend)(object, selector, value);
}

// The style of a TFNBadgeView in the tab bar area, at most every 5s.
static void UNMeasureTabBadge(void) {
    if (CFAbsoluteTimeGetCurrent() - gXBadgeStyleAt < 5) return;
    gXBadgeStyleAt = CFAbsoluteTimeGetCurrent();
    Class badgeClass = objc_getClass("TFNBadgeView");
    UIWindow* window = UNKeyWindow();
    if (!badgeClass || !window) return;
    CGFloat bottomEdge = CGRectGetHeight(window.bounds) - 160;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    UIView* found = nil;
    while (queue.count > 0 && visited < 6000 && !found) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view.tag == kBadgeOursTag) continue;
        if ([view isKindOfClass:badgeClass] && view.window &&
            CGRectGetMinY([window convertRect:view.bounds fromView:view]) > bottomEdge) {
            found = view;
            break;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    if (!found) return;
    NSMutableDictionary<NSString*, id>* style = [NSMutableDictionary dictionary];
    for (NSString* name in @[ @"badgeColor", @"textColor", @"font", @"overflowLimit", @"borderColor" ]) {
        id value = UNGetter(found, name);
        if (value) style[name] = value;
    }
    style[@"minimumBadgeHeight"] = @(UNDouble(found, @"minimumBadgeHeight", 0));
    style[@"borderWidth"] = @(UNDouble(found, @"borderWidth", 0));
    style[@"layoutStyle"] = @(UNNumber(found, @"layoutStyle"));
    gXBadgeStyle = style;
}

// An unread-notifications badge for an account's picture: X's TFNBadgeView,
// or a pill of our own when that class is not there. Hidden until it has a count.
static UIView* UNMakeBadge(void) {
    Class badgeClass = objc_getClass("TFNBadgeView");
    UIView* made = nil;
    if (badgeClass && [badgeClass instancesRespondToSelector:@selector(initWithFrame:)] &&
        [badgeClass instancesRespondToSelector:NSSelectorFromString(@"setCount:")]) {
        @try {
            made = [[badgeClass alloc] initWithFrame:CGRectMake(0, 0, 16, 16)];
        } @catch (__unused NSException* exception) {
            made = nil;
        }
        if (![made isKindOfClass:[UIView class]]) made = nil;
    }
    if (!made) {
        UILabel* pill = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 16, 16)];
        pill.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
        pill.textAlignment = NSTextAlignmentCenter;
        pill.layer.cornerRadius = 8;
        pill.clipsToBounds = YES;
        made = pill;
    }
    made.tag = kBadgeOursTag;
    made.userInteractionEnabled = NO;
    made.isAccessibilityElement = NO;
    made.hidden = YES;
    return made;
}

// `rightEdge`, `top`: where the badge's top right corner goes in its superview.
static void UNSetBadge(UIView* badge, NSInteger count, CGFloat rightEdge, CGFloat top) {
    if (!badge) return;
    if (count <= 0) {
        if (!badge.hidden) badge.hidden = YES;
        return;
    }
    Class badgeClass = objc_getClass("TFNBadgeView");
    if (badgeClass && [badge isKindOfClass:badgeClass]) {
        UNMeasureTabBadge();
        NSDictionary<NSString*, id>* style = gXBadgeStyle;
        if (style) {
            gBadgeStylePath = @"X's class TFNBadgeView, measured from tab bar";
            UNSetObject(badge, @"setBadgeColor:", style[@"badgeColor"]);
            UNSetObject(badge, @"setTextColor:", style[@"textColor"]);
            UNSetObject(badge, @"setFont:", style[@"font"]);
            UNSetObject(badge, @"setOverflowLimit:", style[@"overflowLimit"]);
            UNSetObject(badge, @"setBorderColor:", style[@"borderColor"]);
            UNSetDouble(badge, @"setMinimumBadgeHeight:", [style[@"minimumBadgeHeight"] doubleValue]);
            UNSetDouble(badge, @"setBorderWidth:", [style[@"borderWidth"] doubleValue]);
            SEL layoutStyle = NSSelectorFromString(@"setLayoutStyle:");
            if ([badge respondsToSelector:layoutStyle]) {
                ((void (*)(id, SEL, long long))objc_msgSend)(badge, layoutStyle, [style[@"layoutStyle"] longLongValue]);
            }
        } else {
            // No badge of X's on screen to read: X's class in the theme colour.
            gBadgeStylePath = @"X's class TFNBadgeView, theme fallback";
            UIColor* fill = UNBadgeColor();
            UNSetObject(badge, @"setBadgeColor:", fill);
            UNSetObject(badge, @"setTextColor:", UNInkOn(fill));
        }
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(badge, NSSelectorFromString(@"setCount:"), (NSUInteger)count);
        CGSize size = [badge sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        if (!(size.width >= 4 && size.width < 200 && size.height >= 4 && size.height < 200)) size = CGSizeMake(16, 16);
        // Its own size; scaled down, in proportion, only as far as the 36pt item needs.
        CGFloat scale = MIN(1.0, MIN(18.0 / size.height, 30.0 / size.width));
        badge.transform = CGAffineTransformIdentity;
        badge.bounds = CGRectMake(0, 0, size.width, size.height);
        badge.center = CGPointMake(rightEdge - size.width * scale / 2, top + size.height * scale / 2);
        badge.transform = CGAffineTransformMakeScale(scale, scale);
        if (badge.hidden) badge.hidden = NO;
        return;
    }
    if (![badge isKindOfClass:[UILabel class]]) return;
    gBadgeStylePath = @"theme fallback (own pill, TFNBadgeView not there)";
    UILabel* pill = (UILabel*)badge;
    NSString* text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    if (![pill.text isEqualToString:text]) pill.text = text;
    UIColor* fill = UNBadgeColor();
    if (![pill.backgroundColor isEqual:fill]) {
        pill.backgroundColor = fill;
        pill.textColor = UNInkOn(fill);
    }
    CGFloat width = MAX(16, ceil([text sizeWithAttributes:@{NSFontAttributeName : pill.font}].width) + 8);
    CGRect frame = CGRectMake(rightEdge - width, top, width, 16);
    if (!CGRectEqualToRect(pill.frame, frame)) pill.frame = frame;
    if (pill.hidden) pill.hidden = NO;
}

static void UNSwitchTo(BOOL toB, NSString* from);

@interface NFBNotifFilterView : UIView
- (void)setCountA:(NSInteger)countA countB:(NSInteger)countB;
- (void)refresh;
- (void)place;
- (void)tapped:(UIButton*)button;
@end

@implementation NFBNotifFilterView {
    UIVisualEffectView* _highlight;
    NSArray<UIButton*>* _sides;
    NSArray<UIImageView*>* _pictures;
    NSArray<UIView*>* _badges;
}

- (void)setCountA:(NSInteger)countA countB:(NSInteger)countB {
    UNSetBadge(_badges[0], countA, kFilterWidth / 2 - 4, 2);
    UNSetBadge(_badges[1], countB, kFilterWidth / 2 - 4, 2);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:CGRectMake(0, 0, kFilterWidth, kFilterHeight)];
    if (self) {
        self.tag = kFilterTag;
        _highlight = [[UIVisualEffectView alloc] initWithEffect:UNHighlightEffect()];
        _highlight.userInteractionEnabled = NO;
        _highlight.clipsToBounds = YES;
        _highlight.bounds = CGRectMake(0, 0, 38, 38);
        _highlight.layer.cornerRadius = 19;
        if ([_highlight.effect isKindOfClass:[UIBlurEffect class]]) {
            // No glass: a tinted capsule over the blur.
            _highlight.contentView.backgroundColor = [UIColor tertiarySystemFillColor];
        }
        [self addSubview:_highlight];
        NSMutableArray<UIButton*>* sides = [NSMutableArray array];
        NSMutableArray<UIImageView*>* pictures = [NSMutableArray array];
        for (NSInteger i = 0; i < 2; i++) {
            UIButton* side = [UIButton buttonWithType:UIButtonTypeCustom];
            side.tag = i + 1;
            side.frame = CGRectMake(kFilterWidth / 2 * i, 0, kFilterWidth / 2, kFilterHeight);
            [side addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            UIImageView* picture = [[UIImageView alloc] initWithFrame:CGRectMake((kFilterWidth / 2 - 28) / 2, (kFilterHeight - 28) / 2, 28, 28)];
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
        NSMutableArray<UIView*>* badges = [NSMutableArray array];
        for (UIButton* side in sides) {
            UIView* badge = UNMakeBadge();
            [side addSubview:badge];
            [badges addObject:badge];
        }
        _badges = badges;
        [self refresh];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kFilterWidth, kFilterHeight);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(kFilterWidth, kFilterHeight);
}

// Where the highlight sits and which picture is the one in use.
- (void)place {
    BOOL onB = UNFilterIsB();
    _highlight.center = CGPointMake(kFilterWidth / 4 * (onB ? 3 : 1), kFilterHeight / 2);
    for (NSInteger i = 0; i < 2; i++) {
        BOOL selected = (i == 1) == onB;
        _pictures[i].alpha = selected ? 1.0 : kUnselectedAlpha;
        _pictures[i].transform = selected ? CGAffineTransformIdentity
                                          : CGAffineTransformMakeScale(kUnselectedScale, kUnselectedScale);
        _sides[i].accessibilityTraits = selected ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
    }
}

- (void)refresh {
    id a = UNCurrentAccount();
    id b = UNBAccount();
    UIColor* bColor = NFBUnifiedBColor();
    _pictures[0].image = UNAccountPicture(a, @"A", [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1]);
    _pictures[1].image = UNAccountPicture(b, @"B", bColor);
    _pictures[1].layer.borderWidth = 1.5;
    _pictures[1].layer.borderColor = bColor.CGColor;
    _sides[0].accessibilityLabel = [NSString stringWithFormat:@"%@ 알림", UNHandle(a) ?: @"A"];
    _sides[1].accessibilityLabel = [NSString stringWithFormat:@"%@ 알림", UNHandle(b) ?: @"B"];
    [self place];
}

- (void)tapped:(UIButton*)button {
    UNSwitchTo(!UNFilterIsB(), button.tag == 2 ? @"B side" : @"A side");
}

@end

// MARK: - The switch at the avatar button (7.3.151, third place)
//
// The notifications tab's own avatar button (X 12.44:
// _TtC11TwitterDash26TabRootAvatarBarButtonItem, a UIBarButtonItem in the tab
// root's navigationItem.leftBarButtonItems) stays X's and is A's side. B's
// picture is a bar button item of ours put right after it, so nothing of X's
// is moved or resized and B's picture has real bounds of its own. The glass
// highlight is one view behind each picture (X's avatar container gets a
// non-interactive one at the back); on a switch one fades and shrinks towards
// the other while the other grows. A tap anywhere on the pair, either picture,
// toggles the list between A and B; on this one button, while unified is
// active, X's own tap (-didTapAvatar, the account list) is replaced by that.
// X's long press and the swipe that opens the sidebar are left alone.

static const NSInteger kAvatarHighlightTag = 0x4E4649;  // "NFI", in X's avatar container
static const void* kUNHidBadgeKey = &kUNHidBadgeKey;    // on X's own badge view while ours is shown
static UIBarButtonItem* gBBarItem;                      // ours, next to X's avatar item
static __weak UIBarButtonItem* gAAvatarItem;            // X's, of the notifications tab only
static __weak UIViewController* gAvatarHolder;          // whose navigationItem holds both
static BOOL gAvatarBarFailed;
static __weak UIView* gBSideBadge;  // B's badge, in our bar item
static __weak UIView* gASideBadge;  // A's badge, in X's avatar container

@interface NFBNotifAvatarTarget : NSObject
+ (instancetype)shared;
- (void)tappedB:(UIButton*)button;
@end

// X's avatar picture inside its button (DashAvatarImageView : TUIAvatarImageView),
// however deep it sits.
static UIView* UNAvatarInDepth(UIView* view, NSInteger depth) {
    Class avatarClass = objc_getClass("TUIAvatarImageView");
    if (!avatarClass || depth > 4) return nil;
    for (UIView* sub in view.subviews) {
        if ([sub isKindOfClass:avatarClass]) return sub;
        UIView* found = UNAvatarInDepth(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIView* UNAvatarIn(UIView* container) {
    return UNAvatarInDepth(container, 0);
}

// Where X's avatar picture is drawn, in its button's coordinates (a scale on
// it counts); CGRectNull when it cannot be read.
static CGRect UNAvatarRectIn(UIView* container) {
    UIView* avatar = UNAvatarIn(container);
    if (!avatar) return CGRectNull;
    CGRect rect = [avatar convertRect:avatar.bounds toView:container];
    CGFloat size = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect));
    if (size < 16 || size > 64) return CGRectNull;
    return rect;
}

// X's avatar button view of the notifications tab, only if it is that class.
static UIView* UNAvatarContainer(void) {
    UIBarButtonItem* item = gAAvatarItem;
    UIView* container = item.customView;
    return [NSStringFromClass([container class]) containsString:@"TabRootAvatarContainerView"] ? container : nil;
}

// Which picture is the one in use. Both keep their size and their glass
// circle; the one not being looked at is only dimmed.
static void UNApplyAvatarState(void) {
    UIBarButtonItem* ours = gBBarItem;
    if (!ours) return;
    BOOL onB = UNFilterIsB();
    UIView* side = ours.customView;
    UIView* bPicture = [side viewWithTag:2];
    bPicture.alpha = onB ? 1.0 : kUnselectedAlpha;
    side.accessibilityTraits = onB ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
    // X's avatar keeps its frame; only dimmed while B is the one in use.
    UNAvatarIn(UNAvatarContainer()).alpha = onB ? kUnselectedAlpha : 1.0;
}

static CGFloat gBPictureSize = 28;
static NSLayoutConstraint* gBSideWidth;
static NSLayoutConstraint* gBSideHeight;

// 7.3.152: B's picture takes exactly the size X's own A picture is drawn at
// in that bar (28 until it can be read), and our item takes the size of X's
// avatar button, so X's bar (XNavigation's LiquidNavigationBarItemGroupView,
// one glass platter per item) gives both the same glass circle, a little
// bigger than the pictures. No glass of ours is put there any more.
static void UNSizeBPicture(void) {
    UIBarButtonItem* ours = gBBarItem;
    UIView* side = ours.customView;
    UIView* picture = [side viewWithTag:2];
    if (!picture) return;
    UIView* container = UNAvatarContainer();
    CGRect aRect = UNAvatarRectIn(container);
    CGFloat size = CGRectIsNull(aRect) ? 28 : round(MIN(CGRectGetWidth(aRect), CGRectGetHeight(aRect)) * 2) / 2;
    gBPictureSize = size;
    CGFloat box = size + 2 * kAvatarGlassPad;
    CGFloat boxWidth = MIN(MAX(box, CGRectGetWidth(container.bounds)), 64);
    CGFloat boxHeight = MIN(MAX(box, CGRectGetHeight(container.bounds)), 64);
    if (gBSideWidth.constant != boxWidth) gBSideWidth.constant = boxWidth;
    if (gBSideHeight.constant != boxHeight) gBSideHeight.constant = boxHeight;
    if (!side.superview) side.frame = CGRectMake(0, 0, boxWidth, boxHeight);
    if (CGRectGetWidth(picture.bounds) != size) picture.bounds = CGRectMake(0, 0, size, size);
    CGPoint middle = CGPointMake(CGRectGetMidX(side.bounds), CGRectGetMidY(side.bounds));
    if (!CGPointEqualToPoint(picture.center, middle)) picture.center = middle;
    if (picture.layer.cornerRadius != size / 2) picture.layer.cornerRadius = size / 2;
}

static void UNRemoveAvatarSwitch(void) {
    UIBarButtonItem* ours = gBBarItem;
    UIViewController* holder = gAvatarHolder;
    UIView* container = UNAvatarContainer();
    gBSideWidth = nil;
    gBSideHeight = nil;
    if (ours && holder) {
        void (^drop)(void) = ^{
            NSMutableArray<UIBarButtonItem*>* items = [holder.navigationItem.leftBarButtonItems mutableCopy];
            if ([items containsObject:ours]) {
                [items removeObject:ours];
                holder.navigationItem.leftBarButtonItems = items;
            }
        };
        UIView* side = ours.customView;
        if (side.window) {
            side.userInteractionEnabled = NO;
            [UIView animateWithDuration:0.2
                             animations:^{
                                 side.alpha = 0.0;
                             }
                             completion:^(__unused BOOL finished) {
                                 drop();
                             }];
        } else {
            drop();
        }
    }
    for (UIView* sub in [container.subviews copy]) {
        if (sub.tag == kAvatarHighlightTag || sub.tag == kBadgeOursTag) {
            [sub removeFromSuperview];
        } else if (objc_getAssociatedObject(sub, kUNHidBadgeKey)) {
            // X's own badge, as X left it (only our alpha is undone).
            sub.alpha = 1.0;
            objc_setAssociatedObject(sub, kUNHidBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    UIView* avatar = UNAvatarIn(container);
    if (avatar && avatar.alpha < 1.0) {
        [UIView animateWithDuration:0.25
                         animations:^{
                             avatar.alpha = 1.0;
                         }];
    }
    gBBarItem = nil;
    gAAvatarItem = nil;
    gAvatarHolder = nil;
}

// X's avatar bar item of the notifications tab: in the leftBarButtonItems of
// A's notifications screen or of the root of its navigation stack, and only
// when that root is (or holds) A's notifications screen. nil when it cannot
// be told (then no control goes there).
static UIBarButtonItem* UNFindAvatarItem(UIViewController* parent, UIViewController** outHolder) {
    Class itemClass = objc_getClass("_TtC11TwitterDash26TabRootAvatarBarButtonItem");
    UIViewController* root = parent.navigationController.viewControllers.firstObject;
    if (!itemClass || !root || !UNIsInside(parent, root)) return nil;
    for (UIViewController* holder in @[ parent, root ]) {
        for (UIBarButtonItem* item in holder.navigationItem.leftBarButtonItems) {
            if ([item isKindOfClass:itemClass]) {
                if (outHolder) *outHolder = holder;
                return item;
            }
        }
    }
    return nil;
}

static BOOL UNInstallAvatarSwitch(UIViewController* parent) {
    UIViewController* holder = nil;
    UIBarButtonItem* avatarItem = UNFindAvatarItem(parent, &holder);
    if (!avatarItem || !holder) return NO;
    if (gBBarItem && (gAvatarHolder != holder || gAAvatarItem != avatarItem)) UNRemoveAvatarSwitch();
    UIBarButtonItem* ours = gBBarItem;
    if (!ours) {
        UIButton* side = [UIButton buttonWithType:UIButtonTypeCustom];
        side.frame = CGRectMake(0, 0, 36, 36);
        gBSideWidth = [side.widthAnchor constraintEqualToConstant:36];
        gBSideHeight = [side.heightAnchor constraintEqualToConstant:36];
        gBSideWidth.active = YES;
        gBSideHeight.active = YES;
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
        UIView* badge = UNMakeBadge();
        [side addSubview:badge];
        gBSideBadge = badge;
        [side addTarget:[NFBNotifAvatarTarget shared] action:@selector(tappedB:) forControlEvents:UIControlEventTouchUpInside];
        ours = [[UIBarButtonItem alloc] initWithCustomView:side];
        gBBarItem = ours;
        side.alpha = 0.0;
        [UIView animateWithDuration:0.2
                         animations:^{
                             side.alpha = 1.0;
                         }];
    }
    UINavigationItem* item = holder.navigationItem;
    if (![item.leftBarButtonItems containsObject:ours]) {
        NSMutableArray<UIBarButtonItem*>* items = [item.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
        NSUInteger at = [items indexOfObjectIdenticalTo:avatarItem];
        [items insertObject:ours atIndex:at == NSNotFound ? items.count : at + 1];
        item.leftBarButtonItems = items;
    }
    gAAvatarItem = avatarItem;
    gAvatarHolder = holder;
    UIView* side = ours.customView;
    UIImageView* picture = (UIImageView*)[side viewWithTag:2];
    id b = UNBAccount();
    UIColor* bColor = NFBUnifiedBColor();
    picture.image = UNAccountPicture(b, @"B", bColor);
    picture.layer.borderColor = bColor.CGColor;
    side.accessibilityLabel = [NSString stringWithFormat:@"%@ 알림", UNHandle(b) ?: @"B"];
    UNSizeBPicture();
    UNApplyAvatarState();
    return YES;
}

static void UNRefreshFilter(void) {
    UIView* view = gFilterView;
    if ([view isKindOfClass:[NFBNotifFilterView class]]) [(NFBNotifFilterView*)view refresh];
    UNApplyAvatarState();
    UNUpdateBadgesSoon();
}

// The one way the list is switched, whichever control was tapped.
static void UNSwitchTo(BOOL toB, NSString* from) {
    if (toB == UNFilterIsB()) return;
    [[NSUserDefaults standardUserDefaults] setObject:toB ? @"b" : @"a" forKey:kNotifFilterKey];
    UNLog([NSString stringWithFormat:@"switch: %@ (tap on %@)", toB ? @"B" : @"A", from]);
    [[UISelectionFeedbackGenerator new] selectionChanged];
    // The highlight goes over to the chosen picture.
    [UIView animateWithDuration:0.55
                          delay:0
         usingSpringWithDamping:0.68
          initialSpringVelocity:0.6
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         UIView* view = gFilterView;
                         if ([view isKindOfClass:[NFBNotifFilterView class]]) [(NFBNotifFilterView*)view place];
                         UNApplyAvatarState();
                     }
                     completion:nil];
    // The list follows on the next turn, so the spring starts at once.
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UNSyncLive(gANotifController);
            UNEvaluateSeen();
        } @catch (NSException* exception) {
            UNLog([NSString stringWithFormat:@"switch threw %@", exception.name]);
        }
        UNRefreshFilter();
    });
}

@implementation NFBNotifAvatarTarget

+ (instancetype)shared {
    static NFBNotifAvatarTarget* target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        target = [NFBNotifAvatarTarget new];
    });
    return target;
}

- (void)tappedB:(__unused UIButton*)button {
    if (!UNActive()) return;
    UNSwitchTo(!UNFilterIsB(), @"B side");
}

@end

// X's avatar button was tapped. YES (and the list toggles instead of X's
// account list) only for the notifications tab's own button, the one our item
// sits next to, while unified is active; every other avatar button, and this
// one at any other time, keeps X's own tap.
static BOOL UNAvatarTapToggles(id item) {
    if (!gBBarItem || !item || item != gAAvatarItem) return NO;
    UIViewController* holder = gAvatarHolder;
    if (!holder || ![holder.navigationItem.leftBarButtonItems containsObject:gBBarItem]) return NO;
    if (!UNActive()) return NO;
    UNSwitchTo(!UNFilterIsB(), @"X avatar");
    return YES;
}

static const void* kUNSavedTitleViewKey = &kUNSavedTitleViewKey;
static __weak UIViewController* gFilterParent;

// Puts back the title view X had before the switch took its place (nil when
// X had none, so X's own title shows again). X's `title` is never changed here.
static void UNRestoreTitle(UIViewController* parent) {
    if (!parent) return;
    UINavigationItem* item = parent.navigationItem;
    id saved = objc_getAssociatedObject(parent, kUNSavedTitleViewKey);
    if (item.titleView && item.titleView.tag == kFilterTag) {
        item.titleView = [saved isKindOfClass:[UIView class]] ? (UIView*)saved : nil;
    }
    objc_setAssociatedObject(parent, kUNSavedTitleViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void UNRemoveFilter(UIViewController* parent) {
    UIView* view = gFilterView;
    UIViewController* holder = gFilterParent;
    UNRestoreTitle(parent);
    if (holder != parent) UNRestoreTitle(holder);
    [view removeFromSuperview];
    gFilterView = nil;
    gFilterParent = nil;
    gFilterPlace = @"not installed";
}

static BOOL gFilterTitleFailed;

// The fallback place: centred at the top of the list area.
static void UNFloatFilter(UIViewController* parent) {
    UIView* current = gFilterView;
    NFBNotifFilterView* filter = [current isKindOfClass:[NFBNotifFilterView class]] ? (NFBNotifFilterView*)current : nil;
    UNRestoreTitle(parent);
    [filter removeFromSuperview];
    if (!filter) filter = [[NFBNotifFilterView alloc] initWithFrame:CGRectZero];
    filter.backgroundColor = [UIColor secondarySystemBackgroundColor];
    filter.layer.cornerRadius = kFilterHeight / 2;
    filter.frame = CGRectMake((CGRectGetWidth(parent.view.bounds) - kFilterWidth) / 2, parent.view.safeAreaInsets.top + 2, kFilterWidth,
                              kFilterHeight);
    filter.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [parent.view addSubview:filter];
    gFilterView = filter;
    gFilterParent = parent;
    gFilterPlace = @"top of list (the navigation bar did not show a title view)";
    [filter refresh];
    UNLayoutLive();
}

// The switch takes the place of the title ("알림") in the navigation bar of A's
// notifications screen while unified is active; what X had there is kept and
// put back by UNRestoreTitle.
static void UNInstallFilter(UIViewController* parent) {
    if (!parent || !parent.isViewLoaded) return;
    UINavigationItem* item = parent.navigationItem;
    if (item.titleView && item.titleView.tag == kFilterTag) {
        gFilterView = item.titleView;
        gFilterParent = parent;
        UNRefreshFilter();
        return;
    }
    UIView* existing = gFilterView;
    if (existing && existing.superview == parent.view) {
        UNRefreshFilter();
        return;
    }
    if (existing || gFilterParent) UNRemoveFilter(gFilterParent);
    if (gFilterTitleFailed) {
        UNFloatFilter(parent);
        return;
    }
    NFBNotifFilterView* filter = [[NFBNotifFilterView alloc] initWithFrame:CGRectZero];
    objc_setAssociatedObject(parent, kUNSavedTitleViewKey, item.titleView ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    item.titleView = filter;
    gFilterView = filter;
    gFilterParent = parent;
    gFilterPlace = @"title view (fallback)";
    UNLog([NSString stringWithFormat:@"switch placed as the title view (X had title \"%@\", title view %@)", item.title ?: @"",
                                     NSStringFromClass([objc_getAssociatedObject(parent, kUNSavedTitleViewKey) class])]);
    __weak UIViewController* weakParent = parent;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController* strongParent = weakParent;
        UIView* shown = gFilterView;
        if (!strongParent || !strongParent.view.window || !gAVisible || shown.window || !UNActive()) return;
        // X's bar did not show the title view (or dropped it): X's title goes
        // back and the switch sits at the top of the list instead.
        gFilterTitleFailed = YES;
        UNLog(@"switch not shown as the title view; placed at the top of the list");
        UNFloatFilter(strongParent);
    });
}

// MARK: - Unread badges on the two pictures

static NSInteger gBadgeA;
static NSInteger gBadgeB;
static NSString* gBadgeASource = @"-";
static NSString* gBadgeBSource = @"-";
static NSString* gXBadgeNote = @"-";

// Notifications only, never DMs; no request is made. A (the account in use):
// the tab bar's own number as the dock reads it, else the dock's saved one.
// B: 0 once B's rows were seen here, else the dock's saved number for B.
static void UNReadBadgeCounts(void) {
    NSString* aID = UNAccountID(UNCurrentAccount());
    NSInteger live = -1;
    @try {
        live = NFBTabNotificationCount(UNKeyWindow());
    } @catch (__unused NSException* exception) {
    }
    NSNumber* savedA = UNDockStored(aID);
    if (live >= 0) {
        gBadgeA = live;
        gBadgeASource = @"tab bar";
    } else {
        gBadgeA = savedA ? savedA.integerValue : 0;
        gBadgeASource = savedA ? @"dock saved" : @"none";
    }
    id b = UNBAccount();
    NSNumber* savedB = UNDockStored(UNAccountID(b));
    if (b && NFBUnifiedNotificationsBadgeOverride(b) == 0) {
        gBadgeB = 0;
        gBadgeBSource = @"seen here";
    } else {
        gBadgeB = savedB ? savedB.integerValue : 0;
        gBadgeBSource = savedB ? @"dock saved" : @"none";
    }
}

// X's avatar button of the notifications tab while the pair is on it: X's own
// badge (the container's `badgeView`; found as a subview whose class name says
// Badge) is made invisible so A's picture carries one badge, ours; the dimming
// of X's avatar is kept. Only sets what differs (it runs from the button's layout).
static void UNTendAvatarContainer(UIView* container) {
    if (!container) return;
    UIView* ours = nil;
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (UIView* sub in container.subviews) {
        if (sub.tag == kBadgeOursTag) {
            ours = sub;
            continue;
        }
        if (sub.tag == kAvatarHighlightTag) continue;
        NSString* name = NSStringFromClass([sub class]);
        if ([name rangeOfString:@"Badge" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [names addObject:name];
        if (sub.alpha != 0.0) {
            sub.alpha = 0.0;
            objc_setAssociatedObject(sub, kUNHidBadgeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    gXBadgeNote = names.count ? [names componentsJoinedByString:@","] : @"none found";
    if (ours && container.subviews.lastObject != ours) [container bringSubviewToFront:ours];
    CGFloat wanted = UNFilterIsB() ? kUnselectedAlpha : 1.0;
    UIView* avatar = UNAvatarIn(container);
    if (avatar && avatar.alpha != wanted) avatar.alpha = wanted;
}

static void UNUpdateBadges(void) {
    UIBarButtonItem* ours = gBBarItem;
    UIView* filter = gFilterView;
    if (!ours && !filter) return;
    if (!UNActive()) return;
    UNReadBadgeCounts();
    if (ours) {
        UIView* side = ours.customView;
        UNSetBadge(gBSideBadge, gBadgeB, CGRectGetWidth(side.bounds), 0);
        UIView* container = UNAvatarContainer();
        if (container) {
            UIView* badge = gASideBadge;
            if (badge.superview != container) {
                [badge removeFromSuperview];
                badge = UNMakeBadge();
                [container addSubview:badge];
                gASideBadge = badge;
            }
            UNSetBadge(badge, gBadgeA, CGRectGetWidth(container.bounds), 0);
            UNTendAvatarContainer(container);
        }
    }
    if ([filter isKindOfClass:[NFBNotifFilterView class]]) [(NFBNotifFilterView*)filter setCountA:gBadgeA countB:gBadgeB];
}

static BOOL gBadgeUpdateQueued;

// Several changes in a row (the defaults notification comes in bursts) are answered once.
static void UNUpdateBadgesSoon(void) {
    if (gBadgeUpdateQueued) return;
    gBadgeUpdateQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gBadgeUpdateQueued = NO;
        @try {
            UNUpdateBadges();
        } @catch (__unused NSException* exception) {
        }
    });
}

// For UnifiedHomeSign.x, which hooks the avatar buttons' layoutSubviews: the
// notifications tab's button was laid out (X may have put its badge back).
void NFBUnifiedNotificationsAvatarLaidOut(UIView* container) {
    if (!gBBarItem || !container || container != UNAvatarContainer()) return;
    UNSizeBPicture();
    UNTendAvatarContainer(container);
}

// Where the switch goes: at the notifications tab's avatar button; if that
// button cannot be told (or our item is not in a window after 1s), the title
// place; if the bar shows no title view either, the top of the list.
static void UNInstallSwitch(UIViewController* parent) {
    if (!parent || !parent.isViewLoaded) return;
    BOOL placed = NO;
    @try {
        placed = !gAvatarBarFailed && UNInstallAvatarSwitch(parent);
    } @catch (NSException* exception) {
        UNLog([NSString stringWithFormat:@"avatar switch threw %@", exception.name]);
        UNRemoveAvatarSwitch();
        gAvatarBarFailed = YES;
    }
    if (!placed) {
        if (!gAvatarBarFailed && [gFilterPlace isEqualToString:@"not installed"]) {
            UNLog(@"avatar button of the notifications tab not found; title place instead");
        }
        UNInstallFilter(parent);
        return;
    }
    if (gFilterView || gFilterParent) UNRemoveFilter(parent);
    if (![gFilterPlace hasPrefix:@"avatar bar"]) UNLog(@"switch placed at the avatar button (second bar item)");
    gFilterPlace = @"avatar bar (second bar item)";
    UNUpdateBadgesSoon();
    __weak UIViewController* weakParent = parent;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController* strongParent = weakParent;
        UIBarButtonItem* ours = gBBarItem;
        if (!strongParent || !strongParent.view.window || !gAVisible || !ours || ours.customView.window || !UNActive()) return;
        // The bar did not show our item: the title place instead.
        gAvatarBarFailed = YES;
        UNLog(@"B's picture not shown next to the avatar button; title place instead");
        UNRemoveAvatarSwitch();
        UNInstallFilter(strongParent);
    });
}

// Everything of the switch off every bar, X's own back as it was.
static void UNRemoveSwitch(UIViewController* parent) {
    UNRemoveAvatarSwitch();
    UNRemoveFilter(parent);
}

// For UnifiedTimeline.x. A view inside B's screen on screen (while it is B's):
// what is tapped there is B's.
BOOL NFBUnifiedNotificationsIsBView(UIView* view) {
    UIView* host = gBLiveHost;
    return host && view && [view isDescendantOfView:host] && UNLiveValid();
}

// For UnifiedTimeline.x. A tweet of B's notifications, while B's screen is the
// one being looked at: opened or reacted to from there it is B's.
BOOL NFBUnifiedNotificationIsBStatus(long long statusID) {
    return statusID > 0 && [gBNotifStatusIDs containsObject:@(statusID)] && UNLiveValid() && UNLiveOnTop();
}

// UnifiedTimeline.x calls this once it treats NFBUnifiedNotificationsIsBView()
// as a B screen (reactions there go out as B); until then they are stopped here.
void NFBUnifiedNotificationsReactionsWired(void) {
    gReactionsWired = YES;
}

// For the dock (AccountBubbles.x): 0 when `account` is B and B's notifications
// were looked at here since the dock last saved a different number for B;
// -1 = no opinion, use the dock's own number.
NSInteger NFBUnifiedNotificationsBadgeOverride(id account) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary* seen = [defaults dictionaryForKey:kNotifSeenKey];
    NSString* accountID = UNAccountID(account);
    if (!seen || !accountID || ![seen[@"id"] isEqual:accountID]) return -1;
    NSNumber* stored = UNDockStored(accountID) ?: @(-1);
    if (![stored isEqual:seen[@"base"]]) {
        // X's list gave a new number since: that one counts again.
        [defaults removeObjectForKey:kNotifSeenKey];
        UNLog([NSString stringWithFormat:@"dock's B number is now %@; local hide ended", stored]);
        return -1;
    }
    return 0;
}

NSInteger NFBUnifiedNotificationsBadgeCountForB(void) {
    return NFBUnifiedNotificationsBadgeOverride(UNAccountForID([[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"]));
}

// What X's push router holds for an account (diagnostics only: the shape of
// -[T1PushNotificationRouter badgeCountsForUserID] is not in the dump).
static NSString* UNRouterBadgeNote(NSString* accountID) {
    @try {
        Class routerClass = objc_getClass("T1PushNotificationRouter");
        SEL shared = NSSelectorFromString(@"defaultRouter");
        if (!routerClass || ![routerClass respondsToSelector:shared]) return @"no router";
        id router = ((id (*)(id, SEL))objc_msgSend)(routerClass, shared);
        id counts = UNGetter(router, @"badgeCountsForUserID");
        if (![counts isKindOfClass:[NSDictionary class]]) return @"no dictionary";
        NSDictionary* dictionary = counts;
        id value = accountID ? (dictionary[accountID] ?: dictionary[@(accountID.longLongValue)]) : nil;
        if (!value) {
            return [NSString stringWithFormat:@"no entry (%lu keys of %@)", (unsigned long)dictionary.count,
                                              NSStringFromClass([dictionary.allKeys.firstObject class]) ?: @"-"];
        }
        NSString* text = [value description];
        if (text.length > 80) text = [[text substringToIndex:80] stringByAppendingString:@"…"];
        return [NSString stringWithFormat:@"%@ %@", NSStringFromClass([value class]), text];
    } @catch (__unused NSException* exception) {
        return @"(threw)";
    }
}

// A reaction button inside B's screen: X's own path may pick the account in
// use, so it is stopped unless UnifiedTimeline.x sends it as B.
static BOOL UNStopInlineAction(id actionsView) {
    UIView* host = gBLiveHost;
    if (!host || ![actionsView isKindOfClass:[UIView class]] || ![(UIView*)actionsView isDescendantOfView:host]) return NO;
    BOOL valid = UNLiveValid();
    if (valid && gReactionsWired) return NO;
    gReactionsBlocked++;
    NFBShowNotice(valid ? @"B 계정 알림이에요. 여기서는 반응을 막아뒀어요. 게시물을 열어서 반응해 주세요"
                        : @"계정 설정이 바뀌어서 막았어요");
    return YES;
}

// A tweet opened from B's screen: X's own code there holds B's account; if it
// passed A's anyway, B's goes in instead.
static id UNAccountForTweetScreen(id account, long long statusID, id viewModel) {
    @try {
        if (!gBLive || !UNLiveValid() || !UNLiveOnTop()) return account;
        NSString* accountID = UNAccountID(account);
        if (!accountID || ![accountID isEqualToString:UNAccountID(UNCurrentAccount())]) return account;
        BOOL known = NO;
        for (NSNumber* candidate in @[ @(statusID), @(UNNumber(viewModel, @"statusID")),
                                       @(UNNumber(UNGetter(viewModel, @"representedStatus"), @"statusID")) ]) {
            if (candidate.longLongValue > 0 && [gBNotifStatusIDs containsObject:candidate]) known = YES;
        }
        id b = UNBAccount();
        if (!known || !b) return account;
        gOpenedAsB++;
        UNLog([NSString stringWithFormat:@"tweet %lld from B's notifications: X passed A, opened as B", statusID]);
        return b;
    } @catch (__unused NSException* exception) {
        return account;
    }
}

// Unified mode is off (a single account in use, or the feature off): nothing
// of this file stays. B's screens go, the switch goes, what was learnt goes;
// X's own notifications list is all that is left. The saved switch position
// stays for the next time unified is on.
static void UNDeactivate(NSString* why) {
    BOOL had = gBLive || gBNotifController || gFilterView || gBBarItem || gANotifController;
    UNTearDown(why);
    UNRemoveLive(why);
    UNRemoveSwitch(gANotifController);
    gANotifController = nil;
    gAVisible = NO;
    gANotifSections = nil;
    gBNotifSections = nil;
    gBLiveSections = nil;
    [gBNotifStatusIDs removeAllObjects];
    gBSeenSignature = nil;
    if (had) UNLog([NSString stringWithFormat:@"unified not active: cleared (%@)", why]);
}

static BOOL gDeactivateQueued;

// Not from inside X's list update: on the next turn of the main queue.
static void UNDeactivateSoon(void) {
    if (gDeactivateQueued) return;
    gDeactivateQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gDeactivateQueued = NO;
        @try {
            if (!UNActive()) UNDeactivate(@"found inactive");
        } @catch (__unused NSException* exception) {
        }
    });
}

// Sections handed to a list on B's off-screen screen, or on A's own.
static void UNSawSections(id controller, NSArray* sections) {
    // 7.3.151: nothing of this file is in play (unified off, or the
    // notifications tab not opened yet): straight back.
    if (!gBLive && !gBNotifController && !gANotifController) return;
    if (![controller isKindOfClass:[UIViewController class]] || !sections) return;
    if (!UNActive()) {
        UNDeactivateSoon();
        return;
    }
    UIViewController* list = controller;
    if (gBLive && UNIsInside(list, gBLive)) {
        // B's screen on screen: what it lists, which tweets are B's, and
        // whether a new batch is being looked at.
        gBLiveUpdates++;
        gBLiveSections = sections;
        gBLiveListClass = NSStringFromClass([list class]);
        UNNoteBStatuses(sections);
        NSString* top = UNTopSignature(sections);
        if (top) gBLiveTop = top;
        UNEvaluateSeen();
        return;
    }
    if (gBNotifController && UNIsInside(list, gBNotifController)) {
        gBNotifArrivals++;
        gBNotifSections = sections;
        gBNotifListClass = NSStringFromClass([list class]);
        UNLog([NSString stringWithFormat:@"B sections %lu", (unsigned long)gBNotifArrivals]);
        if (gBNotifArrivals >= 2) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UNTearDown(@"two updates");
            });
        }
        return;
    }
    UIViewController* a = gANotifController;
    if (a && UNIsInside(list, a)) {
        gANotifSections = sections;
        gANotifListClass = NSStringFromClass([list class]);
    }
}

// A list's last sections, summarised now (the dump was asked for).
static NSString* UNSectionsText(NSArray* sections, NSString* listClass, NSUInteger updates, NSString* none) {
    if (!sections) return none;
    @try {
        return [NSString stringWithFormat:@"%@ (update %lu) %@%@", listClass ?: @"?", (unsigned long)updates, UNSummarise(sections),
                                          UNDatedNote(sections)];
    } @catch (NSException* exception) {
        return [NSString stringWithFormat:@"(summary threw %@)", exception.name];
    }
}

NSString* NFBUnifiedNotificationsDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    BOOL active = UNActive();
    [out appendFormat:@"active=%d B=%@ reading=%d last=%@\n", active, UNBAccount() ? @"found" : @"missing",
                      gBNotifController != nil,
                      gBNotifLast > 0 ? [NSString stringWithFormat:@"%.0fs ago", CFAbsoluteTimeGetCurrent() - gBNotifLast] : @"never"];
    // 7.3.151, step 2.
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* aID = UNAccountID(UNCurrentAccount());
    NSString* bID = [defaults stringForKey:@"kemo_unified_b_id"];
    [out appendFormat:@"merge: not interleaved (separated variant): A rows untouched, B rows inserted 0, unknown-shape skipped 0\n"];
    [out appendFormat:@"filter=%@ (saved %@) control=%@ | B on screen=%d valid=%d onTop=%d updates=%lu top=%@\n",
                      UNFilterIsB() ? @"B" : @"A", [defaults objectForKey:kNotifFilterKey] ?: @"(unset)", gFilterPlace,
                      gBLive != nil, UNLiveValid(), UNLiveOnTop(), (unsigned long)gBLiveUpdates, gBLiveTop ?: @"-"];
    NSDictionary* seen = [defaults dictionaryForKey:kNotifSeenKey];
    [out appendFormat:@"B seen: batches=%lu last top=%@ local hide=%@ | silent read: viewed calls stopped=%lu\n",
                      (unsigned long)gBSeenBatches, gBSeenSignature ?: @"-",
                      seen ? [NSString stringWithFormat:@"on for %@ (dock number then %@)", seen[@"id"], seen[@"base"]] : @"off",
                      (unsigned long)gSilentViewedStopped];
    [out appendFormat:@"tab again: %@ (toggles %lu)%c", gTabRetapNote, (unsigned long)gTabRetapToggles, 10];
    UIView* glassContainer = UNAvatarContainer();
    [out appendFormat:@"avatar pair: A rect %@ in button %@, B item %@%c", NSStringFromCGRect(UNAvatarRectIn(glassContainer)),
                      NSStringFromCGRect(glassContainer.bounds), NSStringFromCGRect(gBBarItem.customView.bounds), 10];
    [out appendFormat:@"B picture size=%.0f (X's avatar) | badge style: %@ (colour source when not measured: %@) | ", gBPictureSize, gBadgeStylePath, gBadgeColorSource];
    [out appendFormat:@"picture badges: A=%ld (%@) B=%ld (%@) | X's own badge on the avatar: %@ (made invisible while ours shows)\n",
                      (long)gBadgeA, gBadgeASource, (long)gBadgeB, gBadgeBSource, gXBadgeNote];
    if (active) {
        [out appendFormat:@"badge A: dock saved %@, push router %@\n", UNDockStored(aID) ?: @"(none)", UNRouterBadgeNote(aID)];
        [out appendFormat:@"badge B: dock saved %@, push router %@, override %ld\n", UNDockStored(bID) ?: @"(none)",
                          UNRouterBadgeNote(bID), (long)NFBUnifiedNotificationsBadgeCountForB()];
    }
    [out appendFormat:@"B tweets known=%lu opened as B here=%lu | reactions in B screen: wired=%d stopped=%lu\n",
                      (unsigned long)gBNotifStatusIDs.count, (unsigned long)gOpenedAsB, gReactionsWired,
                      (unsigned long)gReactionsBlocked];
    [out appendFormat:@"-- B (on screen) --\n%@\n", UNSectionsText(gBLiveSections, gBLiveListClass, gBLiveUpdates, @"(not shown)")];
    [out appendFormat:@"-- B (off screen) --\n%@\n-- A (on screen) --\n%@\n",
                      UNSectionsText(gBNotifSections, gBNotifListClass, gBNotifArrivals, @"(not read yet)"),
                      UNSectionsText(gANotifSections, gANotifListClass, 0, @"(not read yet)")];
    @synchronized(UNLock()) {
        [out appendFormat:@"%@\n", gNotifLog.count ? [gNotifLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

// A's list in A's notifications screen `a`, being pulled by the user right now.
static BOOL UNIsUserPull(UIViewController* list) {
    UIViewController* a = gANotifController;
    if (!a || !gAVisible || !UNIsInside(list, a) || (gBLive && UNIsInside(list, gBLive))) return NO;
    UIScrollView* scroll = list.isViewLoaded ? UNListScrollView(list.view, 0) : nil;
    return scroll && (scroll.isTracking || scroll.isDragging || scroll.isDecelerating);
}

// A list of B's off-screen (silent) screen.
static BOOL UNIsSilentList(id controller) {
    UIViewController* silent = gBNotifController;
    return silent && [controller isKindOfClass:[UIViewController class]] && UNIsInside((UIViewController*)controller, silent);
}

%hook T1NotificationsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try {
        UIViewController* controller = (UIViewController*)self;
        if (controller == gBNotifController || controller == gBLive) return;
        if (!UNActive()) {
            // 7.3.151: a single account in use: X's own screen, nothing of ours.
            UNDeactivate(@"notifications tab appeared with unified off");
            UNRemoveSwitch(controller);
            return;
        }
        if (UNGetter(controller, @"account") != UNCurrentAccount()) return;
        gANotifController = controller;
        gAVisible = YES;
        UNEnsurePair();
        UNInstallSwitch(controller);
        UNSyncLive(controller);
        UNEvaluateSeen();
        // After A's tab has settled.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                UNReadB(NO);
            } @catch (NSException* exception) {
                UNLog([NSString stringWithFormat:@"read B threw %@", exception.name]);
            }
        });
    } @catch (__unused NSException* exception) {
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if ((UIViewController*)self == gANotifController) gAVisible = NO;
}

- (void)viewDidLayoutSubviews {
    %orig;
    @try {
        if (gBLiveHost && (UIViewController*)self == gBLiveParent) UNLayoutLive();
    } @catch (__unused NSException* exception) {
    }
}

%end

%hook T1URTViewController

// The user's own pull-to-refresh on A's notifications list reads B again too
// (off screen, at most every 30s).
- (void)loadTop:(id)sender {
    %orig;
    @try {
        if (gANotifController && !gBLive && !gBNotifController && UNIsUserPull((UIViewController*)self) && UNActive()) {
            UNReadB(YES);
        }
    } @catch (__unused NSException* exception) {
    }
}

// B's screen read off screen is nobody looking at B's notifications: its
// "these rows were viewed" call (what X's seen-marking starts from) is dropped
// for that instance only. B's screen on screen and A's own keep X's.
- (void)markAsViewedHelper:(id)helper didViewCells:(id)cells {
    if (UNIsSilentList(self)) {
        gSilentViewedStopped++;
        return;
    }
    %orig;
}

%end

%hook TFNMarkAsViewedHelper

- (void)_markAsViewed {
    if (gBNotifController && UNIsSilentList(UNGetter(self, @"dataViewController"))) {
        gSilentViewedStopped++;
        return;
    }
    %orig;
}

%end

%hook TTAStatusInlineActionsView

- (void)didTapInlineActionButton:(id)button {
    if (UNStopInlineAction(self)) return;
    %orig;
}

- (void)didTapInlineActionButton:(id)button withPrompt:(id)prompt menuItem:(long long)menuItem {
    if (UNStopInlineAction(self)) return;
    %orig;
}

- (void)inlineActionButtonDidRecognizeLongPressBegan:(id)button {
    if (UNStopInlineAction(self)) return;
    %orig;
}

- (void)didTriggerAlternateActionInInlineActionButton:(id)button {
    if (UNStopInlineAction(self)) return;
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
    return %orig(UNAccountForTweetScreen(account, statusID, nil), statusID, navigationContext, scribeContext, sourceMetadata,
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
    return %orig(UNAccountForTweetScreen(account, UNNumber(viewModel, @"statusID"), viewModel), viewModel, navigationContext,
                 scribeContext, sourceMetadata, overrideMetadata, referrer, notifyEdit, quickPromote, excluded);
}

%end

%hook TFNItemsDataViewController

- (void)setSections:(NSArray*)sections restoreScrollPosition:(BOOL)restoreScrollPosition {
    %orig;
    @try {
        UNSawSections(self, sections);
    } @catch (__unused NSException* exception) {
    }
}

- (void)updateSections:(NSArray*)sections
    reconfigureItemIdentifiers:(NSArray*)identifiers
              withRowAnimation:(long long)animation
                    completion:(id)completion {
    %orig;
    @try {
        UNSawSections(self, sections);
    } @catch (__unused NSException* exception) {
    }
}

%end

// 7.3.152: the notifications tab tapped again while it is already showing.
// X 12.44 (T1Twitter dump): -[T1TabNavigationController
// handleTabSelectionIfAlreadySelected] v16@0:8. On the notifications tab's own
// navigation controller, at its root, with the A | B switch up: when the list
// on screen is at its top, the tap does what a tap on the avatar pair does (the
// list goes over to the other account); when it is scrolled down, the tap
// scrolls it to the top as X does (A's list by X's own code, B's embedded
// list here, since X's code only knows A's). Anywhere else, and with unified
// off, X's own.
static NSUInteger gTabRetapToggles;
static NSString* gTabRetapNote = @"never called";

// The list inside B's embedded screen (UNListScrollView skips that screen).
static UIScrollView* UNScrollInside(UIView* view, int depth) {
    if (!view || depth > 12 || view.hidden) return nil;
    if (([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) && view.window &&
        CGRectGetHeight(view.bounds) > 200) {
        return (UIScrollView*)view;
    }
    for (UIView* sub in view.subviews) {
        UIScrollView* found = UNScrollInside(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static BOOL UNTabRetapToggles(UINavigationController* navigation) {
    if (![NSThread isMainThread] || ![navigation isKindOfClass:[UINavigationController class]]) return NO;
    UIViewController* a = gANotifController;
    UIViewController* root = navigation.viewControllers.firstObject;
    if (!a || !root || !UNIsInside(a, root)) return NO;  // another tab
    if (!gAVisible || navigation.viewControllers.count != 1 || navigation.presentedViewController) {
        gTabRetapNote = @"notifications tab, not at its root: X's own";
        return NO;
    }
    if (!UNActive() || (!gBBarItem && !gFilterView)) {
        gTabRetapNote = @"notifications tab, no switch up: X's own";
        return NO;
    }
    BOOL onB = UNFilterIsB() && gBLiveHost && UNLiveValid();
    UIScrollView* list = onB ? UNScrollInside(gBLiveHost, 0) : UNListScrollView(a.view, 0);
    if (list) {
        CGFloat top = -list.adjustedContentInset.top;
        if (list.contentOffset.y > top + 8) {
            if (!onB) {
                gTabRetapNote = @"A's list scrolled down: X's own (to the top)";
                return NO;
            }
            [list setContentOffset:CGPointMake(list.contentOffset.x, top) animated:YES];
            gTabRetapNote = @"B's list scrolled down: to the top";
            return YES;
        }
    }
    gTabRetapToggles++;
    gTabRetapNote = list ? @"at the top: toggled" : @"list not found: toggled";
    UNSwitchTo(!UNFilterIsB(), @"notifications tab again");
    return YES;
}

%group UnifiedNotifTabRetap

%hook T1TabNavigationController

- (void)handleTabSelectionIfAlreadySelected {
    BOOL toggled = NO;
    @try {
        toggled = UNTabRetapToggles((UINavigationController*)self);
    } @catch (__unused NSException* exception) {
        toggled = NO;
    }
    if (toggled) return;
    %orig;
}

%end

%end

%group UnifiedNotifAvatarButton

// The tab roots' avatar bar button (private Swift class of TwitterDash, 12.44).
%hook _TtC11TwitterDash26TabRootAvatarBarButtonItem

- (void)didTapAvatar {
    if (UNAvatarTapToggles(self)) return;
    %orig;
}

%end

%end

%ctor {
    %init;
    // Installed only when 12.44's class and method are there; without the
    // hook the avatar button is left alone (the title place is used).
    Class avatarItem = objc_getClass("_TtC11TwitterDash26TabRootAvatarBarButtonItem");
    if (avatarItem && class_getInstanceMethod(avatarItem, NSSelectorFromString(@"didTapAvatar")) != NULL) {
        %init(UnifiedNotifAvatarButton);
    } else {
        gAvatarBarFailed = YES;
    }
    Class tabNavigation = objc_getClass("T1TabNavigationController");
    if (tabNavigation && class_getInstanceMethod(tabNavigation, NSSelectorFromString(@"handleTabSelectionIfAlreadySelected")) != NULL) {
        %init(UnifiedNotifTabRetap);
    } else {
        gTabRetapNote = @"not hooked (no such method)";
    }
    // Unified mode, the pair or the switch changed in settings (or from the
    // dock): what no longer holds is taken away. queue:nil, then main (a main
    // queue observer stalls the launch, see CLAUDE.md).
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification* note) {
                                                      static BOOL queued;
                                                      if (queued || (!gBLive && !gBNotifController && !gFilterView && !gBBarItem)) return;
                                                      if (gFilterView || gBBarItem) UNUpdateBadgesSoon();
                                                      queued = YES;
                                                      dispatch_async(dispatch_get_main_queue(), ^{
                                                          queued = NO;
                                                          @try {
                                                              if (!UNActive()) {
                                                                  UNDeactivate(@"settings changed");
                                                              } else if (gBLive && !UNLiveValid()) {
                                                                  UNRemoveLive(@"settings changed");
                                                                  UNRefreshFilter();
                                                              }
                                                          } @catch (__unused NSException* exception) {
                                                          }
                                                      });
                                                  }];
}
