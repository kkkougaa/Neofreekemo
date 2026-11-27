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
//    7.3.134: in 7.3.133 the merge stopped at "A's items are wrapped": module
//    (conversation) children are TFNDataViewItem-wrapped while standalone
//    statuses are not. The section is now read as blocks (a standalone status,
//    or a whole module) and B's statuses go between blocks, never into a module.
//  - 7.3.135, reacting as B: on a tweet only B has, like and repost are sent with
//    B's own TFNTwitterAccount (favoriteStatusWithStatusID:, unfavorite…,
//    retweetWithStatusID:), reply opens X's composer and switches it to B with its
//    setAccount:, and the other buttons (bookmark) stay stopped. On a tweet both
//    have, like and repost ask which account, A first. This covers every
//    TTAStatusInlineActionsView, the tweet detail screen included.
//  - A small avatar of the only account that has a tweet sits after its time
//    (TTAStatusAuthorView); none when both have it. "A only" means A has it and it
//    is newer than the oldest tweet B has loaded.
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
static NSMutableSet<NSNumber*>* gBothIDs;
static NSMutableSet<NSNumber*>* gAOnlyIDs;
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

// A section is a run of blocks: a standalone status view model on its own, or a
// conversation module (header, wrapped TFNDataViewItem children, footer). B's
// standalone statuses go between blocks, never inside a module.
static NSArray<NSArray*>* Blocks(NSArray* items) {
    NSMutableArray<NSArray*>* blocks = [NSMutableArray array];
    NSMutableArray* module = nil;
    for (id item in items) {
        BOOL wrapped = unwrapDataViewItem(item) != item;
        BOOL chrome = IsModuleHeaderItem(item) || IsModuleFooterItem(item);
        if (wrapped || chrome) {
            if (IsModuleHeaderItem(item) && module.count) {
                [blocks addObject:module];
                module = nil;
            }
            if (!module) module = [NSMutableArray array];
            [module addObject:item];
            if (IsModuleFooterItem(item)) {
                [blocks addObject:module];
                module = nil;
            }
            continue;
        }
        if (module.count) {
            [blocks addObject:module];
            module = nil;
        }
        [blocks addObject:@[ item ]];
    }
    if (module.count) [blocks addObject:module];
    return blocks;
}

// Newest key of the statuses in a block; 0 when it has none.
static long long BlockKey(NSArray* block) {
    long long key = 0;
    for (id item in block) {
        id model = unwrapDataViewItem(item);
        if (IsStatusItem(model)) key = MAX(key, SortKey(model));
    }
    return key;
}

static NSString* gTemplateNote = @"-";

static NSArray* MergedSections(id controller, NSArray* sections) {
    id stream = Getter(gBTimeline, @"stream");
    id bObjects = Getter(stream, @"streamObjects");
    if (![bObjects isKindOfClass:[NSArray class]] || [bObjects count] == 0) {
        gLastMerge = @"B stream empty";
        return sections;
    }

    // The section with the most statuses is the timeline.
    NSUInteger target = NSNotFound, best = 0, raw = 0, wrappedCount = 0;
    for (NSUInteger i = 0; i < sections.count; i++) {
        if (![sections[i] isKindOfClass:[NSArray class]]) continue;
        NSUInteger count = 0, rawHere = 0, wrappedHere = 0;
        for (id item in sections[i]) {
            id model = unwrapDataViewItem(item);
            if (!IsStatusItem(model)) continue;
            count++;
            if (model == item) rawHere++; else wrappedHere++;
        }
        if (count > best) {
            best = count;
            target = i;
            raw = rawHere;
            wrappedCount = wrappedHere;
        }
    }
    if (target == NSNotFound) {
        gLastMerge = [NSString stringWithFormat:@"no status section in %lu sections", (unsigned long)sections.count];
        return sections;
    }
    if (raw == 0) {
        // Every status is wrapped; note what a wrapper carries for the next step.
        for (id item in sections[target]) {
            if (unwrapDataViewItem(item) == item) continue;
            gTemplateNote = [NSString stringWithFormat:@"objectIdentifier=%@ options=%@ adapter=%@ section=%@",
                                                       NSStringFromClass([Getter(item, @"objectIdentifier") class]),
                                                       [[Getter(item, @"options") allKeys] componentsJoinedByString:@","],
                                                       NSStringFromClass([Getter(item, @"dataViewAdapter") class]),
                                                       NSStringFromClass([Getter(item, @"sectionController") class])];
            break;
        }
        gLastMerge = [NSString stringWithFormat:@"all %lu statuses wrapped; not merging", (unsigned long)wrappedCount];
        return sections;
    }

    NSArray* aItems = sections[target];
    NSMutableSet<NSNumber*>* aIDs = [NSMutableSet set];
    for (id item in aItems) CollectStatusIDs(unwrapDataViewItem(item), aIDs, 0);
    NSArray<NSArray*>* blocks = Blocks(aItems);
    long long oldestA = LLONG_MAX;
    for (NSArray* block in blocks) {
        long long key = BlockKey(block);
        if (key > 0) oldestA = MIN(oldestA, key);
    }

    NSMutableArray* bItems = [NSMutableArray array];
    NSMutableSet<NSNumber*>* bOnly = [NSMutableSet set];
    NSMutableSet<NSNumber*>* both = [NSMutableSet set];
    long long oldestB = LLONG_MAX;
    for (id object in bObjects) {
        if (IsStatusItem(object) && SortKey(object) > 0) oldestB = MIN(oldestB, SortKey(object));
    }
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
            [both addObject:@(statusID)];
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
    for (NSArray* block in blocks) {
        long long key = BlockKey(block);
        if (key > 0) {
            if (key > running) outOfOrder++;
            running = MIN(running, key);
            while (next < bItems.count && SortKey(bItems[next]) > running) {
                [merged addObject:bItems[next++]];
            }
        }
        [merged addObjectsFromArray:block];
    }

    // A's standalone statuses newer than B's oldest: B would have them if it
    // followed their source, so they count as A-only.
    NSMutableSet<NSNumber*>* aOnly = [NSMutableSet set];
    for (id item in aItems) {
        if (!IsStatusItem(item)) continue;
        long long statusID = NumberGetter(item, @"statusID");
        if (statusID > 0 && ![both containsObject:@(statusID)] && SortKey(item) > oldestB) [aOnly addObject:@(statusID)];
    }
    @synchronized([NSObject class]) {
        if (!gBOnlyIDs) gBOnlyIDs = [NSMutableSet set];
        if (!gBothIDs) gBothIDs = [NSMutableSet set];
        if (!gAOnlyIDs) gAOnlyIDs = [NSMutableSet set];
        [gBOnlyIDs unionSet:bOnly];
        [gBothIDs unionSet:both];
        [gBOnlyIDs minusSet:both];
        [gAOnlyIDs unionSet:aOnly];
        [gAOnlyIDs minusSet:both];
    }
    gLastMerge = [NSString stringWithFormat:@"A items=%lu blocks=%lu statuses=%lu (raw %lu, wrapped %lu) | B inserted=%lu "
                                            @"both=%lu olderThanA=%lu promoted=%lu leftOver=%lu | A outOfOrder=%lu",
                                            (unsigned long)aItems.count, (unsigned long)blocks.count,
                                            (unsigned long)best, (unsigned long)raw, (unsigned long)wrappedCount,
                                            (unsigned long)next, (unsigned long)dupes, (unsigned long)older,
                                            (unsigned long)promoted, (unsigned long)(bItems.count - next),
                                            (unsigned long)outOfOrder];
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

static long long ViewModelStatusID(id viewModel) {
    long long statusID = NumberGetter(viewModel, @"statusID");
    if (statusID <= 0) statusID = NumberGetter(Getter(viewModel, @"status"), @"statusID");
    if (statusID <= 0) statusID = NumberGetter(Getter(viewModel, @"representedStatus"), @"statusID");
    return statusID;
}

// The tweet a like or repost acts on: the retweeted original for a retweet.
static id ActedStatus(id viewModel) {
    id status = Getter(viewModel, @"representedStatus") ?: Getter(viewModel, @"status");
    id represented = Getter(status, @"representedStatus");
    return represented ?: status;
}

static UIViewController* TopController(void) {
    UIWindow* window = nil;
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* candidate in ((UIWindowScene*)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    UIViewController* top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

static NSString* BName(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedBName] ?: @"B";
}

static NSString* AName(void) {
    NSString* name = AccountUsername(CurrentAccount());
    return name ? ([name hasPrefix:@"@"] ? name : [@"@" stringByAppendingString:name]) : @"A";
}

// Likes and reposts made as B in this session, so a second tap undoes them.
static NSMutableSet<NSNumber*>* gBLiked;
static NSMutableSet<NSNumber*>* gBUnliked;
static NSMutableSet<NSNumber*>* gBReposted;

static void CallStatusMethod(id account, NSString* selectorName, long long statusID) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![account respondsToSelector:selector]) {
        UnifiedLog([NSString stringWithFormat:@"B account has no %@", selectorName]);
        ShowNotice(@"이 X 버전에서는 B로 보낼 수 없어요.");
        return;
    }
    void (^response)(void) = ^{
    };
    ((void (*)(id, SEL, long long, id))objc_msgSend)(account, selector, statusID, response);
}

static void LikeAsB(id viewModel) {
    id status = ActedStatus(viewModel);
    long long statusID = NumberGetter(status, @"statusID");
    if (statusID <= 0 || !gBAccount) return;
    if (!gBLiked) gBLiked = [NSMutableSet set];
    if (!gBUnliked) gBUnliked = [NSMutableSet set];
    BOOL liked = [gBLiked containsObject:@(statusID)] ||
                 (![gBUnliked containsObject:@(statusID)] &&
                  (BoolGetter(status, @"favoritedByLoadingAccount") || BoolGetter(status, @"seenAsFavorited")));
    if (liked) {
        CallStatusMethod(gBAccount, @"unfavoriteStatusWithStatusID:responseBlock:", statusID);
        [gBLiked removeObject:@(statusID)];
        [gBUnliked addObject:@(statusID)];
        ShowNotice([NSString stringWithFormat:@"%@의 마음에 들어요를 취소했어요", BName()]);
    } else {
        CallStatusMethod(gBAccount, @"favoriteStatusWithStatusID:responseBlock:", statusID);
        [gBLiked addObject:@(statusID)];
        [gBUnliked removeObject:@(statusID)];
        ShowNotice([NSString stringWithFormat:@"♥ %@로 마음에 들어요 했어요", BName()]);
    }
    UnifiedLog([NSString stringWithFormat:@"%@ as B", liked ? @"unlike" : @"like"]);
}

static void RepostAsB(id viewModel) {
    id status = ActedStatus(viewModel);
    long long statusID = NumberGetter(status, @"statusID");
    if (statusID <= 0 || !gBAccount) return;
    if (!gBReposted) gBReposted = [NSMutableSet set];
    BOOL reposted = [gBReposted containsObject:@(statusID)] || BoolGetter(status, @"seenAsRetweeted");
    if (reposted) {
        // Undoing needs the repost's own ID, which only X's own state has.
        ShowNotice([NSString stringWithFormat:@"%@의 재게시 취소는 아직 %@로 전환해서 해주세요", BName(), BName()]);
        return;
    }
    CallStatusMethod(gBAccount, @"retweetWithStatusID:responseBlock:", statusID);
    [gBReposted addObject:@(statusID)];
    ShowNotice([NSString stringWithFormat:@"🔁 %@로 재게시했어요", BName()]);
    UnifiedLog(@"repost as B");
}

// A composer opened within a few seconds of this is switched to B.
static CFAbsoluteTime gComposeAsBUntil;

static void ChooseAccount(NSString* title, void (^asA)(void), void (^asB)(void)) {
    UIAlertController* sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:@"두 계정 모두 이 게시물을 보고 있어요."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ (A) ✓", AName()]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                asA();
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ (B)", BName()]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                asB();
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController* top = TopController();
    sheet.popoverPresentationController.sourceView = top.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMaxY(top.view.bounds) - 80, 1, 1);
    [top presentViewController:sheet animated:YES completion:nil];
}

// YES when the tap was handled here (sent as B, a sheet shown, or stopped).
// `orig` runs X's own handling, which acts as A.
static BOOL HandleInlineAction(id actionsView, id button, void (^orig)(void)) {
    if (!UnifiedActive()) return NO;
    NSString* buttonClass = NSStringFromClass([button class]);
    if ([buttonClass containsString:@"Share"] || [buttonClass containsString:@"Analytics"]) return NO;
    id viewModel = Getter(actionsView, @"viewModel");
    long long statusID = ViewModelStatusID(viewModel);
    if (statusID <= 0) return NO;
    BOOL bOnly = [gBOnlyIDs containsObject:@(statusID)];
    BOOL both = [gBothIDs containsObject:@(statusID)];
    if (!bOnly && !both) return NO;
    if (!BTimeline() || !gBAccount) return NO;

    BOOL like = [buttonClass containsString:@"Favorite"];
    BOOL repost = [buttonClass containsString:@"Retweet"];
    BOOL reply = [buttonClass containsString:@"Reply"];

    if (bOnly) {
        if (like) {
            LikeAsB(viewModel);
            return YES;
        }
        if (repost) {
            RepostAsB(viewModel);
            return YES;
        }
        if (reply) {
            gComposeAsBUntil = CFAbsoluteTimeGetCurrent() + 6;
            UnifiedLog(@"reply: composer will switch to B");
            return NO;
        }
        gBlocked++;
        UnifiedLog([NSString stringWithFormat:@"blocked %@ on a B-only tweet", buttonClass]);
        ShowNotice(@"B 계정 트윗이에요. 이 버튼은 아직 B로 보낼 수 없어서 막아뒀어요.");
        return YES;
    }

    // Both accounts have it: like and repost ask, A first.
    if (like) {
        ChooseAccount(@"어느 계정으로 마음에 들어요할까요?", orig, ^{
            LikeAsB(viewModel);
        });
        return YES;
    }
    if (repost) {
        ChooseAccount(@"어느 계정으로 재게시할까요?", orig, ^{
            RepostAsB(viewModel);
        });
        return YES;
    }
    return NO;
}

// MARK: - Which account has it (badge next to the time)

static UIImage* AccountAvatar(id account, NSString* letter, UIColor* color) {
    static NSCache<NSString*, UIImage*>* cache;
    if (!cache) cache = [NSCache new];
    NSString* userID = AccountUserID(account) ?: letter;
    UIImage* image = [cache objectForKey:userID];
    if (image) return image;
    // AccountBubbles.x keeps the accounts' pictures here.
    NSURL* base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSString* path = [[base URLByAppendingPathComponent:@"NFBAccountAvatars"] URLByAppendingPathComponent:
                                                                                 [userID stringByAppendingString:@".img"]].path;
    NSData* data = [NSData dataWithContentsOfFile:path];
    __block UIImage* found = data.length ? [UIImage imageWithData:data] : nil;
    if (!found) {
        // On-screen avatar of that account (the drawer shows them).
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
    // A letter in a circle until a picture is found.
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
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

static const NSInteger kBadgeTag = 0x4E4642;  // "NFB"

static void UpdateAccountBadge(UIView* authorView) {
    UIImageView* badge = [authorView viewWithTag:kBadgeTag];
    UIView* statusView = authorView.superview;
    while (statusView && ![NSStringFromClass([statusView class]) isEqualToString:@"T1StandardStatusView"]) {
        statusView = statusView.superview;
    }
    long long statusID = UnifiedActive() && statusView ? ViewModelStatusID(Getter(statusView, @"viewModel")) : 0;
    id account = nil;
    NSString* letter = nil;
    UIColor* color = nil;
    if (statusID > 0 && [gBOnlyIDs containsObject:@(statusID)]) {
        account = gBAccount;
        letter = @"B";
        color = [UIColor colorWithRed:1 green:0.48 blue:0 alpha:1];
    } else if (statusID > 0 && [gAOnlyIDs containsObject:@(statusID)]) {
        account = CurrentAccount();
        letter = @"A";
        color = [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1];
    }
    if (!letter) {
        badge.hidden = YES;
        return;
    }
    UIView* anchor = nil;
    for (UIView* view in authorView.subviews) {
        if ([view.accessibilityIdentifier isEqualToString:@"StatusTimeStamp"]) anchor = view;
    }
    if (!anchor) {
        for (UIView* view in authorView.subviews) {
            if ([view.accessibilityIdentifier isEqualToString:@"StatusUsername"]) anchor = view;
        }
    }
    if (!anchor || anchor.hidden || anchor.frame.size.width <= 0) {
        badge.hidden = YES;
        return;
    }
    if (!badge) {
        badge = [UIImageView new];
        badge.tag = kBadgeTag;
        badge.contentMode = UIViewContentModeScaleAspectFill;
        badge.clipsToBounds = YES;
        badge.layer.cornerRadius = 7;
        badge.userInteractionEnabled = NO;
        [authorView addSubview:badge];
    }
    badge.image = AccountAvatar(account, letter, color);
    badge.hidden = NO;
    badge.frame = CGRectMake(CGRectGetMaxX(anchor.frame) + 4, CGRectGetMidY(anchor.frame) - 7, 14, 14);
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
    [out appendFormat:@"wrapper: %@\n", gTemplateNote];
    [out appendFormat:@"last merge: %@\nB-only ids=%lu both=%lu A-only=%lu blocked=%lu likedAsB=%lu repostedAsB=%lu\n",
                      gLastMerge, (unsigned long)gBOnlyIDs.count, (unsigned long)gBothIDs.count,
                      (unsigned long)gAOnlyIDs.count, (unsigned long)gBlocked, (unsigned long)gBLiked.count,
                      (unsigned long)gBReposted.count];
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
    if (HandleInlineAction(self, button, ^{
            %orig;
        }))
        return;
    %orig;
}

- (void)didTapInlineActionButton:(id)button withPrompt:(id)prompt menuItem:(long long)menuItem {
    if (HandleInlineAction(self, button, ^{
            %orig;
        }))
        return;
    %orig;
}

- (void)inlineActionButtonDidRecognizeLongPressBegan:(id)button {
    if (HandleInlineAction(self, button, ^{
            %orig;
        }))
        return;
    %orig;
}

- (void)didTriggerAlternateActionInInlineActionButton:(id)button {
    if (HandleInlineAction(self, button, ^{
            %orig;
        }))
        return;
    %orig;
}

%end

%hook TTAStatusAuthorView

- (void)layoutSubviews {
    %orig;
    UIView* view = (UIView*)self;
    if (UnifiedActive() || [view viewWithTag:kBadgeTag]) UpdateAccountBadge(view);
}

%end

// A reply to a tweet only B has opens X's composer as A; switch it to B the way
// the composer's own account picker would (setAccount:).
%hook T1TweetComposeViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (CFAbsoluteTimeGetCurrent() > gComposeAsBUntil || !gBAccount) return;
    gComposeAsBUntil = 0;
    id composer = (id)self;
    SEL setAccount = NSSelectorFromString(@"setAccount:");
    if (![composer respondsToSelector:setAccount]) {
        UnifiedLog(@"composer has no setAccount:");
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(composer, setAccount, gBAccount);
    SEL didUpdate = NSSelectorFromString(@"accountDidUpdate:");
    if ([composer respondsToSelector:didUpdate]) ((void (*)(id, SEL, id))objc_msgSend)(composer, didUpdate, gBAccount);
    BOOL switched = Getter(composer, @"account") == gBAccount;
    UnifiedLog([NSString stringWithFormat:@"composer switched to B: %@", switched ? @"yes" : @"no"]);
    ShowNotice(switched ? [NSString stringWithFormat:@"%@로 답글을 써요. 보내기 전에 왼쪽 위 프로필을 확인해주세요", BName()]
                        : @"B로 바꾸지 못했어요. 왼쪽 위 프로필을 눌러 직접 바꿔주세요");
}

%end

%ctor {
    // The first B load happens once the Following tab has been set up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (UnifiedActive()) RefreshB(101, @"launch");
    });
}
