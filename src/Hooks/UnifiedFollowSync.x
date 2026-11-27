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

//  7.3.151: only while the unified mode is in use (NFBUnifiedIsActive, a saved A
//  that is the account in use, and B). Nothing is scheduled, started or
//  scrolled otherwise, and a read that is running stops and stores nothing.
//  Only user rows of the list itself count (URTTimelineUserItemViewModel,
//  outside a module), the read waits while the app is not in front, and what
//  it found replaces the stored list only when the read stalled with the app
//  in front and is not much smaller than the stored one; a first read, or one
//  under 85% of the stored list, has to be matched by a second read.
//

extern void NFBUnifiedAddKnownFollows(NSString* accountID, NSSet<NSNumber*>* userIDs);
extern BOOL NFBUnifiedIsActive(void);

static const NSTimeInterval kSyncEvery = 3 * 24 * 60 * 60;
static const NSTimeInterval kRetryEvery = 6 * 60 * 60;  // a read that stored nothing is not tried again sooner
static const NSTimeInterval kTickSeconds = 2.5;
static const NSUInteger kMaxTicks = 160;   // about 7 minutes per account at most
static const NSUInteger kStaleTicks = 8;   // this many pages in a row (app in front) with nobody new: stalled

static UIViewController* gSyncController;
static UIView* gSyncHost;
static NSString* gSyncAccountID;
static NSMutableSet<NSNumber*>* gSyncIDs;
static NSUInteger gSyncTicks, gSyncStale, gSyncLastCount;
static NSUInteger gSyncScrolls;       // scrolls to the bottom: each asks X for at most one more page
static NSUInteger gSyncUpdates;       // times X handed the list its rows
static NSUInteger gSyncInModule;      // user rows skipped because they sit in a module (suggestions)
static NSUInteger gSyncNoID;          // user rows whose user ID could not be read
static BOOL gSyncCursorSeen, gSyncCursorNow, gSyncCursorError, gSyncPaused;
static NSMutableDictionary<NSString*, NSNumber*>* gSyncOtherRows;   // other row classes seen -> how often
static NSString* gSyncRowNote;                                      // what the first rows looked like
static NSMutableArray* gSyncQueue;
static NSMutableDictionary<NSString*, NSNumber*>* gSyncCandidates;  // a read waiting for a second one to match
static NSMutableDictionary<NSString*, NSString*>* gSyncLast;        // account ID -> how its last read ended
static NSMutableSet<NSString*>* gSyncHanded;                        // stored lists already given to the timeline
static NSString* gSyncLastGate;
static BOOL gSyncSchedulePending;
static NSMutableArray<NSString*>* gSyncLog;

// 7.3.151: a lock of this file's own (was [NSObject class], shared process-wide).
static id FSLock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    return lock;
}

static void FSLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized(FSLock()) {
        if (!gSyncLog) gSyncLog = [NSMutableArray array];
        [gSyncLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        while (gSyncLog.count > 30) [gSyncLog removeObjectAtIndex:0];
    }
}

// A line about why nothing runs, once per change (it is asked often).
static void FSGateLog(NSString* line) {
    if ([gSyncLastGate isEqualToString:line]) return;
    gSyncLastGate = [line copy];
    FSLog(line);
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

static NSString* FSCurrentAccountID(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    id host = [hostClass respondsToSelector:@selector(sharedHostViewController)]
                  ? ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController))
                  : nil;
    return FSAccountID(FSGetter(host, @"currentAccount"));
}

// 7.3.151: nil while the sync may run, else why not. The unified mode has to
// be in use, with a saved A that is the account in use (never "whoever is in
// use") and a B that is another account. Main thread only.
static NSString* FSBlocked(void) {
    BOOL active = NO;
    @try {
        active = NFBUnifiedIsActive();
    } @catch (__unused NSException* exception) {
    }
    if (!active) return @"mode inactive";
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* aID = [defaults stringForKey:@"kemo_unified_a_id"];
    NSString* bID = [defaults stringForKey:@"kemo_unified_b_id"];
    if (bID.length == 0) return @"no B";
    if (aID.length == 0) return @"no saved A";
    if ([aID isEqualToString:bID]) return @"A and B are the same";
    NSString* currentID = FSCurrentAccountID();
    if (currentID.length == 0 || ![aID isEqualToString:currentID]) return @"account in use is not A";
    return nil;
}

// "A" or "B" for one of the pair's IDs, nil for any other account.
static NSString* FSRole(NSString* accountID) {
    if (accountID.length == 0) return nil;
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([accountID isEqualToString:[defaults stringForKey:@"kemo_unified_a_id"]]) return @"A";
    if ([accountID isEqualToString:[defaults stringForKey:@"kemo_unified_b_id"]]) return @"B";
    return nil;
}

static void FSNext(void);

// The read is over: take the off-screen list down, and store what was read
// only when `stalled` (no new people for kStaleTicks pages with the app in
// front and the mode in use) and the size is believable. Anything else
// (stopped, page limit, load error) leaves the stored list as it was.
static void FSFinish(NSString* why, BOOL stalled) {
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
    if (accountID) {
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        NSMutableSet* ids = gSyncIDs ? [gSyncIDs mutableCopy] : [NSMutableSet set];
        [ids removeObject:@(accountID.longLongValue)];
        NSUInteger count = ids.count;
        NSUInteger previous = [defaults arrayForKey:FSKey(@"kemo_unified_follows_", accountID)].count;
        NSString* verdict = why ?: @"stopped";
        BOOL replaced = NO;
        if (stalled && count > 0) {
            NSNumber* candidate = gSyncCandidates[accountID];
            NSUInteger first = candidate.unsignedIntegerValue;
            NSUInteger apart = first > count ? first - count : count - first;
            BOOL agrees = candidate != nil && apart <= MAX((NSUInteger)2, first / 50);
            // A first list, or one under 85% of the stored one, is not taken on
            // one read's word: a second read has to come to the same count.
            BOOL needsSecond = previous == 0 || count * 100 < previous * 85;
            if (!needsSecond || agrees) {
                [defaults setObject:[ids allObjects] forKey:FSKey(@"kemo_unified_follows_", accountID)];
                [defaults setObject:[NSDate date] forKey:FSKey(@"kemo_unified_follows_at_", accountID)];
                [gSyncCandidates removeObjectForKey:accountID];
                replaced = YES;
                if (needsSecond) {
                    verdict = [NSString stringWithFormat:@"%@, second read agreed (%lu then %lu)", verdict,
                                                         (unsigned long)first, (unsigned long)count];
                }
                if (!gSyncHanded) gSyncHanded = [NSMutableSet set];
                [gSyncHanded addObject:accountID];
                NFBUnifiedAddKnownFollows(accountID, ids);
            } else if (!candidate) {
                if (!gSyncCandidates) gSyncCandidates = [NSMutableDictionary dictionary];
                gSyncCandidates[accountID] = @(count);
                if (!gSyncQueue) gSyncQueue = [NSMutableArray array];
                if (![gSyncQueue containsObject:accountID]) [gSyncQueue addObject:accountID];
                verdict = previous == 0
                              ? [NSString stringWithFormat:@"%@, first list: waiting for a second read to agree", verdict]
                              : [NSString stringWithFormat:@"rejected: too small vs previous %lu (second read queued)",
                                                           (unsigned long)previous];
            } else {
                [gSyncCandidates removeObjectForKey:accountID];
                verdict = [NSString stringWithFormat:@"rejected: second read disagreed (%lu then %lu, previous %lu)",
                                                     (unsigned long)first, (unsigned long)count, (unsigned long)previous];
            }
        } else {
            [gSyncCandidates removeObjectForKey:accountID];
        }
        NSString* role = FSRole(accountID) ?: @"?";
        NSString* line = [NSString
            stringWithFormat:@"ended: %@ | %lu people, pages %lu, requests as %@ at most %lu (1 + %lu scrolls), stored list %@ "
                             @"(previous %lu) | rows: updates=%lu inModule=%lu noID=%lu cursor=%@ other=%@ %@",
                             verdict, (unsigned long)count, (unsigned long)gSyncTicks, role,
                             (unsigned long)(gSyncScrolls + 1), (unsigned long)gSyncScrolls,
                             replaced ? @"replaced" : @"not replaced", (unsigned long)previous,
                             (unsigned long)gSyncUpdates, (unsigned long)gSyncInModule, (unsigned long)gSyncNoID,
                             gSyncCursorError ? @"error row" : (gSyncCursorNow ? @"still there" : (gSyncCursorSeen ? @"gone" : @"never seen")),
                             gSyncOtherRows.count ? [[gSyncOtherRows description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"-",
                             gSyncRowNote ?: @""];
        if (!gSyncLast) gSyncLast = [NSMutableDictionary dictionary];
        gSyncLast[accountID] = line;
        FSLog([NSString stringWithFormat:@"%@ %@", role, line]);
    }
    gSyncAccountID = nil;
    gSyncIDs = nil;
    gSyncPaused = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FSNext();
    });
}

static void FSTick(void) {
    if (!gSyncController) return;
    // 7.3.151: the mode is asked on every page. Left (or A, B changed) in the
    // middle of a read: stop here, nothing of this read is stored and the
    // stored list stays as it was; whatever else was queued is dropped too.
    NSString* blocked = FSBlocked();
    if (!blocked && !FSRole(gSyncAccountID)) blocked = @"account is no longer A or B";
    if (blocked) {
        [gSyncQueue removeAllObjects];
        FSFinish([NSString stringWithFormat:@"stopped: %@", blocked], NO);
        return;
    }
    // 7.3.151: not in front, nothing loads: those pages are not counted as
    // "nobody new" and nothing is scrolled. Wait, and go on when it is back.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        if (!gSyncPaused) {
            gSyncPaused = YES;
            FSLog([NSString stringWithFormat:@"%@: paused (app not active) at page %lu", FSRole(gSyncAccountID),
                                             (unsigned long)gSyncTicks]);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTickSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FSTick();
        });
        return;
    }
    if (gSyncPaused) {
        gSyncPaused = NO;
        gSyncStale = 0;
        FSLog([NSString stringWithFormat:@"%@: resumed", FSRole(gSyncAccountID)]);
    }
    gSyncTicks++;
    NSUInteger count = gSyncIDs.count;
    if (count == gSyncLastCount) gSyncStale++;
    else gSyncStale = 0;
    gSyncLastCount = count;
    if (gSyncTicks >= kMaxTicks) {
        // Still growing (or never settled): not a whole list.
        FSFinish(@"stopped: page limit", NO);
        return;
    }
    if (gSyncStale >= kStaleTicks) {
        if (gSyncCursorError) FSFinish(@"stalled: load error row", NO);
        else if (count == 0) FSFinish(@"stalled: nobody read", NO);
        else FSFinish(gSyncCursorSeen && !gSyncCursorNow ? @"end of list (cursor row gone)" : @"stalled", YES);
        return;
    }
    // One page further, as if scrolled by hand; X loads the next page itself.
    UIScrollView* list = FSList(gSyncController.view);
    if (list) {
        CGFloat bottom = MAX(0, list.contentSize.height - CGRectGetHeight(list.bounds));
        [list setContentOffset:CGPointMake(0, bottom) animated:NO];
        gSyncScrolls++;
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
    gSyncScrolls = 0;
    gSyncUpdates = 0;
    gSyncInModule = 0;
    gSyncNoID = 0;
    gSyncCursorSeen = NO;
    gSyncCursorNow = NO;
    gSyncCursorError = NO;
    gSyncPaused = NO;
    gSyncOtherRows = [NSMutableDictionary dictionary];
    gSyncRowNote = nil;
    // A read that stores nothing is not tried again for kRetryEvery.
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:FSKey(@"kemo_unified_follows_try_", accountID)];
    @try {
        controller.view.frame = gSyncHost.bounds;
        [controller beginAppearanceTransition:YES animated:NO];
        [gSyncHost addSubview:controller.view];
        [controller endAppearanceTransition];
    } @catch (NSException* exception) {
        FSFinish([NSString stringWithFormat:@"stopped: showing threw %@", exception.name], NO);
        return;
    }
    FSLog([NSString stringWithFormat:@"%@: reading %@", FSRole(accountID), NSStringFromClass([controller class])]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTickSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FSTick();
    });
}

static void FSNext(void) {
    if (gSyncController || gSyncQueue.count == 0) return;
    // 7.3.151: each account's read starts only while the mode is in use.
    NSString* blocked = FSBlocked();
    if (blocked) {
        [gSyncQueue removeAllObjects];
        [gSyncCandidates removeAllObjects];
        FSGateLog([NSString stringWithFormat:@"follow sync: not started (%@)", blocked]);
        return;
    }
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        // Wait for the app to be in front again.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FSNext();
        });
        return;
    }
    NSString* accountID = gSyncQueue.firstObject;
    [gSyncQueue removeObjectAtIndex:0];
    if (!FSRole(accountID)) {
        // Queued as A or B, and that was changed since.
        FSLog(@"follow sync: skipped an account that is no longer A or B");
        FSNext();
        return;
    }
    gSyncLastGate = nil;
    FSStart(accountID);
}

// A and B whose lists are older than 3 days (or never read).
// 7.3.151: only while the unified mode is in use, and A is the saved A (it has
// to be the account in use), never "whoever is in use".
static void FSScheduleIfDue(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* blocked = FSBlocked();
    if (blocked) {
        FSGateLog([NSString stringWithFormat:@"follow sync: not scheduled (%@)", blocked]);
        return;
    }
    NSString* aID = [defaults stringForKey:@"kemo_unified_a_id"];
    NSString* bID = [defaults stringForKey:@"kemo_unified_b_id"];
    if (aID.length == 0 || bID.length == 0) return;
    if (!gSyncQueue) gSyncQueue = [NSMutableArray array];
    if (!gSyncHanded) gSyncHanded = [NSMutableSet set];
    for (NSString* accountID in @[ aID, bID ]) {
        if ([gSyncQueue containsObject:accountID] || [accountID isEqualToString:gSyncAccountID]) continue;
        NSDate* last = [defaults objectForKey:FSKey(@"kemo_unified_follows_at_", accountID)];
        NSDate* tried = [defaults objectForKey:FSKey(@"kemo_unified_follows_try_", accountID)];
        NSArray* kept = [defaults arrayForKey:FSKey(@"kemo_unified_follows_", accountID)];
        // The stored list, handed over once (this is asked again on every return to the app).
        if (kept.count && ![gSyncHanded containsObject:accountID]) {
            [gSyncHanded addObject:accountID];
            NFBUnifiedAddKnownFollows(accountID, [NSSet setWithArray:kept]);
        }
        if ([last isKindOfClass:[NSDate class]] && fabs([last timeIntervalSinceNow]) < kSyncEvery) continue;
        if ([tried isKindOfClass:[NSDate class]] && fabs([tried timeIntervalSinceNow]) < kRetryEvery) {
            FSGateLog([NSString stringWithFormat:@"follow sync: %@ due but tried %.0f min ago, waiting", FSRole(accountID),
                                                 fabs([tried timeIntervalSinceNow]) / 60]);
            continue;
        }
        [gSyncQueue addObject:accountID];
        FSLog([NSString stringWithFormat:@"%@: due (last %@)", FSRole(accountID), last ?: @"never"]);
    }
    FSNext();
}

// Asked a little after launch and after each return to the app, since at
// launch the mode may not be in use (on B, say). One pending ask at a time.
static void FSScheduleSoon(NSTimeInterval delay) {
    if (gSyncSchedulePending) return;
    gSyncSchedulePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gSyncSchedulePending = NO;
        FSScheduleIfDue();
    });
}

NSString* NFBUnifiedFollowSyncDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    for (NSString* key in @[ @"kemo_unified_a_id", @"kemo_unified_b_id" ]) {
        NSString* accountID = [defaults stringForKey:key];
        if (accountID.length == 0) continue;
        [out appendFormat:@"%@: %lu people, read %@, tried %@\n", [key containsString:@"_a_"] ? @"A" : @"B",
                          (unsigned long)[defaults arrayForKey:FSKey(@"kemo_unified_follows_", accountID)].count,
                          [defaults objectForKey:FSKey(@"kemo_unified_follows_at_", accountID)] ?: @"never",
                          [defaults objectForKey:FSKey(@"kemo_unified_follows_try_", accountID)] ?: @"never"];
        // 7.3.151: how this account's last read (this run of the app) ended.
        [out appendFormat:@"  last read %@\n", [gSyncLast[accountID] copy] ?: @"(none since launch)"];
    }
    NSString* blocked = [NSThread isMainThread] ? FSBlocked() : @"(not asked off the main thread)";
    [out appendFormat:@"gate: %@ | user row class=%d cursor class=%d\n", blocked ?: @"open (mode active, A in use)",
                      objc_getClass("URTTimelineUserItemViewModel") != nil, objc_getClass("URTTimelineCursorViewModel") != nil];
    [out appendFormat:@"reading now: %@ (%lu people, page %lu, scrolls %lu, stale %lu%@) queued=%lu\n",
                      FSRole(gSyncAccountID) ?: @"-", (unsigned long)gSyncIDs.count, (unsigned long)gSyncTicks,
                      (unsigned long)gSyncScrolls, (unsigned long)gSyncStale, gSyncPaused ? @", paused" : @"",
                      (unsigned long)gSyncQueue.count];
    @synchronized(FSLock()) {
        [out appendFormat:@"%@\n", gSyncLog.count ? [gSyncLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

// The people the off-screen list shows, as X hands it its sections.
// 7.3.151: only the list's own user rows count: URTTimelineUserItemViewModel
// (12.44 dump, XAppLibraries), and not while inside a module, which is a run
// of module header, content, module footer (HookHelpers: IsModuleHeaderItem /
// IsModuleFooterItem), the form a "who to follow" block takes. A module with
// no footer hides the rest of its section: fewer people, never more. Cursor
// rows (URTTimelineCursorViewModel / ...ErrorViewModel) are noted for the end
// of the read; every other row class is counted for the dump.
static void FSHarvest(id controller, NSArray* sections) {
    if (!gSyncController || controller != gSyncController) return;
    Class userRow = objc_getClass("URTTimelineUserItemViewModel");
    Class cursorRow = objc_getClass("URTTimelineCursorViewModel");
    Class cursorErrorRow = objc_getClass("URTTimelineCursorErrorViewModel");
    BOOL cursor = NO, cursorError = NO;
    NSUInteger inModule = 0, noID = 0;
    gSyncUpdates++;
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) continue;
        BOOL module = NO;
        for (id item in section) {
            id model = unwrapDataViewItem(item);
            if (!model) continue;
            if (IsModuleHeaderItem(item)) {
                module = YES;
                continue;
            }
            if (IsModuleFooterItem(item)) {
                module = NO;
                continue;
            }
            if (cursorErrorRow && [model isKindOfClass:cursorErrorRow]) {
                cursorError = YES;
                continue;
            }
            if (cursorRow && [model isKindOfClass:cursorRow]) {
                cursor = YES;
                continue;
            }
            if (!userRow || ![model isKindOfClass:userRow]) {
                NSString* name = NSStringFromClass([model class]);
                if (name && (gSyncOtherRows[name] || gSyncOtherRows.count < 8)) {
                    gSyncOtherRows[name] = @(gSyncOtherRows[name].unsignedIntegerValue + 1);
                }
                continue;
            }
            if (module) {
                inModule++;
                continue;
            }
            long long userID = FSNumber(model, @"userID");
            if (userID <= 0) userID = FSNumber(FSGetter(model, @"user"), @"userID");
            if (userID > 0) {
                [gSyncIDs addObject:@(userID)];
            } else {
                noID++;
            }
            if (!gSyncRowNote) {
                // What the first user row answers to, for the dump.
                gSyncRowNote = [NSString stringWithFormat:@"firstRow(userID=%d user=%d moduleIndex=%lld id=%d)",
                                                          [model respondsToSelector:NSSelectorFromString(@"userID")],
                                                          [model respondsToSelector:NSSelectorFromString(@"user")],
                                                          FSNumber(model, @"timelineModuleItemIndex"), userID > 0];
            }
        }
    }
    // The rows handed over are the whole list as loaded so far, so these are
    // its state now, not sums.
    gSyncInModule = inModule;
    gSyncNoID = noID;
    gSyncCursorNow = cursor;
    gSyncCursorError = cursorError;
    if (cursor) gSyncCursorSeen = YES;
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
    // 7.3.151: FSScheduleIfDue itself asks whether the unified mode is in use;
    // it is asked again after each return to the app (nothing runs otherwise).
    dispatch_async(dispatch_get_main_queue(), ^{
        FSScheduleSoon(40);
    });
    (void)[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(__unused NSNotification* note) {
                                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                                FSScheduleSoon(40);
                                                            });
                                                        }];
}
