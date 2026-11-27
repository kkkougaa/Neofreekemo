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
//  - 7.3.149: every "which account?" question is a sheet from the bottom
//    (UnifiedSheet.x). The composer shows A and B in fixed places with a
//    Liquid Glass highlight on the one in use. A tweet screen for a tweet only
//    B has opens as B through the app navigation too, matched by the item's or
//    the original's ID, accounts compared by user ID.
//  - 7.3.147: B's colour can be X's theme colour or any colour from a picker.
//    B's For You marks (and B reactions) only where B follows whoever brought
//    the tweet; a tweet B was only recommended is plain and reacts as A. The
//    composer's account switch springs a liquid ring between the pictures.
//    Bookmarks as B: the manager's account is an ivar without a getter.
//  - 7.3.140: only B's tweets get the small account picture (A-only ones had
//    A's). B loaded only its first page, so scrolling A down ran past B's
//    tweets; when A's Following stream loads more (-[TFSTwitterStream
//    loadBottomWithSource:]), B's loads more too.
//  - 7.3.151: like, repost and bookmark ask "which account?" with one sheet
//    (PresentReactionSheet): each account's state and a pill naming what a tap
//    does; rows keep the sheet up so A and then B can act. The accounts that
//    reposted or bookmarked show left of those buttons like the likes do
//    (UpdateActionBadges). The repost button on a tweet only B has asks
//    "repost or quote?", and the quote opens X's own quote composer with B's
//    account, recognised by the tweet it quotes and guarded like a reply
//    (QuoteAsB). Notices that something was stopped come with a warning haptic
//    and say what to do next.
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

//  - 7.3.151, accounts never mixed, nothing outside the mode:
//    * A and B are both saved accounts; the mode is active only while the
//      account in use is the saved A (UnifiedActive, cached per run-loop turn).
//    * Every send / open / lookup as B takes its account from VerifiedB() at
//      that moment; A's explicit sends take VerifiedA(). No account: blocked.
//    * Whose a row is comes from the object on screen (ProvOf): the view models
//      this file's merges put on A's lists from B's streams are marked, per
//      merge. Tweet IDs are kept only for opening a tweet screen from the
//      unified home lists, the composer guard and the scribe guard.
//    * A row whose object was loaded as B never runs X's own like / repost /
//      bookmark path: B rows go as B, the others as A with an explicit call on
//      A's own account (ActAs), or the sheet when A's state is not known.
//    * Leaving the mode (UnifiedBecameInactive) puts A's lists back, closes
//      the tweet screens opened as B and drops everything kept for B.
//  - 7.3.151, the reaction rules (like / repost / bookmark; HandleInlineAction):
//    1. A-base (only A's stream has it): tap = A, X's own path. Long press =
//       the account sheet, where B can be chosen. A protected author: A only.
//    2. Both follow: as A-base. Where the copy on the list is B's, "tap = A"
//       is an explicit call on A's verified account (or the sheet when A's
//       state is not known; repost always the sheet), never X's own path.
//    3. B-base (a row of B's alone, a screen opened as B): tap = B. Long
//       press = the sheet, where A can be chosen (explicit call as A). A
//       protected author: B only.
//    4. Reply / quote never ask: the composer opens as the row's account (A
//       for 1 and 2, B for 3) and its own A/B pictures switch.
//    "Always ask" (kemo_unified_always_ask): a tap on like / repost / bookmark
//    of an A-base or both tweet opens the sheet; replies still never ask.

static NSHashTable* gFollowingTimelines;  // A's Following-tab timelines, from X's factory
static NSHashTable* gFollowingControllers;  // A's home controllers (Following and For You) with a merge
static BOOL gMakingB;
static NSHashTable* gForYouTimelines;   // A's For You timelines, from X's factory
static id gBForYouTimeline;
static id gBForYouAccount;
static CFAbsoluteTime gBForYouLastRefresh;
// 7.3.151: people A's Following tab showed as followed, used only until A's
// synced Following list exists (AFollowSet).
static NSMutableSet<NSNumber*>* gALearntFollows;
static NSString* gALearntFor;
static NSString* gAFollowNote = @"(no merge yet)";
static NSString* gLastForYouMerge = @"(no For You merge yet)";
// Of B's own tweets: the reposts (the "reposted" line gets B's colour) and the
// ones whose display name does (the author only B follows).
// 7.3.151: these ID sets are rebuilt from the controllers' last merges
// (RebuildMarks) and replaced whole; they are never added to.
static NSSet<NSNumber*>* gBRepostLineIDs;
static NSSet<NSNumber*>* gBNameIDs;
// The originals of tweets only B has (a tweet screen may be opened by either ID).
static NSSet<NSNumber*>* gBOnlyActedIDs;
// Who each account follows, from its own Following list (UnifiedFollowSync.x).
static NSMutableDictionary<NSString*, NSSet<NSNumber*>*>* gKnownFollows;
static void ReapplyMerge(BOOL following, BOOL forYou);
static id gBTimeline;
static id gBAccount;  // the last VerifiedB(); for pictures only, never sent with
static CFAbsoluteTime gBLastRefresh;
static NSUInteger gBBottomLoads;
static CFAbsoluteTime gBLastBottom;
static long long gLastASource = 101;
static void FollowBottomLoad(id stream, long long source);
static void LoadMoreB(id controller, long long source, NSString* why);
static NSSet<NSNumber*>* gBOnlyIDs;
static NSSet<NSNumber*>* gBothIDs;
static NSSet<NSNumber*>* gAOnlyIDs;
static NSMutableArray<NSString*>* gUnifiedLog;
static NSString* gLastMerge = @"(no merge yet)";
static const void* kOriginalSectionsKey = &kOriginalSectionsKey;
// 7.3.151: requests made as B in this run, for the dump.
static NSUInteger gReqRefresh;
static NSUInteger gReqMore;
static NSUInteger gReqForYouRefresh;
static NSUInteger gReqForYouMore;

// 7.3.151: this file's own lock (it was [NSObject class], shared with other files).
static NSObject* UnifiedLock(void) {
    static NSObject* lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    return lock;
}

static void UnifiedLog(NSString* line) {
    static NSDateFormatter* formatter;
    @synchronized(UnifiedLock()) {
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.dateFormat = @"HH:mm:ss";
        }
        if (!gUnifiedLog) gUnifiedLog = [NSMutableArray array];
        [gUnifiedLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        // 7.3.151: 50 (was 30); a sheet that stays up writes a line per tap.
        if (gUnifiedLog.count > 50) [gUnifiedLog removeObjectAtIndex:0];
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

static id AccountForID(NSString* userID) {
    if (userID.length == 0) return nil;
    for (id account in Accounts()) {
        if ([AccountUserID(account) isEqualToString:userID]) return account;
    }
    return nil;
}

// MARK: - Whether the mode is in use, and the two accounts (7.3.151)

static void RefreshB(long long source, NSString* why);
static void CollectControllers(UIViewController* controller, NSString* className, NSMutableArray* found);
static void UnifiedBecameInactive(NSString* why);
static void UnifiedBecameActive(void);
static void BadgeMemoClear(void);
static void SessionClear(void);

// The pair (saved A | saved B) the mode is active for; nil while it is not.
// Everything kept below belongs to one pair.
static NSString* gPairKey;
static NSString* gSessionPair;  // the pair the session's own actions were recorded for
static BOOL gActiveCacheValid;
static BOOL gActiveCacheValue;
static BOOL gActiveCacheQueued;
static BOOL gEverActive;  // NO: no hook in this file does anything but call X
static BOOL gWasActive;
static NSString* gInactiveHint;  // why, when the caller knows (the dock)
static NSString* gInactiveNote = @"(not yet)";
static NSString* gVerifiedBWhy = @"not asked yet";
static CFAbsoluteTime gStartedAt;

// 7.3.151, for the pictures next to the buttons (UpdateActionBadges): B's
// like / repost / bookmark of a tweet whose copy on screen is A's, kept per
// tweet (working it out walks B's streams, too slow for every layout). Only
// from what is in memory; nothing is asked. Main thread only.
static NSMutableDictionary<NSNumber*, NSArray<NSNumber*>*>* gBadgeMemo;
static NSMutableArray<NSString*>* gBadgeLog;  // repost / bookmark pictures and their source, each once
static NSMutableSet<NSString*>* gBadgeLogged;

// 7.3.151: A and B are both fixed, saved accounts. The mode is active only
// with the feature and the dock's choice on, a saved A that is the account in
// use, and a saved B that is another account. (It used to take whoever was in
// use as A when none was saved.)
static BOOL ComputeActive(NSString** pairOut, NSString** whyNot) {
    NSString* why = nil;
    NSString* aID = AID();
    NSString* bID = BID();
    if (![BHTSettings boolForKey:kUnifiedOn]) {
        why = @"feature switched off";
    } else if (!UnifiedModeSelected()) {
        why = @"the dock is on a single account";
    } else if (aID.length == 0) {
        why = @"no A saved";
    } else if (bID.length == 0) {
        why = @"no B saved";
    } else if ([aID isEqualToString:bID]) {
        why = @"A and B are the same account";
    } else {
        NSString* currentID = AccountUserID(CurrentAccount());
        if (currentID.length == 0 || ![aID isEqualToString:currentID]) {
            why = @"the account in use is not A";
        } else if (!AccountForID(bID)) {
            // 7.3.153: B has to be signed in on this device (a logged-out B
            // left the mode on, with its rows opening as A).
            why = @"B is not signed in";
        }
    }
    if (whyNot) *whyNot = why;
    if (why) return NO;
    if (pairOut) *pairOut = [NSString stringWithFormat:@"%@|%@", aID, bID];
    return YES;
}

// The B account object the pictures use; when it changes, what was loaded or
// asked with the old one is dropped. Main thread only.
static void SetBAccount(id account) {
    if (account == gBAccount) return;
    BOOL had = gBAccount != nil;
    gBAccount = account;
    gBTimeline = nil;
    gBForYouTimeline = nil;
    gBForYouAccount = nil;
    gBLastRefresh = 0;
    gBForYouLastRefresh = 0;
    BadgeMemoClear();
    if (had) UnifiedLog(account ? @"B's account object changed; B's timelines dropped" : @"B's account gone; B's timelines dropped");
}

// 7.3.151: asked on every layout of every author line and action bar, so the
// answer is kept for the run-loop turn (on the main thread; other threads
// compute it). The turn's first question is also the one place that sees the
// mode go on or off.
static BOOL UnifiedActive(void) {
    if (![NSThread isMainThread]) return ComputeActive(NULL, NULL);
    if (gActiveCacheValid) return gActiveCacheValue;
    NSString* pair = nil;
    NSString* whyNot = nil;
    BOOL active = ComputeActive(&pair, &whyNot);
    gActiveCacheValid = YES;
    gActiveCacheValue = active;
    if (!gActiveCacheQueued) {
        gActiveCacheQueued = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            gActiveCacheQueued = NO;
            gActiveCacheValid = NO;
        });
    }
    if (active) {
        if (gWasActive && gPairKey && ![gPairKey isEqualToString:pair]) UnifiedBecameInactive(@"pair changed");
        if (!gWasActive) {
            gWasActive = YES;
            gEverActive = YES;
            gPairKey = pair;
            if (![pair isEqualToString:gSessionPair]) {
                SessionClear();
                gSessionPair = pair;
            }
            UnifiedLog([NSString stringWithFormat:@"unified mode active (pair %@)", pair]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UnifiedBecameActive();
            });
        }
        SetBAccount(AccountForID(BID()));
    } else if (gWasActive) {
        NSString* why = gInactiveHint ?: whyNot ?: @"not active";
        gInactiveHint = nil;
        UnifiedBecameInactive(why);
    }
    return active;
}

// 7.3.151: B's account for anything sent, opened or asked as B, checked at
// that moment: the saved B, signed in here, its user ID the saved one, not the
// account in use, and the mode active with the saved pair. nil: do not send.
// (Sends used a B object kept since B's timeline was made; after B was changed
// in settings the sheet named the new B while requests went out as the old.)
static id VerifiedB(void) {
    if (![NSThread isMainThread]) return nil;
    NSString* why = nil;
    id account = nil;
    if (!UnifiedActive()) {
        why = @"unified mode not active";
    } else {
        NSString* bID = BID();
        account = AccountForID(bID);
        id current = CurrentAccount();
        NSString* accountID = AccountUserID(account);
        NSString* currentID = AccountUserID(current);
        if (!account) why = @"B is not signed in here";
        else if (accountID.length == 0 || ![accountID isEqualToString:bID]) why = @"its user ID is not the saved B";
        else if (currentID.length == 0) why = @"account in use not known";
        else if (account == current || [accountID isEqualToString:currentID]) why = @"B is the account in use";
    }
    if (why) account = nil;
    SetBAccount(account);
    gVerifiedBWhy = why;
    return account;
}

// The same for A: the account in use, its user ID the saved A (and not the
// saved B), the mode active.
static id VerifiedA(void) {
    if (![NSThread isMainThread] || !UnifiedActive()) return nil;
    id current = CurrentAccount();
    NSString* currentID = AccountUserID(current);
    NSString* aID = AID();
    if (!current || currentID.length == 0 || aID.length == 0 || ![currentID isEqualToString:aID]) return nil;
    if ([currentID isEqualToString:BID()]) return nil;
    return current;
}

id NFBUnifiedVerifiedB(void) {
    return VerifiedB();
}

// B's timeline, made once per B account the way the 7.3.132 probe did.
static id BTimeline(void) {
    id account = VerifiedB();
    if (!account) return nil;
    // VerifiedB() dropped the timeline if the account object changed.
    if (gBTimeline) return gBTimeline;

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
    gReqRefresh++;
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
    id account = VerifiedB();
    if (!account) return nil;
    if (gBForYouTimeline && gBForYouAccount == account) return gBForYouTimeline;
    Class factoryClass = objc_getClass("T1TimelineFactory");
    if (!factoryClass || ![factoryClass respondsToSelector:@selector(sharedTimelineFactory)]) return nil;
    id factory = ((id (*)(id, SEL))objc_msgSend)(factoryClass, @selector(sharedTimelineFactory));
    SEL selector = NSSelectorFromString(@"homeTimelineForAccount:");
    if (![factory respondsToSelector:selector]) return nil;
    id timeline = nil;
    gMakingB = YES;
    @try {
        timeline = ((id (*)(id, SEL, id))objc_msgSend)(factory, selector, account);
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
    gBForYouAccount = account;
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
    gReqForYouRefresh++;
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

// 7.3.151: the tweets only B has (their own IDs and their originals') go to
// UnifiedScribeGuard.x, which keeps A's records of them from being written.
extern void NFBUnifiedGuardNote(NSSet<NSNumber*>* ids, id bAccount);

static void NoteGuard(void) {
    NSMutableSet<NSNumber*>* ids = [NSMutableSet set];
    @synchronized(UnifiedLock()) {
        if (gBOnlyIDs) [ids unionSet:gBOnlyIDs];
        if (gBOnlyActedIDs) [ids unionSet:gBOnlyActedIDs];
    }
    NFBUnifiedGuardNote(ids, gBAccount);
}

// MARK: - Whose a row is: provenance (7.3.151)
//
// It was decided by tweet ID anywhere in the app: A's own copy of a tweet met
// in search or on a profile acted as B, and its flags (A's) were read as B's.
// It is decided by the object now. Every view model (and module row) a merge
// puts on A's lists from B's streams is remembered, with its class for that
// merge; a row is B's when the view model it shows is one of those.

enum {
    kProvNone = 0,
    kProvBOnly = 1,   // B's copy; only B has it: everything goes as B
    kProvBBoth = 2,   // B's copy; A has it too (A follows whoever brought it)
    kProvBPlain = 3,  // B's copy; B was only recommended it: reacts as A
    kProvABoth = 4,   // A's copy; B has it too
    kProvAOnly = 5,   // A's copy; B would have it if it followed the source
    kProvBStale = 6,  // B's copy from an earlier merge or pair: nothing is sent
};

// Everything ever put on A's lists from B's streams, while it lives: view
// models, module rows (for taking them out again) and, separately, the status
// objects they hold. Weak, compared by address. Main thread only.
static NSHashTable* gBLoadedItems;
static NSHashTable* gBLoadedStatuses;
// The classes of the controllers' last merges (RebuildMarks). Weak keys.
static NSMapTable* gMarks;
static NSMapTable* gStatusMarks;
static NSUInteger gMarkCountB;  // rows inserted from B in this generation
static NSUInteger gMarkCountA;
// Whether A's and B's streams hand out the very same status object for a
// tweet both have (then a status object says nothing about who loaded it and
// only the view models count). Checked on every tweet both streams hold.
static BOOL gStatusShared;
static NSUInteger gStatusSharedChecked;
static NSUInteger gProvHitItem;
static NSUInteger gProvHitStatus;
static const void* kRecordKey = &kRecordKey;  // a controller's last merge: its entries and ID sets

static NSHashTable* WeakAddressTable(void) {
    return [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
}

static NSMapTable* WeakAddressMap(void) {
    return [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                 valueOptions:NSPointerFunctionsStrongMemory];
}

static NSMutableDictionary* NewRecord(void) {
    return [@{
        @"entries" : [NSMutableArray array],
        @"bOnly" : [NSMutableSet set],
        @"both" : [NSMutableSet set],
        @"aOnly" : [NSMutableSet set],
        @"acted" : [NSMutableDictionary dictionary],
        @"name" : [NSMutableSet set],
        @"line" : [NSMutableSet set],
    } mutableCopy];
}

// One row of a merge: its class, and the objects that stand for it (the view
// model, the status it is, the tweet it shows).
static void RecordEntry(NSMutableDictionary* record, id item, NSInteger cls) {
    if (!item) return;
    long long statusID = NumberGetter(item, @"statusID");
    id status = Getter(item, @"status");
    id acted = ActedStatusOf(item);
    [record[@"entries"] addObject:@[ @(statusID), @(cls), item, status ?: [NSNull null], acted ?: [NSNull null] ]];
    if (cls == kProvBOnly || cls == kProvBBoth || cls == kProvBPlain) {
        if (!gBLoadedItems) gBLoadedItems = WeakAddressTable();
        if (!gBLoadedStatuses) gBLoadedStatuses = WeakAddressTable();
        [gBLoadedItems addObject:item];
        if (status) [gBLoadedStatuses addObject:status];
        if (acted) [gBLoadedStatuses addObject:acted];
    }
}

// A module row of B's (header, wrapped status, footer): remembered so it can
// be taken out of A's list again.
static void NoteBRow(id row) {
    if (!row) return;
    if (!gBLoadedItems) gBLoadedItems = WeakAddressTable();
    [gBLoadedItems addObject:row];
}

// The marks of every controller's last merge, put together. A tweet that any
// merge found both accounts have is "both" in all of them (the two merges
// used to disagree, and B-only won).
static void RebuildMarks(void) {
    NSMapTable* marks = WeakAddressMap();
    NSMapTable* statusMarks = WeakAddressMap();
    NSMutableSet<NSNumber*>* bOnly = [NSMutableSet set];
    NSMutableSet<NSNumber*>* both = [NSMutableSet set];
    NSMutableSet<NSNumber*>* aOnly = [NSMutableSet set];
    NSMutableSet<NSNumber*>* acted = [NSMutableSet set];
    NSMutableSet<NSNumber*>* name = [NSMutableSet set];
    NSMutableSet<NSNumber*>* line = [NSMutableSet set];
    NSMutableArray<NSDictionary*>* records = [NSMutableArray array];
    for (id controller in [gFollowingControllers allObjects]) {
        NSDictionary* record = objc_getAssociatedObject(controller, kRecordKey);
        if (!record) continue;
        [records addObject:record];
        [both unionSet:record[@"both"]];
    }
    NSUInteger countB = 0, countA = 0;
    for (NSDictionary* record in records) {
        [bOnly unionSet:record[@"bOnly"]];
        [aOnly unionSet:record[@"aOnly"]];
        [name unionSet:record[@"name"]];
        [line unionSet:record[@"line"]];
        NSDictionary<NSNumber*, NSNumber*>* actedByID = record[@"acted"];
        for (NSNumber* statusID in actedByID) {
            if (![both containsObject:statusID]) [acted addObject:actedByID[statusID]];
        }
        for (NSArray* entry in record[@"entries"]) {
            NSInteger cls = [entry[1] integerValue];
            if (cls == kProvBOnly && [both containsObject:entry[0]]) cls = kProvBBoth;
            if (cls == kProvAOnly && [both containsObject:entry[0]]) cls = kProvABoth;
            if (cls == kProvBOnly || cls == kProvBBoth || cls == kProvBPlain) countB++;
            else countA++;
            [marks setObject:@(cls) forKey:entry[2]];
            for (NSUInteger i = 3; i < 5; i++) {
                if (entry[i] != [NSNull null]) [statusMarks setObject:@(cls) forKey:entry[i]];
            }
        }
    }
    [bOnly minusSet:both];
    [aOnly minusSet:both];
    gMarks = marks;
    gStatusMarks = statusMarks;
    gMarkCountB = countB;
    gMarkCountA = countA;
    @synchronized(UnifiedLock()) {
        gBOnlyIDs = bOnly;
        gBothIDs = both;
        gAOnlyIDs = aOnly;
        gBOnlyActedIDs = acted;
        gBNameIDs = name;
        gBRepostLineIDs = line;
    }
    BadgeMemoClear();
}

// Whose the row showing `viewModel` is. The view model itself first; then, if
// status objects are not shared between the accounts, the statuses it holds
// (another screen may wrap B's copy in a view model of its own).
static NSInteger ProvOf(id viewModel) {
    if (!viewModel || (!gBLoadedItems && !gMarks)) return kProvNone;
    NSNumber* cls = [gMarks objectForKey:viewModel];
    BOOL loaded = [gBLoadedItems containsObject:viewModel];
    if (cls || loaded) {
        gProvHitItem++;
    } else if (!gStatusShared) {
        id status = Getter(viewModel, @"status");
        id acted = ActedStatusOf(viewModel);
        for (id object in @[ viewModel, status ?: [NSNull null], acted ?: [NSNull null] ]) {
            if (object == [NSNull null]) continue;
            if (!cls) cls = [gStatusMarks objectForKey:object];
            if ([gBLoadedStatuses containsObject:object]) loaded = YES;
        }
        if (cls || loaded) gProvHitStatus++;
    }
    NSInteger value = cls.integerValue;
    if (loaded && value != kProvBOnly && value != kProvBBoth && value != kProvBPlain) return kProvBStale;
    return value;
}

static BOOL ProvIsBLoaded(NSInteger cls) {
    return cls == kProvBOnly || cls == kProvBBoth || cls == kProvBPlain || cls == kProvBStale;
}

// B's rows taken out of sections that are about to be merged again (they are
// never there when X hands the sections over; this keeps a list this file
// re-sets from ever counting B's rows as A's).
static NSArray* StripBLoaded(NSArray* sections, NSUInteger* removedOut) {
    NSUInteger removed = 0;
    if (!gBLoadedItems || ![sections isKindOfClass:[NSArray class]]) {
        if (removedOut) *removedOut = 0;
        return sections;
    }
    NSMutableArray* result = nil;
    for (NSUInteger i = 0; i < sections.count; i++) {
        NSArray* section = sections[i];
        if (![section isKindOfClass:[NSArray class]]) continue;
        NSMutableArray* kept = nil;
        for (NSUInteger j = 0; j < section.count; j++) {
            id item = section[j];
            BOOL bRow = [gBLoadedItems containsObject:item] || [gBLoadedItems containsObject:unwrapDataViewItem(item)];
            if (bRow) {
                if (!kept) kept = [[section subarrayWithRange:NSMakeRange(0, j)] mutableCopy];
                removed++;
            } else if (kept) {
                [kept addObject:item];
            }
        }
        if (kept) {
            if (!result) result = [sections mutableCopy];
            result[i] = kept;
        }
    }
    if (removedOut) *removedOut = removed;
    return result ?: sections;
}

// Whether a home controller is the one being looked at: in a window and, in
// the home pager, the page that fills at least half of it.
static BOOL ControllerVisible(id controller) {
    if (![controller isKindOfClass:[UIViewController class]]) return NO;
    UIView* view = ((UIViewController*)controller).viewIfLoaded;
    UIWindow* window = view.window;
    if (!window || view.hidden) return NO;
    CGRect seen = CGRectIntersection([view convertRect:view.bounds toView:nil], window.bounds);
    return !CGRectIsNull(seen) && seen.size.height > 0 && seen.size.width >= window.bounds.size.width * 0.5;
}

// MARK: - Who A follows (7.3.151)
//
// "A follows whoever brought it" decides whether a tweet from B's stream is
// B's alone. It used to be learnt from every status row in A's Following tab
// (people A does not follow inside conversations included), kept up to 8000
// and never dropped an unfollow, so tweets lost their B mark and went as A.
// Once A's synced Following list exists (UnifiedFollowSync.x, kept current by
// UnifiedProfile.x's follow / unfollow results) only that list counts and
// what was learnt is dropped. Before the first sync, people are learnt only
// from standalone rows whose author A is shown to follow.
static NSSet<NSNumber*>* AFollowSet(NSArray* aFollowingItems) {
    NSString* aID = AID();
    NSMutableSet<NSNumber*>* result = [NSMutableSet set];
    if (aID.longLongValue > 0) [result addObject:@(aID.longLongValue)];  // A's own tweets
    if (aID.length == 0) return result;
    NSString* key = [@"kemo_unified_a_follows_" stringByAppendingString:aID];
    NSSet<NSNumber*>* synced = gKnownFollows[aID];
    if (synced) {
        [result unionSet:synced];
        if (gALearntFollows.count || [[NSUserDefaults standardUserDefaults] objectForKey:key]) {
            gALearntFollows = nil;
            gALearntFor = nil;
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
            UnifiedLog(@"A's synced Following list is there; what was learnt from the timeline is dropped");
        }
        gAFollowNote = [NSString stringWithFormat:@"synced list (%lu)", (unsigned long)synced.count];
        return result;
    }
    if (!gALearntFollows || ![gALearntFor isEqualToString:aID]) {
        gALearntFollows = [NSMutableSet set];
        gALearntFor = aID;
        for (id userID in [[NSUserDefaults standardUserDefaults] arrayForKey:key]) {
            if ([userID isKindOfClass:[NSNumber class]]) [gALearntFollows addObject:userID];
        }
    }
    NSUInteger before = gALearntFollows.count;
    for (id item in aFollowingItems) {
        // Standalone rows only: a conversation's rows may be anybody's.
        if (unwrapDataViewItem(item) != item || !IsStatusItem(item) || BoolGetter(item, @"isPromoted")) continue;
        if (NumberGetter(item, @"representedFromUserFollowedByCurrentAccountState") != 1) continue;
        long long author = NumberGetter(ActedStatusOf(item), @"fromUserID");
        if (author > 0) [gALearntFollows addObject:@(author)];
    }
    if (gALearntFollows.count != before) {
        NSArray* save = [gALearntFollows allObjects];
        if (save.count > 8000) save = [save subarrayWithRange:NSMakeRange(0, 8000)];
        [[NSUserDefaults standardUserDefaults] setObject:save forKey:key];
    }
    [result unionSet:gALearntFollows];
    gAFollowNote = [NSString stringWithFormat:@"no synced list yet; learnt from standalone rows (%lu)", (unsigned long)gALearntFollows.count];
    return result;
}

// MARK: - B's conversation modules (7.3.151)
//
// B's stream holds a reply chain as one URTTimelineModuleViewModel; A's section
// holds its own as rows (header, TFNDataViewItem-wrapped statuses, footer).
// The Following controller (THFHomeTimelineItemsViewController, in the app's
// main binary) keeps the TFNItemsSectionTransformer that makes those rows in
// its _sectionTransformer ivar; B's module is handed to that same transformer
// (-sectionsWithItems:), so its rows carry what A's own module rows carry.
// Anything not shaped like A's own module rows is left out, as before.

static const void* kModuleCacheKey = &kModuleCacheKey;
static NSString* gModuleTransformerNote = @"(not looked up yet)";
static NSString* gModuleNote = @"(no merge yet)";
static NSMutableSet<NSString*>* gAModuleShapes;  // what A's own wrapped status rows carry, as X made them
static NSMutableArray<NSString*>* gModuleWhys;   // each reason a module was left out, once

static BOOL IsModuleViewModel(id object) {
    return [NSStringFromClass([object class]) isEqualToString:@"URTTimelineModuleViewModel"];
}

static void NoteModuleWhy(NSString* why) {
    if (!why) return;
    if (!gModuleWhys) gModuleWhys = [NSMutableArray array];
    if ([gModuleWhys containsObject:why] || gModuleWhys.count >= 8) return;
    [gModuleWhys addObject:why];
    UnifiedLog([@"B module left out: " stringByAppendingString:why]);
}

// The adapter and section controller classes a wrapped row carries.
static NSString* RowShape(id row) {
    Class adapter = [Getter(row, @"dataViewAdapter") class];
    Class section = [Getter(row, @"sectionController") class];
    return [NSString stringWithFormat:@"adapter=%@ section=%@", adapter ? NSStringFromClass(adapter) : @"nil",
                                      section ? NSStringFromClass(section) : @"nil"];
}

// The controller's own section transformer, only when it is what the 12.44
// binary says it is (ivar _sectionTransformer, -sectionsWithItems: @24@0:8@16).
static id ModuleTransformer(id controller) {
    id transformer = nil;
    NSString* note = nil;
    Ivar ivar = class_getInstanceVariable([controller class], "_sectionTransformer");
    const char* type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!ivar || !type || type[0] != '@') {
        note = @"no _sectionTransformer ivar";
    } else {
        transformer = object_getIvar(controller, ivar);
        SEL selector = NSSelectorFromString(@"sectionsWithItems:");
        Class expected = objc_getClass("TFNItemsSectionTransformer");
        NSMethodSignature* signature =
            [transformer respondsToSelector:selector] ? [transformer methodSignatureForSelector:selector] : nil;
        BOOL usable = expected && [transformer isKindOfClass:expected] && signature && signature.numberOfArguments == 3 &&
                      signature.methodReturnType[0] == '@' && [signature getArgumentTypeAtIndex:2][0] == '@';
        note = [NSString stringWithFormat:@"%@ usable=%d", transformer ? NSStringFromClass([transformer class]) : @"nil", usable];
        if (!usable) transformer = nil;
    }
    if (![note isEqualToString:gModuleTransformerNote]) {
        gModuleTransformerNote = note;
        UnifiedLog([@"module transformer: " stringByAppendingString:note]);
    }
    return transformer;
}

// B's module as rows from A's controller's transformer: {rows, shape} when it
// is a conversation (wrapped statuses, with a header or footer at most),
// {other} when it is some other module, {why} when the result is not what a
// module of A's looks like. Kept per module while it stays in B's stream.
static NSDictionary* ModuleInfo(id transformer, id module, NSDictionary* oldCache, NSMutableDictionary* newCache) {
    NSValue* cacheKey = [NSValue valueWithNonretainedObject:module];
    NSDictionary* cached = oldCache[cacheKey];
    if (cached && cached[@"module"] == module) {
        newCache[cacheKey] = cached;
        return cached;
    }
    NSMutableDictionary* info = [NSMutableDictionary dictionaryWithObject:module forKey:@"module"];
    newCache[cacheKey] = info;
    id sections = nil;
    @try {
        sections = ((id (*)(id, SEL, id))objc_msgSend)(transformer, NSSelectorFromString(@"sectionsWithItems:"), @[ module ]);
    } @catch (NSException* exception) {
        info[@"why"] = [NSString stringWithFormat:@"sectionsWithItems: threw %@", exception.name];
        return info;
    }
    if (![sections isKindOfClass:[NSArray class]]) {
        info[@"why"] = [NSString stringWithFormat:@"sectionsWithItems: gave %@", sections ? NSStringFromClass([sections class]) : @"nil"];
        return info;
    }
    NSArray* rows = nil;
    NSUInteger filled = 0;
    for (id section in (NSArray*)sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            info[@"why"] = [NSString stringWithFormat:@"a section is %@", NSStringFromClass([section class])];
            return info;
        }
        if ([section count] == 0) continue;
        filled++;
        rows = section;
    }
    if (filled != 1) {
        info[@"why"] = [NSString stringWithFormat:@"%lu sections with rows", (unsigned long)filled];
        return info;
    }
    NSString* shape = nil;
    NSUInteger statuses = 0;
    for (id row in rows) {
        id model = unwrapDataViewItem(row);
        if (IsModuleHeaderItem(row) || IsModuleFooterItem(row)) continue;
        if (IsModuleViewModel(model)) {
            info[@"why"] = @"the module came back as it was";
            return info;
        }
        if (!IsStatusItem(model)) {
            // Who to follow, a carousel, a thread with a "show more" row: not ours.
            info[@"other"] = model ? NSStringFromClass([model class]) : @"nil";
            return info;
        }
        if (model == row) {
            info[@"why"] = @"a status row is not wrapped";
            return info;
        }
        if (BoolGetter(model, @"isPromoted") || NumberGetter(model, @"statusID") <= 0) {
            info[@"other"] = @"promoted or no status ID";
            return info;
        }
        NSString* rowShape = RowShape(row);
        if (shape && ![shape isEqualToString:rowShape]) {
            info[@"why"] = [NSString stringWithFormat:@"rows differ (%@ / %@)", shape, rowShape];
            return info;
        }
        shape = rowShape;
        statuses++;
    }
    if (statuses == 0 || !shape) {
        info[@"other"] = @"no statuses";
        return info;
    }
    info[@"rows"] = rows;
    info[@"shape"] = shape;
    return info;
}

// A unit of B's to place: a standalone status view model, or a module's rows.
static long long UnitKey(id unit) {
    return [unit isKindOfClass:[NSArray class]] ? BlockKey(unit) : SortKey(unit);
}

// One of B's statuses that has gone onto A's list: its class, by one rule for
// both tabs (7.3.151; the two merges had their own). A follows whoever brought
// it (the reposter for a repost): both have it. Else B follows whoever brought
// it: B's alone. Else B was only shown it: plain. `followedByB`: it stands on
// its own in B's Following stream, which is what B follows by construction.
static NSInteger ClassifyB(id object, BOOL followedByB, NSSet<NSNumber*>* aFollows, NSMutableDictionary* record) {
    long long statusID = NumberGetter(object, @"statusID");
    long long acted = ActedID(object);
    long long bringer = BringerID(object);
    id status = Getter(object, @"status");
    BOOL repost = Getter(status, @"representedStatus") != nil || (acted > 0 && acted != statusID);
    long long author = NumberGetter(ActedStatusOf(object), @"fromUserID");
    NSString* bID = BID();
    NSSet<NSNumber*>* bList = bID.length ? gKnownFollows[bID] : nil;
    BOOL shownFollowed = NumberGetter(object, @"representedFromUserFollowedByCurrentAccountState") == 1;  // B's state: B loaded it
    BOOL aFollowsBringer = bringer > 0 && [aFollows containsObject:@(bringer)];
    BOOL bFollowsBringer = followedByB || (bringer > 0 && ([bList containsObject:@(bringer)] || bringer == bID.longLongValue)) ||
                           (!repost && shownFollowed);
    NSInteger cls = aFollowsBringer ? kProvBBoth : (bFollowsBringer ? kProvBOnly : kProvBPlain);
    RecordEntry(record, object, cls);
    if (cls == kProvBBoth) [record[@"both"] addObject:@(statusID)];
    if (cls != kProvBOnly) return cls;
    [record[@"bOnly"] addObject:@(statusID)];
    if (acted > 0) [(NSMutableDictionary*)record[@"acted"] setObject:@(acted) forKey:@(statusID)];
    // Two separate things: who follows the reposter (why it is here) and
    // who follows the author. A repost is here for its reposter, so its
    // "reposted" line is B's; the name is B's only when B follows the
    // author and A is not known to.
    if (!repost) {
        [record[@"name"] addObject:@(statusID)];
    } else {
        [record[@"line"] addObject:@(statusID)];
        BOOL bFollowsAuthor = shownFollowed || [bList containsObject:@(author)];
        if (bFollowsAuthor && ![aFollows containsObject:@(author)]) [record[@"name"] addObject:@(statusID)];
    }
    return cls;
}

// Whether A's and B's streams share status objects: asked of every tweet both
// hold (see gStatusShared).
static void CheckSharedStatus(id aStatus, id bStatus) {
    if (!aStatus || !bStatus) return;
    gStatusSharedChecked++;
    if (aStatus == bStatus && !gStatusShared) {
        gStatusShared = YES;
        UnifiedLog(@"A's and B's streams share status objects; rows are told apart by their view models only");
    }
}

static NSArray* MergedSections(id controller, NSArray* sections) {
    NSMutableDictionary* record = NewRecord();
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
    // The originals A has (whoever reposted them), with A's own status objects.
    NSMutableSet<NSNumber*>* aActed = [NSMutableSet set];
    NSMutableDictionary<NSNumber*, id>* aStatusByID = [NSMutableDictionary dictionary];
    long long newestA = 0;
    for (id item in aItems) {
        id model = unwrapDataViewItem(item);
        if (!IsStatusItem(model)) continue;
        if (BoolGetter(model, @"isPromoted")) continue;
        long long acted = ActedID(model);
        if (acted > 0) {
            [aActed addObject:@(acted)];
            id actedStatus = ActedStatusOf(model);
            if (actedStatus) aStatusByID[@(acted)] = actedStatus;
        }
        newestA = MAX(newestA, SortKey(model));
    }
    // 7.3.151: who A follows comes from A's synced list (AFollowSet), not from
    // whoever A's rows happen to be by.
    NSSet<NSNumber*>* aBringers = AFollowSet(aItems);
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
    // 7.3.151: the bottom of A's range is the place of its bottom-most block
    // with a tweet (the smoothed key above), not the smallest key anywhere. One
    // old tweet in A (15 blocks were out of order on device) made the smallest
    // key far older than A's real bottom: nothing of B's counted as "older than
    // A", B loaded another page after every refresh, and what could not be
    // placed piled up (leftOver 265).
    long long oldestA = LLONG_MAX;
    for (NSInteger i = (NSInteger)blocks.count - 1; i >= 0; i--) {
        if (keys[i].longLongValue > 0 && places[i].longLongValue > 0) {
            oldestA = places[i].longLongValue;
            break;
        }
    }
    // What A's own module rows carry, as X hands them over.
    if (!gAModuleShapes) gAModuleShapes = [NSMutableSet set];
    for (id item in aItems) {
        if (gAModuleShapes.count >= 6) break;
        id model = unwrapDataViewItem(item);
        if (model != item && IsStatusItem(model)) [gAModuleShapes addObject:RowShape(item)];
    }

    NSMutableArray* bItems = [NSMutableArray array];
    NSMutableSet<NSNumber*>* both = record[@"both"];
    NSMutableSet<NSNumber*>* bothActed = [NSMutableSet set];  // the originals both have
    long long oldestB = LLONG_MAX;
    for (id object in bObjects) {
        if (IsStatusItem(object) && SortKey(object) > 0) oldestB = MIN(oldestB, SortKey(object));
    }
    // A reaches further back than B: B loads its next page (7.3.141; X's own
    // load-more for the home tab does not go through loadBottomWithSource:).
    // 7.3.151: "further back" is by A's bottom place (above), so this asks for
    // B's next page only once A's bottom really is below B's oldest; and only
    // for the controller being looked at, within the page budget (LoadMoreB).
    if (oldestB != LLONG_MAX && oldestA != LLONG_MAX && oldestA < oldestB) {
        LoadMoreB(controller, gLastASource, @"A is older than B");
    }
    NSUInteger dupes = 0, older = 0, promoted = 0, followedByA = 0, newer = 0;
    NSMutableSet<NSNumber*>* bTaken = [NSMutableSet set];  // B's statuses that are going in
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
            if (acted > 0) {
                [bothActed addObject:@(acted)];
                CheckSharedStatus(aStatusByID[@(acted)], ActedStatusOf(object));
            }
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
        // 7.3.151: classed (ClassifyB) once it really goes onto the list, below.
        [bItems addObject:object];
        [bTaken addObject:@(statusID)];
    }

    // 7.3.151: B's conversation modules, each as one block of rows made by this
    // controller's own transformer. A module A has any tweet of is left out
    // whole (A's copy shows); so is anything that is not a plain conversation
    // or whose rows are not shaped like A's own module rows.
    NSUInteger modSeen = 0, modInserted = 0, modDupes = 0, modBad = 0, modOther = 0, modRange = 0;
    NSMutableDictionary<NSString*, NSNumber*>* otherClasses = [NSMutableDictionary dictionary];
    NSString* lastShape = @"-";
    id transformer = ModuleTransformer(controller);
    NSDictionary* oldCache = objc_getAssociatedObject(controller, kModuleCacheKey);
    NSMutableDictionary* newCache = [NSMutableDictionary dictionary];
    for (id object in bObjects) {
        if (IsStatusItem(object)) continue;
        NSString* className = NSStringFromClass([object class]) ?: @"?";
        otherClasses[className] = @(otherClasses[className].unsignedIntegerValue + 1);
        if (!IsModuleViewModel(object)) continue;
        modSeen++;
        if (!transformer) {
            modBad++;
            NoteModuleWhy([@"transformer: " stringByAppendingString:gModuleTransformerNote]);
            continue;
        }
        NSDictionary* info = ModuleInfo(transformer, object, oldCache, newCache);
        NSArray* rows = info[@"rows"];
        if (!rows) {
            if (info[@"other"]) {
                modOther++;
            } else {
                modBad++;
                NoteModuleWhy(info[@"why"] ?: @"no rows");
            }
            continue;
        }
        lastShape = info[@"shape"];
        if (![gAModuleShapes containsObject:lastShape]) {
            modBad++;
            NoteModuleWhy([NSString stringWithFormat:@"rows carry %@, A's carry %@", lastShape,
                                                     gAModuleShapes.count ? [[gAModuleShapes allObjects] componentsJoinedByString:@" / "]
                                                                          : @"(A shows no module yet)"]);
            continue;
        }
        NSMutableArray* children = [NSMutableArray array];
        BOOL duplicate = NO;
        for (id row in rows) {
            id model = unwrapDataViewItem(row);
            if (!IsStatusItem(model)) continue;
            [children addObject:model];
            long long statusID = NumberGetter(model, @"statusID");
            long long acted = ActedID(model);
            if ([aIDs containsObject:@(statusID)] || (acted > 0 && [aActed containsObject:@(acted)])) {
                duplicate = YES;
                [both addObject:@(statusID)];
                if (acted > 0) [bothActed addObject:@(acted)];
            } else if ([bTaken containsObject:@(statusID)]) {
                duplicate = YES;  // already going in on its own
            }
        }
        if (duplicate) {
            modDupes++;
            continue;
        }
        long long key = BlockKey(rows);
        if (key <= 0 || key <= oldestA || (newestA > 0 && key > newestA)) {
            modRange++;
            continue;
        }
        [bItems addObject:rows];
        for (id child in children) [bTaken addObject:@(NumberGetter(child, @"statusID"))];
    }
    objc_setAssociatedObject(controller, kModuleCacheKey, newCache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [bItems sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [@(UnitKey(b)) compare:@(UnitKey(a))];
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
            while (next < bItems.count && UnitKey(bItems[next]) > place) {
                id unit = bItems[next++];
                if ([unit isKindOfClass:[NSArray class]]) {
                    // A module's rows go in as one run, between two of A's blocks.
                    [merged addObjectsFromArray:unit];
                    modInserted++;
                    // 7.3.151: every row is remembered as B's; a conversation's
                    // tweets are B's alone only where B is known to follow.
                    for (id row in (NSArray*)unit) {
                        NoteBRow(row);
                        id model = unwrapDataViewItem(row);
                        if (IsStatusItem(model) && ClassifyB(model, NO, aBringers, record) == kProvBBoth) followedByA++;
                    }
                } else {
                    [merged addObject:unit];
                    if (ClassifyB(unit, YES, aBringers, record) == kProvBBoth) followedByA++;
                }
            }
        }
        [merged addObjectsFromArray:block];
    }
    NSMutableArray<NSString*>* otherParts = [NSMutableArray array];
    for (NSString* name in otherClasses) [otherParts addObject:[NSString stringWithFormat:@"%@ x%@", name, otherClasses[name]]];
    gModuleNote = [NSString stringWithFormat:@"transformer %@ | B's other objects: %@ | B rows %@ | A rows %@ | left out: %@",
                                             gModuleTransformerNote,
                                             otherParts.count ? [otherParts componentsJoinedByString:@", "] : @"(none)", lastShape,
                                             gAModuleShapes.count ? [[gAModuleShapes allObjects] componentsJoinedByString:@" / "] : @"(none)",
                                             gModuleWhys.count ? [gModuleWhys componentsJoinedByString:@"; "] : @"(nothing)"];

    // A's standalone statuses newer than B's oldest: B would have them if it
    // followed their source, so they count as A-only.
    // 7.3.151: A's own rows are marked too (by object): the ones B has as
    // well, and the standalone ones that count as A-only.
    for (id item in aItems) {
        id model = unwrapDataViewItem(item);
        if (!IsStatusItem(model)) continue;
        long long statusID = NumberGetter(model, @"statusID");
        if (statusID <= 0) continue;
        long long acted = ActedID(model);
        if ([both containsObject:@(statusID)] || (acted > 0 && [bothActed containsObject:@(acted)])) {
            [both addObject:@(statusID)];
            RecordEntry(record, model, kProvABoth);
        } else if (model == item && SortKey(model) > oldestB) {
            [record[@"aOnly"] addObject:@(statusID)];
            RecordEntry(record, model, kProvAOnly);
        }
    }
    objc_setAssociatedObject(controller, kRecordKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gLastMerge = [NSString stringWithFormat:@"A items=%lu blocks=%lu statuses=%lu (raw %lu, wrapped %lu) | B inserted=%lu "
                                            @"(followed by A %lu, newer than A %lu) "
                                            @"both=%lu olderThanA=%lu promoted=%lu leftOver=%lu | A outOfOrder=%lu | "
                                            @"B modules seen=%lu inserted=%lu duplicate=%lu untransformable=%lu "
                                            @"notConversation=%lu outOfRange=%lu",
                                            (unsigned long)aItems.count, (unsigned long)blocks.count,
                                            (unsigned long)best, (unsigned long)raw, (unsigned long)wrappedCount,
                                            (unsigned long)next, (unsigned long)followedByA, (unsigned long)newer,
                                            (unsigned long)dupes, (unsigned long)older,
                                            (unsigned long)promoted, (unsigned long)(bItems.count - next),
                                            (unsigned long)outOfOrder, (unsigned long)modSeen, (unsigned long)modInserted,
                                            (unsigned long)modDupes, (unsigned long)modBad, (unsigned long)modOther,
                                            (unsigned long)modRange];
    NSMutableArray* result = [sections mutableCopy];
    result[target] = merged;
    return result;
}

// 7.3.151: B's For You pages asked for since A's For You was last refreshed
// or loaded more itself (at most kMoreBudget), and what B's stream looked
// like when the last one was asked for (no progress since: no further page).
static const NSUInteger kMoreBudget = 2;
static NSUInteger gBForYouMorePages;
static BOOL gBForYouMoreAsked;
static NSUInteger gBForYouMoreCount;
static NSUInteger gBMorePages;
static BOOL gBMoreAsked;
static NSUInteger gBMoreCount;
static long long gBMoreOldest;
static NSString* gMoreNote = @"-";

static void LoadMoreBForYou(id controller, NSUInteger bCount) {
    if (!ControllerVisible(controller)) return;  // never from a merge of a tab that is not being looked at
    static CFAbsoluteTime last;
    if (CFAbsoluteTimeGetCurrent() - last <= 5) return;
    if (gBForYouMorePages >= kMoreBudget) {
        gMoreNote = @"For You: page budget used; waits for A to refresh or load more";
        return;
    }
    if (gBForYouMoreAsked && gBForYouMoreCount == bCount) {
        gMoreNote = @"For You: the last page brought nothing; no further page";
        return;
    }
    id account = VerifiedB();
    id bStream = Getter(gBForYouTimeline, @"stream");
    SEL more = NSSelectorFromString(@"loadBottomWithSource:");
    if (!account || gBForYouAccount != account || !bStream || ![bStream respondsToSelector:more]) return;
    last = CFAbsoluteTimeGetCurrent();
    gBForYouMorePages++;
    gBForYouMoreAsked = YES;
    gBForYouMoreCount = bCount;
    gReqForYouMore++;
    @try {
        BOOL started = ((BOOL (*)(id, SEL, long long))objc_msgSend)(bStream, more, gLastASource);
        UnifiedLog([NSString stringWithFormat:@"B For You more started=%d (page %lu/%lu)", started, (unsigned long)gBForYouMorePages,
                                              (unsigned long)kMoreBudget]);
    } @catch (__unused NSException* exception) {
    }
}

// A's For You with B's mixed in half and half: after each of A's blocks that
// holds a tweet, one of B's (in B's own order). B's ads and tweets A already
// has are left out; what is left over waits for A to load more.
static NSArray* MergedForYou(id controller, NSArray* sections) {
    NSMutableDictionary* record = NewRecord();
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
    NSMutableSet<NSNumber*>* both = record[@"both"];
    NSMutableSet<NSNumber*>* bothActed = [NSMutableSet set];
    NSSet<NSNumber*>* aFollows = AFollowSet(nil);
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
            if (acted > 0) [bothActed addObject:@(acted)];
            continue;
        }
        [bItems addObject:object];
    }
    NSArray<NSArray*>* blocks = Blocks(aItems);
    NSMutableArray* merged = [NSMutableArray arrayWithCapacity:aItems.count + bItems.count];
    NSUInteger next = 0;
    for (NSArray* block in blocks) {
        [merged addObjectsFromArray:block];
        if (BlockKey(block) > 0 && next < bItems.count) {
            id object = bItems[next++];
            [merged addObject:object];
            // 7.3.147: B's For You is recommendations; marks and B reactions
            // only when B follows whoever brought it and A does not. A tweet B
            // was only recommended is shown plain and reacts as A.
            // 7.3.151: by the same rule as the Following tab (ClassifyB), and
            // only for what really went onto the list.
            if (ClassifyB(object, NO, aFollows, record) == kProvBBoth) followedByA++;
        }
    }
    // A's own rows that B has too.
    for (id item in aItems) {
        id model = unwrapDataViewItem(item);
        if (!IsStatusItem(model)) continue;
        long long statusID = NumberGetter(model, @"statusID");
        long long acted = ActedID(model);
        if (statusID > 0 && ([both containsObject:@(statusID)] || (acted > 0 && [bothActed containsObject:@(acted)]))) {
            [both addObject:@(statusID)];
            RecordEntry(record, model, kProvABoth);
        }
    }
    objc_setAssociatedObject(controller, kRecordKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gLastForYouMerge = [NSString stringWithFormat:@"A statuses=%lu blocks=%lu | B inserted=%lu of %lu (followed by A %lu) "
                                                 @"same as A=%lu ads=%lu",
                                                 (unsigned long)best, (unsigned long)blocks.count, (unsigned long)next,
                                                 (unsigned long)bItems.count, (unsigned long)followedByA,
                                                 (unsigned long)dupes, (unsigned long)ads];
    if (next >= bItems.count && blocks.count > bItems.count) {
        // B ran out before A did: B's next page (7.3.151: within LoadMoreBForYou's limits).
        LoadMoreBForYou(controller, [bObjects count]);
    }
    NSMutableArray* result = [sections mutableCopy];
    result[target] = merged;
    return result;
}

static NSMutableArray<NSString*>* gMergeHistory;
static BOOL gUnmerging;  // A's lists are being given back as X made them
static const void* kReapplyOwedKey = &kReapplyOwedKey;

static NSArray* SectionsForController(id controller, NSArray* sections) {
    if (!sections || gUnmerging || !UnifiedActive()) return sections;
    BOOL forYou = IsForYouController(controller);
    if (!forYou && !IsFollowingController(controller)) return sections;
    // 7.3.151: never count a row of B's as A's (see StripBLoaded).
    NSUInteger stripped = 0;
    sections = StripBLoaded(sections, &stripped);
    if (stripped) UnifiedLog([NSString stringWithFormat:@"%lu of B's rows were in the sections handed over; taken out", (unsigned long)stripped]);
    objc_setAssociatedObject(controller, kOriginalSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, kReapplyOwedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gFollowingControllers) gFollowingControllers = [NSHashTable weakObjectsHashTable];
    [gFollowingControllers addObject:controller];
    // This merge's marks replace the controller's last ones, whatever happens.
    objc_setAssociatedObject(controller, kRecordKey, NewRecord(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray* result = sections;
    if (forYou) {
        if (BForYouTimeline()) {
            @try {
                result = MergedForYou(controller, sections);
            } @catch (NSException* exception) {
                gLastForYouMerge = [NSString stringWithFormat:@"For You merge threw %@", exception.name];
                objc_setAssociatedObject(controller, kRecordKey, NewRecord(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                result = sections;
            }
        }
    } else if (BTimeline()) {
        @try {
            result = MergedSections(controller, sections);
        } @catch (NSException* exception) {
            gLastMerge = [NSString stringWithFormat:@"merge threw %@", exception.name];
            objc_setAssociatedObject(controller, kRecordKey, NewRecord(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            result = sections;
        }
        // The last few merges, to see what happened when the tab suddenly changes.
        if (!gMergeHistory) gMergeHistory = [NSMutableArray array];
        NSDateFormatter* formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss";
        [gMergeHistory addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], gLastMerge]];
        while (gMergeHistory.count > 6) [gMergeHistory removeObjectAtIndex:0];
    }
    RebuildMarks();
    NoteGuard();
    return result;
}

static BOOL gReapplyQueued;
static BOOL gReapplyFollowing;
static BOOL gReapplyForYou;

// One controller's last sections from X, merged again.
static void ReapplyController(id controller) {
    NSArray* original = objc_getAssociatedObject(controller, kOriginalSectionsKey);
    SEL set = @selector(setSections:restoreScrollPosition:);
    if (!original || ![controller respondsToSelector:set]) return;
    @try {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, set, original, YES);
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"re-merge threw %@", exception.name]);
    }
}

// When B's stream changes, give the tab it belongs to its last sections from X
// again. 7.3.151: only that tab's controller, only while it is in a window
// (one that is not gets it when it is next displayed), and never when the
// mode is not active (an old snapshot rewound A's home list).
static void ReapplyMerge(BOOL following, BOOL forYou) {
    gReapplyFollowing = gReapplyFollowing || following;
    gReapplyForYou = gReapplyForYou || forYou;
    if (gReapplyQueued) return;
    gReapplyQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gReapplyQueued = NO;
        BOOL doFollowing = gReapplyFollowing, doForYou = gReapplyForYou;
        gReapplyFollowing = NO;
        gReapplyForYou = NO;
        if (!UnifiedActive()) return;
        for (id controller in [gFollowingControllers allObjects]) {
            BOOL isForYou = IsForYouController(controller);
            if (isForYou ? !doForYou : !doFollowing) continue;
            UIView* view = [controller isKindOfClass:[UIViewController class]] ? ((UIViewController*)controller).viewIfLoaded : nil;
            if (!view.window) {
                objc_setAssociatedObject(controller, kReapplyOwedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                continue;
            }
            ReapplyController(controller);
        }
    });
}

// MARK: - Notice

extern void NFBShowNotice(NSString* text);

// 7.3.150: X-style toast (UnifiedSheet.x).
static void ShowNotice(NSString* text) {
    NFBShowNotice(text);
}

// 7.3.151: something was stopped: the same toast with a warning haptic
// (UnifiedSheet.x). The text ends with what to do next.
extern void NFBShowBlockNotice(NSString* text);

static void ShowBlockNotice(NSString* text) {
    NFBShowBlockNotice(text);
}

static NSUInteger gBlocked;
// 7.3.151: of those, the ones stopped because the account was wrong or not
// certain, with the last three reasons (for the dump).
static NSUInteger gAccountBlocked;
static NSMutableArray<NSString*>* gBlockReasons;

static void Blocked(NSString* reason, NSString* toast) {
    gBlocked++;
    gAccountBlocked++;
    if (!gBlockReasons) gBlockReasons = [NSMutableArray array];
    [gBlockReasons addObject:reason ?: @"?"];
    while (gBlockReasons.count > 3) [gBlockReasons removeObjectAtIndex:0];
    UnifiedLog([@"blocked: " stringByAppendingString:reason ?: @"?"]);
    if (toast) ShowBlockNotice(toast);
}

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

// Likes, reposts and bookmarks made in this session with an explicit call on
// an account (kind: 0 like, 1 repost, 2 bookmark), so a second tap undoes
// them. 7.3.151: per account: B's as before, and A's own explicit ones on rows
// whose copy on screen was loaded as B (X's flags there are B's).
static NSMutableSet<NSNumber*>* gDone[2][3];
static NSMutableSet<NSNumber*>* gUndone[2][3];

static NSMutableSet<NSNumber*>* Done(BOOL asB, int kind) {
    if (!gDone[asB ? 1 : 0][kind]) gDone[asB ? 1 : 0][kind] = [NSMutableSet set];
    return gDone[asB ? 1 : 0][kind];
}

static NSMutableSet<NSNumber*>* Undone(BOOL asB, int kind) {
    if (!gUndone[asB ? 1 : 0][kind]) gUndone[asB ? 1 : 0][kind] = [NSMutableSet set];
    return gUndone[asB ? 1 : 0][kind];
}

static NSString* SideName(BOOL asB) {
    return asB ? BName() : AName();
}

// 7.3.151: returns NO when nothing was sent (the callers went on to say
// "sent" and to remember the action). `account` is VerifiedB() or VerifiedA(),
// taken by the caller just before.
static BOOL CallStatusMethod(id account, BOOL asB, NSString* selectorName, long long statusID) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!account || ![account respondsToSelector:selector]) {
        UnifiedLog([NSString stringWithFormat:@"%@ account has no %@", asB ? @"B" : @"A", selectorName]);
        ShowBlockNotice([NSString stringWithFormat:@"이 X 버전에서는 %@로 보낼 수 없어요. %@ 계정으로 전환해서 해주세요", SideName(asB), SideName(asB)]);
        return NO;
    }
    void (^response)(void) = ^{
    };
    @try {
        ((void (*)(id, SEL, long long, id))objc_msgSend)(account, selector, statusID, response);
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"%@ threw %@", selectorName, exception.name]);
        ShowBlockNotice([NSString stringWithFormat:@"%@로 보내지 못했어요. 잠시 뒤 다시 눌러주세요", SideName(asB)]);
        return NO;
    }
    return YES;
}

static id BStatusFor(long long actedID);
static id AStatusFor(long long actedID);

#import <malloc/malloc.h>

// 7.3.151: B's like / repost state of a tweet as X answered when asked as B
// (LookUpBState, below), kept per (pair, tweet) for the session. Main thread
// only. An entry holds liked, reposted (NSNumber), status (B's copy, for its
// repost ID) and acted (a repost or undo was sent as B since).
static NSMutableDictionary<NSString*, NSMutableDictionary*>* gBLookups;
static NSMutableDictionary<NSString*, NSMutableArray*>* gBLookupWaiters;
static NSUInteger gBLookupsSent;
static NSUInteger gALookupsSent;

// 7.3.151: kept per (pair, account, tweet): A's state is looked up too, for
// rows whose copy on screen was loaded as B.
static NSString* LookupKey(BOOL asB, long long statusID) {
    return [NSString stringWithFormat:@"%@|%@|%lld", gPairKey ?: @"", asB ? @"B" : @"A", statusID];
}

static NSMutableDictionary* LookedUp(BOOL asB, long long statusID) {
    return statusID > 0 ? gBLookups[LookupKey(asB, statusID)] : nil;
}

// What was done with explicit calls in this session, and what was looked up.
static void SessionClear(void) {
    for (int side = 0; side < 2; side++) {
        for (int kind = 0; kind < 3; kind++) {
            [gDone[side][kind] removeAllObjects];
            [gUndone[side][kind] removeAllObjects];
        }
    }
    [gBLookups removeAllObjects];
    BadgeMemoClear();
}

// X's own flag on a status, which is the flag of the account that loaded it.
static BOOL LoadedFlag(id status, int kind) {
    if (kind == 0) return BoolGetter(status, @"favoritedByLoadingAccount") || BoolGetter(status, @"seenAsFavorited");
    if (kind == 1) return BoolGetter(status, @"seenAsRetweeted");
    return BoolGetter(status, @"bookmarkedByLoadingAccount") || BoolGetter(status, @"seenAsBookmarked");
}

// One account's like / repost / bookmark of the tweet `status` (the acted one):
// 1 done, 0 not, -1 not known. screenIsTheirs: the copy on screen was loaded
// by that account, so its flags are that account's; otherwise only that
// account's own copy counts (7.3.150). In order: what was done with explicit
// calls in this session, the account's own copy (on screen or in its own
// streams), what X answered when asked as that account (LookUpState). Never
// the other account's flag: "not known" only ever offers the action itself.
static int SideState(BOOL asB, int kind, id status, BOOL screenIsTheirs) {
    long long statusID = NumberGetter(status, @"statusID");
    if (statusID <= 0) return -1;
    NSNumber* key = @(statusID);
    if ([gDone[asB ? 1 : 0][kind] containsObject:key]) return 1;
    if ([gUndone[asB ? 1 : 0][kind] containsObject:key]) return 0;
    NSDictionary* looked = LookedUp(asB, statusID);
    if (kind == 1 && looked[@"acted"]) return [looked[@"reposted"] boolValue] ? 1 : 0;
    id own = screenIsTheirs ? status : (asB ? BStatusFor(statusID) : AStatusFor(statusID));
    if (own) return LoadedFlag(own, kind) ? 1 : 0;
    NSNumber* answer = looked[kind == 0 ? @"liked" : (kind == 1 ? @"reposted" : @"bookmarked")];
    return answer ? (answer.boolValue ? 1 : 0) : -1;
}

// Where each of those answers came from, for the log.
static NSString* SideSource(BOOL asB, id status, BOOL screenIsTheirs, int kind) {
    long long statusID = NumberGetter(status, @"statusID");
    NSNumber* key = @(statusID);
    NSDictionary* looked = LookedUp(asB, statusID);
    if ([gDone[asB ? 1 : 0][kind] containsObject:key] || [gUndone[asB ? 1 : 0][kind] containsObject:key]) return @"session";
    if (kind == 1 && looked[@"acted"]) return @"session";
    if (screenIsTheirs) return asB ? @"screen, loaded as B" : @"screen, loaded as A";
    if (asB ? BStatusFor(statusID) != nil : AStatusFor(statusID) != nil) return asB ? @"B's copy" : @"A's copy";
    return looked[kind == 0 ? @"liked" : (kind == 1 ? @"reposted" : @"bookmarked")] ? @"lookup" : @"unknown";
}

// A repost or its undo sent with an explicit call: the looked-up state no longer counts.
static void LookupNoteRepost(BOOL asB, long long statusID, BOOL reposted) {
    NSMutableDictionary* entry = LookedUp(asB, statusID);
    if (!entry) {
        // Done() covers a repost; an undo has to be remembered here.
        if (reposted || statusID <= 0) return;
        if (!gBLookups) gBLookups = [NSMutableDictionary dictionary];
        entry = [NSMutableDictionary dictionary];
        gBLookups[LookupKey(asB, statusID)] = entry;
    }
    entry[@"reposted"] = @(reposted);
    entry[@"acted"] = @YES;
    [entry removeObjectForKey:@"status"];
}

// An argument of a block whose signature the dump does not give, taken as a
// TFNTwitterStatus only when it provably is one: a heap allocation at least
// that big whose class is exactly TFNTwitterStatus. Anything else is nil.
static id StatusFromUnknownArg(void* arg) {
    Class statusClass = objc_getClass("TFNTwitterStatus");
    uintptr_t value = (uintptr_t)arg;
    if (!statusClass || value < 0x10000 || (value & 0xF) != 0 || (value >> 48) != 0) return nil;
    if (!malloc_zone_from_ptr(arg) || malloc_size(arg) < class_getInstanceSize(statusClass)) return nil;
    Class isa = ((Class (*)(void*))object_getClass)(arg);
    return isa == statusClass ? (__bridge id)arg : nil;
}

// Why a status that came back is not taken as B's view of the tweet (nil: it
// is). TFNTwitterStatus has no "loading account" to read (12.44 dump), so the
// proof is the receiver (B's own account / B's own model) plus this: it must
// not be, or share its canonical status with, the copy on screen, which is A's.
// 7.3.151: the same holds the other way round when A is asked about a row
// whose copy on screen is B's.
static NSString* BLookupDistrust(id found, long long statusID, id screenStatus) {
    if (![found isKindOfClass:objc_getClass("TFNTwitterStatus")]) return @"not a status";
    if (NumberGetter(found, @"statusID") != statusID) return @"another tweet";
    if (found == screenStatus) return @"the very object on screen (the other account's)";
    id canonical = Getter(found, @"canonicalStatus");
    if (canonical && canonical == Getter(screenStatus, @"canonicalStatus")) return @"shares the canonical status of the copy on screen";
    return nil;
}

static void BLookupFinish(NSString* key, BOOL asB, long long statusID, id found, NSString* how, NSString* why) {
    NSArray* waiters = gBLookupWaiters[key];
    if (!waiters) return;  // answered already (the timeout, or a second callback)
    [gBLookupWaiters removeObjectForKey:key];
    NSString* letter = asB ? @"B" : @"A";
    if (found) {
        NSMutableDictionary* entry = gBLookups[key] ?: [NSMutableDictionary dictionary];
        BOOL liked = BoolGetter(found, @"favoritedByLoadingAccount") || BoolGetter(found, @"seenAsFavorited");
        entry[@"liked"] = @(liked);
        // 7.3.151: the same answer carries the account's bookmark (no further request).
        entry[@"bookmarked"] = @(BoolGetter(found, @"bookmarkedByLoadingAccount") || BoolGetter(found, @"seenAsBookmarked"));
        if (!entry[@"acted"]) {
            entry[@"reposted"] = @(BoolGetter(found, @"seenAsRetweeted"));
            entry[@"status"] = found;
        }
        if (gBLookups.count > 300) [gBLookups removeAllObjects];
        gBLookups[key] = entry;
        UnifiedLog([NSString stringWithFormat:@"sheet: %@ state lookup for %lld -> liked=%d reposted=%d bookmarked=%d (loadedBy=%@, %@)", letter,
                                              statusID, liked, [entry[@"reposted"] boolValue], [entry[@"bookmarked"] boolValue], letter, how]);
    } else {
        UnifiedLog([NSString stringWithFormat:@"sheet: %@ state lookup for %lld -> failed (%@)", letter, statusID, why ?: @"?"]);
    }
    BadgeMemoClear();
    for (void (^waiter)(void) in waiters) waiter();
}

// 7.3.151: asks X, as B, for one tweet so the long-press sheet can show B's
// like / repost state. This is a read request to X's servers with B's account:
// -[TFNTwitterAccount _fetchRemoteStatusWithID:responseBlock:] (q, block;
// 12.44 dump), sent only from the like / repost / bookmark sheet
// (PresentReactionSheet: a long press, or a tap that asks) when B's state is
// not known and no answer is kept, once per tweet at a time. If it gives no status, B's own
// model is asked (-[TFNTwitterAccountModel lookUpStatusForID:completionBlock:],
// as PostInteractions.x calls it). `done` runs on the main thread, also when
// nothing came back within 6 seconds; the answer is then in LookedUp().
// 7.3.151: the account is VerifiedB() taken here. With asB NO the same request
// goes out with A's own account (VerifiedA()), for a row whose copy on screen
// was loaded as B: A's state is not on screen there.
static void LookUpState(BOOL asB, long long statusID, id screenStatus, void (^done)(void)) {
    NSString* key = LookupKey(asB, statusID);
    if (!gBLookups) gBLookups = [NSMutableDictionary dictionary];
    if (!gBLookupWaiters) gBLookupWaiters = [NSMutableDictionary dictionary];
    NSMutableArray* waiters = gBLookupWaiters[key];
    if (waiters) {
        // Already asked and not answered yet: no second request.
        [waiters addObject:[done copy]];
        return;
    }
    waiters = [NSMutableArray arrayWithObject:[done copy]];
    gBLookupWaiters[key] = waiters;

    // Only that account, verified now (B: never the one in use; A: the one in use).
    id account = asB ? VerifiedB() : VerifiedA();
    NSString* letter = asB ? @"B" : @"A";
    if (!account) {
        BLookupFinish(key, asB, statusID, nil, nil,
                      asB ? [NSString stringWithFormat:@"B's account not certain (%@)", gVerifiedBWhy ?: @"?"] : @"A's account not certain");
        return;
    }

    void (^fromModel)(NSString*) = ^(NSString* whyNot) {
        id model = Getter(account, @"model");
        SEL lookUp = NSSelectorFromString(@"lookUpStatusForID:completionBlock:");
        if (!model || Getter(model, @"account") != account || ![model respondsToSelector:lookUp]) {
            BLookupFinish(key, asB, statusID, nil, nil, [NSString stringWithFormat:@"%@; the account's model not usable", whyNot]);
            return;
        }
        void (^completion)(id) = ^(id modelStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString* distrust = modelStatus ? BLookupDistrust(modelStatus, statusID, screenStatus) : @"not in the account's model";
                BLookupFinish(key, asB, statusID, distrust ? nil : modelStatus, @"the account's model",
                              distrust ? [NSString stringWithFormat:@"%@; %@", whyNot, distrust] : nil);
            });
        };
        @try {
            ((void (*)(id, SEL, long long, id))objc_msgSend)(model, lookUp, statusID, completion);
        } @catch (NSException* exception) {
            BLookupFinish(key, asB, statusID, nil, nil, [NSString stringWithFormat:@"%@; model lookup threw %@", whyNot, exception.name]);
        }
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Only this request's waiters: a later one for the tweet has its own.
        if (gBLookupWaiters[key] == waiters) BLookupFinish(key, asB, statusID, nil, nil, @"no answer in 6s");
    });

    SEL fetch = NSSelectorFromString(@"_fetchRemoteStatusWithID:responseBlock:");
    if (![account respondsToSelector:fetch]) {
        UnifiedLog([NSString stringWithFormat:@"sheet: %@ state lookup for %lld started (the account's model only)", letter, statusID]);
        fromModel(@"no _fetchRemoteStatusWithID:responseBlock:");
        return;
    }
    // The response block's arguments are not in the dump: they are taken as raw
    // words and only a provable TFNTwitterStatus among them is used.
    void (^response)(void*, void*, void*) = ^(void* first, void* second, void* third) {
        id found = StatusFromUnknownArg(first) ?: StatusFromUnknownArg(second) ?: StatusFromUnknownArg(third);
        NSString* shape = [NSString stringWithFormat:@"args %p %p %p", first, second, third];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!found) {
                fromModel([NSString stringWithFormat:@"fetch gave no status (%@)", shape]);
                return;
            }
            NSString* distrust = BLookupDistrust(found, statusID, screenStatus);
            BLookupFinish(key, asB, statusID, distrust ? nil : found, asB ? @"fetched as B" : @"fetched as A", distrust);
        });
    };
    if (asB) gBLookupsSent++;
    else gALookupsSent++;
    UnifiedLog([NSString stringWithFormat:@"sheet: %@ state lookup for %lld started (_fetchRemoteStatusWithID as %@, #%lu)", letter, statusID,
                                          letter, (unsigned long)(asB ? gBLookupsSent : gALookupsSent)]);
    @try {
        (void)((id (*)(id, SEL, long long, id))objc_msgSend)(account, fetch, statusID, response);
    } @catch (NSException* exception) {
        fromModel([NSString stringWithFormat:@"fetch threw %@", exception.name]);
    }
}

// MARK: - Sending with an explicit account (7.3.151)
//
// Like, repost and bookmark sent by this file go out with the receiver of the
// call: VerifiedB() (B rows, B screens, the sheet's B row) or VerifiedA() (a
// row whose copy on screen was loaded as B but which is A's to act on, and
// the sheet's A row there). The account is taken at the moment of sending;
// with none, nothing is sent and a notice says so. X's own tap path is only
// ever used on a status that A loaded.

static id SendAccount(BOOL asB, NSString* what) {
    id account = asB ? VerifiedB() : VerifiedA();
    if (account) return account;
    Blocked([NSString stringWithFormat:@"%@ as %@: account not verified (%@)", what, asB ? @"B" : @"A",
                                       asB ? (gVerifiedBWhy ?: @"?") : @"the account in use is not the saved A"],
            asB ? @"B 계정을 확인하지 못해서 보내지 않았어요. kemo 설정에서 B 계정을 다시 골라주세요"
                : @"A 계정을 확인하지 못해서 보내지 않았어요. 계정을 확인한 뒤 다시 눌러주세요");
    return nil;
}

// screenIsTheirs: the copy on screen was loaded by that account (see SideState).
static void LikeAs(BOOL asB, id viewModel, BOOL screenIsTheirs) {
    id status = ActedStatus(viewModel);
    long long statusID = NumberGetter(status, @"statusID");
    if (statusID <= 0) return;
    id account = SendAccount(asB, @"like");
    if (!account) return;
    BOOL liked = SideState(asB, 0, status, screenIsTheirs) == 1;
    if (liked) {
        if (!CallStatusMethod(account, asB, @"unfavoriteStatusWithStatusID:responseBlock:", statusID)) return;
        [Done(asB, 0) removeObject:@(statusID)];
        [Undone(asB, 0) addObject:@(statusID)];
        ShowNotice([NSString stringWithFormat:@"%@로 마음에 들어요 취소를 보냈어요", SideName(asB)]);
    } else {
        if (!CallStatusMethod(account, asB, @"favoriteStatusWithStatusID:responseBlock:", statusID)) return;
        [Done(asB, 0) addObject:@(statusID)];
        [Undone(asB, 0) removeObject:@(statusID)];
        ShowNotice([NSString stringWithFormat:@"♥ %@로 마음에 들어요를 보냈어요", SideName(asB)]);
    }
    BadgeMemoClear();
    UnifiedLog(asB ? [NSString stringWithFormat:@"%@ as B", liked ? @"unlike" : @"like"]
                   : [NSString stringWithFormat:@"%@ as A (explicit) on a B row", liked ? @"unlike" : @"like"]);
}

static BOOL IsProtectedStatus(id status) {
    return BoolGetter(Getter(status, @"fromUser"), @"protectedUser");
}

// statusIsB: the tweet on screen was loaded as B, so its bookmark flag is B's.
// 7.3.151: on a tweet both have, the flag on screen is A's; reading it made
// "bookmark as B" send a removal when A had it bookmarked. B's state comes
// from SideState() (never A's flag); "not known" sends an add.
// 7.3.151: for either account (the manager is made for that account and its
// account read back before anything is sent).
static void BookmarkAs(BOOL asB, id viewModel, UIView* sourceView, BOOL screenIsTheirs) {
    id status = ActedStatus(viewModel);
    long long statusID = NumberGetter(status, @"statusID");
    Class managerClass = objc_getClass("T1BookmarksManager");
    NSString* who = SideName(asB);
    NSString* letter = asB ? @"B" : @"A";
    if (statusID <= 0 || !status) return;
    id account = SendAccount(asB, @"bookmark");
    if (!account) return;
    if (!managerClass) {
        ShowBlockNotice([NSString stringWithFormat:@"이 X 버전에서는 %@로 북마크할 수 없어요. %@ 계정으로 전환해서 해주세요", who, who]);
        return;
    }
    BOOL marked = SideState(asB, 2, status, screenIsTheirs) == 1;
    NSString* stateFrom = SideSource(asB, status, screenIsTheirs, 2);
    id manager = nil;
    @try {
        manager = ((id (*)(id, SEL, id))objc_msgSend)([managerClass alloc], NSSelectorFromString(@"initWithAccount:"), account);
    } @catch (__unused NSException* exception) {
    }
    // The manager must be that account's; anything else and nothing is sent.
    // 7.3.147: its account is a plain ivar with no getter (7.3.143 read nil
    // and stopped every bookmark), so read the ivar.
    id managerAccount = Getter(manager, @"account") ?: objectIvar(manager, "account");
    if (!manager || (managerAccount && ![AccountUserID(managerAccount) isEqualToString:AccountUserID(account)])) {
        Blocked([NSString stringWithFormat:@"bookmark as %@: the manager is not that account's", letter],
                [NSString stringWithFormat:@"%@로 확실히 보낼 수 없어서 북마크를 막았어요. kemo 설정에서 계정을 다시 골라주세요", who]);
        return;
    }
    if (!managerAccount) UnifiedLog([NSString stringWithFormat:@"bookmark manager account unreadable; it was made with %@'s account", letter]);
    // The account's own copy of the tweet when there is one (the copy on
    // screen may be the other account's).
    id sendStatus = screenIsTheirs ? status : ((asB ? BStatusFor(statusID) : AStatusFor(statusID)) ?: status);
    void (^completion)(void) = ^{
    };
    @try {
        if (marked) {
            SEL remove = NSSelectorFromString(@"removeStatusFromBookmarks:withScribeContext:completion:");
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, remove, sendStatus, nil, completion);
            [Done(asB, 2) removeObject:@(statusID)];
            [Undone(asB, 2) addObject:@(statusID)];
            ShowNotice([NSString stringWithFormat:@"%@로 북마크 해제를 보냈어요", who]);
        } else {
            SEL add = NSSelectorFromString(@"addStatusToBookmarks:sourceView:withScribeContext:completion:");
            ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(manager, add, sendStatus, sourceView, nil, completion);
            [Done(asB, 2) addObject:@(statusID)];
            [Undone(asB, 2) removeObject:@(statusID)];
            ShowNotice([NSString stringWithFormat:@"🔖 %@로 북마크를 보냈어요", who]);
        }
        BadgeMemoClear();
        UnifiedLog([NSString stringWithFormat:@"%@ as %@%@ (state from: %@)", marked ? @"unbookmark" : @"bookmark", letter,
                                              asB ? @"" : @" (explicit) on a B row", stateFrom]);
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"bookmark as %@ threw %@", letter, exception.name]);
        ShowBlockNotice([NSString stringWithFormat:@"%@로 북마크를 보내지 못했어요. 잠시 뒤 다시 눌러주세요", who]);
    }
}

extern BOOL NFBUnifiedUndoRepostAsB(id bAccount, id status, NSString** why);
extern NSString* NFBUnifiedRepostDebugText(void);

// The tweet (the original, for a repost) as B's own streams have it.
// 7.3.151: on the main thread the streams are walked once per change of B's
// streams (gBStreamGen) or 5 seconds, not once per question: the pictures next
// to the buttons ask for every row on screen.
static NSUInteger gBStreamGen;

static id BStatusFor(long long actedID) {
    if (actedID <= 0) return nil;
    static NSMutableDictionary<NSNumber*, id>* index;
    static NSUInteger indexGen;
    static CFAbsoluteTime indexAt;
    static __weak id indexTimeline;
    static __weak id indexForYou;
    BOOL indexed = [NSThread isMainThread];
    if (indexed && index && indexGen == gBStreamGen && indexTimeline == gBTimeline && indexForYou == gBForYouTimeline &&
        CFAbsoluteTimeGetCurrent() - indexAt < 5) {
        return index[@(actedID)];
    }
    NSMutableDictionary<NSNumber*, id>* fresh = indexed ? [NSMutableDictionary dictionary] : nil;
    for (id timeline in @[ gBTimeline ?: [NSNull null], gBForYouTimeline ?: [NSNull null] ]) {
        if (timeline == [NSNull null]) continue;
        id objects = Getter(Getter(timeline, @"stream"), @"streamObjects");
        if (![objects isKindOfClass:[NSArray class]]) continue;
        for (id object in objects) {
            if (!IsStatusItem(object)) continue;
            long long objectActed = ActedID(object);
            if (!indexed) {
                if (objectActed == actedID) return ActedStatusOf(object);
                continue;
            }
            // The first one found counts, as before (Following before For You).
            if (objectActed > 0 && !fresh[@(objectActed)]) {
                id acted = ActedStatusOf(object);
                if (acted) fresh[@(objectActed)] = acted;
            }
        }
    }
    if (!indexed) return nil;
    index = fresh;
    indexGen = gBStreamGen;
    indexAt = CFAbsoluteTimeGetCurrent();
    indexTimeline = gBTimeline;
    indexForYou = gBForYouTimeline;
    return index[@(actedID)];
}

// 7.3.151: the same tweet as A's own home streams have it (standalone items of
// the Following and For You timelines X made for the account in use), for a
// row whose copy on screen was loaded as B. Walked at most every 5 seconds;
// main thread only. nil: A's streams do not hold it.
static id AStatusFor(long long actedID) {
    if (actedID <= 0 || ![NSThread isMainThread]) return nil;
    static NSMutableDictionary<NSNumber*, id>* index;
    static CFAbsoluteTime indexAt;
    static NSString* indexPair;
    if (index && CFAbsoluteTimeGetCurrent() - indexAt < 5 && [indexPair isEqualToString:gPairKey ?: @""]) return index[@(actedID)];
    NSMutableDictionary<NSNumber*, id>* fresh = [NSMutableDictionary dictionary];
    id current = CurrentAccount();
    NSMutableArray* timelines = [NSMutableArray array];
    [timelines addObjectsFromArray:[gFollowingTimelines allObjects]];
    [timelines addObjectsFromArray:[gForYouTimelines allObjects]];
    for (id timeline in timelines) {
        if (!current || Getter(timeline, @"account") != current) continue;
        id objects = Getter(Getter(timeline, @"stream"), @"streamObjects");
        if (![objects isKindOfClass:[NSArray class]]) continue;
        for (id object in objects) {
            // Only what A's stream itself holds, never a row this file put there.
            if (!IsStatusItem(object) || [gBLoadedItems containsObject:object]) continue;
            long long objectActed = ActedID(object);
            id acted = ActedStatusOf(object);
            if (objectActed > 0 && acted && !fresh[@(objectActed)] && ![gBLoadedStatuses containsObject:acted]) fresh[@(objectActed)] = acted;
        }
    }
    index = fresh;
    indexAt = CFAbsoluteTimeGetCurrent();
    indexPair = gPairKey ?: @"";
    return index[@(actedID)];
}

// statusIsB: the tweet on screen was loaded as B (a tweet only B has, a screen
// opened as B), so its repost flag is B's. 7.3.151: it was always read as "not
// B's", so on a screen opened as B a tweet B had already reposted was sent
// another repost instead of the undo its row offers.
// 7.3.151: A's own undo of a repost, on a row whose copy on screen was loaded
// as B. -[TFNTwitterAccount unretweetID:statusID:responseBlock:]
// (v40@0:8q16q24@?32, 12.44 dump; the call UnifiedRepost.x makes for B), with
// the repost's ID from A's own copy of the tweet (-retweetID, as there).
static BOOL UndoRepostAsA(id account, long long statusID, NSString** why) {
    id own = AStatusFor(statusID) ?: LookedUp(NO, statusID)[@"status"];
    long long repostID = (own && BoolGetter(own, @"seenAsRetweeted")) ? NumberGetter(own, @"retweetID") : 0;
    SEL undo = NSSelectorFromString(@"unretweetID:statusID:responseBlock:");
    if (![account respondsToSelector:undo]) {
        if (why) *why = [NSString stringWithFormat:@"이 X 버전에서는 %@로 재게시 취소를 보낼 수 없어요", AName()];
        return NO;
    }
    if (repostID <= 0 || repostID == statusID) {
        // Not known (a repost made a moment ago has no ID here yet): forget
        // what is kept so the sheet asks X as A again next time.
        [gBLookups removeObjectForKey:LookupKey(NO, statusID)];
        [Done(NO, 1) removeObject:@(statusID)];
        if (why) *why = [NSString stringWithFormat:@"%@의 재게시 ID를 찾지 못했어요. 잠시 뒤 길게 눌러 다시 해주세요", AName()];
        return NO;
    }
    void (^response)(void) = ^{
    };
    @try {
        ((void (*)(id, SEL, long long, long long, id))objc_msgSend)(account, undo, repostID, statusID, response);
    } @catch (__unused NSException* exception) {
        if (why) *why = [NSString stringWithFormat:@"%@로 재게시 취소를 보내지 못했어요", AName()];
        return NO;
    }
    return YES;
}

static void RepostAs(BOOL asB, id viewModel, BOOL screenIsTheirs) {
    id status = ActedStatus(viewModel);
    long long statusID = NumberGetter(status, @"statusID");
    NSString* who = SideName(asB);
    NSString* letter = asB ? @"B" : @"A";
    if (statusID <= 0) return;
    if (IsProtectedStatus(status)) {
        // X does not let anyone repost a protected account's tweet.
        UnifiedLog([NSString stringWithFormat:@"repost as %@ stopped: protected", letter]);
        ShowBlockNotice(@"비공개 계정의 게시물은 재게시할 수 없어요");
        return;
    }
    id account = SendAccount(asB, @"repost");
    if (!account) return;
    NSString* stateFrom = SideSource(asB, status, screenIsTheirs, 1);
    BOOL reposted = SideState(asB, 1, status, screenIsTheirs) == 1;
    NSString* suffix = asB ? @"" : @" (explicit) on a B row";
    if (reposted) {
        NSString* why = nil;
        BOOL sent = NO;
        if (asB) {
            // B's own copy of the tweet: the one on screen may be A's, whose
            // repost state is A's (7.3.145).
            // 7.3.151: or the copy X gave when asked as B (LookUpState), which
            // also carries B's repost ID for the undo.
            id bStatus = BStatusFor(statusID) ?: LookedUp(YES, statusID)[@"status"];
            if (!bStatus && screenIsTheirs) bStatus = status;
            // 7.3.153: never A's copy of the tweet (it carries A's repost ID);
            // without B's own it is not sent.
            sent = bStatus ? NFBUnifiedUndoRepostAsB(account, bStatus, &why) : NO;
            if (!bStatus) UnifiedLog([NSString stringWithFormat:@"unrepost as B stopped: no status of B's for %lld", statusID]);
        } else {
            sent = UndoRepostAsA(account, statusID, &why);
        }
        if (sent) {
            [Done(asB, 1) removeObject:@(statusID)];
            LookupNoteRepost(asB, statusID, NO);
            BadgeMemoClear();
            ShowNotice([NSString stringWithFormat:@"%@로 재게시 취소를 보냈어요", who]);
            UnifiedLog([NSString stringWithFormat:@"unrepost as %@%@ (state from: %@)", letter, suffix, stateFrom]);
        } else {
            BadgeMemoClear();
            ShowBlockNotice(why ?: [NSString stringWithFormat:@"%@의 재게시 취소는 %@ 계정으로 전환해서 해주세요", who, who]);
        }
        return;
    }
    if (!CallStatusMethod(account, asB, @"retweetWithStatusID:responseBlock:", statusID)) return;
    [Done(asB, 1) addObject:@(statusID)];
    LookupNoteRepost(asB, statusID, YES);
    BadgeMemoClear();
    ShowNotice([NSString stringWithFormat:@"🔁 %@로 재게시를 보냈어요", who]);
    UnifiedLog([NSString stringWithFormat:@"repost as %@%@ (state from: %@)", letter, suffix, stateFrom]);
}

// A reply composer opened within a few seconds of this, for one of these
// tweets, is switched to B.
static CFAbsoluteTime gComposeAsBUntil;
static NSSet<NSNumber*>* gComposeTargets;

extern void NFBPresentAccountSheet(NSString* title, NSString* message, NSArray<NSDictionary*>* rows);
extern NSUInteger NFBAccountSheetToken(void);
extern void NFBUpdateAccountSheetRow(NSUInteger token, NSUInteger index, NSDictionary* changes);
static UIImage* AccountAvatar(id account, NSString* letter, UIColor* color);
static UIColor* BColor(void);

// What was asked holds only for the pair that was active when it was asked;
// this runs again at every tap of a sheet row (7.3.151: also of rows that stay).
static BOOL PairStill(NSString* pairAtAsk, NSString* what) {
    if (UnifiedActive() && pairAtAsk && [gPairKey isEqualToString:pairAtAsk]) return YES;
    ShowBlockNotice(@"계정이 바뀌어서 보내지 않았어요. 다시 눌러주세요");
    UnifiedLog([NSString stringWithFormat:@"%@ dropped: account pair changed while asking", what]);
    return NO;
}

static void RelayoutSoon(UIView* view);

// 7.3.151: the mark is for a reply to the tweet, or for a quote of it
// (gComposeQuote); the composer that opens next is matched against it.
static BOOL gComposeQuote;
static long long gComposeQuoteID;

// 7.3.151: which account the reply or quote of a tweet was last asked for
// from a row or a screen ("A" / "B"), by the tweet's IDs. It does not run out
// with time (the composer may come up late, after an interstitial); it is used
// up by the composer that opens for the tweet and replaced by the next tap.
static NSMutableDictionary<NSNumber*, NSString*>* gComposeChoices;
static NSMutableArray<NSNumber*>* gComposeChoiceOrder;

static void NoteComposeChoice(id viewModel, long long statusID, NSString* letter) {
    long long acted = NumberGetter(ActedStatus(viewModel), @"statusID");
    if (!gComposeChoices) gComposeChoices = [NSMutableDictionary dictionary];
    if (!gComposeChoiceOrder) gComposeChoiceOrder = [NSMutableArray array];
    for (NSNumber* target in @[ @(statusID), @(acted) ]) {
        if (target.longLongValue <= 0) continue;
        [gComposeChoiceOrder removeObject:target];
        if (!letter) {
            [gComposeChoices removeObjectForKey:target];
            continue;
        }
        gComposeChoices[target] = letter;
        [gComposeChoiceOrder addObject:target];
    }
    while (gComposeChoiceOrder.count > 50) {
        [gComposeChoices removeObjectForKey:gComposeChoiceOrder.firstObject];
        [gComposeChoiceOrder removeObjectAtIndex:0];
    }
}

static void MarkComposeAsB(id viewModel, long long statusID, BOOL quote) {
    long long acted = NumberGetter(ActedStatus(viewModel), @"statusID");
    NoteComposeChoice(viewModel, statusID, @"B");
    gComposeAsBUntil = CFAbsoluteTimeGetCurrent() + 6;
    gComposeTargets = [NSSet setWithObjects:@(statusID), @(acted), nil];
    gComposeQuote = quote;
    gComposeQuoteID = quote ? (acted > 0 ? acted : statusID) : 0;
    UnifiedLog(quote ? [NSString stringWithFormat:@"quote: the composer for %lld will be marked for B", gComposeQuoteID]
                     : [NSString stringWithFormat:@"reply: the composer for %lld must hold B", acted > 0 ? acted : statusID]);
}

static void MarkReplyAsB(id viewModel, long long statusID) {
    MarkComposeAsB(viewModel, statusID, NO);
}

// MARK: - Tweet screens opened as B
//
// 7.3.151: the screens are remembered when they are made (it was "a tweet
// screen whose account is the saved B", which stopped being true the moment B
// was changed in settings while the screen stayed up). Each keeps the user ID
// of the B it was opened as.
static NSHashTable* gBScreens;
static const void* kBScreenOwnerKey = &kBScreenOwnerKey;
static NSMutableSet<NSNumber*>* gBScreenStatusIDs;  // the tweets those screens were opened for

static BOOL IsBScreen(UIViewController* controller) {
    return controller && [gBScreens containsObject:controller];
}

static UIViewController* BScreenOf(UIView* view) {
    if (!view || gBScreens.count == 0) return nil;
    for (UIResponder* responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            for (UIViewController* controller = (UIViewController*)responder; controller; controller = controller.parentViewController) {
                if (IsBScreen(controller)) return controller;
            }
            return nil;
        }
    }
    return nil;
}

extern BOOL NFBUnifiedNotificationsIsBView(UIView* view);
extern BOOL NFBUnifiedHistoryIsBView(UIView* view);
extern BOOL NFBUnifiedNotificationIsBStatus(long long statusID);
extern BOOL NFBUnifiedHistoryIsBStatus(long long statusID);
extern void NFBUnifiedNotificationsReactionsWired(void);
extern void NFBUnifiedHistoryReactionsWired(void);

// A view on a screen that is B's: B's notifications or B's history while they
// are shown (UnifiedNotifications.x / UnifiedHistory.x say), or a tweet screen
// opened as B.
static BOOL IsInBScreen(UIView* view) {
    if (NFBUnifiedNotificationsIsBView(view)) return YES;
    if (NFBUnifiedHistoryIsBView(view)) return YES;
    return BScreenOf(view) != nil;
}

// Why nothing may be sent as B from a view on a B screen (nil: it may): B has
// to be verified now and be the account the screen was opened as.
static NSString* BScreenTrouble(UIView* view) {
    id b = VerifiedB();
    if (!b) return [NSString stringWithFormat:@"no verified B (%@)", gVerifiedBWhy ?: @"?"];
    UIViewController* screen = BScreenOf(view);
    if (!screen) return nil;  // B's notifications / history check their own pair
    NSString* owner = objc_getAssociatedObject(screen, kBScreenOwnerKey);
    if (!owner || ![owner isEqualToString:AccountUserID(b)]) return @"the screen was opened as another B";
    return nil;
}

static BOOL gInlineBypass;  // X's own tap path as A, chosen in the long-press sheet

// X's own handling of the long press being answered (set by the hook only
// while LongPressChooser runs); the repost sheet offers it as a row.
static void (^gLongPressXPath)(void);

static BOOL PresentReactionSheet(id actionsView, id button, NSString* gesture, void (^xPath)(void));
static void PresentBRepostSheet(UIView* actionsView, id viewModel, NSString* gesture);

// What a button of the action bar does: 0 like, 1 repost, 2 bookmark, 3 reply,
// -1 anything else (by class name: TTAStatusInline…Button, 12.44 dump).
static int ButtonKind(id button) {
    NSString* buttonClass = NSStringFromClass([button class]);
    if ([buttonClass containsString:@"Favorite"]) return 0;
    if ([buttonClass containsString:@"Retweet"]) return 1;
    if ([buttonClass containsString:@"Bookmark"]) return 2;
    if ([buttonClass containsString:@"Reply"]) return 3;
    return -1;
}

// YES when the tap was handled here (sent with an explicit account, a sheet
// shown, or stopped). `orig` runs X's own handling, which acts as A.
// 7.3.151, the rules (the user's):
// - A-base (A's own copy): tap = A through X's own path; long press = sheet.
// - both: the same; when the copy on the list is B's (A follows whoever
//   brought it but the row came from B's stream), "tap = A" is an explicit
//   call on A's verified account, or the sheet when A's state is not known,
//   never X's own path on a status B loaded.
// - B-base (a row of B's alone, a screen opened as B): tap = B; long press =
//   sheet where A can be chosen (not for a protected author: B only).
// - reply never asks: the composer opens as the row's account and its own
//   A/B buttons switch.
// - "always ask": a tap on like / repost / bookmark of an A-base or both tweet
//   opens the sheet.
static BOOL HandleInlineAction(id actionsView, id button, void (^orig)(void)) {
    if (gInlineBypass || !gEverActive) return NO;
    NSString* buttonClass = NSStringFromClass([button class]);
    if ([buttonClass containsString:@"Share"] || [buttonClass containsString:@"Analytics"]) return NO;
    id viewModel = Getter(actionsView, @"viewModel");
    UIView* actions = [actionsView isKindOfClass:[UIView class]] ? (UIView*)actionsView : nil;
    // Before the "is the mode active" question: a screen opened as B that is
    // still up, or a row of B's still on a list, never runs X's own path.
    BOOL inB = actions && IsInBScreen(actions);
    NSInteger cls = ProvOf(viewModel);
    if (!UnifiedActive()) {
        if (!inB && !ProvIsBLoaded(cls)) return NO;
        Blocked(@"tap on a leftover B screen or row while the mode is not active", @"A/B 통합 모드가 꺼져서 막았어요. 화면을 닫고 다시 눌러주세요");
        return YES;
    }
    int kind = ButtonKind(button);
    UIView* sourceView = [button isKindOfClass:[UIView class]] ? button : nil;
    long long statusID = ViewModelStatusID(viewModel);

    if (inB || cls == kProvBOnly) {
        // B-base: everything goes as B, sent with B's account here.
        NSString* trouble = inB ? BScreenTrouble(actions) : (VerifiedB() ? nil : [NSString stringWithFormat:@"no verified B (%@)", gVerifiedBWhy ?: @"?"]);
        if (trouble) {
            Blocked([NSString stringWithFormat:@"%@ on a B %@: %@", buttonClass, inB ? @"screen" : @"row", trouble],
                    @"B 계정을 확인하지 못해서 막았어요. kemo 설정에서 B 계정을 다시 골라주세요");
            return YES;
        }
        if (kind == 0) {
            LikeAs(YES, viewModel, YES);
            if (actions) RelayoutSoon(actions);
            return YES;
        }
        if (kind == 1) {
            // 7.3.151: a tap sent the repost at once and a quote as B was not
            // possible; it asks "repost or quote?" now, both as B.
            PresentBRepostSheet(actions, viewModel, inB ? @"tap on a B screen" : @"tap");
            return YES;
        }
        if (kind == 2) {
            BookmarkAs(YES, viewModel, sourceView, YES);
            if (actions) RelayoutSoon(actions);
            return YES;
        }
        if (kind == 3) {
            MarkReplyAsB(viewModel, statusID);
            return NO;
        }
        gBlocked++;
        UnifiedLog([NSString stringWithFormat:@"blocked %@ on a B %@", buttonClass, inB ? @"screen" : @"row"]);
        ShowBlockNotice([NSString stringWithFormat:@"이 버튼은 아직 %@로 보낼 수 없어서 막아뒀어요. %@ 계정으로 전환해서 해주세요", BName(), BName()]);
        return YES;
    }
    if (cls == kProvBStale) {
        // B's copy from an earlier merge or pair: whose it is now is not known.
        Blocked([NSString stringWithFormat:@"%@ on a row loaded as B that this merge does not class", buttonClass],
                @"계정 설정이 바뀌어서 막았어요. 당겨서 새로고침한 뒤 다시 눌러주세요");
        return YES;
    }
    if (statusID <= 0) return NO;
    BOOL alwaysAsk = [BHTSettings boolForKey:kUnifiedAlwaysAsk];

    if (cls == kProvBBoth || cls == kProvBPlain) {
        // B's copy of a tweet that is A's to act on: never X's own path for
        // like / repost / bookmark (which account X would use for a status B
        // loaded is not proven).
        if (kind == 3) {
            NoteComposeChoice(viewModel, statusID, @"A");
            return NO;
        }
        if (kind < 0) return NO;
        int state = SideState(NO, kind, ActedStatus(viewModel), NO);
        // Repost always asks here: X's own menu (repost / quote) is X's path.
        if (alwaysAsk || kind == 1 || state < 0) {
            NSString* gesture = alwaysAsk ? @"tap (always ask)" : (kind == 1 ? @"tap (repost on B's copy)" : @"tap (A's state not known)");
            if (!PresentReactionSheet(actionsView, button, gesture, nil)) {
                Blocked([NSString stringWithFormat:@"%@ on B's copy of a tweet both have: no sheet", buttonClass],
                        @"어느 계정으로 보낼지 확인하지 못해서 막았어요. 당겨서 새로고침한 뒤 다시 눌러주세요");
            }
            return YES;
        }
        if (kind == 0) LikeAs(NO, viewModel, NO);
        else BookmarkAs(NO, viewModel, sourceView, NO);
        if (actions) RelayoutSoon(actions);
        return YES;
    }

    // A's own copy (or a row outside the unified lists): X's own path is A's.
    if (kind == 3) {
        NoteComposeChoice(viewModel, statusID, nil);
        return NO;
    }
    if (kind < 0 || !alwaysAsk || (cls != kProvABoth && cls != kProvAOnly)) return NO;
    // "Always ask": the same rows as the long press; A runs X's own handling of this tap.
    return PresentReactionSheet(actionsView, button, @"tap (always ask)", orig);
}

// The second button some action buttons carry (-[TTAStatusInlineActionsView
// didTapSecondaryInlineActionButton:], 12.44 dump; not hooked before 7.3.151).
// What it does is not known here, so on anything of B's it is stopped.
static BOOL HandleSecondaryAction(id actionsView, id button) {
    if (gInlineBypass || !gEverActive) return NO;
    UIView* actions = [actionsView isKindOfClass:[UIView class]] ? (UIView*)actionsView : nil;
    BOOL inB = actions && IsInBScreen(actions);
    if (!inB && !ProvIsBLoaded(ProvOf(Getter(actionsView, @"viewModel")))) return NO;
    gBlocked++;
    UnifiedLog([NSString stringWithFormat:@"blocked the secondary button (%@) on a B %@", NSStringFromClass([button class]), inB ? @"screen" : @"row"]);
    ShowBlockNotice([NSString stringWithFormat:@"이 버튼은 아직 %@로 보낼 수 없어서 막아뒀어요. %@ 계정으로 전환해서 해주세요", BName(), BName()]);
    return YES;
}

// 7.3.150: a long press on like / repost opens the account sheet: each
// account with its state and a button. A runs X's own tap path (the account in
// use); B goes with B's own account. A is offered only where X's path really
// is A's: not on a screen opened as B, not on a tweet only B has (its state on
// screen is B's).
static CFAbsoluteTime gLongPressAt;
static __weak id gLongPressButton;

// A tap X may still send for the button just long-pressed is not a second action.
static BOOL SwallowAfterLongPress(id button) {
    if (gInlineBypass || !button || button != gLongPressButton) return NO;
    if (CFAbsoluteTimeGetCurrent() - gLongPressAt > 1.5) return NO;
    UnifiedLog(@"tap right after the long press ignored");
    return YES;
}

// 7.3.151: one sheet shape for every "which account?" on like / repost /
// bookmark, whether a long press or a tap that asks opened it: each account
// with its state and a pill that names what a tap does, a reason when a row
// cannot be used, and B's state filled in when it has to be looked up. Rows
// stay (the sheet is not closed by them), so A and then B can be acted for in
// one sheet; the pair is checked again at every tap.
// kind: 0 like, 1 repost, 2 bookmark.
static NSString* ReactionVerb(int kind) {
    return kind == 0 ? @"마음에 들어요" : (kind == 1 ? @"재게시" : @"북마크");
}

static NSString* ReactionName(int kind) {
    return kind == 0 ? @"like" : (kind == 1 ? @"repost" : @"bookmark");
}

// The pill of a row whose action is already done names its undo: a bare "취소"
// read like the sheet's own footer.
static NSString* ReactionPill(int kind, int state) {
    if (state != 1) return ReactionVerb(kind);
    return kind == 0 ? @"마음에 들어요 취소" : (kind == 1 ? @"재게시 취소" : @"북마크 해제");
}

// A row's detail line and pill for a state (1 done, 0 not, -1 not known).
static NSDictionary* ReactionRowChanges(NSString* letter, int kind, int state, NSString* unknownText) {
    NSString* text = state < 0 ? (unknownText ?: @"상태 확인 안 됨")
                               : [NSString stringWithFormat:@"%@ %@", ReactionVerb(kind), state ? @"함" : @"안 함"];
    return @{
        @"detail" : [NSString stringWithFormat:@"%@ 계정 · %@", letter, text],
        @"button" : ReactionPill(kind, state),
        @"buttonStyle" : state == 1 ? @"outline" : @"filled",
    };
}

// X's own view of a status for the account it was loaded for. As it is shown
// (afterTap NO): the flag it was loaded with or the "seen as" one, as the
// like pictures have always read it. Right after X's own tap (afterTap YES):
// the "seen as" flag alone when the status has it, since the loaded flag does
// not change with a tap and would keep an undone action looking done.
static BOOL SeenFlag(id status, NSString* seen, NSString* loaded, BOOL afterTap) {
    BOOL hasSeen = seen && [status respondsToSelector:NSSelectorFromString(seen)];
    if (afterTap && hasSeen) return BoolGetter(status, seen);
    return (hasSeen && BoolGetter(status, seen)) || (loaded && BoolGetter(status, loaded));
}

// A's state of the tweet on screen (meaningful only when it was not loaded as B).
static int AReactionState(id status, int kind, BOOL afterTap) {
    if (kind == 0) return SeenFlag(status, @"seenAsFavorited", @"favoritedByLoadingAccount", afterTap) ? 1 : 0;
    if (kind == 1) return SeenFlag(status, @"seenAsRetweeted", nil, afterTap) ? 1 : 0;
    return SeenFlag(status, @"seenAsBookmarked", @"bookmarkedByLoadingAccount", afterTap) ? 1 : 0;
}

static void QuoteAs(BOOL asB, UIView* actionsView, id viewModel);

// YES when the sheet was shown (or the tap was stopped with a notice).
// gesture: what opened it, for the log. xPath: X's own handling of the tap
// that opened it, which acts as A; nil (a long press) uses X's plain tap.
// 7.3.151: on a row whose copy on screen was loaded as B (a row of B's, a
// screen opened as B, B's copy of a tweet both have) the A row no longer runs
// X's tap path, which is not provably A's there (it was switched off on B's
// rows and screens): it sends with A's own verified account (LikeAs /
// RepostAs / BookmarkAs with asB NO), and A's state, which is not on screen
// there, is looked up as A (LookUpState).
static BOOL PresentReactionSheet(id actionsView, id button, NSString* gesture, void (^xPath)(void)) {
    if (!UnifiedActive() || ![actionsView isKindOfClass:[UIView class]]) return NO;
    int kind = ButtonKind(button);
    if (kind < 0 || kind > 2) return NO;
    id viewModel = Getter(actionsView, @"viewModel");
    long long statusID = ViewModelStatusID(viewModel);
    if (statusID <= 0) return NO;
    BOOL inB = IsInBScreen((UIView*)actionsView);
    NSInteger cls = ProvOf(viewModel);
    if (!inB && cls == kProvBStale) {
        Blocked(@"sheet on a row loaded as B that this merge does not class", @"계정 설정이 바뀌어서 막았어요. 당겨서 새로고침한 뒤 다시 눌러주세요");
        return YES;
    }
    BOOL bBase = inB || cls == kProvBOnly;                                    // B's alone: a tap goes as B
    BOOL statusIsB = bBase || cls == kProvBBoth || cls == kProvBPlain;        // the copy on screen was loaded as B
    id status = ActedStatus(viewModel);
    BOOL protectedTweet = IsProtectedStatus(status);
    NSString* verb = ReactionVerb(kind);

    // A's state: X's flags on screen are A's only when A loaded the copy.
    int aState = statusIsB ? SideState(NO, kind, status, NO) : AReactionState(status, kind, NO);
    int bState = SideState(YES, kind, status, statusIsB);

    NSString* pairAtAsk = gPairKey;
    __weak UIView* weakActions = (UIView*)actionsView;
    __weak id weakButton = button;
    __block NSUInteger token = 0;  // the sheet, once it is up

    id verifiedB = VerifiedB();
    NSString* aWhy = nil;
    if (kind == 1 && protectedTweet) aWhy = @"비공개 계정은 재게시할 수 없어요";
    else if (bBase && protectedTweet) aWhy = @"A 계정은 볼 수 없는 게시물이에요";  // a protected author only B follows: B only
    else if (statusIsB && !VerifiedA()) aWhy = @"A 계정을 확인하지 못했어요";
    else if (statusIsB && kind == 2 && !objc_getClass("T1BookmarksManager")) aWhy = @"이 X 버전에서는 안 돼요";
    else if (!statusIsB && !xPath && ![actionsView respondsToSelector:@selector(didTapInlineActionButton:)]) aWhy = @"이 X 버전에서는 안 돼요";
    NSString* bWhy = nil;
    if (!verifiedB) bWhy = @"B 계정을 찾지 못했어요";
    else if (inB && BScreenTrouble((UIView*)actionsView)) bWhy = @"다른 B 계정으로 연 화면이에요";
    else if (kind == 1 && protectedTweet) bWhy = @"비공개 계정은 재게시할 수 없어요";
    else if (cls == kProvAOnly && protectedTweet) bWhy = @"B 계정은 볼 수 없는 게시물이에요";  // a protected author only A follows: A only
    else if (kind == 2 && !objc_getClass("T1BookmarksManager")) bWhy = @"이 X 버전에서는 안 돼요";
    // 7.3.151: an account's state not known (the copy on screen is the other
    // account's and its own timelines do not hold the tweet): ask X as that
    // account once the sheet is up.
    long long actedID = NumberGetter(status, @"statusID");
    BOOL bLookup = !bWhy && bState < 0 && !statusIsB && actedID > 0;
    BOOL aLookup = !aWhy && aState < 0 && statusIsB && actedID > 0;
    // X's own repost path opens X's menu (repost / quote), which cannot come
    // up over this sheet: that one row closes the sheet first. An explicit
    // call as A (on B's copy) stays like B's row does.
    BOOL aExplicit = statusIsB;
    BOOL aStays = aExplicit || kind != 1;

    void (^asA)(void) = ^{
        UIView* actions = weakActions;
        id tapped = weakButton;
        if (!PairStill(pairAtAsk, @"sheet choice")) return;
        if (aExplicit) {
            // With A's own account, never X's tap path: the status was loaded as B.
            if (kind == 0) LikeAs(NO, viewModel, NO);
            else if (kind == 1) RepostAs(NO, viewModel, NO);
            else BookmarkAs(NO, viewModel, [tapped isKindOfClass:[UIView class]] ? (UIView*)tapped : nil, NO);
            if (actions) RelayoutSoon(actions);
            int state = SideState(NO, kind, status, NO);
            NFBUpdateAccountSheetRow(token, 0, ReactionRowChanges(@"A", kind, state, nil));
            UnifiedLog([NSString stringWithFormat:@"stay tap: %@ as A (explicit) -> recomputed A=%d (%@)", ReactionName(kind), state,
                                                  SideSource(NO, status, NO, kind)]);
            return;
        }
        // The row may show another tweet by now (the sheet can stay up a while).
        if (!actions || !tapped || ViewModelStatusID(Getter(actions, @"viewModel")) != statusID) {
            UnifiedLog([NSString stringWithFormat:@"sheet: %@ as A dropped, the row no longer shows %lld", ReactionName(kind), statusID]);
            ShowBlockNotice(@"화면이 바뀌어서 보내지 않았어요. 게시물에서 다시 눌러주세요");
            return;
        }
        // X's own tap, which is the account in use's (A's): re-checked now
        // (7.3.151: also that what the row shows was not loaded as B).
        if (IsInBScreen(actions) || ProvIsBLoaded(ProvOf(Getter(actions, @"viewModel")))) {
            ShowBlockNotice([NSString stringWithFormat:@"%@로 보는 화면이라 %@로는 보내지 않았어요. 뒤로 나가서 다시 눌러주세요", BName(), AName()]);
            return;
        }
        // 7.3.153: X's own tap goes out as the action bar's account
        // (-[TTAStatusInlineActionsView account], 12.44 XAppLibraries dump).
        // On a screen that was pushed from a B screen and is not one this
        // file knows, that is not A: the row says A, so it is not sent.
        NSString* barAccountID = AccountUserID(Getter(actions, @"account"));
        if (barAccountID.length > 0 && ![barAccountID isEqualToString:AID()]) {
            Blocked([NSString stringWithFormat:@"sheet: %@ as A, but the action bar's account is %@", ReactionName(kind), barAccountID],
                    [NSString stringWithFormat:@"%@의 화면이 아니라서 %@로는 보내지 않았어요. 뒤로 나가서 다시 눌러주세요", AName(), AName()]);
            return;
        }
        UnifiedLog([NSString stringWithFormat:@"sheet: %@ as A via X (%@)", ReactionName(kind),
                                              xPath ? @"this tap's own path" : @"didTapInlineActionButton:"]);
        if (xPath) {
            xPath();
        } else {
            gInlineBypass = YES;
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(actions, @selector(didTapInlineActionButton:), tapped);
            } @finally {
                gInlineBypass = NO;
            }
        }
        RelayoutSoon(actions);
        if (!aStays) return;
        // What X did is read back from the tweet a moment later, not assumed.
        __block int shownState = -2;
        for (NSNumber* delay in @[ @0.15, @0.8, @2.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIView* shown = weakActions;
                id model = Getter(shown, @"viewModel");
                if (!shown || ViewModelStatusID(model) != statusID) return;
                id now = ActedStatus(model);
                int state = AReactionState(now, kind, YES);
                NFBUpdateAccountSheetRow(token, 0, ReactionRowChanges(@"A", kind, state, nil));
                if (state == shownState) return;
                shownState = state;
                UnifiedLog([NSString stringWithFormat:@"stay tap: %@ as A -> recomputed A=%d after %.2fs (X's flags: liked %d/%d reposted %d bookmarked %d/%d)",
                                                      ReactionName(kind), state, delay.doubleValue,
                                                      BoolGetter(now, @"favoritedByLoadingAccount"), BoolGetter(now, @"seenAsFavorited"),
                                                      BoolGetter(now, @"seenAsRetweeted"), BoolGetter(now, @"bookmarkedByLoadingAccount"),
                                                      BoolGetter(now, @"seenAsBookmarked")]);
            });
        }
    };
    void (^asB)(void) = ^{
        if (!PairStill(pairAtAsk, @"sheet choice")) return;
        UIView* actions = weakActions;
        if (inB) {
            // The screen has to be B's still, and this B's.
            NSString* trouble = actions ? BScreenTrouble(actions) : @"the screen is gone";
            if (trouble) {
                Blocked([NSString stringWithFormat:@"sheet: %@ as B on a B screen: %@", ReactionName(kind), trouble],
                        @"화면이 바뀌어서 보내지 않았어요. 게시물에서 다시 눌러주세요");
                return;
            }
        }
        if (kind == 0) {
            LikeAs(YES, viewModel, statusIsB);
        } else if (kind == 1) {
            RepostAs(YES, viewModel, statusIsB);
        } else {
            id tapped = weakButton;
            BookmarkAs(YES, viewModel, [tapped isKindOfClass:[UIView class]] ? (UIView*)tapped : nil, statusIsB);
        }
        if (actions) RelayoutSoon(actions);
        // B's state is this file's own record; read again after the action.
        int state = SideState(YES, kind, status, statusIsB);
        NFBUpdateAccountSheetRow(token, 1, ReactionRowChanges(@"B", kind, state, nil));
        UnifiedLog([NSString stringWithFormat:@"stay tap: %@ as B -> recomputed B=%d (%@)", ReactionName(kind), state,
                                              SideSource(YES, status, statusIsB, kind)]);
    };

    UIColor* purple = [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1];
    NSMutableDictionary* aRow = [NSMutableDictionary dictionary];
    aRow[@"title"] = AName();
    aRow[@"image"] = AccountAvatar(CurrentAccount(), @"A", purple);
    aRow[@"disabled"] = @(aWhy != nil);
    aRow[@"stay"] = @(aStays);
    aRow[@"action"] = asA;
    [aRow addEntriesFromDictionary:ReactionRowChanges(@"A", kind, aState, aLookup ? @"확인 중…" : nil)];
    if (aWhy) {
        aRow[@"detail"] = aWhy;
        aRow[@"button"] = verb;
    }
    NSMutableDictionary* bRow = [NSMutableDictionary dictionary];
    bRow[@"title"] = BName();
    bRow[@"image"] = AccountAvatar(verifiedB, @"B", BColor());
    bRow[@"disabled"] = @(bWhy != nil);
    bRow[@"stay"] = @YES;
    bRow[@"action"] = asB;
    [bRow addEntriesFromDictionary:ReactionRowChanges(@"B", kind, bState, bLookup ? @"확인 중…" : nil)];
    if (bWhy) {
        bRow[@"detail"] = bWhy;
        bRow[@"button"] = verb;
    }
    NSMutableArray<NSDictionary*>* rows = [NSMutableArray arrayWithObjects:aRow, bRow, nil];
    if (kind == 1 && aExplicit && !bBase && !aWhy) {
        // B's copy of a tweet both have: X's own repost menu, where A quotes,
        // is not used on it, so the quote as A is offered here.
        void (^quoteAsA)(void) = ^{
            if (!PairStill(pairAtAsk, @"sheet choice")) return;
            QuoteAs(NO, weakActions, viewModel);
        };
        [rows addObject:@{
            @"title" : [NSString stringWithFormat:@"%@로 인용", AName()],
            @"image" : AccountAvatar(CurrentAccount(), @"A", purple),
            @"action" : quoteAsA,
        }];
    }
    // 7.3.152: the long press on the repost button is X's way to the list of
    // quotes, and this sheet took its place. From X's own long-press callback
    // the sheet gets one more row that runs X's handling of that very press
    // (the callback's %orig), so the list is still one tap away. Not on B's
    // screens or on rows only B has: X would open it with A's account there.
    void (^xLongPress)(void) = gLongPressXPath;
    if (kind == 1 && xLongPress && !inB && cls != kProvBOnly) {
        [rows addObject:@{
            @"title" : @"인용 목록 보기",
            @"image" : [UIImage systemImageNamed:@"quote.bubble"] ?: [UIImage new],
            @"action" : ^{
                if (!PairStill(pairAtAsk, @"sheet choice")) return;
                UnifiedLog(@"sheet: X's own repost long press (the quotes list)");
                xLongPress();
            },
        }];
    }
    NSString* title = kind == 0 ? @"어느 계정으로 마음에 들어요를 누를까요?"
                                : (kind == 1 ? @"어느 계정으로 재게시할까요?" : @"어느 계정으로 북마크할까요?");
    NFBPresentAccountSheet(title, nil, rows);
    token = NFBAccountSheetToken();
    UnifiedLog([NSString stringWithFormat:@"sheet shown: account rows with state + pill, %@ %lld, from %@ (A=%d%@%@ B=%d%@ stay%@%@)",
                                          ReactionName(kind), statusID, gesture, aState, aWhy ? @" off" : @"", aStays ? @" stay" : @" closes",
                                          bState, bWhy ? @" off" : @"", bLookup ? @" lookup" : @"", aLookup ? @" A-lookup" : @""]);
    UnifiedLog([NSString stringWithFormat:@"%@ sheet: %@ %lld on %@ (A row: %@)", [gesture hasPrefix:@"long press"] ? @"long press" : @"tap",
                                          ReactionName(kind), statusID,
                                          inB ? @"a B screen" : (cls == kProvBOnly ? @"a B row" : (statusIsB ? @"B's copy of a tweet both have" : @"A's copy")),
                                          aWhy ? [@"off: " stringByAppendingString:aWhy] : (aExplicit ? @"explicit as A" : @"X's own path")]);
    NSUInteger shownToken = token;
    if (bLookup) {
        LookUpState(YES, actedID, status, ^{
            // Read again rather than from the answer: what B did meanwhile wins.
            int now = SideState(YES, kind, status, NO);
            NFBUpdateAccountSheetRow(shownToken, 1, ReactionRowChanges(@"B", kind, now, @"상태를 확인하지 못했어요"));
        });
    }
    if (aLookup) {
        // The copy on screen is B's, so what comes back as A is checked against it.
        LookUpState(NO, actedID, status, ^{
            int now = SideState(NO, kind, status, NO);
            NFBUpdateAccountSheetRow(shownToken, 0, ReactionRowChanges(@"A", kind, now, @"상태를 확인하지 못했어요"));
        });
    }
    return YES;
}

// 7.3.151, quote as B. What it stands on, all read from the 12.44 binaries:
// - -[UIViewController t1_directQuoteTweetStatus:account:scribeParameters:]
//   (v40@0:8@16@24@32), X's own way to open the quote composer for a status
//   with an account. It is in T1Twitter's (linker-merged) category whose
//   class resolves to _OBJC_CLASS_$_UIViewController through the binary's
//   import table, next to t1_retweetMenuSheetForStatus:account:source:....
// - The composer says what it quotes: -[T1TweetComposeViewController
//   compositions] / -originalComposition (TFNTwitterComposition),
//   -[TFNTwitterComposition quotedStatusInfo], and
//   -[TFNTwitterCompositionQuotedStatusInfo statusID] (q) with
//   -retweetingStatusInfo; that is how the composer is recognised
//   (QuoteTargetID) before it is marked for B and guarded like a reply.
// If any of it is missing in the running X, the quote row is off.
static NSString* gQuoteNote = @"(not looked up yet)";

static NSString* QuoteAsBMissing(void) {
    NSMutableArray<NSString*>* missing = [NSMutableArray array];
    Method quoteMethod =
        class_getInstanceMethod([UIViewController class], NSSelectorFromString(@"t1_directQuoteTweetStatus:account:scribeParameters:"));
    const char* types = quoteMethod ? method_getTypeEncoding(quoteMethod) : NULL;
    if (!quoteMethod) {
        [missing addObject:@"-[UIViewController t1_directQuoteTweetStatus:account:scribeParameters:]"];
    } else if (!types || strcmp(types, "v40@0:8@16@24@32") != 0) {
        [missing addObject:[NSString stringWithFormat:@"t1_directQuoteTweetStatus types %s", types ?: "?"]];
    }
    NSArray<NSArray<NSString*>*>* getters = @[
        @[ @"T1TweetComposeViewController", @"compositions" ],
        @[ @"TFNTwitterComposition", @"quotedStatusInfo" ],
        @[ @"TFNTwitterCompositionQuotedStatusInfo", @"statusID" ],
    ];
    for (NSArray<NSString*>* getter in getters) {
        Class owner = NSClassFromString(getter[0]);
        if (!owner || !class_getInstanceMethod(owner, NSSelectorFromString(getter[1]))) {
            [missing addObject:[NSString stringWithFormat:@"-[%@ %@]", getter[0], getter[1]]];
        }
    }
    if (!objc_getClass("TFNTwitterStatus")) [missing addObject:@"TFNTwitterStatus"];
    NSString* note = missing.count ? [@"missing " stringByAppendingString:[missing componentsJoinedByString:@", "]] : @"all found";
    if (![note isEqualToString:gQuoteNote]) {
        gQuoteNote = note;
        UnifiedLog([@"quote as B, X's pieces: " stringByAppendingString:note]);
    }
    return missing.count ? note : nil;
}

static UIViewController* ControllerOfView(UIView* view) {
    for (UIResponder* responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController*)responder;
    }
    return nil;
}

// Opens X's quote composer for the tweet with B's account, with the composer
// marked for B the way a reply's is: MaybeSwitchReply() recognises it by the
// tweet it quotes and SendAllowed() then guards every send path. This is a
// send path as B (the user's own post); nothing is sent here.
// 7.3.151: the account is VerifiedB() taken here. With asB NO the same call
// opens it with A's own verified account (B's copy of a tweet both have, where
// X's own repost menu is not used); that composer is noted as A's.
static void QuoteAs(BOOL asB, UIView* actionsView, id viewModel) {
    id status = ActedStatus(viewModel);
    long long statusID = NumberGetter(status, @"statusID");
    UIViewController* host = actionsView ? ControllerOfView(actionsView) : nil;
    NSString* who = SideName(asB);
    NSString* why = QuoteAsBMissing();
    if (!why && (statusID <= 0 || ![status isKindOfClass:objc_getClass("TFNTwitterStatus")])) why = @"the tweet is not a TFNTwitterStatus";
    // Only that account, verified now (B: never the one in use).
    id account = why ? nil : (asB ? VerifiedB() : VerifiedA());
    if (!why && !account) why = asB ? [NSString stringWithFormat:@"B's account not certain (%@)", gVerifiedBWhy ?: @"?"] : @"A's account not certain";
    if (!why && !host) why = @"no view controller above the buttons";
    if (why) {
        Blocked([NSString stringWithFormat:@"quote composer for %lld as %@: not opened (%@)", statusID, asB ? @"B" : @"A", why],
                [NSString stringWithFormat:@"%@로 인용할 수 없어서 막았어요. %@ 계정으로 전환해서 해주세요", who, who]);
        return;
    }
    if (asB) MarkComposeAsB(viewModel, ViewModelStatusID(viewModel), YES);
    else NoteComposeChoice(viewModel, ViewModelStatusID(viewModel), @"A");
    UnifiedLog([NSString stringWithFormat:@"quote as %@: -[%@ t1_directQuoteTweetStatus:account:scribeParameters:] for %lld with %@'s account",
                                          asB ? @"B" : @"A", NSStringFromClass([host class]), statusID, asB ? @"B" : @"A"]);
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(host, NSSelectorFromString(@"t1_directQuoteTweetStatus:account:scribeParameters:"), status,
                                                      account, nil);
    } @catch (NSException* exception) {
        if (asB) {
            gComposeAsBUntil = 0;
            gComposeTargets = nil;
            gComposeQuote = NO;
        }
        UnifiedLog([NSString stringWithFormat:@"quote composer for %lld: X's call threw %@", statusID, exception.name]);
        ShowBlockNotice([NSString stringWithFormat:@"인용 화면을 열지 못했어요. %@ 계정으로 전환해서 해주세요", who]);
        return;
    }
    if (!asB) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Still waiting: no composer came up for it.
        if (gComposeQuote && gComposeQuoteID == statusID && gComposeAsBUntil > 0 && CFAbsoluteTimeGetCurrent() > gComposeAsBUntil) {
            gComposeAsBUntil = 0;
            gComposeTargets = nil;
            gComposeQuote = NO;
            UnifiedLog([NSString stringWithFormat:@"quote composer for %lld: none appeared in 6s (not marked, not guarded)", statusID]);
            ShowBlockNotice([NSString stringWithFormat:@"%@로 인용하는 화면을 확인하지 못했어요. 작성 화면이 떴다면 닫고 %@ 계정으로 전환해서 해주세요", BName(),
                                                       BName()]);
        }
    });
}

// 7.3.151: the repost button on a tweet only B has (or on a screen opened as
// B). A tap sent the repost at once and a quote could only go out as A; it
// asks now: repost (or its undo, when B already reposted) or quote, as B.
static void PresentBRepostSheet(UIView* actionsView, id viewModel, NSString* gesture) {
    id status = ActedStatus(viewModel);
    long long actedID = NumberGetter(status, @"statusID");
    id verifiedB = VerifiedB();
    if (actedID <= 0 || !verifiedB) {
        Blocked([NSString stringWithFormat:@"repost / quote as B: no verified B (%@)", gVerifiedBWhy ?: @"?"],
                @"B 계정을 찾지 못해서 막았어요. kemo 설정에서 B 계정을 다시 골라주세요");
        return;
    }
    if (IsProtectedStatus(status)) {
        // Neither can be done; RepostAs says so.
        RepostAs(YES, viewModel, YES);
        return;
    }
    int state = SideState(YES, 1, status, YES);
    NSString* quoteWhy = QuoteAsBMissing();
    NSString* pairAtAsk = gPairKey;
    __weak UIView* weakActions = actionsView;
    UIImage* avatar = AccountAvatar(verifiedB, @"B", BColor());
    // On a screen opened as B, the screen has to be this B's still at the tap.
    BOOL (^screenStill)(void) = ^BOOL {
        UIView* actions = weakActions;
        if (!actions || !BScreenOf(actions)) return YES;
        NSString* trouble = BScreenTrouble(actions);
        if (!trouble) return YES;
        Blocked([@"repost / quote as B on a B screen: " stringByAppendingString:trouble], @"화면이 바뀌어서 보내지 않았어요. 게시물에서 다시 눌러주세요");
        return NO;
    };
    void (^repost)(void) = ^{
        if (!PairStill(pairAtAsk, @"repost / quote choice") || !screenStill()) return;
        RepostAs(YES, viewModel, YES);
        UIView* actions = weakActions;
        if (actions) RelayoutSoon(actions);
    };
    void (^quote)(void) = ^{
        if (!PairStill(pairAtAsk, @"repost / quote choice") || !screenStill()) return;
        QuoteAs(YES, weakActions, viewModel);
    };
    NSMutableDictionary* quoteRow = [NSMutableDictionary dictionary];
    quoteRow[@"title"] = @"인용";
    quoteRow[@"image"] = avatar;
    quoteRow[@"action"] = quote;
    if (quoteWhy) {
        quoteRow[@"detail"] = [NSString stringWithFormat:@"이 X 버전에서는 %@로 인용할 수 없어요", BName()];
        quoteRow[@"disabled"] = @YES;
    }
    NFBPresentAccountSheet([NSString stringWithFormat:@"%@로 재게시할까요?", BName()], nil, @[
        @{ @"title" : state == 1 ? @"재게시 취소" : @"재게시", @"image" : avatar, @"action" : repost },
        quoteRow,
    ]);
    UnifiedLog([NSString stringWithFormat:@"sheet shown: repost / quote as B, %lld, from %@ (B reposted=%d from %@, quote %@)", actedID, gesture,
                                          state, SideSource(YES, status, YES, 1), quoteWhy ? @"off" : @"on"]);
}

static NSString* gBookmarkPressNote = @"(no long press on a bookmark button yet)";
static NSString* gComposerNote = @"(no composer looked at yet)";

// 7.3.151: every long press on like / repost / bookmark opens the account
// sheet, on B's rows and screens too (a tap there goes as B; the sheet is
// where A can be chosen). The bookmark button is new here: X's callback for it
// (-inlineActionButtonDidRecognizeLongPressBegan:) or, if X does not send one,
// this file's own recogniser on the button (BookmarkPress), whichever comes.
// The view is inside one of the unified home's own lists.
static BOOL IsInUnifiedHome(UIView* view) {
    for (UIResponder* responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]] && [gFollowingControllers containsObject:responder]) return YES;
    }
    return NO;
}

static BOOL LongPressChooser(id actionsView, id button, NSString* how) {
    if (!UnifiedActive() || ![actionsView isKindOfClass:[UIView class]]) return NO;
    int kind = ButtonKind(button);
    if (kind < 0 || kind > 2) return NO;
    // 7.3.153: the sheet belongs to the unified home and to B's screens.
    // Anywhere else (search, profiles, lists, a tweet screen of A's) the long
    // press is X's own.
    if (!IsInBScreen((UIView*)actionsView) && !IsInUnifiedHome((UIView*)actionsView)) return NO;
    // The same press reported twice (X's callback and our recogniser): one sheet.
    if (button == gLongPressButton && CFAbsoluteTimeGetCurrent() - gLongPressAt < 1.5) return YES;
    if (kind == 2) {
        NSString* note = [@"sheet opened from " stringByAppendingString:how];
        if (![note isEqualToString:gBookmarkPressNote]) {
            gBookmarkPressNote = note;
            UnifiedLog([@"bookmark long press: " stringByAppendingString:note]);
        }
    }
    BOOL shown = PresentReactionSheet(actionsView, button, [@"long press, " stringByAppendingString:how], nil);
    if (!shown) return NO;
    gLongPressAt = CFAbsoluteTimeGetCurrent();
    gLongPressButton = button;
    // 7.3.151: one tap of haptics as the sheet comes up (the long press began
    // on the main thread; once per sheet).
    UIImpactFeedbackGenerator* haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic prepare];
    [haptic impactOccurred];
    return YES;
}

// 7.3.151: this file's own long press on the bookmark button, put on while
// the mode is active (UpdateActionBadges) and taken off when it is not. It
// opens the same sheet as X's callback would; if both report a press, the
// second is dropped (LongPressChooser).
static const void* kBookmarkPressKey = &kBookmarkPressKey;

@interface NFBBookmarkPressTarget : NSObject
+ (instancetype)shared;
- (void)pressed:(UILongPressGestureRecognizer*)recognizer;
@end

@implementation NFBBookmarkPressTarget

+ (instancetype)shared {
    static NFBBookmarkPressTarget* target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        target = [NFBBookmarkPressTarget new];
    });
    return target;
}

- (void)pressed:(UILongPressGestureRecognizer*)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    UIView* button = recognizer.view;
    UIView* actions = button.superview;
    Class actionsClass = objc_getClass("TTAStatusInlineActionsView");
    while (actions && !(actionsClass && [actions isKindOfClass:actionsClass])) actions = actions.superview;
    if (!actions || !button) return;
    @try {
        LongPressChooser(actions, button, @"this file's recogniser");
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"bookmark long press threw %@", exception.name]);
    }
}

@end

static void SetBookmarkPress(UIView* button, BOOL on) {
    if (!button) return;
    UILongPressGestureRecognizer* recognizer = objc_getAssociatedObject(button, kBookmarkPressKey);
    if (on == (recognizer != nil)) return;
    if (on) {
        recognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:[NFBBookmarkPressTarget shared] action:@selector(pressed:)];
        [button addGestureRecognizer:recognizer];
        objc_setAssociatedObject(button, kBookmarkPressKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        [button removeGestureRecognizer:recognizer];
        objc_setAssociatedObject(button, kBookmarkPressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// MARK: - Which account has it (badge next to the time)

static UIImage* AccountAvatar(id account, NSString* letter, UIColor* color) {
    static NSCache<NSString*, UIImage*>* cache;
    static NSMutableDictionary<NSString*, NSNumber*>* misses;  // when a picture was last looked for and not found
    static NSCache<NSString*, UIImage*>* letters;
    if (!cache) cache = [NSCache new];
    if (!misses) misses = [NSMutableDictionary dictionary];
    if (!letters) letters = [NSCache new];
    NSString* userID = AccountUserID(account) ?: letter;
    UIImage* image = [cache objectForKey:userID];
    if (image) return image;
    // 7.3.151: a miss read the file and walked every window's views again on
    // each layout; it is remembered for a few seconds, and the letter picture
    // is kept too.
    NSString* letterKey = [NSString stringWithFormat:@"%@|%lu", letter, (unsigned long)color.hash];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (misses[userID] && now - misses[userID].doubleValue < 5) {
        UIImage* kept = [letters objectForKey:letterKey];
        if (kept) return kept;
    }
    // AccountBubbles.x keeps the accounts' pictures here.
    NSURL* base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSString* path = [[base URLByAppendingPathComponent:@"NFBAccountAvatars"] URLByAppendingPathComponent:
                                                                                 [userID stringByAppendingString:@".img"]].path;
    NSData* data = (misses[userID] && now - misses[userID].doubleValue < 5) ? nil : [NSData dataWithContentsOfFile:path];
    __block UIImage* found = data.length ? [UIImage imageWithData:data] : nil;
    if (!found && !(misses[userID] && now - misses[userID].doubleValue < 5)) {
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
        [misses removeObjectForKey:userID];
        return found;
    }
    if (!misses[userID] || now - misses[userID].doubleValue >= 5) misses[userID] = @(now);
    UIImage* kept = [letters objectForKey:letterKey];
    if (kept) return kept;
    // A letter in a circle until a picture is found.
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28)];
    UIImage* drawn = [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 28, 28)] fill];
        NSDictionary* attributes = @{
            NSFontAttributeName : [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName : UIColor.whiteColor
        };
        CGSize size = [letter sizeWithAttributes:attributes];
        [letter drawAtPoint:CGPointMake((28 - size.width) / 2, (28 - size.height) / 2) withAttributes:attributes];
    }];
    if (drawn) [letters setObject:drawn forKey:letterKey];
    return drawn;
}

// For the other unified files: an account's picture (the stored one, else a
// letter), drawn round at `side` points when side > 0.
UIImage* NFBUnifiedAccountPicture(id account, CGFloat side) {
    BOOL isB = [AccountUserID(account) isEqualToString:BID()];
    UIImage* image = AccountAvatar(account, isB ? @"B" : @"A", isB ? BColor() : [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1]);
    if (!image || side <= 0) return image;
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        CGRect bounds = CGRectMake(0, 0, side, side);
        [[UIBezierPath bezierPathWithOvalInRect:bounds] addClip];
        CGFloat scale = MAX(side / MAX(image.size.width, 1), side / MAX(image.size.height, 1));
        CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((side - size.width) / 2, (side - size.height) / 2, size.width, size.height)];
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

// 7.3.151: bOnly comes from the row's own object (ProvOf), not from its ID.
static void ApplyBMark(UIView* authorView, UIView* statusView, long long statusID, BOOL bOnly) {
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

static const void* kDecoratedKey = &kDecoratedKey;  // a view this file has put something on

static void UpdateAccountBadge(UIView* authorView) {
    BOOL active = UnifiedActive();
    UIView* statusView = authorView.superview;
    static Class statusViewClass;
    if (!statusViewClass) statusViewClass = objc_getClass("T1StandardStatusView");
    while (statusView && !(statusViewClass && [statusView isKindOfClass:statusViewClass])) statusView = statusView.superview;
    id viewModel = active && statusView ? Getter(statusView, @"viewModel") : nil;
    long long statusID = viewModel ? ViewModelStatusID(viewModel) : 0;
    // A row is B's when the view model it shows is one a merge put there from
    // B's stream as B's alone (7.3.151; it was any row showing that tweet ID).
    BOOL bOnly = statusID > 0 && ProvOf(viewModel) == kProvBOnly;
    BOOL decorated = objc_getAssociatedObject(authorView, kDecoratedKey) != nil;
    if (!bOnly && !decorated) return;  // nothing of ours here, nothing to take off
    UIImageView* badge = [authorView viewWithTag:kBadgeTag];
    ApplyBMark(authorView, statusView, statusID, bOnly);
    objc_setAssociatedObject(authorView, kDecoratedKey, bOnly ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id account = bOnly ? gBAccount : nil;
    NSString* letter = bOnly ? @"B" : nil;
    UIColor* color = bOnly ? [UIColor colorWithRed:1 green:0.48 blue:0 alpha:1] : nil;
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
    // 7.3.151: the list replaces what was known (an unfollow drops out); A's is
    // the only source of "A follows" from here on (AFollowSet).
    void (^store)(void) = ^{
        gKnownFollows[accountID] = [userIDs copy];
        UnifiedLog([NSString stringWithFormat:@"following list for %@: %lu people", accountID, (unsigned long)userIDs.count]);
        if (gEverActive) ReapplyMerge(YES, YES);
    };
    if ([NSThread isMainThread]) store();
    else dispatch_async(dispatch_get_main_queue(), store);
}

NSSet<NSNumber*>* NFBUnifiedKnownFollows(NSString* accountID) {
    return accountID.length ? gKnownFollows[accountID] : nil;
}

extern NSString* NFBUnifiedFollowSyncDebugText(void);

NSString* NFBUnifiedTimelineDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedB];
    NSString* currentID = AccountUserID(CurrentAccount());
    [out appendFormat:@"mode=%d A=%@ (%@) unifiedActive=%d alwaysAsk=%d retired=%lu\n", UnifiedModeSelected(),
                      AID().length ? ([AID() isEqualToString:currentID] ? @"set, in use" : @"set, not in use") : @"none",
                      [[NSUserDefaults standardUserDefaults] stringForKey:kUnifiedAName] ?: @"-", UnifiedActive(),
                      [BHTSettings boolForKey:kUnifiedAlwaysAsk], (unsigned long)0];
    // 7.3.151 (retired IDs are gone: a row is told by its object, see "provenance").
    [out appendString:@"rules: A-base tap=A hold=sheet | both tap=A hold=sheet | B-base tap=B hold=sheet (protected: B only) | "
                      @"A-base protected: A only | reply: composer buttons\n"];
    NSString* whyNot = nil;
    ComputeActive(NULL, &whyNot);
    id verified = [NSThread isMainThread] ? VerifiedB() : nil;
    [out appendFormat:@"verified B: %@\n", verified ? (AccountUserID(verified) ?: @"?")
                                                    : [NSString stringWithFormat:@"none (%@)", [NSThread isMainThread] ? (gVerifiedBWhy ?: @"?")
                                                                                                                      : @"dump not on the main thread"]];
    [out appendFormat:@"pair: A %@ B %@ fixed | active pair key %@ | not active because: %@ | ever active %d\n", AID() ?: @"-", BID() ?: @"-",
                      gPairKey ?: @"-", whyNot ?: @"(it is active)", gEverActive];
    [out appendFormat:@"provenance: rows inserted from B this generation %lu, A's rows marked %lu, B-loaded objects alive %lu (statuses %lu) | "
                      @"status objects shared between A and B: %@ (checked %lu) | hits by view model %lu, by status %lu\n",
                      (unsigned long)gMarkCountB, (unsigned long)gMarkCountA, (unsigned long)gBLoadedItems.allObjects.count,
                      (unsigned long)gBLoadedStatuses.allObjects.count, gStatusShared ? @"YES" : @"no", (unsigned long)gStatusSharedChecked,
                      (unsigned long)gProvHitItem, (unsigned long)gProvHitStatus];
    [out appendFormat:@"A follows from: %@\n", gAFollowNote];
    [out appendFormat:@"blocked: wrong/unknown account %lu%@\n", (unsigned long)gAccountBlocked,
                      gBlockReasons.count ? [@" | last: " stringByAppendingString:[gBlockReasons componentsJoinedByString:@" || "]] : @""];
    [out appendFormat:@"became inactive %@\n", gInactiveNote];
    [out appendFormat:@"B requests this run: refresh %lu, more %lu (budget %lu/%lu), For You refresh %lu, For You more %lu (budget %lu/%lu), "
                      @"lookups %lu | as A: lookups %lu | %@\n",
                      (unsigned long)gReqRefresh, (unsigned long)gReqMore, (unsigned long)gBMorePages, (unsigned long)kMoreBudget,
                      (unsigned long)gReqForYouRefresh, (unsigned long)gReqForYouMore, (unsigned long)gBForYouMorePages,
                      (unsigned long)kMoreBudget, (unsigned long)gBLookupsSent, (unsigned long)gALookupsSent, gMoreNote];
    [out appendFormat:@"B screens open %lu | bookmark long press: %@ | composer: %@\n", (unsigned long)gBScreens.allObjects.count,
                      gBookmarkPressNote, gComposerNote];
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
    [out appendFormat:@"B modules: %@\n", gModuleNote];
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
                      (unsigned long)gAOnlyIDs.count, (unsigned long)gBlocked, (unsigned long)gDone[1][0].count,
                      (unsigned long)gDone[1][1].count];
    [out appendFormat:@"explicit as A on B's copies: liked=%lu reposted=%lu bookmarked=%lu\n", (unsigned long)gDone[0][0].count,
                      (unsigned long)gDone[0][1].count, (unsigned long)gDone[0][2].count];
    // 7.3.151: quote as B, the pictures next to repost / bookmark, B's lookups.
    [out appendFormat:@"quote as B, X's pieces: %@ | pending mark: %@\n", gQuoteNote,
                      gComposeAsBUntil > CFAbsoluteTimeGetCurrent() ? (gComposeQuote ? @"quote" : @"reply") : @"none"];
    [out appendFormat:@"bookmarkedAsB=%lu unbookmarkedAsB=%lu B lookups sent=%lu kept=%lu badge memo=%lu\n", (unsigned long)gDone[1][2].count,
                      (unsigned long)gUndone[1][2].count, (unsigned long)gBLookupsSent, (unsigned long)gBLookups.count,
                      (unsigned long)gBadgeMemo.count];
    [out appendFormat:@"repost / bookmark badges (source):\n  %@\n",
                      gBadgeLog.count ? [gBadgeLog componentsJoinedByString:@"\n  "] : @"(none shown)"];
    @synchronized(UnifiedLock()) {
        [out appendFormat:@"%@\n", gUnifiedLog.count ? [gUnifiedLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

// MARK: - Who liked it (left of the heart)

static const NSInteger kLikeBadgeTag = 0x4E464C;  // "NFL"

// 7.3.151: the same left of the repost and bookmark buttons. The buttons are
// found the way the heart is, by class name: TTAStatusInlineFavoriteButton,
// TTAStatusInlineRetweetButton, TTAStatusInlineBookmarkButton (12.44 dump,
// XAppLibraries; all TTAStatusInlineActionButton). A button that is not in
// the row (the bookmark on some screens) gets no pictures.
static const NSInteger kRepostBadgeTag = 0x4E4652;    // "NFR"
static const NSInteger kBookmarkBadgeTag = 0x4E464B;  // "NFK"

// gBadgeMemo (declared at the top): from B's actions here, B's own copy and
// the answers kept by LookUpBState.
static void BadgeMemoClear(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BadgeMemoClear();
        });
        return;
    }
    [gBadgeMemo removeAllObjects];
}

static NSArray<NSNumber*>* BadgeMemo(id status, long long actedID) {
    NSArray<NSNumber*>* memo = gBadgeMemo[@(actedID)];
    if (memo) return memo;
    memo = @[ @(SideState(YES, 0, status, NO)), @(SideState(YES, 1, status, NO)), @(SideState(YES, 2, status, NO)) ];
    if (!gBadgeMemo) gBadgeMemo = [NSMutableDictionary dictionary];
    if (gBadgeMemo.count > 400) [gBadgeMemo removeAllObjects];
    gBadgeMemo[@(actedID)] = memo;
    return memo;
}

static UIView* InlineButton(UIView* actionsView, NSString* classPart) {
    for (UIView* view in actionsView.subviews) {
        if ([NSStringFromClass([view class]) containsString:classPart]) return view;
    }
    return nil;
}

// The accounts' pictures left of one button; none (hidden) when neither acted.
static void ShowBadge(UIView* actionsView, NSInteger tag, UIView* button, BOOL byA, BOOL byB) {
    UIView* holder = [actionsView viewWithTag:tag];
    if (!button || button.hidden || (!byA && !byB)) {
        holder.hidden = YES;
        return;
    }
    if (!holder) {
        holder = [UIView new];
        holder.tag = tag;
        holder.userInteractionEnabled = NO;
        [actionsView addSubview:holder];
    }
    NSMutableArray* accounts = [NSMutableArray array];
    if (byA) [accounts addObject:@[ CurrentAccount() ?: [NSNull null], @"A", [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1] ]];
    if (byB) [accounts addObject:@[ gBAccount ?: [NSNull null], @"B", [UIColor colorWithRed:1 green:0.48 blue:0 alpha:1] ]];
    const CGFloat size = 16, overlap = 5;
    CGFloat width = size + (accounts.count - 1) * (size - overlap);
    // The button's picture sits 6pt into it (TFNAnimatableButton's image).
    CGFloat buttonX = CGRectGetMinX(button.frame) + 6;
    CGRect frame = CGRectMake(buttonX - 3 - width, CGRectGetMidY(button.frame) - size / 2, width, size);
    if (!CGRectEqualToRect(holder.frame, frame)) holder.frame = frame;
    // 7.3.151: the two picture views are kept and reused (they were made anew
    // on every layout of every action bar).
    for (NSUInteger i = 0; i < 2; i++) {
        UIImageView* picture = [holder viewWithTag:100 + (NSInteger)i];
        if (i >= accounts.count) {
            picture.hidden = YES;
            continue;
        }
        if (!picture) {
            picture = [[UIImageView alloc] initWithFrame:CGRectMake(i * (size - overlap), 0, size, size)];
            picture.tag = 100 + (NSInteger)i;
            picture.contentMode = UIViewContentModeScaleAspectFill;
            picture.clipsToBounds = YES;
            picture.layer.cornerRadius = size / 2;
            picture.layer.borderWidth = 1;
            [holder addSubview:picture];
        }
        id account = accounts[i][0] == [NSNull null] ? nil : accounts[i][0];
        UIImage* image = AccountAvatar(account, accounts[i][1], accounts[i][2]);
        if (picture.image != image) picture.image = image;
        picture.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
        picture.hidden = NO;
    }
    if (holder.hidden) holder.hidden = NO;
    if (actionsView.subviews.lastObject != holder) [actionsView bringSubviewToFront:holder];
}

// For the shake dump: where a repost / bookmark picture came from, once each.
static void NoteBadge(int kind, id status, BOOL statusIsB, BOOL byA, BOOL byB) {
    long long actedID = NumberGetter(status, @"statusID");
    NSString* key = [NSString stringWithFormat:@"%@ %lld A=%d B=%d", kind == 1 ? @"repost" : @"bookmark", actedID, byA, byB];
    if ([gBadgeLogged containsObject:key]) return;
    if (!gBadgeLogged) gBadgeLogged = [NSMutableSet set];
    if (!gBadgeLog) gBadgeLog = [NSMutableArray array];
    if (gBadgeLogged.count > 300) [gBadgeLogged removeAllObjects];
    [gBadgeLogged addObject:key];
    [gBadgeLog addObject:[NSString stringWithFormat:@"%@ (A: %@, B: %@)", key,
                                                    byA ? (statusIsB ? SideSource(NO, status, NO, kind) : @"X's flag on A's copy") : @"-",
                                                    byB ? SideSource(YES, status, statusIsB, kind) : @"-"]];
    while (gBadgeLog.count > 10) [gBadgeLog removeObjectAtIndex:0];
}

// Who liked, reposted and bookmarked the tweet, left of each button.
// 7.3.151: it was the heart only, and B's like only when made in this session;
// B's side now comes from BLikeState / BRepostState / BBookmarkState.
static void UpdateActionBadges(UIView* actionsView) {
    UIView* heart = InlineButton(actionsView, @"FavoriteButton");
    UIView* repost = InlineButton(actionsView, @"RetweetButton");
    UIView* bookmark = InlineButton(actionsView, @"BookmarkButton");
    BOOL byA[3] = { NO, NO, NO }, byB[3] = { NO, NO, NO };
    BOOL active = UnifiedActive();
    // 7.3.151: this file's own long press on the bookmark button, only while
    // the mode is active.
    SetBookmarkPress(bookmark, active);
    if (active && (heart || repost || bookmark)) {
        id viewModel = Getter(actionsView, @"viewModel");
        id status = ActedStatus(viewModel);
        long long actedID = NumberGetter(status, @"statusID");
        // 7.3.151: by the object the row shows, not by the tweet's ID.
        NSInteger cls = ProvOf(viewModel);
        BOOL listed = cls == kProvABoth || cls == kProvAOnly;
        BOOL retired = cls == kProvBStale;
        // The copy on screen was loaded as B: a row from B's stream, or a
        // screen opened as B.
        BOOL statusIsB = cls == kProvBOnly || cls == kProvBBoth || cls == kProvBPlain || (!listed && !retired && IsInBScreen(actionsView));
        if (actedID > 0 && !retired) {
            if (statusIsB) {
                // Loaded by B, so X's own flags are B's. A's side is not on
                // screen: what A did here with explicit calls, A's own copy
                // in its streams, or what X answered when asked as A.
                for (int kind = 0; kind < 3; kind++) {
                    byB[kind] = SideState(YES, kind, status, YES) == 1;
                    byA[kind] = SideState(NO, kind, status, NO) == 1;
                }
            } else {
                // A's copy: X's own flags are A's; B's side is what is known of B.
                NSArray<NSNumber*>* memo = BadgeMemo(status, actedID);
                for (int kind = 0; kind < 3; kind++) byB[kind] = memo[(NSUInteger)kind].intValue == 1;
                // A's pictures as before on the unified timelines; elsewhere
                // only next to B's (a plain screen of A's keeps X's look).
                BOOL loadingLiked = BoolGetter(status, @"favoritedByLoadingAccount") || BoolGetter(status, @"seenAsFavorited");
                byA[0] = loadingLiked && (listed || byB[0]);
                byA[1] = AReactionState(status, 1, NO) == 1 && (listed || byB[1]);
                byA[2] = AReactionState(status, 2, NO) == 1 && (listed || byB[2]);
            }
            if ((byA[1] || byB[1]) && repost && !repost.hidden) NoteBadge(1, status, statusIsB, byA[1], byB[1]);
            if ((byA[2] || byB[2]) && bookmark && !bookmark.hidden) NoteBadge(2, status, statusIsB, byA[2], byB[2]);
        }
    }
    ShowBadge(actionsView, kLikeBadgeTag, heart, byA[0], byB[0]);
    ShowBadge(actionsView, kRepostBadgeTag, repost, byA[1], byB[1]);
    ShowBadge(actionsView, kBookmarkBadgeTag, bookmark, byA[2], byB[2]);
    // Remembered on the view, so a bar this file never touched costs nothing
    // once the mode is off (the layout hook looks for this, not for tags).
    BOOL any = byA[0] || byA[1] || byA[2] || byB[0] || byB[1] || byB[2];
    BOOL decorated = objc_getAssociatedObject(actionsView, kDecoratedKey) != nil;
    BOOL wanted = active && (any || bookmark != nil);
    if (decorated != wanted) objc_setAssociatedObject(actionsView, kDecoratedKey, wanted ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// MARK: - The mode goes off, or on (7.3.151)

// The rows this file decorates, laid out again so marks and pictures go (or come).
static void RelayoutVisibleRows(void) {
    Class author = objc_getClass("TTAStatusAuthorView");
    Class actions = objc_getClass("TTAStatusInlineActionsView");
    Class single = objc_getClass("T1TweetComposeSingleTweetView");
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            EnumerateSubviewsRecursively(window, ^(UIView* view) {
                if ((author && [view isKindOfClass:author]) || (actions && [view isKindOfClass:actions]) ||
                    (single && [view isKindOfClass:single])) {
                    [view setNeedsLayout];
                }
            });
        }
    }
}

// Every tweet screen opened as B that is still on a navigation stack is closed
// (the user's decision): popped without animation when it is on top, taken
// out of the stack otherwise. One that cannot be (the stack's root, or not on
// a stack) stays remembered, and taps on it stay stopped.
static NSUInteger CloseBScreens(NSUInteger* leftOut) {
    NSUInteger closed = 0, left = 0;
    for (UIViewController* screen in [gBScreens allObjects]) {
        BOOL done = NO;
        @try {
            UINavigationController* navigation = screen.navigationController;
            NSArray<UIViewController*>* stack = navigation.viewControllers;
            // The screen itself, or the controller that holds it, on the stack.
            UIViewController* onStack = screen;
            while (onStack && [stack indexOfObjectIdenticalTo:onStack] == NSNotFound) onStack = onStack.parentViewController;
            NSUInteger index = onStack ? [stack indexOfObjectIdenticalTo:onStack] : NSNotFound;
            if (navigation && index != NSNotFound && index > 0) {
                if (navigation.topViewController == onStack) {
                    [navigation popViewControllerAnimated:NO];
                } else {
                    NSMutableArray<UIViewController*>* kept = [stack mutableCopy];
                    [kept removeObjectAtIndex:index];
                    [navigation setViewControllers:kept animated:NO];
                }
                done = YES;
            }
        } @catch (NSException* exception) {
            UnifiedLog([NSString stringWithFormat:@"closing a B screen threw %@", exception.name]);
        }
        if (done) {
            closed++;
            [gBScreens removeObject:screen];
        } else {
            left++;
        }
    }
    if (leftOut) *leftOut = left;
    return closed;
}

// The one place the mode ends: the dock stopped on a single account, the
// feature was switched off, the saved pair changed, or the account in use is
// no longer A (called by UnifiedActive() the first time it sees it). Nothing
// built for the unified mode may go on having an effect after this.
extern void NFBUnifiedGuardReset(void);

static void UnifiedBecameInactive(NSString* why) {
    NFBUnifiedGuardReset();
    gWasActive = NO;
    gPairKey = nil;
    // (1) A's lists as X made them, once; then nothing is kept that a later
    // re-merge could push back (an old snapshot rewound A's home list).
    NSMutableArray<NSArray*>* toRestore = [NSMutableArray array];
    for (id controller in [gFollowingControllers allObjects]) {
        NSArray* original = objc_getAssociatedObject(controller, kOriginalSectionsKey);
        if (original) [toRestore addObject:@[ controller, original ]];
        objc_setAssociatedObject(controller, kOriginalSectionsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, kRecordKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, kReapplyOwedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, kModuleCacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [gFollowingControllers removeAllObjects];
    // (3) Everything kept for B. The marks go; what was loaded as B stays
    // known as such (gBLoadedItems), so a row of B's still on screen is stopped.
    SetBAccount(nil);
    for (NSString* key in [gBLookupWaiters allKeys]) BLookupFinish(key, [key containsString:@"|B|"], 0, nil, nil, @"the mode went off");
    [gBLookups removeAllObjects];
    gComposeTargets = nil;
    gComposeAsBUntil = 0;
    gComposeQuote = NO;
    [gComposeChoices removeAllObjects];
    [gComposeChoiceOrder removeAllObjects];
    [gBScreenStatusIDs removeAllObjects];
    RebuildMarks();  // no controllers left: every mark and ID set is emptied
    NoteGuard();
    gMoreNote = @"-";
    NSUInteger restoring = toRestore.count;
    UnifiedLog([NSString stringWithFormat:@"became inactive (%@)", why]);
    gInactiveNote = [NSString stringWithFormat:@"(%@): clearing…", why];
    // (1), (2), (4) touch X's views: after the current layout or tap is over.
    dispatch_async(dispatch_get_main_queue(), ^{
        gActiveCacheValid = NO;
        BOOL activeAgain = UnifiedActive();  // the pair changed and the new one is active
        NSUInteger restored = 0;
        gUnmerging = !activeAgain;
        for (NSArray* pair in toRestore) {
            id controller = pair[0];
            SEL set = @selector(setSections:restoreScrollPosition:);
            if (![controller respondsToSelector:set]) continue;
            @try {
                ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, set, StripBLoaded(pair[1], NULL), YES);
                restored++;
            } @catch (NSException* exception) {
                UnifiedLog([NSString stringWithFormat:@"giving A's list back threw %@", exception.name]);
            }
        }
        gUnmerging = NO;
        NSUInteger left = 0;
        NSUInteger closed = CloseBScreens(&left);
        RelayoutVisibleRows();
        gInactiveNote = [NSString stringWithFormat:@"(%@): closed %lu B screens (%lu could not be closed), cleared B's timelines, lookups, marks, "
                                                   @"composer marks; A's lists put back %lu of %lu%@",
                                                   why, (unsigned long)closed, (unsigned long)left, (unsigned long)restored,
                                                   (unsigned long)restoring, activeAgain ? @"; active again with the new pair" : @""];
        UnifiedLog([@"became inactive " stringByAppendingString:gInactiveNote]);
    });
}

// The mode came on (or the pair changed): A's home lists, as they are now,
// are merged. Their sections are read from the controllers themselves
// (-[TFNItemsDataViewController sections], 12.44 dump), never from something
// kept from an earlier active stretch.
static void UnifiedBecameActive(void) {
    if (!UnifiedActive()) return;
    NSMutableArray* found = [NSMutableArray array];
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* window in ((UIWindowScene*)scene).windows) CollectControllers(window.rootViewController, @"THFHomeTimelineItemsViewController", found);
    }
    NSUInteger merged = 0;
    for (id controller in found) {
        if ([gFollowingControllers containsObject:controller]) continue;
        if (!IsFollowingController(controller) && !IsForYouController(controller)) continue;
        id sections = Getter(controller, @"sections");
        SEL set = @selector(setSections:restoreScrollPosition:);
        if (![sections isKindOfClass:[NSArray class]] || [sections count] == 0 || ![controller respondsToSelector:set]) continue;
        @try {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller, set, sections, YES);
            merged++;
        } @catch (NSException* exception) {
            UnifiedLog([NSString stringWithFormat:@"merging a home list on activation threw %@", exception.name]);
        }
    }
    UnifiedLog([NSString stringWithFormat:@"mode on: %lu home lists found, %lu given their sections again to merge", (unsigned long)found.count,
                                          (unsigned long)merged]);
    RelayoutVisibleRows();
    // The first B load of a launch waits for the Following tab (the constructor's own, 8s in).
    if (CFAbsoluteTimeGetCurrent() - gStartedAt > 8) {
        gBLastRefresh = 0;
        RefreshB(101, @"mode on");
    }
}

// MARK: - The dock's "A/B" circle (AccountBubbles.x)

// A and B for the dock: both from settings. 7.3.151: with no A saved there is
// no pair (it used to take the account in use as A), so the circle does not
// appear and nothing is active.
BOOL NFBUnifiedDockPair(id* outA, id* outB) {
    if (![BHTSettings boolForKey:kUnifiedOn]) return NO;
    NSString* aID = AID();
    NSString* bID = BID();
    if (aID.length == 0 || bID.length == 0 || [aID isEqualToString:bID]) return NO;
    id a = AccountForID(aID);
    id b = AccountForID(bID);
    if (!a || !b || [AccountUserID(a) isEqualToString:AccountUserID(b)]) return NO;
    if (outA) *outA = a;
    if (outB) *outB = b;
    return YES;
}

BOOL NFBUnifiedIsActive(void) {
    return UnifiedActive();
}

// The dock stopped on the "A/B" circle (unified YES, `a` is A) or on an account.
// 7.3.151: it no longer saves the account in use as A; A is the saved one.
void NFBUnifiedDockChose(BOOL unified, id a) {
    if (![BHTSettings boolForKey:kUnifiedOn]) return;
    if (unified && (AID().length == 0 || ![AccountUserID(a) isEqualToString:AID()])) {
        UnifiedLog(@"dock: A/B chosen but its A is not the saved A; nothing changed");
        return;
    }
    if (UnifiedModeSelected() == unified && [[NSUserDefaults standardUserDefaults] objectForKey:kUnifiedMode]) return;
    SetUnifiedMode(unified);
    UnifiedLog(unified ? @"dock: A/B chosen, unified on" : @"dock: an account chosen, unified off");
    void (^look)(void) = ^{
        // The turn's first question sees the change (UnifiedActive): off at
        // once; on once the dock has switched to A.
        if (!unified) gInactiveHint = @"the dock stopped on a single account";
        gActiveCacheValid = NO;
        (void)UnifiedActive();
        gInactiveHint = nil;
    };
    if ([NSThread isMainThread]) look();
    else dispatch_async(dispatch_get_main_queue(), look);
    if (unified) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), look);
}

// MARK: - Hooks

// 7.3.151: which of X's home timelines are A's Following / For You ones is
// only noted while the feature is switched on (kemo_unified_exp): with it off
// these three are X's own calls and nothing else. (It cannot wait for the mode
// to be active: the timelines are made once, at launch, and the dock may turn
// the mode on later. A weak note of the object is all that is kept.)
%hook T1TimelineFactory

- (id)homeTimelineForAccount:(id)account {
    id timeline = %orig;
    if (timeline && !gMakingB && [BHTSettings boolForKey:kUnifiedOn]) {
        if (!gForYouTimelines) gForYouTimelines = [NSHashTable weakObjectsHashTable];
        [gForYouTimelines addObject:timeline];
    }
    return timeline;
}

- (id)homeLatestTimelineForAccount:(id)account {
    id timeline = %orig;
    if (timeline && !gMakingB && [BHTSettings boolForKey:kUnifiedOn]) {
        if (!gFollowingTimelines) gFollowingTimelines = [NSHashTable weakObjectsHashTable];
        [gFollowingTimelines addObject:timeline];
    }
    return timeline;
}

- (id)homeRankedFollowingTimelineForAccount:(id)account {
    id timeline = %orig;
    if (timeline && !gMakingB && [BHTSettings boolForKey:kUnifiedOn]) {
        if (!gFollowingTimelines) gFollowingTimelines = [NSHashTable weakObjectsHashTable];
        [gFollowingTimelines addObject:timeline];
    }
    return timeline;
}

%end

// The controller of A's that shows `timeline` and is the one being looked at.
static id VisibleControllerForTimeline(id timeline) {
    for (id controller in [gFollowingControllers allObjects]) {
        if (ControllerTimeline(controller) == timeline && ControllerVisible(controller)) return controller;
    }
    return nil;
}

// A's timeline refreshed: B's matching timeline (Following or For You) too.
// 7.3.151: B's Following on every refresh of A's Following, as before (the
// user needs B's new tweets on each refresh). B's For You only when A's For
// You is the tab being looked at. Each resets its page budget.
static void FollowARefresh(id timeline, long long source) {
    if (!gEverActive) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FollowARefresh(timeline, source);
        });
        return;
    }
    if (timeline == gBTimeline || timeline == gBForYouTimeline || !UnifiedActive()) return;
    if (Getter(timeline, @"account") != CurrentAccount()) return;
    if ([gFollowingTimelines containsObject:timeline]) {
        gBMorePages = 0;
        RefreshB(source, @"A refreshed");
    } else if ([gForYouTimelines containsObject:timeline]) {
        if (!VisibleControllerForTimeline(timeline)) {
            UnifiedLog(@"A's For You refreshed while it is not the tab on screen; B's For You left alone");
            return;
        }
        gBForYouMorePages = 0;
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
    if (!gEverActive) return;
    // 7.3.151: this may not be the main thread; everything below is main-only.
    id timeline = self;
    void (^updated)(void) = ^{
        BOOL following = timeline == gBTimeline;
        if (!following && timeline != gBForYouTimeline) return;
        // B's copies changed; what was worked out from them is stale.
        gBStreamGen++;
        BadgeMemoClear();
        if (!UnifiedActive()) return;
        UnifiedLog(following ? @"B stream updated" : @"B For You updated");
        ReapplyMerge(following, !following);
    };
    if ([NSThread isMainThread]) updated();
    else dispatch_async(dispatch_get_main_queue(), updated);
}

%end

// B's Following stream loads its next page. 7.3.151: only for the controller
// being looked at, only when the page asked for before brought something
// (B's oldest tweet moved or the stream grew), and at most kMoreBudget pages
// until A itself refreshes or loads more. It used to ask after every merge
// while A reached further back than B.
static void LoadMoreB(id controller, long long source, NSString* why) {
    if (!UnifiedActive() || !IsFollowingController(controller) || !ControllerVisible(controller)) return;
    id bStream = Getter(gBTimeline, @"stream");
    if (!bStream || CFAbsoluteTimeGetCurrent() - gBLastBottom < 5) return;
    if (gBMorePages >= kMoreBudget) {
        gMoreNote = @"Following: page budget used; waits for A to refresh or load more";
        return;
    }
    id objects = Getter(bStream, @"streamObjects");
    NSUInteger count = [objects isKindOfClass:[NSArray class]] ? [objects count] : 0;
    long long oldest = LLONG_MAX;
    if ([objects isKindOfClass:[NSArray class]]) {
        for (id object in objects) {
            if (IsStatusItem(object) && SortKey(object) > 0) oldest = MIN(oldest, SortKey(object));
        }
    }
    if (gBMoreAsked && count == gBMoreCount && oldest == gBMoreOldest) {
        gMoreNote = @"Following: the last page brought nothing; no further page";
        return;
    }
    // B's timeline has to be this B's, verified now.
    id account = VerifiedB();
    if (!account || Getter(gBTimeline, @"account") != account) return;
    SEL selector = NSSelectorFromString(@"loadBottomWithSource:");
    if (![bStream respondsToSelector:selector]) {
        UnifiedLog(@"B stream has no loadBottomWithSource:");
        return;
    }
    gBLastBottom = CFAbsoluteTimeGetCurrent();
    gBMorePages++;
    gBMoreAsked = YES;
    gBMoreCount = count;
    gBMoreOldest = oldest;
    gReqMore++;
    gMoreNote = @"-";
    @try {
        BOOL started = ((BOOL (*)(id, SEL, long long))objc_msgSend)(bStream, selector, source);
        gBBottomLoads++;
        UnifiedLog([NSString stringWithFormat:@"B more (%@, source %lld) started=%d (page %lu/%lu)", why, source, started,
                                              (unsigned long)gBMorePages, (unsigned long)kMoreBudget]);
    } @catch (NSException* exception) {
        UnifiedLog([NSString stringWithFormat:@"B load more threw %@", exception.name]);
    }
}

// A's own stream loaded more: the page budget starts again, and B's Following
// loads more with A's (at most every 5s, within LoadMoreB's limits).
static void FollowBottomLoad(id stream, long long source) {
    if (!gEverActive) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FollowBottomLoad(stream, source);
        });
        return;
    }
    if (!UnifiedActive()) return;
    if (stream == Getter(gBTimeline, @"stream") || stream == Getter(gBForYouTimeline, @"stream")) return;
    id current = CurrentAccount();
    for (id timeline in [gFollowingTimelines allObjects]) {
        if (Getter(timeline, @"stream") != stream || Getter(timeline, @"account") != current) continue;
        gBMorePages = 0;
        id controller = VisibleControllerForTimeline(timeline);
        if (controller) LoadMoreB(controller, source, @"A loaded more");
        return;
    }
    for (id timeline in [gForYouTimelines allObjects]) {
        if (Getter(timeline, @"stream") != stream || Getter(timeline, @"account") != current) continue;
        // B's For You asks for its own next page when a merge runs out of B's.
        gBForYouMorePages = 0;
        return;
    }
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

// 7.3.151: a home list whose B stream changed while it was not in a window
// (ReapplyMerge leaves it alone then) is merged again when it is displayed.
// -[TFNItemsDataViewController dataViewDidDisplay] (v16@0:8, 12.44 dump).
- (void)dataViewDidDisplay {
    %orig;
    if (!gEverActive || !objc_getAssociatedObject(self, kReapplyOwedKey)) return;
    objc_setAssociatedObject(self, kReapplyOwedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (UnifiedActive()) ReapplyController(self);
}

%end

// 7.3.151: with the mode never active in this run, every method below is X's
// own call and nothing else (gEverActive); with it off again, only a view this
// file had put something on is cleaned up, once.
%hook TTAStatusInlineActionsView

- (void)layoutSubviews {
    %orig;
    if (!gEverActive) return;
    UIView* view = (UIView*)self;
    if (UnifiedActive() || objc_getAssociatedObject(view, kDecoratedKey)) UpdateActionBadges(view);
}

- (void)didTapInlineActionButton:(id)button {
    if (!gEverActive) {
        %orig;
        return;
    }
    if (SwallowAfterLongPress(button)) return;
    // 7.3.151: repost and bookmark too (their pictures follow X's own taps).
    int kind = ButtonKind(button);
    if (kind >= 0 && kind <= 2 && UnifiedActive()) RelayoutSoon((UIView*)self);
    if (HandleInlineAction(self, button, ^{
            %orig;
        }))
        return;
    %orig;
}

- (void)didTapInlineActionButton:(id)button withPrompt:(id)prompt menuItem:(long long)menuItem {
    if (!gEverActive) {
        %orig;
        return;
    }
    if (SwallowAfterLongPress(button)) return;
    if (HandleInlineAction(self, button, ^{
            %orig;
        }))
        return;
    %orig;
}

// 7.3.151: not hooked before; X's own handling ran here even on B's rows.
- (void)didTapSecondaryInlineActionButton:(id)button {
    if (HandleSecondaryAction(self, button)) return;
    %orig;
}

- (void)inlineActionButtonDidRecognizeLongPressBegan:(id)button {
    if (!gEverActive) {
        %orig;
        return;
    }
    gLongPressXPath = ^{
        %orig;
    };
    BOOL chose = LongPressChooser(self, button, @"X's long-press callback");
    gLongPressXPath = nil;
    if (chose) return;
    if (HandleInlineAction(self, button, ^{
            %orig;
        }))
        return;
    %orig;
}

- (void)didTriggerAlternateActionInInlineActionButton:(id)button {
    if (!gEverActive) {
        %orig;
        return;
    }
    if (SwallowAfterLongPress(button)) return;
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
    if (!gEverActive) return;
    UIView* view = (UIView*)self;
    if (UnifiedActive() || objc_getAssociatedObject(view, kDecoratedKey)) UpdateAccountBadge(view);
}

%end

// MARK: - Likes, reposts and bookmarks that do not come from the action bar (7.3.151)
//
// X can like, repost or bookmark a row without its action bar: a swipe on the
// row (T1StatusCell -onSwipeRight / -onSwipeLeft / -getSwipeActionDelegateForAction:
// logAction:, whose T1StatusCellSwipeActionDelegateFavorite / …Repost /
// …Bookmark run -onAction) and a double tap on media (-[T1InlineMediaView
// _t1_doubleTapAction], -[TweetMediaAttachments.MultiMediaView
// multiPhotoDidDoubleTap:], -[T1TwitterSwift.ImmersiveDoubleTapLikePluginView
// handleDoubleTap:]); all from the 12.44 dump. These are X's own paths with
// whatever account X picks, so on anything loaded as B (a row from B's stream,
// a screen opened as B) they are stopped with a notice; the buttons are where
// B's rows are acted on.

static NSMapTable* gSwipeCells;  // a swipe delegate -> the cell that made it (both weak)

static void NoteSwipeDelegate(id delegate, id cell) {
    if (!delegate || !cell || !gEverActive || !UnifiedActive()) return;
    if (!gSwipeCells) gSwipeCells = [NSMapTable weakToWeakObjectsMapTable];
    [gSwipeCells setObject:cell forKey:delegate];
}

// The view model of the tweet a view belongs to: the nearest view above it
// that has one with a status ID (T1StandardStatusView).
static id ViewModelAbove(UIView* view) {
    for (UIView* current = view; current; current = current.superview) {
        id viewModel = Getter(current, @"viewModel");
        if (viewModel && ViewModelStatusID(viewModel) > 0) return viewModel;
    }
    return nil;
}

static BOOL StopIfLoadedAsB(UIView* view, id viewModel, NSString* what) {
    BOOL inB = view && IsInBScreen(view);
    if (!inB && !ProvIsBLoaded(ProvOf(viewModel))) return NO;
    gBlocked++;
    UnifiedLog([NSString stringWithFormat:@"blocked %@ on a B %@", what, inB ? @"screen" : @"row"]);
    ShowBlockNotice([NSString stringWithFormat:@"%@ 게시물이라 이 동작은 막아뒀어요. 아래 버튼으로 눌러주세요", BName()]);
    return YES;
}

static BOOL StopSwipeAction(id delegate, NSString* what) {
    if (!gEverActive) return NO;
    UIView* cell = [gSwipeCells objectForKey:delegate];
    if (!cell) {
        Class cellClass = objc_getClass("T1StatusCell");
        id actionView = Getter(delegate, @"actionView");
        UIView* current = [actionView isKindOfClass:[UIView class]] ? (UIView*)actionView : nil;
        while (current && !(cellClass && [current isKindOfClass:cellClass])) current = current.superview;
        cell = current;
    }
    if (!cell) {
        // Which row was swiped is not known: stopped only while the mode is on.
        if (!UnifiedActive()) return NO;
        Blocked([NSString stringWithFormat:@"%@: the swiped row is not known", what], @"어느 게시물인지 확인하지 못해서 막았어요. 아래 버튼으로 눌러주세요");
        return YES;
    }
    id statusView = Getter(cell, @"statusView");
    id viewModel = Getter(statusView, @"viewModel") ?: ViewModelAbove([statusView isKindOfClass:[UIView class]] ? (UIView*)statusView : nil);
    return StopIfLoadedAsB(cell, viewModel, what);
}

%hook T1StatusCell

- (id)getSwipeActionDelegateForAction:(long long)action logAction:(id)logAction {
    id delegate = %orig;
    NoteSwipeDelegate(delegate, self);
    return delegate;
}

- (id)onSwipeRight {
    id delegate = %orig;
    NoteSwipeDelegate(delegate, self);
    return delegate;
}

- (id)onSwipeLeft {
    id delegate = %orig;
    NoteSwipeDelegate(delegate, self);
    return delegate;
}

%end

%hook T1StatusCellSwipeActionDelegateFavorite
- (void)onAction {
    if (StopSwipeAction(self, @"swipe to like")) return;
    %orig;
}
%end

%hook T1StatusCellSwipeActionDelegateRepost
- (void)onAction {
    if (StopSwipeAction(self, @"swipe to repost")) return;
    %orig;
}
%end

%hook T1StatusCellSwipeActionDelegateBookmark
- (void)onAction {
    if (StopSwipeAction(self, @"swipe to bookmark")) return;
    %orig;
}
%end

%hook T1InlineMediaView
- (void)_t1_doubleTapAction {
    if (gEverActive && StopIfLoadedAsB((UIView*)self, ViewModelAbove((UIView*)self), @"double tap on media")) return;
    %orig;
}
%end

%hook _TtC21TweetMediaAttachments14MultiMediaView
- (void)multiPhotoDidDoubleTap:(id)sender {
    if (gEverActive && StopIfLoadedAsB((UIView*)self, ViewModelAbove((UIView*)self), @"double tap on photos")) return;
    %orig;
}
%end

// The full-screen media viewer's double tap to like. The view holds no tweet
// this file can read; the action bars of the same screen do (their view
// models), so it is stopped when any of them shows something loaded as B.
%hook _TtC14T1TwitterSwift32ImmersiveDoubleTapLikePluginView
- (void)handleDoubleTap:(id)recognizer {
    if (gEverActive) {
        UIView* view = (UIView*)self;
        UIViewController* screen = ControllerOfView(view);
        while (screen.parentViewController) screen = screen.parentViewController;
        Class actionsClass = objc_getClass("TTAStatusInlineActionsView");
        __block BOOL stopped = NO;
        __block NSUInteger bars = 0;
        if (screen.viewIfLoaded && actionsClass) {
            EnumerateSubviewsRecursively(screen.viewIfLoaded, ^(UIView* current) {
                if (stopped || ![current isKindOfClass:actionsClass]) return;
                bars++;
                if (ProvIsBLoaded(ProvOf(Getter(current, @"viewModel"))) || IsInBScreen(current)) stopped = YES;
            });
        }
        if (stopped) {
            gBlocked++;
            UnifiedLog(@"blocked double tap to like in the media viewer: it shows a tweet loaded as B");
            ShowBlockNotice([NSString stringWithFormat:@"%@ 게시물이라 두 번 탭은 막아뒀어요. 하트 버튼으로 눌러주세요", BName()]);
            return;
        }
        static BOOL noted;
        if (!noted && UnifiedActive()) {
            noted = YES;
            UnifiedLog([NSString stringWithFormat:@"media viewer double tap: %lu action bars looked at, none loaded as B", (unsigned long)bars]);
        }
    }
    %orig;
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

static BOOL gSwitchingComposer;  // this file is switching a composer (not the user, in X's picker)

static void SwitchComposerTo(UIViewController* composer, id account, BOOL quiet) {
    if (!account) return;
    gSwitchingComposer = YES;
    SEL setAccount = NSSelectorFromString(@"setAccount:");
    NSMutableArray* singles = [NSMutableArray array];
    NSMutableArray* tables = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeSingleTweetViewController", singles);
    CollectControllers(composer, @"T1TweetComposeTableViewController", tables);
    SEL didSwitch = NSSelectorFromString(@"singleTweetViewController:didSwitchToAccount:");
    // 7.3.151: a composer X opened with this account already (a quote as B)
    // has nothing to switch; the check and the notice below still run.
    if (ComposerIsAll(composer, account, NULL)) {
        singles = [NSMutableArray array];
        tables = [NSMutableArray array];
    }
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
    gSwitchingComposer = NO;
    NSString* detail = nil;
    BOOL all = ComposerIsAll(composer, account, &detail);
    BOOL toB = [AccountUserID(account) isEqualToString:BID()];
    NSString* name = toB ? BName() : AName();
    UnifiedLog([NSString stringWithFormat:@"composer to %@: %@", toB ? @"B" : @"A", detail]);
    if (!quiet || !all) {
        ShowNotice(all ? [NSString stringWithFormat:@"%@로 써요. 왼쪽 위 프로필이 %@인지 확인해주세요", name, name]
                       : [NSString stringWithFormat:@"%@로 다 바꾸지 못했어요. 왼쪽 위 프로필을 눌러 직접 바꿔주세요", name]);
    }
}

// The account a composer must send as, once it is known (user ID). A composer
// with one is checked at every send path: every piece must be that account.
static const void* kIntendedKey = &kIntendedKey;
static const void* kPendingBKey = &kPendingBKey;

// 7.3.151: the user picked the account in the composer itself (its A/B
// pictures, or X's own account picker): that choice is the one checked.
static const void* kUserChoseKey = &kUserChoseKey;
// Looked at and decided (ComposerCheck); why nothing may leave it, if so; a
// reply or quote for B was expected but the composer could not say its target.
static const void* kDecidedKey = &kDecidedKey;
static const void* kSendBlockedKey = &kSendBlockedKey;
static const void* kTargetUnknownKey = &kTargetUnknownKey;
static const void* kFromBScreenKey = &kFromBScreenKey;

static void SetIntended(UIViewController* composer, id account) {
    objc_setAssociatedObject(composer, kIntendedKey, AccountUserID(account), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The tweet a reply composer answers: from its compositions
// (-[TFNTwitterComposition replyToStatusIDNumber], NSNumber; 12.44 dump), else
// from its reply-context controller (-status). 7.3.151: the compositions
// first; the context controller's status can come late.
static long long ReplyTargetID(UIViewController* composer) {
    NSMutableArray* compositions = [NSMutableArray array];
    id listed = Getter(composer, @"compositions");
    if ([listed isKindOfClass:[NSArray class]]) [compositions addObjectsFromArray:listed];
    NSMutableArray* contexts = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeReplyContextViewController", contexts);
    for (id context in contexts) {
        id composition = Getter(context, @"composition");
        if (composition) [compositions addObject:composition];
    }
    for (id composition in compositions) {
        id number = Getter(composition, @"replyToStatusIDNumber");
        if ([number isKindOfClass:[NSNumber class]] && [number longLongValue] > 0) return [number longLongValue];
    }
    for (id context in contexts) {
        long long statusID = NumberGetter(Getter(context, @"status"), @"statusID");
        if (statusID > 0) return statusID;
    }
    return 0;
}

// The status a reply composer shows as answered, when its context has it.
static id ReplyTargetStatus(UIViewController* composer) {
    NSMutableArray* contexts = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeReplyContextViewController", contexts);
    for (id context in contexts) {
        id status = Getter(context, @"status");
        if (status) return status;
    }
    return nil;
}

// 7.3.151: the tweet a composer quotes, from its compositions
// (-[T1TweetComposeViewController compositions] / -originalComposition and each
// single-tweet controller's -composition are TFNTwitterComposition;
// -quotedStatusInfo is a TFNTwitterCompositionQuotedStatusInfo with -statusID
// and, for a quoted repost, -retweetingStatusInfo; 12.44 dump).
// 7.3.151: every tweet the composer answers or quotes (ComposerTargetIDs);
// `replyOut`: it answers one.
static NSArray<NSNumber*>* ComposerTargetIDs(UIViewController* composer, BOOL* replyOut) {
    NSMutableArray<NSNumber*>* targets = [NSMutableArray array];
    long long reply = ReplyTargetID(composer);
    if (replyOut) *replyOut = reply > 0;
    if (reply > 0) [targets addObject:@(reply)];
    NSMutableArray* compositions = [NSMutableArray array];
    id listed = Getter(composer, @"compositions");
    if ([listed isKindOfClass:[NSArray class]]) [compositions addObjectsFromArray:listed];
    id original = Getter(composer, @"originalComposition");
    if (original) [compositions addObject:original];
    NSMutableArray* singles = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeSingleTweetViewController", singles);
    for (id single in singles) {
        id composition = Getter(single, @"composition");
        if (composition) [compositions addObject:composition];
    }
    Class infoClass = objc_getClass("TFNTwitterCompositionQuotedStatusInfo");
    for (id composition in compositions) {
        id info = Getter(composition, @"quotedStatusInfo");
        for (int depth = 0; depth < 2 && infoClass && [info isKindOfClass:infoClass]; depth++) {
            long long statusID = NumberGetter(info, @"statusID");
            if (statusID > 0 && ![targets containsObject:@(statusID)]) [targets addObject:@(statusID)];
            info = Getter(info, @"retweetingStatusInfo");
        }
    }
    return targets;
}

// The screen a composer was presented over: down through navigation and tab
// controllers to what is shown.
static UIViewController* ShownLeaf(UIViewController* controller) {
    for (int depth = 0; depth < 12 && controller; depth++) {
        UIViewController* next = nil;
        if ([controller isKindOfClass:[UINavigationController class]]) next = ((UINavigationController*)controller).topViewController;
        else if ([controller isKindOfClass:[UITabBarController class]]) next = ((UITabBarController*)controller).selectedViewController;
        if (!next) break;
        controller = next;
    }
    return controller;
}

static BOOL ComposerOpenedOverBScreen(UIViewController* composer) {
    if (gBScreens.count == 0) return NO;
    UIViewController* presenter = composer.presentingViewController ?: composer.navigationController.presentingViewController;
    for (UIViewController* controller = ShownLeaf(presenter); controller; controller = controller.parentViewController) {
        if (IsBScreen(controller)) return YES;
    }
    return NO;
}

// Whose the tweets a composer answers or quotes are: 1 B's, 0 A's (the row it
// was opened from said so), -1 nothing known. 7.3.151, in order: what the tap
// that opened it asked for (NoteComposeChoice); a composer that came up over a
// screen opened as B; a tweet this merge put on A's lists as B's alone, the
// tweet a B screen was opened for, a tweet of B's notifications or history
// while they are shown. `consume`: the composer is taking the tap's answer.
static int TargetsOwner(UIViewController* composer, NSArray<NSNumber*>* targets, BOOL consume, NSString** how) {
    NSString* why = nil;
    int owner = -1;
    for (NSNumber* target in targets) {
        NSString* choice = gComposeChoices[target];
        if (!choice) continue;
        owner = [choice isEqualToString:@"B"] ? 1 : 0;
        why = [NSString stringWithFormat:@"the tap that opened it asked for %@", choice];
        break;
    }
    if (owner >= 0 && consume) {
        for (NSNumber* target in targets) {
            [gComposeChoices removeObjectForKey:target];
            [gComposeChoiceOrder removeObject:target];
        }
    }
    if (owner < 0 && targets.count && [objc_getAssociatedObject(composer, kFromBScreenKey) boolValue]) {
        owner = 1;
        why = @"it came up over a screen opened as B";
    }
    if (owner < 0) {
        for (NSNumber* target in targets) {
            long long statusID = target.longLongValue;
            if ([gBOnlyIDs containsObject:target] || [gBOnlyActedIDs containsObject:target]) why = @"a row of B's alone in this merge";
            else if (gBScreens.count && [gBScreenStatusIDs containsObject:target]) why = @"the tweet a B screen was opened for";
            else if (NFBUnifiedNotificationIsBStatus(statusID)) why = @"a tweet of B's notifications";
            else if (NFBUnifiedHistoryIsBStatus(statusID)) why = @"a tweet of B's history";
            if (why) {
                owner = 1;
                break;
            }
        }
    }
    if (how) *how = why;
    return owner;
}

static void SendAlert(UIViewController* composer, NSString* message) {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"보내지 않았어요" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleDefault handler:nil]];
    [composer presentViewController:alert animated:YES completion:nil];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeWarning];
}

static void StopSend(UIViewController* composer, NSString* name, NSString* why) {
    UnifiedLog([NSString stringWithFormat:@"send stopped: %@", why]);
    SendAlert(composer, [NSString stringWithFormat:@"이 글은 %@로 보내야 하는데 작성 화면 일부가 다른 계정이에요. "
                                                   @"글은 그대로 있어요. 왼쪽 위 프로필을 눌러 계정을 다시 골라주세요.",
                                                   name]);
}

// Last check before anything leaves a composer.
// 7.3.151: it used to pass every composer that had not been marked within 6
// seconds of the tap. Now what the composer answers or quotes is read here
// too: when that is B's, every piece of the composer must hold B (verified
// now) or nothing is sent, however long the composer took to come up. The
// account the user picked in the composer itself is the one checked instead.
// With the mode off, only a composer already marked is still checked.
static BOOL SendAllowed(UIViewController* composer) {
    if (!gEverActive) return YES;
    NSString* blockedWhy = objc_getAssociatedObject(composer, kSendBlockedKey);
    if (blockedWhy.length) {
        UnifiedLog([@"send stopped: " stringByAppendingString:blockedWhy]);
        SendAlert(composer, [NSString stringWithFormat:@"%@로 쓰려던 글인지 확인하지 못했어요. 글은 그대로 있어요. "
                                                       @"작성 화면을 닫고 게시물에서 다시 눌러주세요.",
                                                       BName()]);
        return NO;
    }
    NSString* intended = objc_getAssociatedObject(composer, kIntendedKey);
    BOOL active = UnifiedActive();
    BOOL userChose = [objc_getAssociatedObject(composer, kUserChoseKey) boolValue];
    if (active && !userChose) {
        NSArray<NSNumber*>* targets = ComposerTargetIDs(composer, NULL);
        NSString* how = nil;
        int owner = targets.count ? TargetsOwner(composer, targets, NO, &how) : -1;
        if (owner == 1) {
            id b = VerifiedB();
            if (!b) {
                Blocked([NSString stringWithFormat:@"send: the target is B's (%@) but B is not verified (%@)", how, gVerifiedBWhy ?: @"?"], nil);
                SendAlert(composer, @"B 계정으로 보내야 하는 글인데 B 계정을 확인하지 못했어요. 글은 그대로 있어요. kemo 설정에서 B 계정을 다시 골라주세요.");
                return NO;
            }
            if (![intended isEqualToString:AccountUserID(b)]) {
                UnifiedLog([NSString stringWithFormat:@"send: the target is B's (%@); the composer must hold B", how]);
                SetIntended(composer, b);
                intended = AccountUserID(b);
            }
        } else if (targets.count == 0 && [objc_getAssociatedObject(composer, kTargetUnknownKey) boolValue]) {
            Blocked(@"send: a reply or quote for B was expected and the composer does not say what it answers", nil);
            SendAlert(composer, [NSString stringWithFormat:@"%@로 쓰려던 글인지 확인하지 못했어요. 글은 그대로 있어요. "
                                                           @"왼쪽 위 프로필에서 계정을 직접 고른 뒤 다시 보내주세요.",
                                                           BName()]);
            return NO;
        }
    }
    if (intended.length == 0) return YES;
    // 7.3.153: the account the composer was marked for has to be one that may
    // send now: A or B of the pair while the mode is on, and only the account
    // in use once it is off (a composer marked for B used to send as B after
    // the mode had ended, and one marked for an earlier B at any time).
    NSString* currentID = AccountUserID(CurrentAccount());
    BOOL mayHold = active ? ([intended isEqualToString:AID()] || [intended isEqualToString:BID()])
                          : (currentID.length > 0 && [intended isEqualToString:currentID]);
    if (!mayHold) {
        Blocked([NSString stringWithFormat:@"send: the composer is marked for %@, which may not send now (mode %@)", intended,
                                           active ? @"on, not this pair" : @"off"],
                nil);
        SendAlert(composer, @"통합 계정 상태가 바뀌어서 보내지 않았어요. 글은 그대로 있어요. 작성 화면을 닫고 게시물에서 다시 눌러주세요.");
        return NO;
    }
    BOOL isB = [intended isEqualToString:BID()];
    id account = (isB && active) ? VerifiedB() : AccountForID(intended);
    if (account && ![AccountUserID(account) isEqualToString:intended]) account = nil;
    NSString* name = isB ? BName() : AName();
    NSString* detail = nil;
    if (account && ComposerIsAll(composer, account, &detail)) {
        UnifiedLog([NSString stringWithFormat:@"send as %@: all pieces match", isB ? @"B" : @"A"]);
        return YES;
    }
    Blocked([NSString stringWithFormat:@"send as %@: %@", isB ? @"B" : @"A", account ? detail : @"account not found"], nil);
    StopSend(composer, name, account ? detail : @"account not found");
    return NO;
}

// A reply to a tweet only B has: switch to B as early as the composer can say
// which tweet it answers. 7.3.142: when it cannot say (once in 7.3.140), it is
// still switched, since the reply was asked for as B a moment ago; the send
// check stops anything that is not all B, and the other avatar switches back.
// 7.3.151: the same for a quote of the tweet (QuoteAsB): the composer is
// recognised by the tweet it quotes. Unlike a reply, one that cannot be
// recognised is not switched on trust: it is blocked from sending.
// 7.3.151: it no longer depends on the composer coming up within 6 seconds of
// the tap (a slow open or an interstitial meant no switch and no check), and a
// composer is never switched to B just because it came up in that window. For
// every composer that appears while the mode is active, what it answers or
// quotes is read (ComposerTargetIDs) and whose that is decided (TargetsOwner):
// B's: the composer is marked for B and switched to it (VerifiedB()); A's by
// the row's own tap: marked for A; nothing known: left as X opened it. Only
// "a composer for B was expected a moment ago and this one cannot say what it
// answers" still looks at the window, and that composer is not switched: it
// is stopped at the send check until its target is known or the user picks
// the account in it. A composer of the mode's off time is never looked at.
static void ComposerCheck(UIViewController* composer, BOOL last) {
    if (!UnifiedActive() || [objc_getAssociatedObject(composer, kDecidedKey) boolValue]) return;
    BOOL isReply = NO;
    NSArray<NSNumber*>* targets = ComposerTargetIDs(composer, &isReply);
    // Not before the composer has its single-tweet controller: the account
    // check looks at it (viewDidAppear asks again).
    NSMutableArray* loaded = [NSMutableArray array];
    CollectControllers(composer, @"T1TweetComposeSingleTweetViewController", loaded);
    if (!last && (loaded.count == 0 || targets.count == 0)) {
        objc_setAssociatedObject(composer, kPendingBKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    objc_setAssociatedObject(composer, kPendingBKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(composer, kDecidedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (targets.count && ComposerOpenedOverBScreen(composer)) {
        objc_setAssociatedObject(composer, kFromBScreenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL expected = CFAbsoluteTimeGetCurrent() <= gComposeAsBUntil;  // a reply / quote for B was asked for a moment ago
    BOOL expectedQuote = expected && gComposeQuote;
    long long wanted = gComposeQuoteID;
    if (expected) {
        gComposeAsBUntil = 0;
        gComposeTargets = nil;
        gComposeQuote = NO;
    }
    NSString* how = nil;
    int owner = targets.count ? TargetsOwner(composer, targets, YES, &how) : -1;
    NSString* targetText = targets.count ? [targets componentsJoinedByString:@","] : @"none";
    if (owner == 1) {
        id b = VerifiedB();
        if (!b) {
            objc_setAssociatedObject(composer, kSendBlockedKey, @"the target is B's but B is not verified", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            Blocked([NSString stringWithFormat:@"composer for %@: B's (%@) but B is not verified (%@)", targetText, how, gVerifiedBWhy ?: @"?"],
                    @"B 계정을 확인하지 못해서 보내기를 막았어요. kemo 설정에서 B 계정을 다시 골라주세요");
            gComposerNote = [NSString stringWithFormat:@"targets %@: B's, B not verified, send blocked", targetText];
            return;
        }
        gComposerNote = [NSString stringWithFormat:@"targets %@ (%@): B's (%@), marked for B", targetText, isReply ? @"reply" : @"quote", how];
        UnifiedLog([@"composer: " stringByAppendingString:gComposerNote]);
        SetIntended(composer, b);
        SwitchComposerTo(composer, b, NO);
        return;
    }
    if (owner == 0) {
        id a = VerifiedA();
        gComposerNote = [NSString stringWithFormat:@"targets %@: A's (%@)%@", targetText, how, a ? @", marked for A" : @", A not verified"];
        UnifiedLog([@"composer: " stringByAppendingString:gComposerNote]);
        if (!a) return;
        SetIntended(composer, a);
        if (!ComposerIsAll(composer, a, NULL)) SwitchComposerTo(composer, a, NO);
        return;
    }
    // Nothing says whose it is.
    if (expectedQuote && !isReply) {
        // Asked for as a quote as B, and this composer is not that quote.
        objc_setAssociatedObject(composer, kSendBlockedKey, @"quote composer not recognised as B's", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Blocked([NSString stringWithFormat:@"quote composer for %lld: not recognised (it has %@)", wanted, targetText],
                [NSString stringWithFormat:@"%@로 인용하는 화면인지 확인하지 못해서 보내기를 막았어요. 닫고 인용을 다시 눌러주세요", BName()]);
        gComposerNote = [NSString stringWithFormat:@"targets %@: a quote as B was expected, not recognised, send blocked", targetText];
        return;
    }
    if (expected && targets.count == 0) {
        // Not switched on trust (it was, in 7.3.142): checked again at the send.
        objc_setAssociatedObject(composer, kTargetUnknownKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gComposerNote = @"a reply / quote for B was expected; this composer does not say what it answers; send is checked";
        UnifiedLog([@"composer: " stringByAppendingString:gComposerNote]);
        return;
    }
    gComposerNote = [NSString stringWithFormat:@"targets %@: nothing known, left as X opened it", targetText];
}

// A tweet only A has, by a protected author: B cannot see it, so a reply or
// quote of it is not switched to B (7.3.151). Only when the composer shows the
// tweet it answers and that tweet's author can be read as protected.
static BOOL ComposerTargetIsAOnlyProtected(UIViewController* composer) {
    id status = ReplyTargetStatus(composer);
    if (!status || !IsProtectedStatus(status)) return NO;
    long long statusID = NumberGetter(status, @"statusID");
    return ProvOf(status) == kProvAOnly || (statusID > 0 && [gAOnlyIDs containsObject:@(statusID)]);
}

// MARK: - The other account under the composer's avatar

static const NSInteger kOtherAvatarTag = 0x4E464F;  // "NFO", the slots' holder

// 7.3.149: A and B in fixed places under each other (A on top, where X's own
// picture is); the account in use is the big one with a Liquid Glass
// highlight behind it, the other small and dim. Tapping the other moves the
// highlight to it and swaps the sizes; nothing changes place. X's own picture
// is hidden while the slots show.
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

static UIView* ComposerAvatar(UIView* singleView) {
    for (UIView* view in singleView.subviews) {
        if ([NSStringFromClass([view class]) isEqualToString:@"TCRComposeAccountAvatarImageView"]) return view;
    }
    return nil;
}

static UIVisualEffect* GlassEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (glassClass) {
        id effect = [[glassClass alloc] init];
        SEL interactive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:interactive]) ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, interactive, YES);
        if ([effect isKindOfClass:[UIVisualEffect class]]) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

// 7.3.155: the slots' holder covers the whole tweet view (the slots are
// placed in its coordinates) and, as a plain view on top, it took every touch
// meant for what is under it: the text, the photos and their edit buttons.
// It now takes a touch only where one of the two slots is.
@interface NFBComposerSlotsHolder : UIView
@end

@implementation NFBComposerSlotsHolder

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    return [hit isKindOfClass:[UIButton class]] ? hit : nil;
}

@end

static void UpdateOtherAvatar(UIView* singleView) {
    UIView* holder = [singleView viewWithTag:kOtherAvatarTag];
    UIView* avatar = ComposerAvatar(singleView);
    id shown = Getter(avatar, @"account");
    id a = CurrentAccount();
    // 7.3.151: B's picture is the account UnifiedActive() refreshed this turn
    // (no timeline is made from a layout); the tap takes VerifiedB() itself.
    BOOL show = UnifiedActive() && avatar && a && gBAccount && (shown == a || shown == gBAccount);
    objc_setAssociatedObject(singleView, kDecoratedKey, show ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!show) {
        holder.hidden = YES;
        if (avatar && avatar.alpha == 0) avatar.alpha = 1;
        return;
    }
    CGRect frame = avatar.frame;
    CGFloat big = CGRectGetWidth(frame), small = 22, pad = 5;
    CGPoint top = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CGPoint bottom = CGPointMake(top.x, top.y + big / 2 + pad * 2 + big / 2);
    if (!holder) {
        holder = [[NFBComposerSlotsHolder alloc] initWithFrame:singleView.bounds];
        holder.tag = kOtherAvatarTag;
        holder.clipsToBounds = NO;
        UIVisualEffectView* glass = [[UIVisualEffectView alloc] initWithEffect:GlassEffect()];
        glass.tag = 1;
        glass.userInteractionEnabled = NO;
        glass.clipsToBounds = YES;
        [holder addSubview:glass];
        for (NSInteger i = 0; i < 2; i++) {
            UIButton* slot = [UIButton buttonWithType:UIButtonTypeCustom];
            slot.tag = 10 + i;
            slot.clipsToBounds = YES;
            slot.imageView.contentMode = UIViewContentModeScaleAspectFill;
            slot.adjustsImageWhenHighlighted = NO;
            [slot addTarget:[NFBComposerSwitchTarget shared] action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
            [holder addSubview:slot];
        }
        [singleView addSubview:holder];
    }
    holder.frame = singleView.bounds;
    holder.hidden = NO;
    avatar.alpha = 0;  // the slots show the accounts instead
    BOOL aActive = shown == a;
    UIVisualEffectView* glass = [holder viewWithTag:1];
    CGFloat ring = big + pad * 2;
    glass.bounds = CGRectMake(0, 0, ring, ring);
    glass.center = aActive ? top : bottom;
    glass.layer.cornerRadius = ring / 2;
    NSArray* accounts = @[ a, gBAccount ];
    NSArray* centers = @[ [NSValue valueWithCGPoint:top], [NSValue valueWithCGPoint:bottom] ];
    for (NSInteger i = 0; i < 2; i++) {
        UIButton* slot = [holder viewWithTag:10 + i];
        BOOL active = (i == 0) == aActive;
        CGFloat size = active ? big : small;
        slot.bounds = CGRectMake(0, 0, size, size);
        slot.center = [centers[i] CGPointValue];
        slot.layer.cornerRadius = size / 2;
        slot.alpha = active ? 1.0 : 0.45;
        BOOL isB = i == 1;
        [slot setImage:AccountAvatar(accounts[i], isB ? @"B" : @"A",
                                     isB ? BColor() : [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1])
              forState:UIControlStateNormal];
        slot.accessibilityLabel = [NSString stringWithFormat:@"%@%@", isB ? BName() : AName(), active ? @", 지금 계정" : @"로 바꾸기"];
    }
    [holder bringSubviewToFront:glass];
    [holder sendSubviewToBack:glass];
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
    UIView* singleView = button.superview.superview;
    UIViewController* composer = ComposerOf(button);
    UIView* avatar = ComposerAvatar(singleView);
    id shown = Getter(avatar, @"account");
    // 7.3.151: the account is verified at the tap (A: the saved A in use; B:
    // VerifiedB()); with none, nothing is switched.
    BOOL toB = button.tag != 10;
    id target = toB ? VerifiedB() : VerifiedA();
    if (!composer) return;
    if (!target) {
        Blocked([NSString stringWithFormat:@"composer switch to %@: account not verified", toB ? @"B" : @"A"],
                @"계정을 확인하지 못해서 바꾸지 않았어요. kemo 설정에서 계정을 다시 골라주세요");
        return;
    }
    if (shown == target) return;
    if (toB && ComposerTargetIsAOnlyProtected(composer)) {
        // A protected author only A follows: B cannot see the tweet.
        gBlocked++;
        UnifiedLog(@"composer switch to B stopped: the tweet it answers is a protected author's that only A has");
        ShowBlockNotice([NSString stringWithFormat:@"%@ 계정은 볼 수 없는 게시물이라 %@로는 쓸 수 없어요", BName(), BName()]);
        return;
    }
    // Chosen here, so this is the account it must go out as.
    objc_setAssociatedObject(composer, kUserChoseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SetIntended(composer, target);
    SwitchComposerTo(composer, target, NO);
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft] impactOccurred];
    // The highlight glides to the chosen one and the sizes swap, in place.
    [UIView animateWithDuration:0.55
                          delay:0
         usingSpringWithDamping:0.68
          initialSpringVelocity:0.6
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         UpdateOtherAvatar(singleView);
                     }
                     completion:nil];
}

@end

%hook T1TweetComposeSingleTweetView

- (void)layoutSubviews {
    %orig;
    if (!gEverActive) return;
    UIView* view = (UIView*)self;
    if (UnifiedActive() || objc_getAssociatedObject(view, kDecoratedKey)) UpdateOtherAvatar(view);
}

%end

%hook T1TweetComposeTableViewController

// X's own account picker: the account picked there is the one meant.
// 7.3.151: for every composer while the mode is active (it was only for one
// already marked), and remembered as the user's own choice.
- (void)singleTweetViewController:(id)single didSwitchToAccount:(id)account {
    %orig;
    if (!gEverActive) return;
    UIViewController* composer = ComposerOf(((UIViewController*)self).viewIfLoaded);
    if (!composer) {
        for (UIViewController* parent = ((UIViewController*)self).parentViewController; parent; parent = parent.parentViewController) {
            if ([NSStringFromClass([parent class]) isEqualToString:@"T1TweetComposeViewController"]) composer = parent;
        }
    }
    if (!composer || !account) return;
    if (!UnifiedActive() && !objc_getAssociatedObject(composer, kIntendedKey)) return;
    // This file's own switch (SwitchComposerTo) comes through here too; only
    // a switch it did not make is the user's.
    if (!gSwitchingComposer) objc_setAssociatedObject(composer, kUserChoseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gSwitchingComposer || objc_getAssociatedObject(composer, kIntendedKey)) SetIntended(composer, account);
}

%end

%hook T1TweetComposeViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!gEverActive) return;
    ComposerCheck((UIViewController*)self, NO);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!gEverActive) return;
    UIViewController* composer = (UIViewController*)self;
    ComposerCheck(composer, NO);
    if (![objc_getAssociatedObject(composer, kPendingBKey) boolValue]) return;
    // Still no target: give the composer a moment, then decide.
    __weak UIViewController* weakComposer = composer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakComposer) ComposerCheck(weakComposer, YES);
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

// 7.3.151: a scheduled post leaves the composer here (v24@0:8@16, 12.44 dump);
// it was not checked.
- (void)_t1_scheduleCompositions:(id)compositions {
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

// 7.3.149: 7.3.144 compared the account object and only the item's own ID; X
// can pass another instance of A's account, or the original's ID, so the
// screen still opened as A. Accounts are compared by user ID now, and the
// ID by both the item's and the original's.
// 7.3.151: it was "any tweet whose ID a merge ever called B's", so A's own
// copy of such a tweet opened as B from search or a profile too. Now: the
// tapped row's own object decides when X hands its view model over and that
// object is one a merge marked. Without that, the ID counts only when the
// tweet is opened from the unified home list itself (it is the list being
// looked at) and the ID is one of the rows this merge put there as B's; or
// when B's notifications / history, while shown, say it is theirs. The
// account is VerifiedB() taken here.
static BOOL UnifiedHomeOnScreen(void) {
    for (id controller in [gFollowingControllers allObjects]) {
        if (ControllerVisible(controller)) return YES;
    }
    return NO;
}

// Set by the hooks that can simply not open the screen (the "show" calls).
static BOOL gOpenCanRefuse;
static BOOL gOpenRefused;

static id AccountForOpening(id account, long long statusID, id viewModel, NSString* where) {
    if (!gEverActive || !UnifiedActive()) return account;
    NSString* accountID = AccountUserID(account);
    if (accountID && ![accountID isEqualToString:AccountUserID(CurrentAccount())]) return account;
    long long modelID = ViewModelStatusID(viewModel);
    long long acted = NumberGetter(ActedStatus(viewModel), @"statusID");
    NSInteger cls = viewModel ? ProvOf(viewModel) : kProvNone;
    BOOL asB = NO;
    NSString* how = @"nothing says B";
    if (cls != kProvNone) {
        asB = cls == kProvBOnly;
        how = [NSString stringWithFormat:@"the tapped row's own object, class %ld", (long)cls];
    } else {
        BOOL home = UnifiedHomeOnScreen();
        for (NSNumber* candidate in @[ @(statusID), @(modelID), @(acted) ]) {
            long long candidateID = candidate.longLongValue;
            if (candidateID <= 0 || asB) continue;
            if (home && ([gBOnlyIDs containsObject:candidate] || [gBOnlyActedIDs containsObject:candidate])) {
                asB = YES;
                how = @"ID of a row of B's in this merge, opened from the unified home list";
            } else if (NFBUnifiedNotificationIsBStatus(candidateID)) {
                asB = YES;
                how = @"a tweet of B's notifications";
            } else if (NFBUnifiedHistoryIsBStatus(candidateID)) {
                asB = YES;
                how = @"a tweet of B's history";
            }
        }
    }
    UnifiedLog([NSString stringWithFormat:@"tweet screen via %@: id %lld model %lld original %lld -> %@ (%@)", where, statusID, modelID, acted,
                                          asB ? @"B" : @"as is", how]);
    if (!asB) return account;
    id b = VerifiedB();
    if (!b && gOpenCanRefuse) {
        // 7.3.153: from a "show" call the screen is not opened at all.
        gOpenRefused = YES;
        Blocked([NSString stringWithFormat:@"tweet screen for %lld should open as B but B is not verified (%@); not opened", statusID,
                                           gVerifiedBWhy ?: @"?"],
                @"B 계정을 확인하지 못해서 열지 않았어요. kemo 설정에서 B 계정을 다시 골라주세요");
        return account;
    }
    if (!b) {
        // An init cannot be refused; it opens as X asked and says so.
        Blocked([NSString stringWithFormat:@"tweet screen for %lld should open as B but B is not verified (%@)", statusID, gVerifiedBWhy ?: @"?"],
                [NSString stringWithFormat:@"B 계정을 확인하지 못해서 %@로 열었어요. 여기서 하는 반응은 %@로 가요", AName(), AName()]);
        return account;
    }
    return b;
}

// A tweet screen that holds B's account (this file gave it, or
// UnifiedNotifications.x / UnifiedHistory.x did, or X itself opened it from
// inside one): remembered as a B screen, with the B it was opened as.
static void NoteBScreen(id made, long long statusID, id viewModel) {
    if (!gEverActive || ![made isKindOfClass:[UIViewController class]] || !UnifiedActive()) return;
    UIViewController* controller = made;
    if (IsBScreen(controller)) return;
    // Its account is an ivar that may have no getter; compare by user ID.
    id account = Getter(controller, @"account") ?: objectIvar(controller, "account") ?: objectIvar(controller, "_account");
    NSString* accountID = AccountUserID(account);
    NSString* bID = BID();
    if (!accountID || bID.length == 0 || ![accountID isEqualToString:bID] || [accountID isEqualToString:AccountUserID(CurrentAccount())]) return;
    if (!gBScreens) gBScreens = [NSHashTable weakObjectsHashTable];
    if (!gBScreenStatusIDs) gBScreenStatusIDs = [NSMutableSet set];
    [gBScreens addObject:controller];
    objc_setAssociatedObject(controller, kBScreenOwnerKey, accountID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gBScreenStatusIDs.count > 200) [gBScreenStatusIDs removeAllObjects];
    for (NSNumber* target in @[ @(statusID), @(ViewModelStatusID(viewModel)), @(NumberGetter(ActedStatus(viewModel), @"statusID")) ]) {
        if (target.longLongValue > 0) [gBScreenStatusIDs addObject:target];
    }
    UnifiedLog([NSString stringWithFormat:@"tweet screen for %lld is B's; remembered", statusID > 0 ? statusID : ViewModelStatusID(viewModel)]);
}

// 7.3.151: the reply bar at the bottom of a tweet screen sends by itself
// (-[T1PersistentComposeViewController _t1_sendReply], -_t1_didTapReply:,
// -handleSendTweetKeyCommand; its -account and -didSwitchAccounts; 12.44
// dump), not through T1TweetComposeViewController, so it was not checked. On a
// screen opened as B it must hold that B (verified now), unless the user
// picked another account in the bar itself. On any other screen it is X's.
static BOOL PersistentSendAllowed(id made) {
    if (!gEverActive || ![made isKindOfClass:[UIViewController class]]) return YES;
    UIViewController* bar = made;
    UIViewController* screen = BScreenOf(bar.viewIfLoaded);
    for (UIViewController* parent = bar; parent && !screen; parent = parent.parentViewController) {
        if (IsBScreen(parent)) screen = parent;
    }
    if (!screen) return YES;
    if (BoolGetter(bar, @"didSwitchAccounts")) return YES;
    NSString* owner = objc_getAssociatedObject(screen, kBScreenOwnerKey);
    NSString* holds = AccountUserID(Getter(bar, @"account"));
    id b = VerifiedB();
    if (b && owner && holds && [holds isEqualToString:owner] && [owner isEqualToString:AccountUserID(b)]) return YES;
    Blocked([NSString stringWithFormat:@"reply bar on a B screen: holds %@, the screen is %@'s, verified B %@", holds ?: @"?", owner ?: @"?",
                                       b ? @"yes" : (gVerifiedBWhy ?: @"no")],
            [NSString stringWithFormat:@"%@로 보낼 수 있는지 확인하지 못해서 답글을 막았어요. 답글 버튼으로 작성 화면을 열어서 써주세요", BName()]);
    return NO;
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
    id made = %orig(AccountForOpening(account, statusID, nil, @"container id"), statusID, navigationContext, scribeContext, sourceMetadata,
                    overrideMetadata, referrer, quickPromote, excluded);
    NoteBScreen(made, statusID, nil);
    return made;
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
    id made = %orig(AccountForOpening(account, ViewModelStatusID(viewModel), viewModel, @"container model"), viewModel, navigationContext,
                    scribeContext, sourceMetadata, overrideMetadata, referrer, notifyEdit, quickPromote, excluded);
    NoteBScreen(made, 0, viewModel);
    return made;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!gEverActive) return;
    NoteBScreen(self, 0, nil);
    ShowBOnScreen((UIViewController*)self);
}

%end

%hook T1PersistentComposeViewController

- (void)_t1_sendReply {
    if (!PersistentSendAllowed(self)) return;
    %orig;
}

- (void)_t1_didTapReply:(id)sender {
    if (!PersistentSendAllowed(self)) return;
    %orig;
}

- (void)handleSendTweetKeyCommand {
    if (!PersistentSendAllowed(self)) return;
    %orig;
}

%end

// The app's navigation builds the tweet screen with an account too.
%hook T1TabbedAppNavigation

- (id)conversationViewControllerForViewModel:(id)viewModel
                                    statusID:(long long)statusID
                                     account:(id)account
                     statusNavigationContext:(id)navigationContext
                               scribeContext:(id)scribeContext
                    sourceNavigationMetadata:(id)sourceMetadata
                  overrideNavigationMetadata:(id)overrideMetadata
               shouldNotifyDisplayLatestEdit:(BOOL)notifyEdit
               shouldStartQuickPromoteOnOpen:(BOOL)quickPromote
                           excludedStatusIDs:(id)excluded
                                     content:(id)content {
    return %orig(viewModel, statusID, AccountForOpening(account, statusID, viewModel, @"navigation"), navigationContext,
                 scribeContext, sourceMetadata, overrideMetadata, notifyEdit, quickPromote, excluded, content);
}

- (void)showConversationViewControllerForViewModel:(id)viewModel
                                          statusID:(long long)statusID
                                           account:(id)account
                           statusNavigationContext:(id)navigationContext
                                     scribeContext:(id)scribeContext
                          sourceNavigationMetadata:(id)sourceMetadata
                                fromViewController:(id)fromController
                                          animated:(BOOL)animated {
    gOpenCanRefuse = YES;
    gOpenRefused = NO;
    id opening = AccountForOpening(account, statusID, viewModel, @"navigation show");
    gOpenCanRefuse = NO;
    if (gOpenRefused) return;
    %orig(viewModel, statusID, opening, navigationContext, scribeContext, sourceMetadata, fromController, animated);
}

%end

%hook _TtC14T1TwitterSwift20XTabbedAppNavigation

- (id)conversationViewControllerForViewModel:(id)viewModel
                                    statusID:(long long)statusID
                                     account:(id)account
                     statusNavigationContext:(id)navigationContext
                               scribeContext:(id)scribeContext
                    sourceNavigationMetadata:(id)sourceMetadata
                  overrideNavigationMetadata:(id)overrideMetadata
               shouldNotifyDisplayLatestEdit:(BOOL)notifyEdit
               shouldStartQuickPromoteOnOpen:(BOOL)quickPromote
                           excludedStatusIDs:(id)excluded
                                     content:(id)content {
    return %orig(viewModel, statusID, AccountForOpening(account, statusID, viewModel, @"x navigation"), navigationContext,
                 scribeContext, sourceMetadata, overrideMetadata, notifyEdit, quickPromote, excluded, content);
}

- (void)showConversationViewControllerForViewModel:(id)viewModel
                                          statusID:(long long)statusID
                                           account:(id)account
                           statusNavigationContext:(id)navigationContext
                                     scribeContext:(id)scribeContext
                          sourceNavigationMetadata:(id)sourceMetadata
                                fromViewController:(id)fromController
                                          animated:(BOOL)animated {
    gOpenCanRefuse = YES;
    gOpenRefused = NO;
    id opening = AccountForOpening(account, statusID, viewModel, @"x navigation show");
    gOpenCanRefuse = NO;
    if (gOpenRefused) return;
    %orig(viewModel, statusID, opening, navigationContext, scribeContext, sourceMetadata, fromController, animated);
}

%end

static BOOL gDefaultsLookQueued;

%ctor {
    gStartedAt = CFAbsoluteTimeGetCurrent();
    // 7.3.151: reactions inside B's notifications and B's history are B's here
    // (IsInBScreen asks both files): taps go through HandleInlineAction, which
    // sends with VerifiedB() or stops, and never through X's own tap path;
    // swipes and double taps there are stopped (StopIfLoadedAsB). Until this
    // was so, those files stopped every reaction themselves.
    NFBUnifiedNotificationsReactionsWired();
    NFBUnifiedHistoryReactionsWired();
    // The feature, the dock's choice or the saved pair changed: the kept
    // answer is dropped and the mode looked at again, which is where going
    // inactive is seen (UnifiedActive -> UnifiedBecameInactive). queue:nil,
    // then main (a main-queue observer stalls the launch, see CLAUDE.md); one
    // look per burst of changes, and nothing is written from it.
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification* note) {
                                                      @synchronized(UnifiedLock()) {
                                                          if (gDefaultsLookQueued) return;
                                                          gDefaultsLookQueued = YES;
                                                      }
                                                      dispatch_async(dispatch_get_main_queue(), ^{
                                                          @synchronized(UnifiedLock()) {
                                                              gDefaultsLookQueued = NO;
                                                          }
                                                          gActiveCacheValid = NO;
                                                          // Going off is looked for at once; coming on is seen by the
                                                          // next hook that asks (nothing runs here for a mode never used).
                                                          if (gWasActive) (void)UnifiedActive();
                                                      });
                                                  }];
    // The first B load happens once the Following tab has been set up.
    // 7.3.151: B's Following only; B's For You is loaded when A's For You is
    // the tab being looked at and is refreshed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (UnifiedActive()) RefreshB(101, @"launch");
    });
}
