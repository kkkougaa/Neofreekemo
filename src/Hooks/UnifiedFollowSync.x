//
//  UnifiedFollowSync.x
//  NeoFreeBird
//
//  7.3.145, for the A/B unified timeline: who A and B each follow, read from
//  X's own Following list (+[T1URTFollowingTimelineViewControllerFactory
//  followingViewControllerWithAccount:userReference:shouldShowPeopleButton:
//  shouldShowTitle:]), once every 3 days per account. The list is made for that
//  account, so its requests go out as that account, the way opening one's own
//  Following list does. It sits off screen and is scrolled down one page every
//  2.5s, like someone reading it, until no new people come in. The user IDs are
//  kept in NSUserDefaults (kemo_unified_follows_<accountID>) and handed to
//  UnifiedTimeline.x, so "A follows whoever brought this tweet" is a fact, not
//  a guess from A's timeline.
//

#import "HookHelpers.h"

extern void NFBUnifiedAddKnownFollows(NSString* accountID, NSSet<NSNumber*>* userIDs);

static const NSTimeInterval kSyncEvery = 3 * 24 * 60 * 60;
static const NSTimeInterval kTickSeconds = 2.5;
static const NSUInteger kMaxTicks = 160;   // about 7 minutes per account at most
static const NSUInteger kStaleTicks = 4;   // this many pages with nobody new: done

static UIViewController* gSyncController;
static UIView* gSyncHost;
static NSString* gSyncAccountID;
static NSMutableSet<NSNumber*>* gSyncIDs;
static NSUInteger gSyncTicks, gSyncStale, gSyncLastCount;
static NSMutableArray* gSyncQueue;
static NSMutableArray<NSString*>* gSyncLog;

static void FSLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized([NSObject class]) {
        if (!gSyncLog) gSyncLog = [NSMutableArray array];
        [gSyncLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        while (gSyncLog.count > 30) [gSyncLog removeObjectAtIndex:0];
    }
}

static id FSGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static long long FSNumber(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* type = signature.methodReturnType;
    @try {
        if (type[0] == 'q' || type[0] == 'Q' || type[0] == 'l' || type[0] == 'L') {
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

static NSString* FSAccountID(id account) {
    long long userID = FSNumber(account, @"userID");
    if (userID <= 0) userID = FSNumber(FSGetter(account, @"user"), @"userID");
    return userID > 0 ? [NSString stringWithFormat:@"%lld", userID] : nil;
}

static id FSAccountForID(NSString* userID) {
    Class twitterClass = objc_getClass("TFNTwitter");
    if (!twitterClass || ![twitterClass respondsToSelector:@selector(sharedTwitter)]) return nil;
    id twitter = ((id (*)(id, SEL))objc_msgSend)(twitterClass, @selector(sharedTwitter));
    for (id account in FSGetter(twitter, @"accounts")) {
        if ([FSAccountID(account) isEqualToString:userID]) return account;
    }
    return nil;
}

static NSString* FSKey(NSString* prefix, NSString* accountID) {
    return [prefix stringByAppendingString:accountID];
}

static UIWindow* FSKeyWindow(void) {
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static UIScrollView* FSList(UIView* root) {
    __block UIScrollView* found = nil;
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if (!found && [view isKindOfClass:[UITableView class]]) found = (UIScrollView*)view;
    });
    return found;
}

static void FSNext(void);

static void FSFinish(BOOL keep) {
    UIViewController* controller = gSyncController;
    NSString* accountID = gSyncAccountID;
    if (controller) {
        @try {
            [controller beginAppearanceTransition:NO animated:NO];
            [controller.view removeFromSuperview];
            [controller endAppearanceTransition];
        } @catch (__unused NSException* exception) {
        }
    }
    [gSyncHost.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [gSyncHost removeFromSuperview];
    gSyncHost = nil;
    gSyncController = nil;
    if (keep && accountID && gSyncIDs.count) {
        NSMutableSet* ids = [gSyncIDs mutableCopy];
        [ids removeObject:@(accountID.longLongValue)];
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:[ids allObjects] forKey:FSKey(@"kemo_unified_follows_", accountID)];
        [defaults setObject:[NSDate date] forKey:FSKey(@"kemo_unified_follows_at_", accountID)];
        FSLog([NSString stringWithFormat:@"%@: kept %lu people", accountID, (unsigned long)ids.count]);
        NFBUnifiedAddKnownFollows(accountID, ids);
    } else if (accountID) {
        FSLog([NSString stringWithFormat:@"%@: nothing kept", accountID]);
    }
    gSyncAccountID = nil;
    gSyncIDs = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FSNext();
    });
}

static void FSTick(void) {
    if (!gSyncController) return;
    gSyncTicks++;
    NSUInteger count = gSyncIDs.count;
    if (count == gSyncLastCount) gSyncStale++;
    else gSyncStale = 0;
    gSyncLastCount = count;
    if ((gSyncStale >= kStaleTicks && count > 0) || gSyncTicks >= kMaxTicks ||
        (gSyncStale >= kStaleTicks * 2 && count == 0)) {
        FSLog([NSString stringWithFormat:@"%@: done after %lu pages (%lu people)", gSyncAccountID,
                                         (unsigned long)gSyncTicks, (unsigned long)count]);
        FSFinish(count > 0);
        return;
    }
    // One page further, as if scrolled by hand; X loads the next page itself.
    UIScrollView* list = FSList(gSyncController.view);
    if (list) {
        CGFloat bottom = MAX(0, list.contentSize.height - CGRectGetHeight(list.bounds));
        [list setContentOffset:CGPointMake(0, bottom) animated:NO];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTickSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FSTick();
    });
}

static void FSStart(NSString* accountID) {
    id account = FSAccountForID(accountID);
    Class factory = objc_getClass("T1URTFollowingTimelineViewControllerFactory");
    SEL make = NSSelectorFromString(@"followingViewControllerWithAccount:userReference:shouldShowPeopleButton:shouldShowTitle:");
    id reference = FSGetter(FSGetter(account, @"user"), @"userReference");
    UIWindow* window = FSKeyWindow();
    if (!account || !factory || ![factory respondsToSelector:make] || !reference || !window) {
        FSLog([NSString stringWithFormat:@"%@: cannot start (account=%d factory=%d reference=%d window=%d)", accountID,
                                         account != nil, factory && [factory respondsToSelector:make], reference != nil,
                                         window != nil]);
        FSNext();
        return;
    }
    UIViewController* controller = nil;
    @try {
        controller = ((id (*)(id, SEL, id, id, BOOL, BOOL))objc_msgSend)(factory, make, account, reference, NO, NO);
    } @catch (NSException* exception) {
        FSLog([NSString stringWithFormat:@"%@: factory threw %@", accountID, exception.name]);
    }
    if (![controller isKindOfClass:[UIViewController class]]) {
        FSLog([NSString stringWithFormat:@"%@: no list controller", accountID]);
        FSNext();
        return;
    }
    // Off screen, behind everything, untouchable.
    gSyncHost = [[UIView alloc] initWithFrame:CGRectMake(-4000, 0, CGRectGetWidth(window.bounds), CGRectGetHeight(window.bounds))];
    gSyncHost.userInteractionEnabled = NO;
    gSyncHost.clipsToBounds = YES;
    gSyncHost.accessibilityElementsHidden = YES;
    [window insertSubview:gSyncHost atIndex:0];
    gSyncController = controller;
    gSyncAccountID = accountID;
    gSyncIDs = [NSMutableSet set];
    gSyncTicks = 0;
    gSyncStale = 0;
    gSyncLastCount = 0;
    @try {
        controller.view.frame = gSyncHost.bounds;
        [controller beginAppearanceTransition:YES animated:NO];
        [gSyncHost addSubview:controller.view];
        [controller endAppearanceTransition];
    } @catch (NSException* exception) {
        FSLog([NSString stringWithFormat:@"%@: showing threw %@", accountID, exception.name]);
        FSFinish(NO);
        return;
    }
    FSLog([NSString stringWithFormat:@"%@: reading %@", accountID, NSStringFromClass([controller class])]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTickSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FSTick();
    });
}

static void FSNext(void) {
    if (gSyncController || gSyncQueue.count == 0) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        // Wait for the app to be in front again.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FSNext();
        });
        return;
    }
    NSString* accountID = gSyncQueue.firstObject;
    [gSyncQueue removeObjectAtIndex:0];
    FSStart(accountID);
}

// A and B whose lists are older than 3 days (or never read).
static void FSScheduleIfDue(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if (![[defaults objectForKey:@"kemo_unified_exp"] boolValue]) return;
    NSString* bID = [defaults stringForKey:@"kemo_unified_b_id"];
    if (bID.length == 0) return;
    NSString* aID = [defaults stringForKey:@"kemo_unified_a_id"];
    if (aID.length == 0) {
        Class hostClass = objc_getClass("T1HostViewController");
        id host = [hostClass respondsToSelector:@selector(sharedHostViewController)]
                      ? ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController))
                      : nil;
        aID = FSAccountID(FSGetter(host, @"currentAccount"));
    }
    if (!gSyncQueue) gSyncQueue = [NSMutableArray array];
    for (NSString* accountID in @[ aID ?: @"", bID ]) {
        if (accountID.length == 0 || [gSyncQueue containsObject:accountID]) continue;
        NSDate* last = [defaults objectForKey:FSKey(@"kemo_unified_follows_at_", accountID)];
        NSArray* kept = [defaults arrayForKey:FSKey(@"kemo_unified_follows_", accountID)];
        if (kept.count) NFBUnifiedAddKnownFollows(accountID, [NSSet setWithArray:kept]);
        if ([last isKindOfClass:[NSDate class]] && -[last timeIntervalSinceNow] < kSyncEvery) continue;
        [gSyncQueue addObject:accountID];
        FSLog([NSString stringWithFormat:@"%@: due (last %@)", accountID, last ?: @"never"]);
    }
    FSNext();
}

NSString* NFBUnifiedFollowSyncDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    for (NSString* key in @[ @"kemo_unified_a_id", @"kemo_unified_b_id" ]) {
        NSString* accountID = [defaults stringForKey:key];
        if (accountID.length == 0) continue;
        [out appendFormat:@"%@: %lu people, read %@\n", [key containsString:@"_a_"] ? @"A" : @"B",
                          (unsigned long)[defaults arrayForKey:FSKey(@"kemo_unified_follows_", accountID)].count,
                          [defaults objectForKey:FSKey(@"kemo_unified_follows_at_", accountID)] ?: @"never"];
    }
    [out appendFormat:@"reading now: %@ (%lu people, page %lu)\n", gSyncAccountID ?: @"-", (unsigned long)gSyncIDs.count,
                      (unsigned long)gSyncTicks];
    @synchronized([NSObject class]) {
        [out appendFormat:@"%@\n", gSyncLog.count ? [gSyncLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

// The people the off-screen list shows, as X hands it its sections.
static void FSHarvest(id controller, NSArray* sections) {
    if (!gSyncController || controller != gSyncController) return;
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) continue;
        for (id item in section) {
            id model = unwrapDataViewItem(item);
            long long userID = FSNumber(model, @"userID");
            if (userID <= 0) userID = FSNumber(FSGetter(model, @"user"), @"userID");
            if (userID > 0) [gSyncIDs addObject:@(userID)];
        }
    }
}

%hook TFNItemsDataViewController

- (void)setSections:(NSArray*)sections restoreScrollPosition:(BOOL)restoreScrollPosition {
    %orig;
    FSHarvest(self, sections);
}

- (void)updateSections:(NSArray*)sections
    reconfigureItemIdentifiers:(NSArray*)identifiers
              withRowAnimation:(long long)animation
                    completion:(id)completion {
    %orig;
    FSHarvest(self, sections);
}

%end

%ctor {
    // Well after launch, when the home tab has settled.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FSScheduleIfDue();
    });
}
