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
//  - 7.3.142, For You: B's For You (-[T1TimelineFactory homeTimelineForAccount:])
//    is loaded with A's For You and mixed in half and half: one of B's after each
//    of A's (their accounts follow mostly the same people). Same marks and
//    reactions as the Following tab; B's ads are left out.
//  - 7.3.142, composer: under the avatar the other account (A or B) shows small
//    and dim; tapping it switches the composer, and that account is then the one
//    every send path checks for. X's own account picker sets it too.
//  - 7.3.143: X lets nobody repost a protected account's tweet, but the toast
//    said it went out; reposting one is stopped with a notice now, and the
//    toasts say a request was sent, not that it worked. A's tweet screen cannot
//    open a protected tweet only B can see; tapping one offers to switch to B.
//    Bookmarks: B's own T1BookmarksManager (initWithAccount:) adds and removes
//    them as B on tweets only B has; on tweets both have it asks.
//  - 7.3.144: a tweet only B has opens its tweet screen as B: X's own
//    T1ConversationContainerViewController init gets B's account instead of A's,
//    and B's picture sits next to the back button. Inside such a screen like,
//    repost and bookmark are sent with B's account by this file (whatever X
//    would pick), and a reply composer is switched to B with the send check on.
//    The 7.3.143 "switch to B?" prompt for protected tweets is gone.
//  - 7.3.147: B's colour can be X's theme colour or any colour from a picker.
//    B's For You marks (and B reactions) only where B follows whoever brought
//    the tweet; a tweet B was only recommended is plain and reacts as A. The
//    composer's account switch springs a liquid ring between the pictures.
//    Bookmarks as B: the manager's account is an ivar without a getter.
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
static NSHashTable* gForYouTimelines;   // A's For You timelines, from X's factory
static id gBForYouTimeline;
static id gBForYouAccount;
static CFAbsoluteTime gBForYouLastRefresh;
static NSMutableSet<NSNumber*>* gAFollowedBringers;  // people A's Following tab shows A follows
static NSString* gLastForYouMerge = @"(no For You merge yet)";
// Of B's own tweets: the reposts (the "reposted" line gets B's colour) and the
// ones whose display name does (the author only B follows).
static NSMutableSet<NSNumber*>* gBRepostLineIDs;
static NSMutableSet<NSNumber*>* gBNameIDs;
// Who each account follows, from its own Following list (UnifiedFollowSync.x).
static NSMutableDictionary<NSString*, NSSet<NSNumber*>*>* gKnownFollows;
static void ReapplyMerge(void);
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
    [gAFollowedBringers removeAllObjects];
    [gBRepostLineIDs removeAllObjects];
    [gBNameIDs removeAllObjects];
    // Who A follows, as learnt from A's own timelines earlier (kept per A).
    NSString* aID = AccountUserID(CurrentAccount());
    NSArray* known = aID ? [[NSUserDefaults standardUserDefaults] arrayForKey:[@"kemo_unified_a_follows_" stringByAppendingString:aID]] : nil;
    if (!gAFollowedBringers) gAFollowedBringers = [NSMutableSet set];
    for (id userID in known) {
        if ([userID isKindOfClass:[NSNumber class]]) [gAFollowedBringers addObject:userID];
    }
    if (aID && gKnownFollows[aID]) [gAFollowedBringers unionSet:gKnownFollows[aID]];
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

// B's For You, made like B's Following timeline.
static id BForYouTimeline(void) {
    if (!BTimeline() || !gBAccount) return nil;
    if (gBForYouTimeline && gBForYouAccount == gBAccount) return gBForYouTimeline;
    Class factoryClass = objc_getClass("T1TimelineFactory");
    if (!factoryClass || ![factoryClass respondsToSelector:@selector(sharedTimelineFactory)]) return nil;
    id factory = ((id (*)(id, SEL))objc_msgSend)(factoryClass, @selector(sharedTimelineFactory));
    SEL selector = NSSelectorFromString(@"homeTimelineForAccount:");
    if (![factory respondsToSelector:selector]) return nil;
    id timeline = nil;
    gMakingB = YES;
    @try {
        timeline = ((id (*)(id, SEL, id))objc_msgSend)(factory, selector, gBAccount);
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
    gBForYouTimeline = timeline;
    gBForYouAccount = gBAccount;
    gBForYouLastRefresh = 0;
    UnifiedLog([NSString stringWithFormat:@"B For You made, stream %@", Getter(timeline, @"stream") ? @"set" : @"nil"]);
    return timeline;
}

static void RefreshBForYou(long long source) {
    id timeline = BForYouTimeline();
    SEL refresh = NSSelectorFromString(@"refreshWithSource:completion:");
    if (!timeline || ![timeline respondsToSelector:refresh]) return;
    if (CFAbsoluteTimeGetCurrent() - gBForYouLastRefresh < 3) return;
    gBForYouLastRefresh = CFAbsoluteTimeGetCurrent();
    UnifiedLog([NSString stringWithFormat:@"refresh B For You (source %lld)", source]);
    void (^completion)(void) = ^{
    };
    @try {
        ((void (*)(id, SEL, long long, id))objc_msgSend)(timeline, refresh, source, completion);
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"refresh B For You threw %@", exception.name]);
    }
}

static id ControllerTimeline(id controller) {
    if (![NSStringFromClass([controller class]) isEqualToString:@"THFHomeTimelineItemsViewController"]) return nil;
    Ivar ivar = class_getInstanceVariable([controller class], "_timeline");
    return ivar ? object_getIvar(controller, ivar) : nil;
}

static BOOL IsForYouController(id controller) {
    id timeline = ControllerTimeline(controller);
    return timeline && [gForYouTimelines containsObject:timeline] && ![gFollowingTimelines containsObject:timeline];
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
    // 7.3.143: for a repost the item's statusID can be the original's, so a
    // repost from an hour ago of yesterday's tweet sorted as yesterday and
    // dropped B's tweets in early. The latest of the IDs the item carries (the
    // repost's own, its entry ID's) is when it reached the timeline.
    long long key = NumberGetter(item, @"statusID");
    key = MAX(key, NumberGetter(Getter(item, @"status"), @"statusID"));
    id entryID = Getter(item, @"entryID");
    if ([entryID isKindOfClass:[NSString class]]) {
        // The first long run of digits only ("tweet-123", "home-conversation-123-...").
        for (NSString* part in [entryID componentsSeparatedByCharactersInSet:
                                            [[NSCharacterSet decimalDigitCharacterSet] invertedSet]]) {
            if (part.length >= 10 && part.length <= 19) {
                key = MAX(key, part.longLongValue);
                break;
            }
        }
    }
    return key;
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
    // Authors A follows too (A's own follow state of the author it shows).
    for (id item in aItems) {
        id model = unwrapDataViewItem(item);
        if (!IsStatusItem(model) || BoolGetter(model, @"isPromoted")) continue;
        if (NumberGetter(model, @"representedFromUserFollowedByCurrentAccountState") == 1) {
            long long author = NumberGetter(ActedStatusOf(model), @"fromUserID");
            if (author > 0) [aBringers addObject:@(author)];
        }
    }
    if (!gAFollowedBringers) gAFollowedBringers = [NSMutableSet set];
    NSUInteger before = gAFollowedBringers.count;
    [gAFollowedBringers unionSet:aBringers];
    [aBringers unionSet:gAFollowedBringers];
    NSString* aIDForSave = AccountUserID(CurrentAccount());
    if (aIDForSave && gAFollowedBringers.count != before) {
        NSArray* save = [gAFollowedBringers allObjects];
        if (save.count > 8000) save = [save subarrayWithRange:NSMakeRange(0, 8000)];
        [[NSUserDefaults standardUserDefaults] setObject:save forKey:[@"kemo_unified_a_follows_" stringByAppendingString:aIDForSave]];
    }
    NSArray<NSArray*>* blocks = Blocks(aItems);
    // Each block's place in time, never older than anything below it: one old
    // key in the middle (an odd item) cannot pull B's tweets up early.
    NSMutableArray<NSNumber*>* places = [NSMutableArray arrayWithCapacity:blocks.count];
    for (NSUInteger i = 0; i < blocks.count; i++) [places addObject:@0];
    // First the median of each block's neighbourhood (5 blocks), so a single
    // odd key either way does not count; then never older than what is below.
    NSMutableArray<NSNumber*>* keys = [NSMutableArray arrayWithCapacity:blocks.count];
    for (NSArray* block in blocks) [keys addObject:@(BlockKey(block))];
    long long below = 0;
    for (NSInteger i = (NSInteger)blocks.count - 1; i >= 0; i--) {
        long long key = keys[i].longLongValue;
        if (key <= 0) continue;
        NSMutableArray<NSNumber*>* window = [NSMutableArray array];
        for (NSInteger j = MAX(0, i - 2); j <= MIN((NSInteger)blocks.count - 1, i + 2); j++) {
            if (keys[j].longLongValue > 0) [window addObject:keys[j]];
        }
        [window sortUsingSelector:@selector(compare:)];
        long long smooth = window.count ? window[window.count / 2].longLongValue : key;
        below = MAX(below, smooth);
        places[i] = @(below);
    }
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
            // A follows whoever brought it (the reposter for a repost): both have it.
            followedByA++;
            [both addObject:@(statusID)];
        } else {
            [bOnly addObject:@(statusID)];
            // Two separate things: who follows the reposter (why it is here) and
            // who follows the author. A repost is here for its reposter, so its
            // "reposted" line is B's; the name is B's only when B follows the
            // author and A is not known to.
            id status = Getter(object, @"status");
            long long acted = ActedID(object);
            BOOL repost = Getter(status, @"representedStatus") != nil || (acted > 0 && acted != statusID);
            long long author = NumberGetter(ActedStatusOf(object), @"fromUserID");
            BOOL bFollowsAuthor = NumberGetter(object, @"representedFromUserFollowedByCurrentAccountState") == 1 ||
                                  (BID() && [gKnownFollows[BID()] containsObject:@(author)]);
            if (!gBRepostLineIDs) gBRepostLineIDs = [NSMutableSet set];
            if (!gBNameIDs) gBNameIDs = [NSMutableSet set];
            if (!repost) {
                [gBNameIDs addObject:@(statusID)];
            } else {
                [gBRepostLineIDs addObject:@(statusID)];
                if (bFollowsAuthor && ![aBringers containsObject:@(author)]) [gBNameIDs addObject:@(statusID)];
                else [gBNameIDs removeObject:@(statusID)];
            }
        }
    }
    [bItems sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [@(SortKey(b)) compare:@(SortKey(a))];
    }];

    NSMutableArray* merged = [NSMutableArray arrayWithCapacity:aItems.count + bItems.count];
    NSUInteger next = 0, outOfOrder = 0;
    long long previous = LLONG_MAX;
    for (NSUInteger i = 0; i < blocks.count; i++) {
        NSArray* block = blocks[i];
        long long key = BlockKey(block);
        if (key > 0) {
            if (key > previous) outOfOrder++;
            previous = key;
            long long place = places[i].longLongValue;
            while (next < bItems.count && SortKey(bItems[next]) > place) {
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

// A's For You with B's mixed in half and half: after each of A's blocks that
// holds a tweet, one of B's (in B's own order). B's ads and tweets A already
// has are left out; what is left over waits for A to load more.
static NSArray* MergedForYou(id controller, NSArray* sections) {
    EnsurePair();
    id bObjects = Getter(Getter(gBForYouTimeline, @"stream"), @"streamObjects");
    if (![bObjects isKindOfClass:[NSArray class]] || [bObjects count] == 0) {
        gLastForYouMerge = @"B For You empty";
        return sections;
    }
    NSUInteger target = NSNotFound, best = 0;
    for (NSUInteger i = 0; i < sections.count; i++) {
        if (![sections[i] isKindOfClass:[NSArray class]]) continue;
        NSUInteger count = 0;
        for (id item in sections[i]) {
            if (IsStatusItem(unwrapDataViewItem(item))) count++;
        }
        if (count > best) {
            best = count;
            target = i;
        }
    }
    if (target == NSNotFound || best < 5) {
        gLastForYouMerge = [NSString stringWithFormat:@"A For You has %lu statuses; not merging", (unsigned long)best];
        return sections;
    }
    NSArray* aItems = sections[target];
    NSMutableSet<NSNumber*>* aIDs = [NSMutableSet set];
    NSMutableSet<NSNumber*>* aActed = [NSMutableSet set];
    for (id item in aItems) {
        id model = unwrapDataViewItem(item);
        CollectStatusIDs(model, aIDs, 0);
        long long acted = IsStatusItem(model) ? ActedID(model) : 0;
        if (acted > 0) [aActed addObject:@(acted)];
    }
    NSMutableArray* bItems = [NSMutableArray array];
    NSMutableSet<NSNumber*>* bOnly = [NSMutableSet set];
    NSMutableSet<NSNumber*>* both = [NSMutableSet set];
    NSUInteger dupes = 0, ads = 0, followedByA = 0;
    for (id object in bObjects) {
        if (!IsStatusItem(object)) continue;
        if (BoolGetter(object, @"isPromoted")) {
            ads++;
            continue;
        }
        long long statusID = NumberGetter(object, @"statusID");
        if (statusID <= 0) continue;
        long long acted = ActedID(object);
        if ([aIDs containsObject:@(statusID)] || (acted > 0 && [aActed containsObject:@(acted)])) {
            dupes++;
            [both addObject:@(statusID)];
            continue;
        }
        [bItems addObject:object];
        // 7.3.147: B's For You is recommendations; marks and B reactions only
        // when B follows whoever brought it and A does not. A tweet B was only
        // recommended is shown plain and reacted to like any of A's.
        long long bringer = BringerID(object);
        BOOL repost = Getter(Getter(object, @"status"), @"representedStatus") != nil ||
                      (acted > 0 && acted != statusID);
        BOOL bFollows = (bringer > 0 && BID() && [gKnownFollows[BID()] containsObject:@(bringer)]) ||
                        (!repost && NumberGetter(object, @"representedFromUserFollowedByCurrentAccountState") == 1);
        if (bringer > 0 && [gAFollowedBringers containsObject:@(bringer)]) {
            followedByA++;
            [both addObject:@(statusID)];
        } else if (bFollows) {
            [bOnly addObject:@(statusID)];
        }
    }
    NSArray<NSArray*>* blocks = Blocks(aItems);
    NSMutableArray* merged = [NSMutableArray arrayWithCapacity:aItems.count + bItems.count];
    NSUInteger next = 0;
    for (NSArray* block in blocks) {
        [merged addObjectsFromArray:block];
        if (BlockKey(block) > 0 && next < bItems.count) [merged addObject:bItems[next++]];
    }
    // Only what was shown counts; the rest is not on screen yet.
    NSMutableSet<NSNumber*>* shownOnly = [NSMutableSet set];
    if (!gBRepostLineIDs) gBRepostLineIDs = [NSMutableSet set];
    if (!gBNameIDs) gBNameIDs = [NSMutableSet set];
    for (NSUInteger i = 0; i < next; i++) {
        id object = bItems[i];
        NSNumber* statusID = @(NumberGetter(object, @"statusID"));
        if (![bOnly containsObject:statusID]) continue;
        [shownOnly addObject:statusID];
        long long acted = ActedID(object);
        BOOL repost = Getter(Getter(object, @"status"), @"representedStatus") != nil ||
                      (acted > 0 && acted != statusID.longLongValue);
        long long author = NumberGetter(ActedStatusOf(object), @"fromUserID");
        if (!repost) {
            [gBNameIDs addObject:statusID];
        } else {
            [gBRepostLineIDs addObject:statusID];
            BOOL bFollowsAuthor = NumberGetter(object, @"representedFromUserFollowedByCurrentAccountState") == 1;
            if (bFollowsAuthor && ![gAFollowedBringers containsObject:@(author)]) [gBNameIDs addObject:statusID];
        }
    }
    @synchronized([NSObject class]) {
        if (!gBOnlyIDs) gBOnlyIDs = [NSMutableSet set];
        if (!gBothIDs) gBothIDs = [NSMutableSet set];
        [gBOnlyIDs unionSet:shownOnly];
        [gBothIDs unionSet:both];
        [gBOnlyIDs minusSet:both];
        [gRetiredIDs minusSet:shownOnly];
        [gRetiredIDs minusSet:both];
    }
    gLastForYouMerge = [NSString stringWithFormat:@"A statuses=%lu blocks=%lu | B inserted=%lu of %lu (followed by A %lu) "
                                                 @"same as A=%lu ads=%lu",
                                                 (unsigned long)best, (unsigned long)blocks.count, (unsigned long)next,
                                                 (unsigned long)bItems.count, (unsigned long)followedByA,
                                                 (unsigned long)dupes, (unsigned long)ads];
    if (next >= bItems.count && blocks.count > bItems.count) {
        // B ran out before A did: B's next page.
        id bStream = Getter(gBForYouTimeline, @"stream");
        SEL more = NSSelectorFromString(@"loadBottomWithSource:");
        static CFAbsoluteTime last;
        if (bStream && [bStream respondsToSelector:more] && CFAbsoluteTimeGetCurrent() - last > 5) {
            last = CFAbsoluteTimeGetCurrent();
            @try {
                BOOL started = ((BOOL (*)(id, SEL, long long))objc_msgSend)(bStream, more, gLastASource);
                UnifiedLog([NSString stringWithFormat:@"B For You more started=%d", started]);
            } @catch (__unused NSException* exception) {
            }
        }
    }
    NSMutableArray* result = [sections mutableCopy];
    result[target] = merged;
    return result;
}

static NSMutableArray<NSString*>* gMergeHistory;

static NSArray* SectionsForController(id controller, NSArray* sections) {
    if (!sections || !UnifiedActive()) return sections;
    if (IsForYouController(controller)) {
        objc_setAssociatedObject(controller, kOriginalSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gFollowingControllers) gFollowingControllers = [NSHashTable weakObjectsHashTable];
        [gFollowingControllers addObject:controller];
        if (!BForYouTimeline()) return sections;
        @try {
            return MergedForYou(controller, sections);
        } @catch (NSException* exception) {
            gLastForYouMerge = [NSString stringWithFormat:@"For You merge threw %@", exception.name];
            return sections;
        }
    }
    if (!IsFollowingController(controller)) return sections;
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
        ShowNotice([NSString stringWithFormat:@"%@의 마음에 들어요 취소를 보냈어요", BName()]);
    } else {
        CallStatusMethod(gBAccount, @"favoriteStatusWithStatusID:responseBlock:", statusID);
        [gBLiked addObject:@(statusID)];
        [gBUnliked removeObject:@(statusID)];
        ShowNotice([NSString stringWithFormat:@"♥ %@로 마음에 들어요를 보냈어요", BName()]);
    }
    UnifiedLog([NSString stringWithFormat:@"%@ as B", liked ? @"unlike" : @"like"]);
}

static BOOL IsProtectedStatus(id status) {
    return BoolGetter(Getter(status, @"fromUser"), @"protectedUser");
}

static NSMutableSet<NSNumber*>* gBBookmarked;
static NSMutableSet<NSNumber*>* gBUnbookmarked;

static void BookmarkAsB(id viewModel, UIView* sourceView) {
    id status = ActedStatus(viewModel);
    long long statusID = NumberGetter(status, @"statusID");
    Class managerClass = objc_getClass("T1BookmarksManager");
    if (statusID <= 0 || !gBAccount || !status) return;
    if (!managerClass) {
        ShowNotice(@"이 X 버전에서는 B로 북마크할 수 없어요.");
        return;
    }
    if (!gBBookmarked) gBBookmarked = [NSMutableSet set];
    if (!gBUnbookmarked) gBUnbookmarked = [NSMutableSet set];
    BOOL marked = [gBBookmarked containsObject:@(statusID)] ||
                  (![gBUnbookmarked containsObject:@(statusID)] && BoolGetter(status, @"bookmarkedByLoadingAccount"));
    id manager = nil;
    @try {
        manager = ((id (*)(id, SEL, id))objc_msgSend)([managerClass alloc], NSSelectorFromString(@"initWithAccount:"), gBAccount);
    } @catch (__unused NSException* exception) {
    }
    // The manager must be B's; anything else and nothing is sent. 7.3.147:
    // its account is a plain ivar with no getter (7.3.143 read nil and stopped
    // every bookmark), so read the ivar.
    id managerAccount = Getter(manager, @"account") ?: objectIvar(manager, "account");
    if (!manager || (managerAccount && ![AccountUserID(managerAccount) isEqualToString:AccountUserID(gBAccount)])) {
        UnifiedLog(@"bookmark as B stopped: manager is not B's");
        ShowNotice(@"B 계정으로 확실히 보낼 수 없어서 북마크를 막았어요");
        return;
    }
    if (!managerAccount) UnifiedLog(@"bookmark manager account unreadable; it was made with B's account");
    void (^completion)(void) = ^{
    };
    @try {
        if (marked) {
            SEL remove = NSSelectorFromString(@"removeStatusFromBookmarks:withScribeContext:completion:");
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, remove, status, nil, completion);
            [gBBookmarked removeObject:@(statusID)];
            [gBUnbookmarked addObject:@(statusID)];
            ShowNotice([NSString stringWithFormat:@"%@의 북마크 해제를 보냈어요", BName()]);
        } else {
            SEL add = NSSelectorFromString(@"addStatusToBookmarks:sourceView:withScribeContext:completion:");
            ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(manager, add, status, sourceView, nil, completion);
            [gBBookmarked addObject:@(statusID)];
            [gBUnbookmarked removeObject:@(statusID)];
            ShowNotice([NSString stringWithFormat:@"🔖 %@로 북마크를 보냈어요", BName()]);
        }
        UnifiedLog(marked ? @"unbookmark as B" : @"bookmark as B");
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"bookmark as B threw %@", exception.name]);
        ShowNotice(@"B로 북마크하지 못했어요");
    }
}

extern BOOL NFBUnifiedUndoRepostAsB(id bAccount, id status, NSString** why);
extern NSString* NFBUnifiedRepostDebugText(void);

// The tweet (the original, for a repost) as B's own streams have it.
static id BStatusFor(long long actedID) {
    if (actedID <= 0) return nil;
    for (id timeline in @[ gBTimeline ?: [NSNull null], gBForYouTimeline ?: [NSNull null] ]) {
        if (timeline == [NSNull null]) continue;
        id objects = Getter(Getter(timeline, @"stream"), @"streamObjects");
        if (![objects isKindOfClass:[NSArray class]]) continue;
        for (id object in objects) {
            if (IsStatusItem(object) && ActedID(object) == actedID) return ActedStatusOf(object);
        }
    }
    return nil;
}

static void RepostAsB(id viewModel) {
    id status = ActedStatus(viewModel);
    long long statusID = NumberGetter(status, @"statusID");
    if (statusID <= 0 || !gBAccount) return;
    if (IsProtectedStatus(status)) {
        // X does not let anyone repost a protected account's tweet.
        UnifiedLog(@"repost as B stopped: protected");
        ShowNotice(@"비공개 계정의 게시물은 재게시할 수 없어요");
        return;
    }
    if (!gBReposted) gBReposted = [NSMutableSet set];
    // B's own copy of the tweet: the one on screen may be A's, whose repost
    // state is A's (7.3.145).
    id bStatus = BStatusFor(statusID);
    BOOL reposted = [gBReposted containsObject:@(statusID)] || BoolGetter(bStatus, @"seenAsRetweeted");
    if (reposted) {
        NSString* why = nil;
        if (NFBUnifiedUndoRepostAsB(gBAccount, bStatus ?: status, &why)) {
            [gBReposted removeObject:@(statusID)];
            ShowNotice([NSString stringWithFormat:@"%@의 재게시 취소를 보냈어요", BName()]);
            UnifiedLog(@"unrepost as B");
        } else {
            ShowNotice(why ?: [NSString stringWithFormat:@"%@의 재게시 취소는 %@로 전환해서 해주세요", BName(), BName()]);
        }
        return;
    }
    CallStatusMethod(gBAccount, @"retweetWithStatusID:responseBlock:", statusID);
    [gBReposted addObject:@(statusID)];
    ShowNotice([NSString stringWithFormat:@"🔁 %@로 재게시를 보냈어요", BName()]);
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
// A tweet screen opened as B (see the T1ConversationContainerViewController hook).
static BOOL IsBScreen(UIViewController* controller) {
    return gBAccount && Getter(controller, @"account") == gBAccount && CurrentAccount() != gBAccount &&
           [NSStringFromClass([controller class]) isEqualToString:@"T1ConversationContainerViewController"];
}

static BOOL IsInBScreen(UIView* view) {
    for (UIResponder* responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            for (UIViewController* controller = (UIViewController*)responder; controller; controller = controller.parentViewController) {
                if (IsBScreen(controller)) return YES;
            }
            return NO;
        }
    }
    return NO;
}

static BOOL HandleInlineAction(id actionsView, id button, void (^orig)(void)) {
    if (!UnifiedActive()) return NO;
    EnsurePair();
    NSString* buttonClass = NSStringFromClass([button class]);
    if ([buttonClass containsString:@"Share"] || [buttonClass containsString:@"Analytics"]) return NO;
    id viewModel = Getter(actionsView, @"viewModel");
    if ([actionsView isKindOfClass:[UIView class]] && IsInBScreen((UIView*)actionsView)) {
        // Everything on a screen opened as B goes as B, sent with B's account here.
        if (!gBAccount) {
            ShowNotice(@"B 계정을 찾지 못해서 막았어요");
            return YES;
        }
        UIView* source = [button isKindOfClass:[UIView class]] ? button : nil;
        if ([buttonClass containsString:@"Favorite"]) {
            LikeAsB(viewModel);
            return YES;
        }
        if ([buttonClass containsString:@"Retweet"]) {
            RepostAsB(viewModel);
            return YES;
        }
        if ([buttonClass containsString:@"Bookmark"]) {
            BookmarkAsB(viewModel, source);
            return YES;
        }
        if ([buttonClass containsString:@"Reply"]) {
            long long target = ViewModelStatusID(viewModel);
            gComposeAsBUntil = CFAbsoluteTimeGetCurrent() + 6;
            gComposeTargets = [NSSet setWithObjects:@(target), @(NumberGetter(ActedStatus(viewModel), @"statusID")), nil];
            UnifiedLog(@"reply on a B screen: composer will switch to B");
            return NO;
        }
        gBlocked++;
        ShowNotice(@"B로 보는 화면이에요. 이 버튼은 아직 B로 보낼 수 없어서 막아뒀어요.");
        return YES;
    }
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
    BOOL bookmark = [buttonClass containsString:@"Bookmark"];
    UIView* sourceView = [button isKindOfClass:[UIView class]] ? button : nil;

    if (bOnly) {
        if (bookmark) {
            BookmarkAsB(viewModel, sourceView);
            return YES;
        }
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
    if (bookmark) {
        ChooseAccount(@"어느 계정으로 북마크할까요?", message, orig, ^{
            BookmarkAsB(viewModel, sourceView);
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
    if ([hex isEqualToString:@"theme"]) {
        // X's own accent: the windows' tint.
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow* window in ((UIWindowScene*)scene).windows) {
                if (window.isKeyWindow && window.tintColor) return window.tintColor;
            }
        }
        return [UIColor colorWithRed:0.11 green:0.61 blue:0.94 alpha:1];
    }
    unsigned int value = 0;
    if (hex.length != 6 || ![[NSScanner scannerWithString:hex] scanHexInt:&value]) value = 0xFF7A00;
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                           green:((value >> 8) & 0xFF) / 255.0
                            blue:(value & 0xFF) / 255.0
                           alpha:1];
}

UIColor* NFBUnifiedBColor(void) {
    return BColor();
}

// A tweet only B has: the display name in B's colour and a folded top-left
// corner. Anything else gets X's own colour back and no corner.
static void ColorRepostLine(UIView* statusView, UIColor* color) {
    UIView* context = nil;
    for (UIView* view in statusView.subviews) {
        if ([NSStringFromClass([view class]) isEqualToString:@"T1TimelinesItemSocialContextView"]) context = view;
    }
    if (!context) return;
    EnumerateSubviewsRecursively(context, ^(UIView* view) {
        if ([view isKindOfClass:[UILabel class]] && ((UILabel*)view).text.length) {
            UILabel* label = (UILabel*)view;
            UIColor* saved = objc_getAssociatedObject(label, kNameColorKey);
            if (color) {
                if (!saved) objc_setAssociatedObject(label, kNameColorKey, label.textColor ?: [UIColor secondaryLabelColor], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (![label.textColor isEqual:color]) label.textColor = color;
            } else if (saved) {
                label.textColor = saved;
                objc_setAssociatedObject(label, kNameColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else if ([view isKindOfClass:[UIImageView class]]) {
            UIImageView* icon = (UIImageView*)view;
            UIColor* saved = objc_getAssociatedObject(icon, kNameColorKey);
            if (color) {
                if (!saved) objc_setAssociatedObject(icon, kNameColorKey, icon.tintColor ?: [UIColor secondaryLabelColor], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                icon.tintColor = color;
            } else if (saved) {
                icon.tintColor = saved;
                objc_setAssociatedObject(icon, kNameColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    });
}

static void ApplyBMark(UIView* authorView, UIView* statusView, long long statusID) {
    BOOL bOnly = statusID > 0 && [gBOnlyIDs containsObject:@(statusID)];
    BOOL nameB = bOnly && [gBNameIDs containsObject:@(statusID)];
    BOOL lineB = bOnly && [gBRepostLineIDs containsObject:@(statusID)];
    if (statusView) ColorRepostLine(statusView, lineB ? BColor() : nil);
    UIColor* color = nameB ? BColor() : nil;
    for (UIView* view in authorView.subviews) {
        if (![view isKindOfClass:[UILabel class]] || ![view.accessibilityIdentifier isEqualToString:@"StatusFullname"]) {
            continue;
        }
        UILabel* name = (UILabel*)view;
        UIColor* saved = objc_getAssociatedObject(name, kNameColorKey);
        if (nameB) {
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
    ((CAShapeLayer*)corner.layer.sublayers.firstObject).fillColor = BColor().CGColor;
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
    ApplyBMark(authorView, statusView, statusID);
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

void NFBUnifiedAddKnownFollows(NSString* accountID, NSSet<NSNumber*>* userIDs) {
    if (accountID.length == 0 || !userIDs) return;
    if (!gKnownFollows) gKnownFollows = [NSMutableDictionary dictionary];
    gKnownFollows[accountID] = [userIDs copy];
    if ([accountID isEqualToString:AccountUserID(CurrentAccount())]) {
        if (!gAFollowedBringers) gAFollowedBringers = [NSMutableSet set];
        [gAFollowedBringers unionSet:userIDs];
    }
    UnifiedLog([NSString stringWithFormat:@"following list for %@: %lu people", accountID, (unsigned long)userIDs.count]);
    ReapplyMerge();
}

extern NSString* NFBUnifiedFollowSyncDebugText(void);

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
    [out appendFormat:@"For You: A timelines=%lu B=%@ objects=%lu | %@\n", (unsigned long)gForYouTimelines.count,
                      gBForYouTimeline ? @"made" : @"none",
                      (unsigned long)([Getter(Getter(gBForYouTimeline, @"stream"), @"streamObjects") isKindOfClass:[NSArray class]]
                                          ? [Getter(Getter(gBForYouTimeline, @"stream"), @"streamObjects") count] : 0),
                      gLastForYouMerge];
    [out appendFormat:@"following lists:\n%@", NFBUnifiedFollowSyncDebugText()];
    [out appendFormat:@"reposts as B:\n%@\n", NFBUnifiedRepostDebugText()];
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

- (id)homeTimelineForAccount:(id)account {
    id timeline = %orig;
    if (timeline && !gMakingB) {
        if (!gForYouTimelines) gForYouTimelines = [NSHashTable weakObjectsHashTable];
        [gForYouTimelines addObject:timeline];
    }
    return timeline;
}

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

// A's timeline refreshed: B's matching timeline (Following or For You) too.
static void FollowARefresh(id timeline, long long source) {
    if (timeline == gBTimeline || timeline == gBForYouTimeline || !UnifiedActive()) return;
    if (Getter(timeline, @"account") != CurrentAccount()) return;
    if ([gFollowingTimelines containsObject:timeline]) {
        RefreshB(source, @"A refreshed");
    } else if ([gForYouTimelines containsObject:timeline]) {
        RefreshBForYou(source);
    }
}

%hook TFNTwitterHomeTimeline

- (void)refreshWithSource:(long long)source completion:(id)completion {
    %orig;
    FollowARefresh(self, source);
}

- (void)refreshWithSource:(long long)source pushToHomeTweetId:(id)tweetID completion:(id)completion {
    %orig;
    FollowARefresh(self, source);
}

- (void)streamDidUpdate:(id)stream {
    %orig;
    if ((self == gBTimeline || self == gBForYouTimeline) && UnifiedActive()) {
        UnifiedLog(self == gBTimeline ? @"B stream updated" : @"B For You updated");
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

// 7.3.136: setAccount: on the composer alone left the avatar on A; the account
// picker's own path goes through the single-tweet controller: -[T1TweetComposeSingleTweetViewController
// setAccount:] then -[T1TweetComposeTableViewController singleTweetViewController:
// didSwitchToAccount:]. Do the same, then check every piece shows the account.
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

static void SwitchComposerTo(UIViewController* composer, id account, BOOL quiet) {
    if (!account) return;
    SEL setAccount = NSSelectorFromString(@"setAccount:");
    NSMutableArray* singles = [NSMutableArray array];
    NSMutableArray* tables = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeSingleTweetViewController", singles);
    CollectControllers(composer, @"T1TweetComposeTableViewController", tables);
    SEL didSwitch = NSSelectorFromString(@"singleTweetViewController:didSwitchToAccount:");
    for (id single in singles) {
        if ([single respondsToSelector:setAccount]) ((void (*)(id, SEL, id))objc_msgSend)(single, setAccount, account);
        id avatar = Getter(single, @"avatarImageView");
        if ([avatar respondsToSelector:setAccount]) ((void (*)(id, SEL, id))objc_msgSend)(avatar, setAccount, account);
        for (id table in tables) {
            if ([table respondsToSelector:didSwitch]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(table, didSwitch, single, account);
            }
        }
    }
    for (id table in tables) {
        if (Getter(table, @"account") != account && [table respondsToSelector:setAccount]) {
            ((void (*)(id, SEL, id))objc_msgSend)(table, setAccount, account);
        }
    }
    if (Getter(composer, @"account") != account && [composer respondsToSelector:setAccount]) {
        ((void (*)(id, SEL, id))objc_msgSend)(composer, setAccount, account);
    }
    NSString* detail = nil;
    BOOL all = ComposerIsAll(composer, account, &detail);
    NSString* name = account == gBAccount ? BName() : AName();
    UnifiedLog([NSString stringWithFormat:@"composer to %@: %@", account == gBAccount ? @"B" : @"A", detail]);
    if (!quiet || !all) {
        ShowNotice(all ? [NSString stringWithFormat:@"%@로 써요. 왼쪽 위 프로필이 %@인지 확인해주세요", name, name]
                       : [NSString stringWithFormat:@"%@로 다 바꾸지 못했어요. 왼쪽 위 프로필을 눌러 직접 바꿔주세요", name]);
    }
}

// The account a composer must send as, once it is known (user ID). A composer
// with one is checked at every send path: every piece must be that account.
static const void* kIntendedKey = &kIntendedKey;
static const void* kPendingBKey = &kPendingBKey;

static void SetIntended(UIViewController* composer, id account) {
    objc_setAssociatedObject(composer, kIntendedKey, AccountUserID(account), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

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

static void StopSend(UIViewController* composer, NSString* name, NSString* why) {
    UnifiedLog([NSString stringWithFormat:@"send stopped: %@", why]);
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:@"보내지 않았어요"
                                            message:[NSString stringWithFormat:@"이 글은 %@로 보내야 하는데 작성 화면 일부가 다른 계정이에요. "
                                                                               @"글은 그대로 있어요. 왼쪽 위 프로필을 눌러 계정을 다시 골라주세요.",
                                                                               name]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleDefault handler:nil]];
    [composer presentViewController:alert animated:YES completion:nil];
}

// Last check before anything leaves a composer whose account is decided.
static BOOL SendAllowed(UIViewController* composer) {
    NSString* intended = objc_getAssociatedObject(composer, kIntendedKey);
    if (intended.length == 0) return YES;
    id account = AccountForID(intended);
    NSString* name = [intended isEqualToString:BID()] ? BName() : AName();
    NSString* detail = nil;
    if (account && ComposerIsAll(composer, account, &detail)) {
        UnifiedLog([NSString stringWithFormat:@"send as %@: all pieces match", [intended isEqualToString:BID()] ? @"B" : @"A"]);
        return YES;
    }
    StopSend(composer, name, account ? detail : @"account not found");
    return NO;
}

// A reply to a tweet only B has: switch to B as early as the composer can say
// which tweet it answers. 7.3.142: when it cannot say (once in 7.3.140), it is
// still switched, since the reply was asked for as B a moment ago; the send
// check stops anything that is not all B, and the other avatar switches back.
static void MaybeSwitchReply(UIViewController* composer, BOOL last) {
    if (CFAbsoluteTimeGetCurrent() > gComposeAsBUntil || !gBAccount) return;
    long long target = ReplyTargetID(composer);
    if (target <= 0 && !last) {
        objc_setAssociatedObject(composer, kPendingBKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSSet* targets = gComposeTargets;
    gComposeAsBUntil = 0;
    gComposeTargets = nil;
    objc_setAssociatedObject(composer, kPendingBKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (target > 0 && ![targets containsObject:@(target)]) {
        UnifiedLog(@"composer not switched: it answers another tweet");
        return;
    }
    if (target <= 0) UnifiedLog(@"reply target unknown; switching to B anyway, the send check stays on");
    SetIntended(composer, gBAccount);
    SwitchComposerTo(composer, gBAccount, NO);
}

// MARK: - The other account under the composer's avatar

static const NSInteger kOtherAvatarTag = 0x4E464F;  // "NFO"

@interface NFBComposerSwitchTarget : NSObject
+ (instancetype)shared;
- (void)tapped:(UIButton*)button;
@end

static UIViewController* ComposerOf(UIView* view) {
    UIResponder* responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            UIViewController* controller = (UIViewController*)responder;
            while (controller) {
                if ([NSStringFromClass([controller class]) isEqualToString:@"T1TweetComposeViewController"]) return controller;
                controller = controller.parentViewController;
            }
            return nil;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static id OtherAccount(id account) {
    id a = CurrentAccount();
    if (!gBAccount || !account) return nil;
    if (account == gBAccount) return a;
    if (account == a) return gBAccount;
    return nil;
}

static void UpdateOtherAvatar(UIView* singleView) {
    UIButton* button = [singleView viewWithTag:kOtherAvatarTag];
    UIView* avatar = nil;
    for (UIView* view in singleView.subviews) {
        if ([NSStringFromClass([view class]) isEqualToString:@"TCRComposeAccountAvatarImageView"]) avatar = view;
    }
    id shown = Getter(avatar, @"account");
    id other = UnifiedActive() && avatar && !avatar.hidden && BTimeline() ? OtherAccount(shown) : nil;
    if (!other) {
        button.hidden = YES;
        return;
    }
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = kOtherAvatarTag;
        button.clipsToBounds = YES;
        button.imageView.contentMode = UIViewContentModeScaleAspectFill;
        [button addTarget:[NFBComposerSwitchTarget shared] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
        [singleView addSubview:button];
    }
    const CGFloat size = 22;
    CGRect frame = avatar.frame;
    button.frame = CGRectMake(CGRectGetMidX(frame) - size / 2, CGRectGetMaxY(frame) + 6, size, size);
    button.layer.cornerRadius = size / 2;
    BOOL isB = other == gBAccount;
    [button setImage:AccountAvatar(other, isB ? @"B" : @"A",
                                   isB ? BColor() : [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1])
            forState:UIControlStateNormal];
    button.alpha = 0.4;
    button.hidden = NO;
    button.accessibilityLabel = [NSString stringWithFormat:@"%@로 바꾸기", isB ? BName() : AName()];
    [singleView bringSubviewToFront:button];
}

@implementation NFBComposerSwitchTarget

+ (instancetype)shared {
    static NFBComposerSwitchTarget* target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        target = [NFBComposerSwitchTarget new];
    });
    return target;
}

- (void)tapped:(UIButton*)button {
    UIViewController* composer = ComposerOf(button);
    UIView* avatar = nil;
    for (UIView* view in button.superview.subviews) {
        if ([NSStringFromClass([view class]) isEqualToString:@"TCRComposeAccountAvatarImageView"]) avatar = view;
    }
    id other = OtherAccount(Getter(avatar, @"account"));
    if (!composer || !other) return;
    // Chosen here, so this is the account it must go out as.
    SetIntended(composer, other);
    SwitchComposerTo(composer, other, NO);
    UIView* holder = button.superview;
    if (!avatar || !holder) {
        [holder setNeedsLayout];
        return;
    }
    // 7.3.147: a liquid ring springs from the small picture to the big one,
    // the big one gives a little bounce, the small one fades to the other.
    UIColor* tint = other == gBAccount ? BColor() : [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1];
    UIView* ring = [[UIView alloc] initWithFrame:CGRectInset(button.frame, -3, -3)];
    ring.userInteractionEnabled = NO;
    ring.layer.cornerRadius = CGRectGetWidth(ring.bounds) / 2;
    ring.layer.borderWidth = 2.5;
    ring.layer.borderColor = tint.CGColor;
    ring.backgroundColor = [tint colorWithAlphaComponent:0.12];
    ring.layer.shadowColor = tint.CGColor;
    ring.layer.shadowOpacity = 0.5;
    ring.layer.shadowRadius = 6;
    ring.layer.shadowOffset = CGSizeZero;
    [holder addSubview:ring];
    CGRect target = CGRectInset(avatar.frame, -3, -3);
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft] impactOccurred];
    [UIView animateWithDuration:0.5
        delay:0
        usingSpringWithDamping:0.62
        initialSpringVelocity:0.9
        options:UIViewAnimationOptionBeginFromCurrentState
        animations:^{
            ring.frame = target;
            ring.layer.cornerRadius = CGRectGetWidth(target) / 2;
        }
        completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25
                animations:^{
                    ring.alpha = 0;
                    ring.transform = CGAffineTransformMakeScale(1.15, 1.15);
                }
                completion:^(BOOL done) {
                    [ring removeFromSuperview];
                }];
        }];
    avatar.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [UIView animateWithDuration:0.55
                          delay:0.12
         usingSpringWithDamping:0.45
          initialSpringVelocity:1.2
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         avatar.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
    [UIView transitionWithView:button
                      duration:0.3
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        [holder setNeedsLayout];
                        [holder layoutIfNeeded];
                    }
                    completion:nil];
}

@end

%hook T1TweetComposeSingleTweetView

- (void)layoutSubviews {
    %orig;
    UIView* view = (UIView*)self;
    if (UnifiedActive() || [view viewWithTag:kOtherAvatarTag]) UpdateOtherAvatar(view);
}

%end

%hook T1TweetComposeTableViewController

// X's own account picker: the account picked there is the one meant.
- (void)singleTweetViewController:(id)single didSwitchToAccount:(id)account {
    %orig;
    UIViewController* composer = ComposerOf(((UIViewController*)self).viewIfLoaded);
    if (!composer) {
        for (UIViewController* parent = ((UIViewController*)self).parentViewController; parent; parent = parent.parentViewController) {
            if ([NSStringFromClass([parent class]) isEqualToString:@"T1TweetComposeViewController"]) composer = parent;
        }
    }
    if (composer && objc_getAssociatedObject(composer, kIntendedKey) && account) SetIntended(composer, account);
}

%end

%hook T1TweetComposeViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    MaybeSwitchReply((UIViewController*)self, NO);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController* composer = (UIViewController*)self;
    if (![objc_getAssociatedObject(composer, kPendingBKey) boolValue] && CFAbsoluteTimeGetCurrent() > gComposeAsBUntil) return;
    MaybeSwitchReply(composer, NO);
    if (![objc_getAssociatedObject(composer, kPendingBKey) boolValue]) return;
    // Still no reply target: give the reply context a moment, then decide.
    __weak UIViewController* weakComposer = composer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakComposer) MaybeSwitchReply(weakComposer, YES);
    });
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

// MARK: - Tweet screen as B

static id AccountForOpening(id account, long long statusID) {
    if (!UnifiedActive() || !gBAccount || account != CurrentAccount() || statusID <= 0) return account;
    EnsurePair();
    if (![gBOnlyIDs containsObject:@(statusID)]) return account;
    UnifiedLog(@"tweet screen opens as B");
    return gBAccount;
}

static const NSInteger kBScreenAvatarTag = 0x4E4653;  // "NFS"

static void ShowBOnScreen(UIViewController* controller) {
    if (!IsBScreen(controller)) return;
    UINavigationItem* item = controller.navigationItem;
    for (UIBarButtonItem* existing in item.leftBarButtonItems) {
        if (existing.customView.tag == kBScreenAvatarTag) return;
    }
    const CGFloat size = 28;
    UIView* holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size + 8, size)];
    holder.tag = kBScreenAvatarTag;
    UIImageView* picture = [[UIImageView alloc] initWithFrame:CGRectMake(4, 0, size, size)];
    picture.image = AccountAvatar(gBAccount, @"B", BColor());
    picture.contentMode = UIViewContentModeScaleAspectFill;
    picture.clipsToBounds = YES;
    picture.layer.cornerRadius = size / 2;
    picture.layer.borderWidth = 1.5;
    picture.layer.borderColor = BColor().CGColor;
    [holder addSubview:picture];
    [holder.widthAnchor constraintEqualToConstant:size + 8].active = YES;
    [holder.heightAnchor constraintEqualToConstant:size].active = YES;
    holder.isAccessibilityElement = YES;
    holder.accessibilityLabel = [NSString stringWithFormat:@"%@로 보는 중", BName()];
    UIBarButtonItem* avatar = [[UIBarButtonItem alloc] initWithCustomView:holder];
    item.leftItemsSupplementBackButton = YES;
    NSMutableArray* items = [item.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items insertObject:avatar atIndex:0];
    item.leftBarButtonItems = items;
    ShowNotice([NSString stringWithFormat:@"%@ 계정으로 보고 있어요. 여기서 하는 반응은 %@로 가요", BName(), BName()]);
}

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
    return %orig(AccountForOpening(account, statusID), statusID, navigationContext, scribeContext, sourceMetadata,
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
    return %orig(AccountForOpening(account, ViewModelStatusID(viewModel)), viewModel, navigationContext, scribeContext,
                 sourceMetadata, overrideMetadata, referrer, notifyEdit, quickPromote, excluded);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ShowBOnScreen((UIViewController*)self);
}

%end

%ctor {
    // The first B load happens once the Following tab has been set up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (UnifiedActive()) {
            RefreshB(101, @"launch");
            RefreshBForYou(101);
        }
    });
}
