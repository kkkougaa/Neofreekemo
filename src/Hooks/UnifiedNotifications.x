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

#import "HookHelpers.h"

static const NSTimeInterval kNotifEvery = 10 * 60;
static const NSTimeInterval kNotifLife = 20;

static UIViewController* gBNotifController;
static UIView* gBNotifHost;
static NSUInteger gBNotifArrivals;
static CFAbsoluteTime gBNotifLast;
static NSString* gBNotifSummary = @"(not read yet)";
static NSString* gANotifSummary = @"(not read yet)";
static __weak UIViewController* gANotifController;
static NSMutableArray<NSString*>* gNotifLog;

static void UNLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized([NSObject class]) {
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

// MARK: - B's screen off screen

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

static void UNReadB(void) {
    if (gBNotifController || !UNActive()) return;
    if (gBNotifLast > 0 && CFAbsoluteTimeGetCurrent() - gBNotifLast < kNotifEvery) return;
    id b = UNBAccount();
    Class screenClass = objc_getClass("T1NotificationsViewController");
    Class bridgeClass = objc_getClass("T1URTNotificationsInteractionsTimelineBridge");
    SEL makeScreen = NSSelectorFromString(@"initWithAccount:interactionsTimelineBridge:");
    SEL makeBridge = NSSelectorFromString(@"initWithAccount:");
    UIWindow* window = UNKeyWindow();
    if (!b || !screenClass || !bridgeClass || ![screenClass instancesRespondToSelector:makeScreen] ||
        ![bridgeClass instancesRespondToSelector:makeBridge] || !window) {
        UNLog([NSString stringWithFormat:@"cannot read B (B=%d screen=%d bridge=%d window=%d)", b != nil,
                                         screenClass != nil, bridgeClass != nil, window != nil]);
        return;
    }
    gBNotifLast = CFAbsoluteTimeGetCurrent();
    UIViewController* controller = nil;
    @try {
        id bridge = ((id (*)(id, SEL, id))objc_msgSend)([bridgeClass alloc], makeBridge, b);
        controller = ((id (*)(id, SEL, id, id))objc_msgSend)([screenClass alloc], makeScreen, b, bridge);
    } @catch (NSException* exception) {
        UNLog([NSString stringWithFormat:@"making B screen threw %@", exception.name]);
        return;
    }
    // Only B's: never read (or show) anything here under another account.
    if (![controller isKindOfClass:[UIViewController class]] ||
        ![UNAccountID(UNGetter(controller, @"account")) isEqualToString:UNAccountID(b)]) {
        UNLog(@"B screen not made, or not B's; stopped");
        return;
    }
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
    UNLog(@"B screen open off screen");
    __weak UIViewController* weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNotifLife * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakController && weakController == gBNotifController) UNTearDown(@"time");
    });
}

// Sections handed to a list on B's off-screen screen, or on A's own.
static void UNSawSections(id controller, NSArray* sections) {
    if (![controller isKindOfClass:[UIViewController class]] || !sections) return;
    UIViewController* list = controller;
    if (gBNotifController && UNIsInside(list, gBNotifController)) {
        gBNotifArrivals++;
        gBNotifSummary = [NSString stringWithFormat:@"%@ (update %lu) %@", NSStringFromClass([list class]),
                                                    (unsigned long)gBNotifArrivals, UNSummarise(sections)];
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
        gANotifSummary = [NSString stringWithFormat:@"%@ %@", NSStringFromClass([list class]), UNSummarise(sections)];
    }
}

NSString* NFBUnifiedNotificationsDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"active=%d B=%@ reading=%d last=%@\n", UNActive(), UNBAccount() ? @"found" : @"missing",
                      gBNotifController != nil,
                      gBNotifLast > 0 ? [NSString stringWithFormat:@"%.0fs ago", CFAbsoluteTimeGetCurrent() - gBNotifLast] : @"never"];
    [out appendFormat:@"-- B (off screen) --\n%@\n-- A (on screen) --\n%@\n", gBNotifSummary, gANotifSummary];
    @synchronized([NSObject class]) {
        [out appendFormat:@"%@\n", gNotifLog.count ? [gNotifLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

%hook T1NotificationsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try {
        UIViewController* controller = (UIViewController*)self;
        if (controller == gBNotifController || !UNActive()) return;
        if (UNGetter(controller, @"account") != UNCurrentAccount()) return;
        gANotifController = controller;
        // After A's tab has settled.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                UNReadB();
            } @catch (NSException* exception) {
                UNLog([NSString stringWithFormat:@"read B threw %@", exception.name]);
            }
        });
    } @catch (__unused NSException* exception) {
    }
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
