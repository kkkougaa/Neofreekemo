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
//    every 3s since 7.3.140; it was 30s). Requests go out as B, the way X itself sends them (probe 7.3.132).
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
//  - 7.3.136: the composer is switched the way its account picker does it, only
//    when it is the reply to the tapped tweet. A composer meant for B is checked
//    at every send path (button, header, toolbar, key command, and X's own
//    _t1_checkForValidTweetsAndSend / _t1_sendCompositions:): unless the composer,
//    its single-tweet and table controllers and the avatar all hold B, nothing is
//    sent. A tweet meant for B never falls through to A when B is missing.
//    The badge moved before the display name.
//  - 7.3.137: A and B are a pair (kemo_unified_a_id, kemo_unified_b_id). Our account
//    dock (AccountBubbles.x) gets an "A/B" circle before A: stopping on it turns
//    the unified mode on (kemo_unified_mode) and switches to A; stopping on any
//    account turns it off, so that account shows alone. X's own account sheet is
//    left alone.
//    Unified is only active while the account in use is A. The ID lists belong to
//    one pair; when the pair changes they are retired, and a tap on a tweet from
//    a retired list is stopped instead of going out as whoever is in use now.
//    "Always ask" (kemo_unified_always_ask) asks on A-only tweets too; a reply on
//    a tweet both have asks as well.
//  - The accounts that liked a tweet show as small pictures left of the heart.
//  - 7.3.138: a tweet only B has also gets its display name in B's colour
//    (kemo_unified_b_color, orange unless picked) and a small folded corner of
//    that colour at the top left of its row. A-only tweets stay as they are.
//  - 7.3.140: only B's tweets get the small account picture (A-only ones had
//    A's). B loaded only its first page, so scrolling A down ran past B's
//    tweets; when A's Following stream loads more (-[TFSTwitterStream
//    loadBottomWithSource:]), B's loads more too.
//  - A small avatar of the only account that has a tweet sits after its time
//    (TTAStatusAuthorView); none when both have it. "A only" means A has it and it
//    is newer than the oldest tweet B has loaded.
//

#import "HookHelpers.h"

static NSString* const kUnifiedOn = @"kemo_unified_exp";
static NSString* const kUnifiedB = @"kemo_unified_b_id";
static NSString* const kUnifiedBName = @"kemo_unified_b_name";
static NSString* const kUnifiedA = @"kemo_unified_a_id";
static NSString* const kUnifiedAName = @"kemo_unified_a_name";
static NSString* const kUnifiedMode = @"kemo_unified_mode";  // unset = on, for setups from before 7.3.137
static NSString* const kUnifiedAlwaysAsk = @"kemo_unified_always_ask";

static NSHashTable* gFollowingTimelines;  // A's Following-tab timelines, from X's factory
static NSHashTable* gFollowingControllers;
static BOOL gMakingB;
static id gBTimeline;
static id gBAccount;
static CFAbsoluteTime gBLastRefresh;
static NSUInteger gBBottomLoads;
static CFAbsoluteTime gBLastBottom;
static long long gLastASource = 101;
static void FollowBottomLoad(id stream, long long source);
static void LoadMoreB(long long source, NSString* why);
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

static NSString* AID(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedA];
}

static NSString* BID(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedB];
}

static BOOL UnifiedModeSelected(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kUnifiedMode];
    return value ? [value boolValue] : YES;
}

static void SetUnifiedMode(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kUnifiedMode];
}

// Unified only while the account in use is A (or, with no A picked, any account but B).
static BOOL UnifiedActive(void) {
    if (![BHTSettings boolForKey:kUnifiedOn] || !UnifiedModeSelected()) return NO;
    NSString* bID = BID();
    if (bID.length == 0) return NO;
    NSString* currentID = AccountUserID(CurrentAccount());
    if (currentID.length == 0 || [bID isEqualToString:currentID]) return NO;
    NSString* aID = AID();
    return aID.length == 0 || [aID isEqualToString:currentID];
}

static id AccountForID(NSString* userID) {
    for (id account in Accounts()) {
        if ([AccountUserID(account) isEqualToString:userID]) return account;
    }
    return nil;
}

static void RefreshB(long long source, NSString* why);

// The ID lists below belong to one (account in use, B) pair. When the pair
// changes, what they held is retired: those tweets may still be on screen with
// the old pair's badge, and a tap on one must not go out as the new pair.
static NSString* gPairKey;
static NSMutableSet<NSNumber*>* gRetiredIDs;
static NSMutableSet<NSNumber*>* gBLiked;
static NSMutableSet<NSNumber*>* gBUnliked;
static NSMutableSet<NSNumber*>* gBReposted;

static void EnsurePair(void) {
    NSString* key = [NSString stringWithFormat:@"%@|%@", AccountUserID(CurrentAccount()) ?: @"-", BID() ?: @"-"];
    if ([key isEqualToString:gPairKey]) return;
    BOOL changed = gPairKey != nil;
    gPairKey = key;
    @synchronized([NSObject class]) {
        if (!gRetiredIDs) gRetiredIDs = [NSMutableSet set];
        if (gBOnlyIDs) [gRetiredIDs unionSet:gBOnlyIDs];
        if (gBothIDs) [gRetiredIDs unionSet:gBothIDs];
        if (gAOnlyIDs) [gRetiredIDs unionSet:gAOnlyIDs];
        [gBOnlyIDs removeAllObjects];
        [gBothIDs removeAllObjects];
        [gAOnlyIDs removeAllObjects];
    }
    [gBLiked removeAllObjects];
    [gBUnliked removeAllObjects];
    [gBReposted removeAllObjects];
    if (changed) UnifiedLog([NSString stringWithFormat:@"account pair changed; %lu ids retired", (unsigned long)gRetiredIDs.count]);
}

// B's timeline, made once per B account the way the 7.3.132 probe did.
static id BTimeline(void) {
    id account = AccountForID(BID());
    if (!account) {
        gBTimeline = nil;
        gBAccount = nil;
        return nil;
    }
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
    // X refreshes a timeline through several calls at once; one B refresh per A refresh.
    if (CFAbsoluteTimeGetCurrent() - gBLastRefresh < 3) return;
    gBLastRefresh = CFAbsoluteTimeGetCurrent();
    gLastASource = source;
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

static id ActedStatusOf(id viewModel);

// When it reached the timeline: the status ID (a snowflake, so in time order;
// for a repost it is the repost's own ID). 7.3.141: it was every digit of the
// entry ID run together, which for a conversation module made a huge number,
// put A out of order (163 of 171 blocks) and piled B's tweets up in one place.
static long long SortKey(id item) {
    long long statusID = NumberGetter(item, @"statusID");
    if (statusID > 0) return statusID;
    id entryID = Getter(item, @"entryID");
    if ([entryID isKindOfClass:[NSString class]]) {
        // The first long run of digits only ("tweet-123", "home-conversation-123-...").
        for (NSString* part in [entryID componentsSeparatedByCharactersInSet:
                                            [[NSCharacterSet decimalDigitCharacterSet] invertedSet]]) {
            if (part.length >= 10) return part.longLongValue;
        }
    }
    return 0;
}

// Who brought a tweet into a Following timeline: the reposter for a repost,
// the author otherwise (the status the timeline item is, not the one it shows).
static long long BringerID(id item) {
    long long userID = NumberGetter(item, @"fromUserID");
    if (userID <= 0) userID = NumberGetter(Getter(item, @"status"), @"fromUserID");
    return userID;
}

static long long ActedID(id item) {
    return NumberGetter(ActedStatusOf(item), @"statusID");
}

static id ActedStatusOf(id viewModel) {
    id status = Getter(viewModel, @"representedStatus") ?: Getter(viewModel, @"status");
    return Getter(status, @"representedStatus") ?: status;
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
    EnsurePair();
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
    if (best < 5) {
        // X is still loading or showing a placeholder; mixing B into a handful
        // of A's tweets would fill the screen with B.
        gLastMerge = [NSString stringWithFormat:@"A has only %lu statuses; not merging", (unsigned long)best];
        return sections;
    }
    NSMutableSet<NSNumber*>* aIDs = [NSMutableSet set];
    for (id item in aItems) CollectStatusIDs(unwrapDataViewItem(item), aIDs, 0);
    // The originals A has (whoever reposted them) and the people who brought
    // A's tweets, i.e. people A follows.
    NSMutableSet<NSNumber*>* aActed = [NSMutableSet set];
    NSMutableSet<NSNumber*>* aBringers = [NSMutableSet set];
    long long newestA = 0;
    for (id item in aItems) {
        id model = unwrapDataViewItem(item);
        if (!IsStatusItem(model)) continue;
        if (BoolGetter(model, @"isPromoted")) continue;
        long long acted = ActedID(model);
        if (acted > 0) [aActed addObject:@(acted)];
        long long bringer = BringerID(model);
        if (bringer > 0) [aBringers addObject:@(bringer)];
        newestA = MAX(newestA, SortKey(model));
    }
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
    // A reaches further back than B: B loads its next page (7.3.141; X's own
    // load-more for the home tab does not go through loadBottomWithSource:).
    if (oldestB != LLONG_MAX && oldestA != LLONG_MAX && oldestA < oldestB) {
        LoadMoreB(gLastASource, @"A is older than B");
    }
    NSUInteger dupes = 0, older = 0, promoted = 0, followedByA = 0, newer = 0;
    for (id object in bObjects) {
        if (!IsStatusItem(object)) continue;
        if (BoolGetter(object, @"isPromoted")) {
            promoted++;
            continue;
        }
        long long statusID = NumberGetter(object, @"statusID");
        if (statusID <= 0) continue;
        long long acted = ActedID(object);
        if ([aIDs containsObject:@(statusID)] || (acted > 0 && [aActed containsObject:@(acted)])) {
            // A has this tweet (maybe through someone else's repost): shown once, A's copy.
            dupes++;
            [both addObject:@(statusID)];
            continue;
        }
        if (SortKey(object) <= oldestA) {
            older++;
            continue;
        }
        if (newestA > 0 && SortKey(object) > newestA) {
            // Newer than A's newest: A's next refresh (which refreshes B too) sorts it in.
            newer++;
            continue;
        }
        [bItems addObject:object];
        long long bringer = BringerID(object);
        if (bringer > 0 && [aBringers containsObject:@(bringer)]) {
            // A follows whoever brought it: both have it, A just has not loaded it.
            followedByA++;
            [both addObject:@(statusID)];
        } else {
            [bOnly addObject:@(statusID)];
        }
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
        // Seen again under this pair: no longer retired.
        [gRetiredIDs minusSet:bOnly];
        [gRetiredIDs minusSet:both];
        [gRetiredIDs minusSet:aOnly];
    }
    gLastMerge = [NSString stringWithFormat:@"A items=%lu blocks=%lu statuses=%lu (raw %lu, wrapped %lu) | B inserted=%lu "
                                            @"(followed by A %lu, newer than A %lu) "
                                            @"both=%lu olderThanA=%lu promoted=%lu leftOver=%lu | A outOfOrder=%lu",
                                            (unsigned long)aItems.count, (unsigned long)blocks.count,
                                            (unsigned long)best, (unsigned long)raw, (unsigned long)wrappedCount,
                                            (unsigned long)next, (unsigned long)followedByA, (unsigned long)newer,
                                            (unsigned long)dupes, (unsigned long)older,
                                            (unsigned long)promoted, (unsigned long)(bItems.count - next),
                                            (unsigned long)outOfOrder];
    NSMutableArray* result = [sections mutableCopy];
    result[target] = merged;
    return result;
}

static NSMutableArray<NSString*>* gMergeHistory;

static NSArray* SectionsForController(id controller, NSArray* sections) {
    if (!sections || !UnifiedActive() || !IsFollowingController(controller)) return sections;
    objc_setAssociatedObject(controller, kOriginalSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gFollowingControllers) gFollowingControllers = [NSHashTable weakObjectsHashTable];
    [gFollowingControllers addObject:controller];
    if (!BTimeline()) return sections;
    NSArray* result = sections;
    @try {
        result = MergedSections(controller, sections);
    } @catch (NSException* exception) {
        gLastMerge = [NSString stringWithFormat:@"merge threw %@", exception.name];
    }
    // The last few merges, to see what happened when the tab suddenly changes.
    if (!gMergeHistory) gMergeHistory = [NSMutableArray array];
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    [gMergeHistory addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], gLastMerge]];
    while (gMergeHistory.count > 6) [gMergeHistory removeObjectAtIndex:0];
    return result;
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

// Likes and reposts made as B in this session (gBLiked and friends, above), so a
// second tap undoes them.

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

// A reply composer opened within a few seconds of this, for one of these
// tweets, is switched to B.
static CFAbsoluteTime gComposeAsBUntil;
static NSSet<NSNumber*>* gComposeTargets;

static void ChooseAccount(NSString* title, NSString* message, void (^asAOrig)(void), void (^asBOrig)(void)) {
    // What was asked holds only for the accounts in use when it was asked.
    NSString* pairAtAsk = gPairKey;
    BOOL (^stillSame)(void) = ^BOOL {
        EnsurePair();
        if (UnifiedActive() && [gPairKey isEqualToString:pairAtAsk]) return YES;
        ShowNotice(@"계정이 바뀌어서 보내지 않았어요");
        UnifiedLog(@"choice dropped: account pair changed while asking");
        return NO;
    };
    void (^asA)(void) = ^{
        if (stillSame()) asAOrig();
    };
    void (^asB)(void) = ^{
        if (stillSame()) asBOrig();
    };
    UIAlertController* sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
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

static void RelayoutSoon(UIView* view);

static void MarkReplyAsB(id viewModel, long long statusID) {
    gComposeAsBUntil = CFAbsoluteTimeGetCurrent() + 6;
    gComposeTargets = [NSSet setWithObjects:@(statusID), @(NumberGetter(ActedStatus(viewModel), @"statusID")), nil];
    UnifiedLog(@"reply: composer will switch to B");
}

// YES when the tap was handled here (sent as B, a sheet shown, or stopped).
// `orig` runs X's own handling, which acts as A.
static BOOL HandleInlineAction(id actionsView, id button, void (^orig)(void)) {
    if (!UnifiedActive()) return NO;
    EnsurePair();
    NSString* buttonClass = NSStringFromClass([button class]);
    if ([buttonClass containsString:@"Share"] || [buttonClass containsString:@"Analytics"]) return NO;
    id viewModel = Getter(actionsView, @"viewModel");
    long long statusID = ViewModelStatusID(viewModel);
    if (statusID <= 0) return NO;
    BOOL bOnly = [gBOnlyIDs containsObject:@(statusID)];
    BOOL both = [gBothIDs containsObject:@(statusID)];
    BOOL aOnly = [gAOnlyIDs containsObject:@(statusID)];
    if (!bOnly && !both && !aOnly && [gRetiredIDs containsObject:@(statusID)]) {
        // Shown under the previous A/B pair: who it belongs to is not known now.
        gBlocked++;
        UnifiedLog(@"blocked a tap on a tweet from the previous account pair");
        ShowNotice(@"계정 설정이 바뀌어서 막았어요. 당겨서 새로고침한 뒤 다시 눌러주세요");
        return YES;
    }
    BOOL ask = both || (aOnly && [BHTSettings boolForKey:kUnifiedAlwaysAsk]);
    if (!bOnly && !ask) return NO;
    if (!BTimeline() || !gBAccount) {
        // Never let a tweet meant for B fall through to A.
        if (!bOnly) return NO;
        ShowNotice(@"B 계정을 찾지 못해서 막았어요");
        return YES;
    }

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
            MarkReplyAsB(viewModel, statusID);
            return NO;
        }
        gBlocked++;
        UnifiedLog([NSString stringWithFormat:@"blocked %@ on a B-only tweet", buttonClass]);
        ShowNotice(@"B 계정 트윗이에요. 이 버튼은 아직 B로 보낼 수 없어서 막아뒀어요.");
        return YES;
    }

    // Both have it (or "always ask"): like, repost and reply ask, A first.
    NSString* message = both ? @"두 계정 모두 이 게시물을 보고 있어요." : [NSString stringWithFormat:@"%@만 팔로우 중인 게시물이에요.", AName()];
    if (like) {
        __weak UIView* weakActions = (UIView*)actionsView;
        ChooseAccount(@"어느 계정으로 마음에 들어요할까요?", message, ^{
            orig();
            if (weakActions) RelayoutSoon(weakActions);
        }, ^{
            LikeAsB(viewModel);
            if (weakActions) RelayoutSoon(weakActions);
        });
        return YES;
    }
    if (repost) {
        ChooseAccount(@"어느 계정으로 재게시할까요?", message, orig, ^{
            RepostAsB(viewModel);
        });
        return YES;
    }
    if (reply) {
        ChooseAccount(@"어느 계정으로 답글할까요?", message, orig, ^{
            MarkReplyAsB(viewModel, statusID);
            orig();
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
static const NSInteger kCornerTag = 0x4E4643;
static const void* kNameColorKey = &kNameColorKey;

static UIColor* BColor(void) {
    NSString* hex = [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_color"] ?: @"FF7A00";
    unsigned int value = 0;
    if (hex.length != 6 || ![[NSScanner scannerWithString:hex] scanHexInt:&value]) value = 0xFF7A00;
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                           green:((value >> 8) & 0xFF) / 255.0
                            blue:(value & 0xFF) / 255.0
                           alpha:1];
}

// A tweet only B has: the display name in B's colour and a folded top-left
// corner. Anything else gets X's own colour back and no corner.
static void ApplyBMark(UIView* authorView, UIView* statusView, BOOL bOnly) {
    UIColor* color = bOnly ? BColor() : nil;
    for (UIView* view in authorView.subviews) {
        if (![view isKindOfClass:[UILabel class]] || ![view.accessibilityIdentifier isEqualToString:@"StatusFullname"]) {
            continue;
        }
        UILabel* name = (UILabel*)view;
        UIColor* saved = objc_getAssociatedObject(name, kNameColorKey);
        if (bOnly) {
            if (!saved) {
                objc_setAssociatedObject(name, kNameColorKey, name.textColor ?: [UIColor labelColor],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (![name.textColor isEqual:color]) name.textColor = color;
        } else if (saved) {
            name.textColor = saved;
            objc_setAssociatedObject(name, kNameColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (!statusView) return;
    UIView* corner = [statusView viewWithTag:kCornerTag];
    if (!bOnly) {
        corner.hidden = YES;
        return;
    }
    const CGFloat size = 11;
    if (!corner) {
        corner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
        corner.tag = kCornerTag;
        corner.userInteractionEnabled = NO;
        CAShapeLayer* flap = [CAShapeLayer layer];
        UIBezierPath* path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointZero];
        [path addLineToPoint:CGPointMake(size, 0)];
        [path addLineToPoint:CGPointMake(0, size)];
        [path closePath];
        flap.path = path.CGPath;
        // A faint shadow along the fold, like a page corner turned down.
        flap.shadowColor = [UIColor blackColor].CGColor;
        flap.shadowOpacity = 0.18;
        flap.shadowRadius = 0.8;
        flap.shadowOffset = CGSizeMake(0.6, 0.6);
        flap.shadowPath = path.CGPath;
        [corner.layer addSublayer:flap];
        [statusView addSubview:corner];
    }
    ((CAShapeLayer*)corner.layer.sublayers.firstObject).fillColor = color.CGColor;
    corner.frame = CGRectMake(0, 0, size, size);
    corner.hidden = NO;
    [statusView bringSubviewToFront:corner];
}

static void UpdateAccountBadge(UIView* authorView) {
    if (UnifiedActive()) EnsurePair();
    UIImageView* badge = [authorView viewWithTag:kBadgeTag];
    UIView* statusView = authorView.superview;
    while (statusView && ![NSStringFromClass([statusView class]) isEqualToString:@"T1StandardStatusView"]) {
        statusView = statusView.superview;
    }
    long long statusID = UnifiedActive() && statusView ? ViewModelStatusID(Getter(statusView, @"viewModel")) : 0;
    ApplyBMark(authorView, statusView, statusID > 0 && [gBOnlyIDs containsObject:@(statusID)]);
    id account = nil;
    NSString* letter = nil;
    UIColor* color = nil;
    if (statusID > 0 && [gBOnlyIDs containsObject:@(statusID)]) {
        account = gBAccount;
        letter = @"B";
        color = [UIColor colorWithRed:1 green:0.48 blue:0 alpha:1];
    }
    if (!letter) {
        badge.hidden = YES;
        return;
    }
    // 7.3.136: before the display name. The name line moves right to make room;
    // when it would then run into the menu button, the name gives up the width.
    UIView* name = nil;
    for (UIView* view in authorView.subviews) {
        if ([view.accessibilityIdentifier isEqualToString:@"StatusFullname"]) name = view;
    }
    if (!name || name.hidden || name.frame.size.width <= 0) {
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
    const CGFloat shift = 18;
    CGFloat width = authorView.bounds.size.width;
    CGFloat nameX = name.frame.origin.x;
    CGFloat nameEnd = CGRectGetMaxX(name.frame);
    // The line's own pieces start left of the right-hand buttons (menu, follow).
    NSMutableArray<UIView*>* line = [NSMutableArray array];
    CGFloat lineEnd = 0;
    for (UIView* view in authorView.subviews) {
        if (view == badge || view.hidden || view.frame.size.width <= 0) continue;
        if (view.frame.origin.x >= width - 40) continue;
        [line addObject:view];
        lineEnd = MAX(lineEnd, CGRectGetMaxX(view.frame));
    }
    CGFloat limit = width - 24;
    CGFloat overflow = MAX(0, lineEnd + shift - limit);
    overflow = MIN(overflow, MAX(0, name.frame.size.width - 30));
    for (UIView* view in line) {
        CGRect frame = view.frame;
        frame.origin.x += shift;
        if (view == name) {
            frame.size.width -= overflow;
        } else if (view.frame.origin.x >= nameEnd - 0.5) {
            frame.origin.x -= overflow;
        }
        view.frame = frame;
    }
    badge.image = AccountAvatar(account, letter, color);
    badge.hidden = NO;
    badge.frame = CGRectMake(nameX, CGRectGetMidY(name.frame) - 7, 14, 14);
}

NSString* NFBUnifiedTimelineDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedB];
    NSString* currentID = AccountUserID(CurrentAccount());
    [out appendFormat:@"mode=%d A=%@ (%@) unifiedActive=%d alwaysAsk=%d retired=%lu\n", UnifiedModeSelected(),
                      AID().length ? ([AID() isEqualToString:currentID] ? @"set, in use" : @"set, not in use") : @"none",
                      [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedAName] ?: @"-", UnifiedActive(),
                      [BHTSettings boolForKey:kUnifiedAlwaysAsk], (unsigned long)gRetiredIDs.count];
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
    [out appendFormat:@"wrapper: %@ bLoadMore=%lu\n", gTemplateNote, (unsigned long)gBBottomLoads];
    if (stream) {
        NSMutableArray* chain = [NSMutableArray array];
        NSMutableArray* loads = [NSMutableArray array];
        for (Class cls = [stream class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
            [chain addObject:NSStringFromClass(cls)];
            unsigned int count = 0;
            Method* methods = class_copyMethodList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                NSString* name = NSStringFromSelector(method_getName(methods[i]));
                if ([name rangeOfString:@"ottom"].location != NSNotFound || [name rangeOfString:@"lder"].location != NSNotFound ||
                    [name rangeOfString:@"oadMore"].location != NSNotFound) {
                    [loads addObject:[NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), name]];
                }
            }
            free(methods);
        }
        [out appendFormat:@"B stream: %@\n  load methods: %@\n", [chain componentsJoinedByString:@" < "],
                          loads.count ? [loads componentsJoinedByString:@" "] : @"(none)"];
    }
    [out appendFormat:@"merges:\n  %@\n", gMergeHistory.count ? [gMergeHistory componentsJoinedByString:@"\n  "] : @"(none)"];
    [out appendFormat:@"last merge: %@\nB-only ids=%lu both=%lu A-only=%lu blocked=%lu likedAsB=%lu repostedAsB=%lu\n",
                      gLastMerge, (unsigned long)gBOnlyIDs.count, (unsigned long)gBothIDs.count,
                      (unsigned long)gAOnlyIDs.count, (unsigned long)gBlocked, (unsigned long)gBLiked.count,
                      (unsigned long)gBReposted.count];
    @synchronized([NSObject class]) {
        [out appendFormat:@"%@\n", gUnifiedLog.count ? [gUnifiedLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

// MARK: - Who liked it (left of the heart)

static const NSInteger kLikeBadgeTag = 0x4E464C;  // "NFL"

static void UpdateLikeBadges(UIView* actionsView) {
    UIView* holder = [actionsView viewWithTag:kLikeBadgeTag];
    UIView* heart = nil;
    for (UIView* view in actionsView.subviews) {
        if ([NSStringFromClass([view class]) containsString:@"FavoriteButton"]) heart = view;
    }
    BOOL likedByA = NO, likedByB = NO;
    if (UnifiedActive() && heart && !heart.hidden) {
        EnsurePair();
        id viewModel = Getter(actionsView, @"viewModel");
        long long statusID = ViewModelStatusID(viewModel);
        id status = ActedStatus(viewModel);
        long long actedID = NumberGetter(status, @"statusID");
        BOOL loadingLiked = BoolGetter(status, @"favoritedByLoadingAccount") || BoolGetter(status, @"seenAsFavorited");
        BOOL bSaysLiked = [gBLiked containsObject:@(actedID)];
        BOOL bSaysUnliked = [gBUnliked containsObject:@(actedID)];
        if (statusID > 0 && [gBOnlyIDs containsObject:@(statusID)]) {
            // Loaded by B, so X's own flag is B's.
            likedByB = bSaysLiked || (!bSaysUnliked && loadingLiked);
        } else if (statusID > 0 && ([gBothIDs containsObject:@(statusID)] || [gAOnlyIDs containsObject:@(statusID)])) {
            // A's copy: X's own flag is A's; B's likes are the ones made here.
            likedByA = loadingLiked;
            likedByB = bSaysLiked;
        }
    }
    if (!likedByA && !likedByB) {
        holder.hidden = YES;
        return;
    }
    if (!holder) {
        holder = [UIView new];
        holder.tag = kLikeBadgeTag;
        holder.userInteractionEnabled = NO;
        [actionsView addSubview:holder];
    }
    [holder.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSMutableArray* accounts = [NSMutableArray array];
    if (likedByA) [accounts addObject:@[ CurrentAccount() ?: [NSNull null], @"A", [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1] ]];
    if (likedByB) [accounts addObject:@[ gBAccount ?: [NSNull null], @"B", [UIColor colorWithRed:1 green:0.48 blue:0 alpha:1] ]];
    const CGFloat size = 16, overlap = 5;
    CGFloat width = size + (accounts.count - 1) * (size - overlap);
    // The heart's picture sits 6pt into its button (TFNAnimatableButton's image).
    CGFloat heartX = CGRectGetMinX(heart.frame) + 6;
    holder.frame = CGRectMake(heartX - 3 - width, CGRectGetMidY(heart.frame) - size / 2, width, size);
    for (NSUInteger i = 0; i < accounts.count; i++) {
        id account = accounts[i][0] == [NSNull null] ? nil : accounts[i][0];
        UIImageView* picture = [[UIImageView alloc] initWithFrame:CGRectMake(i * (size - overlap), 0, size, size)];
        picture.image = AccountAvatar(account, accounts[i][1], accounts[i][2]);
        picture.contentMode = UIViewContentModeScaleAspectFill;
        picture.clipsToBounds = YES;
        picture.layer.cornerRadius = size / 2;
        picture.layer.borderWidth = 1;
        picture.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
        [holder addSubview:picture];
    }
    holder.hidden = NO;
    [actionsView bringSubviewToFront:holder];
}

static void RelayoutSoon(UIView* view) {
    __weak UIView* weakView = view;
    for (NSNumber* delay in @[ @0.15, @0.8 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakView setNeedsLayout];
                       });
    }
}

// MARK: - The dock's "A/B" circle (AccountBubbles.x)

// A and B for the dock: B from settings, A from settings or else the account in use.
BOOL NFBUnifiedDockPair(id* outA, id* outB) {
    if (![BHTSettings boolForKey:kUnifiedOn]) return NO;
    id b = AccountForID(BID());
    id current = CurrentAccount();
    id a = AID().length ? AccountForID(AID()) : current;
    if (!a || !b || [AccountUserID(a) isEqualToString:AccountUserID(b)]) return NO;
    if (outA) *outA = a;
    if (outB) *outB = b;
    return YES;
}

BOOL NFBUnifiedIsActive(void) {
    return UnifiedActive();
}

// The dock stopped on the "A/B" circle (unified YES, `a` is A) or on an account.
void NFBUnifiedDockChose(BOOL unified, id a) {
    if (![BHTSettings boolForKey:kUnifiedOn]) return;
    if (unified) {
        NSString* aID = AccountUserID(a);
        if (aID.length && AID().length == 0) {
            NSString* name = AccountUsername(a) ?: aID;
            [[NSUserDefaults standardUserDefaults] setObject:aID forKey:kUnifiedA];
            [[NSUserDefaults standardUserDefaults] setObject:[name hasPrefix:@"@"] ? name : [@"@" stringByAppendingString:name]
                                                      forKey:kUnifiedAName];
        }
    }
    if (UnifiedModeSelected() == unified && [[NSUserDefaults standardUserDefaults] objectForKey:kUnifiedMode]) return;
    SetUnifiedMode(unified);
    UnifiedLog(unified ? @"dock: A/B chosen, unified on" : @"dock: an account chosen, unified off");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ReapplyMerge();
        if (unified && UnifiedActive()) {
            gBLastRefresh = 0;
            RefreshB(101, @"A/B chosen");
        }
    });
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

static void LoadMoreB(long long source, NSString* why) {
    id bStream = Getter(gBTimeline, @"stream");
    if (!bStream || CFAbsoluteTimeGetCurrent() - gBLastBottom < 5) return;
    gBLastBottom = CFAbsoluteTimeGetCurrent();
    SEL selector = NSSelectorFromString(@"loadBottomWithSource:");
    if (![bStream respondsToSelector:selector]) {
        UnifiedLog(@"B stream has no loadBottomWithSource:");
        return;
    }
    @try {
        BOOL started = ((BOOL (*)(id, SEL, long long))objc_msgSend)(bStream, selector, source);
        gBBottomLoads++;
        UnifiedLog([NSString stringWithFormat:@"B more (%@, source %lld) started=%d", why, source, started]);
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"B load more threw %@", exception.name]);
    }
}

// A's Following stream loaded more: load more of B's too (at most every 5s).
static void FollowBottomLoad(id stream, long long source) {
    if (!UnifiedActive()) return;
    id bStream = Getter(gBTimeline, @"stream");
    if (!bStream || stream == bStream) return;
    BOOL following = NO;
    for (id timeline in [gFollowingTimelines allObjects]) {
        if (Getter(timeline, @"stream") == stream && Getter(timeline, @"account") == CurrentAccount()) following = YES;
    }
    if (following) LoadMoreB(source, @"A loaded more");
}

// The home stream may override it without calling super, so both.
%hook TFSTwitterStream
- (BOOL)loadBottomWithSource:(long long)source {
    BOOL result = %orig;
    FollowBottomLoad(self, source);
    return result;
}
%end

%hook THFURTHomeTimelineStream
- (BOOL)loadBottomWithSource:(long long)source {
    BOOL result = %orig;
    FollowBottomLoad(self, source);
    return result;
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

- (void)layoutSubviews {
    %orig;
    UIView* view = (UIView*)self;
    if (UnifiedActive() || [view viewWithTag:kLikeBadgeTag]) UpdateLikeBadges(view);
}

- (void)didTapInlineActionButton:(id)button {
    if ([NSStringFromClass([button class]) containsString:@"Favorite"]) RelayoutSoon((UIView*)self);
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
static void CollectControllers(UIViewController* controller, NSString* className, NSMutableArray* found) {
    if (!controller) return;
    if ([NSStringFromClass([controller class]) isEqualToString:className]) [found addObject:controller];
    for (UIViewController* child in controller.childViewControllers) CollectControllers(child, className, found);
}

// 7.3.136: in 7.3.135 setAccount: on the composer took (the "private reply"
// notice came from B) but the avatar stayed A, because the account picker's own
// path goes through the single-tweet controller: -[T1TweetComposeSingleTweetViewController
// setAccount:] then -[T1TweetComposeTableViewController singleTweetViewController:
// didSwitchToAccount:]. Do the same, then check every piece shows B.
static void SwitchComposerToB(UIViewController* composer) {
    SEL setAccount = NSSelectorFromString(@"setAccount:");
    NSMutableArray* singles = [NSMutableArray array];
    NSMutableArray* tables = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeSingleTweetViewController", singles);
    CollectControllers(composer, @"T1TweetComposeTableViewController", tables);
    SEL didSwitch = NSSelectorFromString(@"singleTweetViewController:didSwitchToAccount:");
    for (id single in singles) {
        if ([single respondsToSelector:setAccount]) ((void (*)(id, SEL, id))objc_msgSend)(single, setAccount, gBAccount);
        id avatar = Getter(single, @"avatarImageView");
        if ([avatar respondsToSelector:setAccount]) ((void (*)(id, SEL, id))objc_msgSend)(avatar, setAccount, gBAccount);
        for (id table in tables) {
            if ([table respondsToSelector:didSwitch]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(table, didSwitch, single, gBAccount);
            }
        }
    }
    for (id table in tables) {
        if (Getter(table, @"account") != gBAccount && [table respondsToSelector:setAccount]) {
            ((void (*)(id, SEL, id))objc_msgSend)(table, setAccount, gBAccount);
        }
    }
    if (Getter(composer, @"account") != gBAccount && [composer respondsToSelector:setAccount]) {
        ((void (*)(id, SEL, id))objc_msgSend)(composer, setAccount, gBAccount);
    }
    BOOL composerB = Getter(composer, @"account") == gBAccount;
    NSUInteger singlesB = 0, tablesB = 0, avatarsB = 0;
    for (id single in singles) {
        if (Getter(single, @"account") == gBAccount) singlesB++;
        if (Getter(Getter(single, @"avatarImageView"), @"account") == gBAccount) avatarsB++;
    }
    for (id table in tables) {
        if (Getter(table, @"account") == gBAccount) tablesB++;
    }
    BOOL all = composerB && singles.count && singlesB == singles.count && tablesB == tables.count &&
               avatarsB == singles.count;
    UnifiedLog([NSString stringWithFormat:@"composer to B: composer=%d single=%lu/%lu table=%lu/%lu avatar=%lu/%lu",
                                          composerB, (unsigned long)singlesB, (unsigned long)singles.count,
                                          (unsigned long)tablesB, (unsigned long)tables.count, (unsigned long)avatarsB,
                                          (unsigned long)singles.count]);
    ShowNotice(all ? [NSString stringWithFormat:@"%@로 답글을 써요. 왼쪽 위 프로필이 %@인지 확인해주세요", BName(), BName()]
                   : @"B로 다 바꾸지 못했어요. 왼쪽 위 프로필을 눌러 직접 바꿔주세요");
}

static const void* kIntendedBKey = &kIntendedBKey;

// The tweet a reply composer answers, from its reply-context controller.
static long long ReplyTargetID(UIViewController* composer) {
    NSMutableArray* contexts = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeReplyContextViewController", contexts);
    for (id context in contexts) {
        long long statusID = NumberGetter(Getter(context, @"status"), @"statusID");
        if (statusID > 0) return statusID;
    }
    return 0;
}

// Every account the composer carries, and whether they are all `account`.
static BOOL ComposerIsAll(UIViewController* composer, id account, NSString** detail) {
    NSMutableArray* singles = [NSMutableArray array];
    NSMutableArray* tables = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeSingleTweetViewController", singles);
    CollectControllers(composer, @"T1TweetComposeTableViewController", tables);
    NSMutableArray* wrong = [NSMutableArray array];
    if (Getter(composer, @"account") != account) [wrong addObject:@"composer"];
    if (singles.count == 0) [wrong addObject:@"no single"];
    for (id single in singles) {
        if (Getter(single, @"account") != account) [wrong addObject:@"single"];
        if (Getter(Getter(single, @"avatarImageView"), @"account") != account) [wrong addObject:@"avatar"];
    }
    for (id table in tables) {
        if (Getter(table, @"account") != account) [wrong addObject:@"table"];
    }
    if (detail) *detail = wrong.count ? [wrong componentsJoinedByString:@","] : @"all";
    return wrong.count == 0;
}

static void StopSend(UIViewController* composer, NSString* why) {
    UnifiedLog([NSString stringWithFormat:@"send stopped: %@", why]);
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:@"보내지 않았어요"
                                            message:[NSString stringWithFormat:@"이 답글은 %@로 보내야 하는데 작성 화면 일부가 다른 계정이에요. "
                                                                               @"글은 그대로 있어요. 왼쪽 위 프로필을 눌러 %@를 직접 골라주세요.",
                                                                               BName(), BName()]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleDefault handler:nil]];
    [composer presentViewController:alert animated:YES completion:nil];
}

// Last check before anything leaves a composer meant for B: every piece must be B.
static BOOL SendAllowed(UIViewController* composer) {
    if (![objc_getAssociatedObject(composer, kIntendedBKey) boolValue]) return YES;
    NSString* detail = nil;
    if (gBAccount && ComposerIsAll(composer, gBAccount, &detail)) {
        UnifiedLog(@"send as B: all pieces B");
        return YES;
    }
    StopSend(composer, detail ?: @"no B account");
    return NO;
}

%hook T1TweetComposeViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController* composer = (UIViewController*)self;
    if (CFAbsoluteTimeGetCurrent() > gComposeAsBUntil || !gBAccount) return;
    gComposeAsBUntil = 0;
    NSSet* targets = gComposeTargets;
    gComposeTargets = nil;
    // Only the reply to the tapped tweet; any other composer stays as it is.
    long long target = ReplyTargetID(composer);
    if (target <= 0 || ![targets containsObject:@(target)]) {
        UnifiedLog([NSString stringWithFormat:@"composer not switched: reply target %@", target > 0 ? @"differs" : @"unknown"]);
        if (target > 0 || targets.count) {
            ShowNotice(@"B로 바꾸지 않았어요. 이 답글은 지금 계정으로 열렸어요");
        }
        return;
    }
    objc_setAssociatedObject(composer, kIntendedBKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SwitchComposerToB(composer);
}

- (void)_t1_checkForValidTweetsAndSend {
    if (!SendAllowed((UIViewController*)self)) return;
    %orig;
}

- (void)_t1_sendCompositions:(id)compositions {
    if (!SendAllowed((UIViewController*)self)) return;
    %orig;
}

- (void)_t1_didTapSendButton:(id)sender {
    if (!SendAllowed((UIViewController*)self)) return;
    %orig;
}

- (void)composerGlassHeaderDidTapPost:(id)header {
    if (!SendAllowed((UIViewController*)self)) return;
    %orig;
}

- (void)composerToolbarDidTapPost:(id)toolbar {
    if (!SendAllowed((UIViewController*)self)) return;
    %orig;
}

- (void)handleSendTweetKeyCommand {
    if (!SendAllowed((UIViewController*)self)) return;
    %orig;
}

%end

%ctor {
    // The first B load happens once the Following tab has been set up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (UnifiedActive()) RefreshB(101, @"launch");
    });
}
