//
//  UnifiedTimeline.x
//  NeoFreeBird
//
//  Step 1 of the A/B unified timeline (experiment, off by default). With
//  "kemo_unified_exp" on and an account B picked in settings (kemo_unified_b_id),
//  the active account's Following tab also shows B's Following timeline:
//
//  - B's timeline is X's own: -[T1TimelineFactory homeLatestTimelineForAccount:]
//    with its stream set up by -deserializeStream, refreshed with the source X used
//    for the active account's last refresh, whenever that refresh happens (at most
//    every 30s). Requests go out as B, the way X itself sends them (probe 7.3.132).
//  - Which home controller shows the Following tab: the one whose _timeline came
//    from homeLatestTimelineForAccount: or homeRankedFollowingTimelineForAccount:.
//  - Its sections (TFNItemsDataViewController -setSections:restoreScrollPosition:
//    and -updateSections:...) get B's top-level, non-promoted status view models
//    merged in by the number in their entry ID (statusID if none), newest first,
//    only within the range A has loaded. Tweets both have show once.
//  - Reacting is not routed yet: on a tweet only B has, the inline like, repost,
//    reply and bookmark buttons are stopped with a short notice.
//

#import "HookHelpers.h"

static NSString* const kUnifiedOn = @"kemo_unified_exp";
static NSString* const kUnifiedB = @"kemo_unified_b_id";
static NSString* const kUnifiedBName = @"kemo_unified_b_name";

static NSHashTable* gFollowingTimelines;  // A's Following-tab timelines, from X's factory
static NSHashTable* gFollowingControllers;
static BOOL gMakingB;
static id gBTimeline;
static id gBAccount;
static CFAbsoluteTime gBLastRefresh;
static NSMutableSet<NSNumber*>* gBOnlyIDs;
static NSMutableArray<NSString*>* gUnifiedLog;
static NSString* gLastMerge = @"(no merge yet)";
static const void* kOriginalSectionsKey = &kOriginalSectionsKey;

static void UnifiedLog(NSString* line) {
    static NSDateFormatter* formatter;
    @synchronized([NSObject class]) {
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.dateFormat = @"HH:mm:ss";
        }
        if (!gUnifiedLog) gUnifiedLog = [NSMutableArray array];
        [gUnifiedLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        if (gUnifiedLog.count > 30) [gUnifiedLog removeObjectAtIndex:0];
    }
}

static id Getter(id object, NSString* name) {
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

// An integer getter (q/Q/l/L), or an NSNumber/NSString one.
static long long NumberGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2) return 0;
    char type = signature.methodReturnType[0];
    @try {
        if (type == 'q' || type == 'Q' || type == 'l' || type == 'L') {
            return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
        }
        if (type == '@') {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value respondsToSelector:@selector(longLongValue)]) return [value longLongValue];
        }
    } @catch (__unused NSException* exception) {
    }
    return 0;
}

static BOOL BoolGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return NO;
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != 'B') return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static id HostController(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
}

static id CurrentAccount(void) {
    return Getter(HostController(), @"currentAccount");
}

static NSArray* Accounts(void) {
    Class twitterClass = objc_getClass("TFNTwitter");
    if (!twitterClass || ![twitterClass respondsToSelector:@selector(sharedTwitter)]) return nil;
    id twitter = ((id (*)(id, SEL))objc_msgSend)(twitterClass, @selector(sharedTwitter));
    id accounts = Getter(twitter, @"accounts");
    return [accounts isKindOfClass:[NSArray class]] ? accounts : nil;
}

static NSString* AccountUserID(id account) {
    id user = Getter(account, @"user");
    for (id source in @[ account ?: [NSNull null], user ?: [NSNull null] ]) {
        if (source == [NSNull null]) continue;
        for (NSString* name in @[ @"userID", @"userId", @"userIDString" ]) {
            long long number = NumberGetter(source, name);
            if (number > 0) return [NSString stringWithFormat:@"%lld", number];
            id value = Getter(source, name);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
        }
    }
    return nil;
}

static NSString* AccountUsername(id account) {
    id user = Getter(account, @"user");
    for (id source in @[ account ?: [NSNull null], user ?: [NSNull null] ]) {
        if (source == [NSNull null]) continue;
        for (NSString* name in @[ @"username", @"screenName", @"displayUsername" ]) {
            id value = Getter(source, name);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
        }
    }
    return nil;
}

// For the settings page: every account, as {id, name, active}.
NSArray<NSDictionary*>* NFBUnifiedAccountChoices(void) {
    NSMutableArray* choices = [NSMutableArray array];
    NSString* currentID = AccountUserID(CurrentAccount());
    for (id account in Accounts()) {
        NSString* userID = AccountUserID(account);
        if (!userID) continue;
        NSString* name = AccountUsername(account) ?: userID;
        if (![name hasPrefix:@"@"] && AccountUsername(account)) name = [@"@" stringByAppendingString:name];
        [choices addObject:@{@"id" : userID, @"name" : name, @"active" : @([userID isEqualToString:currentID])}];
    }
    return choices;
}

static BOOL UnifiedActive(void) {
    if (![BHTSettings boolForKey:kUnifiedOn]) return NO;
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedB];
    if (bID.length == 0) return NO;
    return ![bID isEqualToString:AccountUserID(CurrentAccount())];
}

static id AccountForID(NSString* userID) {
    for (id account in Accounts()) {
        if ([AccountUserID(account) isEqualToString:userID]) return account;
    }
    return nil;
}

static void RefreshB(long long source, NSString* why);

// B's timeline, made once per B account the way the 7.3.132 probe did.
static id BTimeline(void) {
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedB];
    id account = AccountForID(bID);
    if (!account) return nil;
    if (gBTimeline && gBAccount == account) return gBTimeline;

    Class factoryClass = objc_getClass("T1TimelineFactory");
    if (!factoryClass || ![factoryClass respondsToSelector:@selector(sharedTimelineFactory)]) return nil;
    id factory = ((id (*)(id, SEL))objc_msgSend)(factoryClass, @selector(sharedTimelineFactory));
    SEL latest = NSSelectorFromString(@"homeLatestTimelineForAccount:");
    if (![factory respondsToSelector:latest]) return nil;
    id timeline = nil;
    gMakingB = YES;
    @try {
        timeline = ((id (*)(id, SEL, id))objc_msgSend)(factory, latest, account);
    } @catch (__unused NSException* exception) {
    }
    gMakingB = NO;
    if (!timeline) return nil;
    if (!Getter(timeline, @"stream")) {
        id stream = Getter(timeline, @"deserializeStream");
        SEL setStream = NSSelectorFromString(@"setStream:");
        if (stream && !Getter(timeline, @"stream") && [timeline respondsToSelector:setStream]) {
            ((void (*)(id, SEL, id))objc_msgSend)(timeline, setStream, stream);
        }
    }
    gBTimeline = timeline;
    gBAccount = account;
    gBLastRefresh = 0;
    UnifiedLog([NSString stringWithFormat:@"B timeline made, stream %@", Getter(timeline, @"stream") ? @"set" : @"nil"]);
    return timeline;
}

static void RefreshB(long long source, NSString* why) {
    id timeline = BTimeline();
    SEL refresh = NSSelectorFromString(@"refreshWithSource:completion:");
    if (!timeline || ![timeline respondsToSelector:refresh]) return;
    if (CFAbsoluteTimeGetCurrent() - gBLastRefresh < 30) return;
    gBLastRefresh = CFAbsoluteTimeGetCurrent();
    UnifiedLog([NSString stringWithFormat:@"refresh B (%@, source %lld)", why, source]);
    void (^completion)(void) = ^{
    };
    @try {
        ((void (*)(id, SEL, long long, id))objc_msgSend)(timeline, refresh, source, completion);
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"refresh B threw %@", exception.name]);
    }
}

static BOOL IsFollowingController(id controller) {
    if (![NSStringFromClass([controller class]) isEqualToString:@"THFHomeTimelineItemsViewController"]) return NO;
    id timeline = nil;
    Ivar ivar = class_getInstanceVariable([controller class], "_timeline");
    if (ivar) timeline = object_getIvar(controller, ivar);
    return timeline && [gFollowingTimelines containsObject:timeline];
}

// Number in an entry ID like "tweet-123…"; the status ID otherwise.
static long long SortKey(id item) {
    id entryID = Getter(item, @"entryID");
    if ([entryID isKindOfClass:[NSString class]]) {
        NSString* digits = [[entryID componentsSeparatedByCharactersInSet:
                                         [[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
                            componentsJoinedByString:@""];
        if (digits.length >= 10) return digits.longLongValue;
    }
    return NumberGetter(item, @"statusID");
}

static BOOL IsStatusItem(id item) {
    return [NSStringFromClass([item class]) isEqualToString:@"URTTimelineStatusItemViewModel"];
}

static void CollectStatusIDs(id item, NSMutableSet<NSNumber*>* ids, int depth) {
    if (depth > 3 || !item) return;
    long long statusID = NumberGetter(item, @"statusID");
    if (statusID > 0) [ids addObject:@(statusID)];
    for (NSString* name in @[ @"items", @"moduleItems", @"statusItems" ]) {
        id children = Getter(item, name);
        if ([children isKindOfClass:[NSArray class]]) {
            for (id child in children) CollectStatusIDs(unwrapDataViewItem(child), ids, depth + 1);
        }
    }
}

static NSArray* MergedSections(id controller, NSArray* sections) {
    id stream = Getter(gBTimeline, @"stream");
    id bObjects = Getter(stream, @"streamObjects");
    if (![bObjects isKindOfClass:[NSArray class]] || [bObjects count] == 0) {
        gLastMerge = @"B stream empty";
        return sections;
    }

    // The section with the most status items is the timeline.
    NSUInteger target = NSNotFound, best = 0;
    BOOL wrapped = NO;
    for (NSUInteger i = 0; i < sections.count; i++) {
        if (![sections[i] isKindOfClass:[NSArray class]]) continue;
        NSUInteger count = 0;
        for (id item in sections[i]) {
            if (IsStatusItem(unwrapDataViewItem(item))) {
                count++;
                if (unwrapDataViewItem(item) != item) wrapped = YES;
            }
        }
        if (count > best) {
            best = count;
            target = i;
        }
    }
    if (target == NSNotFound) {
        gLastMerge = [NSString stringWithFormat:@"no status section in %lu sections", (unsigned long)sections.count];
        return sections;
    }
    if (wrapped) {
        gLastMerge = @"A's items are wrapped (TFNDataViewItem); not merging yet";
        return sections;
    }

    NSArray* aItems = sections[target];
    NSMutableSet<NSNumber*>* aIDs = [NSMutableSet set];
    long long oldestA = LLONG_MAX;
    for (id item in aItems) {
        CollectStatusIDs(item, aIDs, 0);
        if (IsStatusItem(item)) {
            long long key = SortKey(item);
            if (key > 0 && key < oldestA) oldestA = key;
        }
    }

    NSMutableArray* bItems = [NSMutableArray array];
    NSMutableSet<NSNumber*>* bOnly = [NSMutableSet set];
    NSUInteger dupes = 0, older = 0, promoted = 0;
    for (id object in bObjects) {
        if (!IsStatusItem(object)) continue;
        if (BoolGetter(object, @"isPromoted")) {
            promoted++;
            continue;
        }
        long long statusID = NumberGetter(object, @"statusID");
        if (statusID <= 0) continue;
        if ([aIDs containsObject:@(statusID)]) {
            dupes++;
            continue;
        }
        if (SortKey(object) <= oldestA) {
            older++;
            continue;
        }
        [bItems addObject:object];
        [bOnly addObject:@(statusID)];
    }
    [bItems sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [@(SortKey(b)) compare:@(SortKey(a))];
    }];

    NSMutableArray* merged = [NSMutableArray arrayWithCapacity:aItems.count + bItems.count];
    NSUInteger next = 0, outOfOrder = 0;
    long long running = LLONG_MAX;
    for (id item in aItems) {
        long long key = IsStatusItem(item) ? SortKey(item) : 0;
        if (key > 0) {
            if (key > running) outOfOrder++;
            running = MIN(running, key);
        }
        if (running != LLONG_MAX) {
            while (next < bItems.count && SortKey(bItems[next]) > running) {
                [merged addObject:bItems[next++]];
            }
        }
        [merged addObject:item];
    }
    while (next < bItems.count) [merged addObject:bItems[next++]];

    @synchronized([NSObject class]) {
        if (!gBOnlyIDs) gBOnlyIDs = [NSMutableSet set];
        [gBOnlyIDs unionSet:bOnly];
    }
    gLastMerge = [NSString stringWithFormat:@"A items=%lu statuses=%lu | B statuses inserted=%lu both=%lu "
                                            @"olderThanA=%lu promoted=%lu | A outOfOrder=%lu sections=%lu",
                                            (unsigned long)aItems.count, (unsigned long)best,
                                            (unsigned long)bItems.count, (unsigned long)dupes, (unsigned long)older,
                                            (unsigned long)promoted, (unsigned long)outOfOrder,
                                            (unsigned long)sections.count];
    NSMutableArray* result = [sections mutableCopy];
    result[target] = merged;
    return result;
}

static NSArray* SectionsForController(id controller, NSArray* sections) {
    if (!sections || !UnifiedActive() || !IsFollowingController(controller)) return sections;
    objc_setAssociatedObject(controller, kOriginalSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gFollowingControllers) gFollowingControllers = [NSHashTable weakObjectsHashTable];
    [gFollowingControllers addObject:controller];
    if (!BTimeline()) return sections;
    @try {
        return MergedSections(controller, sections);
    } @catch (NSException* exception) {
        gLastMerge = [NSString stringWithFormat:@"merge threw %@", exception.name];
        return sections;
    }
}

static BOOL gReapplyQueued;

// When B's stream changes, give the Following tab its last sections from X again.
static void ReapplyMerge(void) {
    if (gReapplyQueued) return;
    gReapplyQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gReapplyQueued = NO;
        for (id controller in [gFollowingControllers allObjects]) {
            NSArray* original = objc_getAssociatedObject(controller, kOriginalSectionsKey);
            SEL set = @selector(setSections:restoreScrollPosition:);
            if (original && [controller respondsToSelector:set]) {
                ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, set, original, YES);
            }
        }
    });
}

// MARK: - Notice

static void ShowNotice(NSString* text) {
    UIWindow* window = nil;
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* candidate in ((UIWindowScene*)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    if (!window) return;
    UILabel* label = [UILabel new];
    label.text = text;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    label.layer.cornerRadius = 14;
    label.clipsToBounds = YES;
    CGFloat width = MIN(window.bounds.size.width - 48, 320);
    CGSize size = [label sizeThatFits:CGSizeMake(width - 28, CGFLOAT_MAX)];
    label.frame = CGRectMake((window.bounds.size.width - width) / 2,
                             window.bounds.size.height - window.safeAreaInsets.bottom - 150, width, size.height + 22);
    label.alpha = 0;
    [window addSubview:label];
    [UIView animateWithDuration:0.2 animations:^{
        label.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.8 options:0 animations:^{
            label.alpha = 0;
        } completion:^(BOOL done) {
            [label removeFromSuperview];
        }];
    }];
}

static NSUInteger gBlocked;

// YES when the button's tweet is one only B has and the button would act as A.
static BOOL ShouldBlockInlineAction(id actionsView, id button) {
    if (!UnifiedActive() || gBOnlyIDs.count == 0) return NO;
    NSString* buttonClass = NSStringFromClass([button class]);
    if ([buttonClass containsString:@"Share"] || [buttonClass containsString:@"Analytics"]) return NO;
    id viewModel = Getter(actionsView, @"viewModel");
    long long statusID = NumberGetter(viewModel, @"statusID");
    if (statusID <= 0) statusID = NumberGetter(Getter(viewModel, @"status"), @"statusID");
    if (statusID <= 0) statusID = NumberGetter(Getter(viewModel, @"representedStatus"), @"statusID");
    BOOL block = statusID > 0 && [gBOnlyIDs containsObject:@(statusID)];
    if (block) {
        gBlocked++;
        UnifiedLog([NSString stringWithFormat:@"blocked %@ on a B-only tweet", buttonClass]);
        ShowNotice(@"B 계정 트윗이에요. 반응은 아직 실험 중이라 막아뒀어요.");
    }
    return block;
}

NSString* NFBUnifiedTimelineDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedB];
    NSString* currentID = AccountUserID(CurrentAccount());
    [out appendFormat:@"on=%d B=%@ (%@) active=%@ sameAsActive=%d\n", [BHTSettings boolForKey:kUnifiedOn],
                      bID.length ? @"set" : @"none",
                      [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedBName] ?: @"-",
                      currentID ? @"found" : @"missing", bID.length && [bID isEqualToString:currentID]];
    [out appendFormat:@"followingTimelines=%lu followingControllers=%lu\n", (unsigned long)gFollowingTimelines.count,
                      (unsigned long)gFollowingControllers.count];
    id stream = Getter(gBTimeline, @"stream");
    id objects = Getter(stream, @"streamObjects");
    [out appendFormat:@"B timeline=%@ stream=%@ objects=%lu\n", gBTimeline ? @"made" : @"none", stream ? @"set" : @"nil",
                      (unsigned long)([objects respondsToSelector:@selector(count)] ? [objects count] : 0)];
    [out appendFormat:@"last merge: %@\nB-only ids=%lu blocked=%lu\n", gLastMerge, (unsigned long)gBOnlyIDs.count,
                      (unsigned long)gBlocked];
    @synchronized([NSObject class]) {
        [out appendFormat:@"%@\n", gUnifiedLog.count ? [gUnifiedLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

// MARK: - Hooks

%hook T1TimelineFactory

- (id)homeLatestTimelineForAccount:(id)account {
    id timeline = %orig;
    if (timeline && !gMakingB) {
        if (!gFollowingTimelines) gFollowingTimelines = [NSHashTable weakObjectsHashTable];
        [gFollowingTimelines addObject:timeline];
    }
    return timeline;
}

- (id)homeRankedFollowingTimelineForAccount:(id)account {
    id timeline = %orig;
    if (timeline && !gMakingB) {
        if (!gFollowingTimelines) gFollowingTimelines = [NSHashTable weakObjectsHashTable];
        [gFollowingTimelines addObject:timeline];
    }
    return timeline;
}

%end

%hook TFNTwitterHomeTimeline

- (void)refreshWithSource:(long long)source completion:(id)completion {
    %orig;
    if (self != gBTimeline && UnifiedActive() && [gFollowingTimelines containsObject:self] &&
        Getter(self, @"account") == CurrentAccount()) {
        RefreshB(source, @"A refreshed");
    }
}

- (void)refreshWithSource:(long long)source pushToHomeTweetId:(id)tweetID completion:(id)completion {
    %orig;
    if (self != gBTimeline && UnifiedActive() && [gFollowingTimelines containsObject:self] &&
        Getter(self, @"account") == CurrentAccount()) {
        RefreshB(source, @"A refreshed");
    }
}

- (void)streamDidUpdate:(id)stream {
    %orig;
    if (self == gBTimeline && UnifiedActive()) {
        UnifiedLog(@"B stream updated");
        ReapplyMerge();
    }
}

%end

%hook TFNItemsDataViewController

- (void)setSections:(NSArray*)sections restoreScrollPosition:(BOOL)restoreScrollPosition {
    %orig(SectionsForController(self, sections), restoreScrollPosition);
}

- (void)updateSections:(NSArray*)sections
    reconfigureItemIdentifiers:(NSArray*)identifiers
              withRowAnimation:(long long)animation
                    completion:(id)completion {
    %orig(SectionsForController(self, sections), identifiers, animation, completion);
}

%end

%hook TTAStatusInlineActionsView

- (void)didTapInlineActionButton:(id)button {
    if (ShouldBlockInlineAction(self, button)) return;
    %orig;
}

- (void)didTapInlineActionButton:(id)button withPrompt:(id)prompt menuItem:(long long)menuItem {
    if (ShouldBlockInlineAction(self, button)) return;
    %orig;
}

- (void)inlineActionButtonDidRecognizeLongPressBegan:(id)button {
    if (ShouldBlockInlineAction(self, button)) return;
    %orig;
}

- (void)didTriggerAlternateActionInInlineActionButton:(id)button {
    if (ShouldBlockInlineAction(self, button)) return;
    %orig;
}

%end

%ctor {
    // The first B load happens once the Following tab has been set up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (UnifiedActive()) RefreshB(101, @"launch");
    });
}
