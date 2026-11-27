//
//  UnifiedTimelineProbe.x
//  NeoFreeBird
//
//  Step 0 of a unified (two account) home timeline: can the Following timeline
//  of an account that is not the active one be loaded, without switching?
//
//  With the shake dump on, the volume-down dump starts the probe and the second
//  dump that follows six seconds later shows what came back:
//  - X's own refreshes of TFNTwitterHomeTimeline are watched (source number, for
//    the active account or another one), so the probe asks with a source X
//    itself uses and the request is the same one X sends for that account.
//  - For the first account that is not the active one it takes
//    -[T1TimelineFactory homeLatestTimelineForAccount:] and refreshes it with
//    -[TFNTwitterHomeTimeline refreshWithSource:completion:].
//  - The timeline objects of both accounts are described: class, whether they
//    are the same object, getters that hold entries and their counts.
//  7.3.130: 7.3.129 showed the factory hands out a fresh timeline with no stream
//  each call, and its refresh completed after exactly 5s with no request sent.
//  X's home controller sets the stream up itself (_setupStreamFromTimeline), so
//  the probe now asks the timeline to deserializeStream first; requests sent
//  while the probe runs are tagged in TIMELINE REQUESTS; and the on-screen
//  THFHomeTimelineItemsViewControllers' object ivars are listed.
//  No tweet text, user names or IDs are recorded. The GraphQL request itself
//  shows in the dump's TIMELINE REQUESTS section (TimelineProbe.x).
//

#import "HookHelpers.h"

static NSMutableArray<NSString*>* gRefreshLog;
static NSMutableArray<NSString*>* gProbeLines;
static NSNumber* gXSource;
static BOOL gProbeRefreshing;
static CFAbsoluteTime gLastKick;
static id gOtherTimeline;  // kept so a fresh object is not freed mid-refresh

static id CallGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static NSString* Stamp(void) {
    static NSDateFormatter* formatter;
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss";
    }
    return [formatter stringFromDate:[NSDate date]];
}

static void ProbeLine(NSString* line) {
    @synchronized([NSObject class]) {
        if (!gProbeLines) gProbeLines = [NSMutableArray array];
        [gProbeLines addObject:[NSString stringWithFormat:@"%@ %@", Stamp(), line]];
        if (gProbeLines.count > 60) [gProbeLines removeObjectAtIndex:0];
    }
}

static id HostController(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
}

static id CurrentAccount(void) {
    return CallGetter(HostController(), @"currentAccount");
}

static NSArray* Accounts(void) {
    Class twitterClass = objc_getClass("TFNTwitter");
    if (!twitterClass || ![twitterClass respondsToSelector:@selector(sharedTwitter)]) {
        return nil;
    }
    id twitter = ((id (*)(id, SEL))objc_msgSend)(twitterClass, @selector(sharedTwitter));
    id accounts = CallGetter(twitter, @"accounts");
    return [accounts isKindOfClass:[NSArray class]] ? accounts : nil;
}

static NSString* WhoseAccount(id account) {
    if (!account) return @"nil";
    id current = CurrentAccount();
    if (account == current) return @"active";
    NSUInteger index = [Accounts() indexOfObjectIdenticalTo:account];
    return index == NSNotFound ? @"unknown" : [NSString stringWithFormat:@"other#%lu", (unsigned long)index];
}

static id LatestTimelineForAccount(id account) {
    Class factoryClass = objc_getClass("T1TimelineFactory");
    if (!factoryClass || ![factoryClass respondsToSelector:@selector(sharedTimelineFactory)]) {
        return nil;
    }
    id factory = ((id (*)(id, SEL))objc_msgSend)(factoryClass, @selector(sharedTimelineFactory));
    SEL selector = NSSelectorFromString(@"homeLatestTimelineForAccount:");
    if (![factory respondsToSelector:selector]) {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(factory, selector, account);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

// Count of whatever a getter returns, if it is a collection.
static NSString* CountOf(id value) {
    if ([value respondsToSelector:@selector(count)] &&
        ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSOrderedSet class]] ||
         [value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSDictionary class]])) {
        return [NSString stringWithFormat:@"%@[%lu]", NSStringFromClass([value class]), (unsigned long)[value count]];
    }
    return value ? NSStringFromClass([value class]) : @"nil";
}

// Method names (own class and superclasses up to NSObject) that look like they
// hold or load entries.
static NSString* InterestingMethods(id object) {
    NSMutableOrderedSet<NSString*>* names = [NSMutableOrderedSet orderedSet];
    NSArray* words = @[ @"ntr", @"tatus", @"tem", @"ursor", @"efresh", @"oad", @"tream", @"ount" ];
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method* methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString* name = NSStringFromSelector(method_getName(methods[i]));
            if ([name hasPrefix:@"."] || [name hasPrefix:@"_"]) continue;
            for (NSString* word in words) {
                if ([name rangeOfString:word].location != NSNotFound) {
                    [names addObject:[NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), name]];
                    break;
                }
            }
        }
        free(methods);
        if (names.count > 60) break;
    }
    return [[names array] componentsJoinedByString:@" "];
}

static NSString* DescribeTimeline(id timeline) {
    if (!timeline) return @"nil";
    NSMutableString* out = [NSMutableString string];
    NSMutableArray* chain = [NSMutableArray array];
    for (Class cls = [timeline class]; cls; cls = class_getSuperclass(cls)) {
        [chain addObject:NSStringFromClass(cls)];
    }
    [out appendFormat:@"class %@ %p account=%@\n", [chain componentsJoinedByString:@" < "], timeline,
                      WhoseAccount(CallGetter(timeline, @"account"))];
    id stream = CallGetter(timeline, @"stream");
    for (id object in @[ timeline, stream ?: [NSNull null] ]) {
        if (object == [NSNull null]) continue;
        NSMutableArray* found = [NSMutableArray array];
        for (NSString* name in @[ @"entries", @"statuses", @"items", @"timelineEntries", @"allEntries", @"statusIDs",
                                  @"entryIDs", @"tweets", @"objects" ]) {
            id value = CallGetter(object, name);
            if (value) [found addObject:[NSString stringWithFormat:@"%@=%@", name, CountOf(value)]];
        }
        [out appendFormat:@"%@ %@: %@\n", object == timeline ? @"timeline" : @"stream", NSStringFromClass([object class]),
                          found.count ? [found componentsJoinedByString:@" "] : @"(no entry getter)"];
        [out appendFormat:@"  methods: %@\n", InterestingMethods(object)];
    }
    return out;
}

// Object ivars of a controller (name and class only), to find the timeline it shows.
static NSString* ObjectIvars(id object) {
    NSMutableArray* parts = [NSMutableArray array];
    for (Class cls = [object class]; cls && cls != [UIViewController class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar* ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char* type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try {
                value = object_getIvar(object, ivars[i]);
            } @catch (__unused NSException* exception) {
            }
            NSString* name = [NSString stringWithUTF8String:ivar_getName(ivars[i]) ?: "?"];
            if (!value) continue;
            [parts addObject:[NSString stringWithFormat:@"%@=%@", name, CountOf(value)]];
        }
        free(ivars);
    }
    return [parts componentsJoinedByString:@" "];
}

static void CollectHomeControllers(UIViewController* controller, NSMutableArray* found) {
    if (!controller || found.count > 6) return;
    if ([NSStringFromClass([controller class]) isEqualToString:@"THFHomeTimelineItemsViewController"]) {
        [found addObject:controller];
    }
    for (UIViewController* child in controller.childViewControllers) {
        CollectHomeControllers(child, found);
    }
    if (controller.presentedViewController && controller.presentedViewController.presentingViewController == controller) {
        CollectHomeControllers(controller.presentedViewController, found);
    }
}

static NSString* DescribeHomeControllers(void) {
    NSMutableArray* found = [NSMutableArray array];
    for (UIWindow* window in [UIApplication sharedApplication].windows) {
        CollectHomeControllers(window.rootViewController, found);
    }
    if (found.count == 0) return @"(no THFHomeTimelineItemsViewController)\n";
    NSMutableString* out = [NSMutableString string];
    for (UIViewController* controller in found) {
        [out appendFormat:@"%@ %p account=%@ onScreen=%d\n  ivars: %@\n", NSStringFromClass([controller class]), controller,
                          WhoseAccount(CallGetter(controller, @"account")), controller.viewIfLoaded.window != nil,
                          ObjectIvars(controller)];
        id timeline = CallGetter(controller, @"timeline");
        if (timeline) [out appendFormat:@"  timeline: %@", DescribeTimeline(timeline)];
    }
    return out;
}

BOOL NFBUnifiedProbeActive(void) {
    return gProbeRefreshing;
}

static void RecordRefresh(id timeline, long long source, BOOL withTweet) {
    BOOL ours = gProbeRefreshing && timeline == gOtherTimeline;
    if (!ours && CallGetter(timeline, @"account") == CurrentAccount()) {
        gXSource = @(source);
    }
    @synchronized([NSObject class]) {
        if (!gRefreshLog) gRefreshLog = [NSMutableArray array];
        [gRefreshLog addObject:[NSString stringWithFormat:@"%@ %@ refresh source=%lld account=%@%@%@", Stamp(),
                                                          NSStringFromClass([timeline class]), source,
                                                          WhoseAccount(CallGetter(timeline, @"account")),
                                                          withTweet ? @" pushToHome" : @"", ours ? @" (probe)" : @""]];
        if (gRefreshLog.count > 20) [gRefreshLog removeObjectAtIndex:0];
    }
}

void NFBUnifiedProbeKick(void) {
    if (![BHTSettings boolForKey:@"kemo_shake_dump"]) return;
    if (CFAbsoluteTimeGetCurrent() - gLastKick < 30) return;
    gLastKick = CFAbsoluteTimeGetCurrent();

    NSArray* accounts = Accounts();
    id current = CurrentAccount();
    ProbeLine([NSString stringWithFormat:@"kick: %lu accounts, active %@", (unsigned long)accounts.count,
                                         current ? @"found" : @"missing"]);
    id other = nil;
    for (id account in accounts) {
        if (account != current) {
            other = account;
            break;
        }
    }
    if (!other) {
        ProbeLine(@"no second account; add one to try");
        return;
    }

    id activeTimeline = LatestTimelineForAccount(current);
    id otherTimeline = LatestTimelineForAccount(other);
    ProbeLine([NSString stringWithFormat:@"factory: active=%p other=%p same=%@ again=%@", activeTimeline, otherTimeline,
                                         activeTimeline == otherTimeline ? @"YES" : @"no",
                                         LatestTimelineForAccount(other) == otherTimeline ? @"cached" : @"new each call"]);
    if (!otherTimeline || otherTimeline == activeTimeline) {
        ProbeLine(@"stop: no separate timeline for the other account");
        return;
    }
    gOtherTimeline = otherTimeline;

    SEL refresh = NSSelectorFromString(@"refreshWithSource:completion:");
    if (![otherTimeline respondsToSelector:refresh]) {
        ProbeLine(@"stop: other timeline has no refreshWithSource:completion:");
        return;
    }
    if (!gXSource) {
        // Only ask the way X asks; until X's own refresh has been seen, wait.
        ProbeLine(@"waiting: X's own refresh source not seen yet; pull to refresh Home (Following), then dump again");
        gLastKick = 0;
        return;
    }
    // X's home controller sets the stream up itself (_setupStreamFromTimeline); a timeline
    // taken straight from the factory has none, and its refresh just times out (7.3.129).
    if (!CallGetter(otherTimeline, @"stream")) {
        id stream = CallGetter(otherTimeline, @"deserializeStream");
        ProbeLine([NSString stringWithFormat:@"deserializeStream -> %@", stream ? NSStringFromClass([stream class]) : @"nil"]);
        if (stream && !CallGetter(otherTimeline, @"stream") &&
            [otherTimeline respondsToSelector:NSSelectorFromString(@"setStream:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(otherTimeline, NSSelectorFromString(@"setStream:"), stream);
            ProbeLine(@"setStream: done");
        }
        ProbeLine([NSString stringWithFormat:@"other stream now %@", CallGetter(otherTimeline, @"stream") ? @"set" : @"nil"]);
    }
    long long source = gXSource.longLongValue;
    ProbeLine([NSString stringWithFormat:@"refreshing other with X's source %lld", source]);
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    gProbeRefreshing = YES;
    void (^completion)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gProbeRefreshing = NO;
        });
        ProbeLine([NSString stringWithFormat:@"other refresh completed after %.1fs", CFAbsoluteTimeGetCurrent() - started]);
    };
    @try {
        ((void (*)(id, SEL, long long, id))objc_msgSend)(otherTimeline, refresh, source, completion);
    } @catch (NSException* exception) {
        gProbeRefreshing = NO;
        ProbeLine([NSString stringWithFormat:@"refresh threw %@", exception.name]);
    }
}

NSString* NFBUnifiedProbeText(void) {
    NSMutableString* out = [NSMutableString string];
    @synchronized([NSObject class]) {
        [out appendFormat:@"X refresh source seen: %@\n", gXSource ?: @"none"];
        [out appendFormat:@"refreshes:\n%@\n", gRefreshLog.count ? [gRefreshLog componentsJoinedByString:@"\n"] : @"(none)"];
        [out appendFormat:@"probe:\n%@\n", gProbeLines.count ? [gProbeLines componentsJoinedByString:@"\n"] : @"(not run)"];
    }
    @try {
        [out appendFormat:@"-- home controllers --\n%@", DescribeHomeControllers()];
        if (gOtherTimeline) {
            [out appendFormat:@"-- other latest --\n%@", DescribeTimeline(gOtherTimeline)];
        }
    } @catch (NSException* exception) {
        [out appendFormat:@"describe threw %@\n", exception.name];
    }
    return out;
}

%hook TFNTwitterHomeTimeline

- (void)refreshWithSource:(long long)source completion:(id)completion {
    if ([BHTSettings boolForKey:@"kemo_shake_dump"]) {
        RecordRefresh(self, source, NO);
    }
    %orig;
}

- (void)refreshWithSource:(long long)source pushToHomeTweetId:(id)tweetID completion:(id)completion {
    if ([BHTSettings boolForKey:@"kemo_shake_dump"]) {
        RecordRefresh(self, source, tweetID != nil);
    }
    %orig;
}

%end
