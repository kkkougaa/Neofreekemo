//
//  UnifiedRepost.x
//  NeoFreeBird
//
//  A/B unified timeline: undoing a repost made as B, with B's own account.
//
//  -[TFNTwitterAccount unretweetID:statusID:responseBlock:] (q, q, block) takes
//  the repost's own ID first and the original's second: its neighbour
//  -_notifyUnretweetForOriginalStatusID:retweetID: names the pair, and
//  TFNTwitterStatus keeps -retweetID (the account's own repost of it) apart
//  from -retweetedStatusID.
//
//  Where B's repost ID comes from, in this order:
//  1. B's own -[TFNTwitterAccount _updateStatesForRetweetStatus:originalStatus:]
//     (two TFNTwitterStatus objects), which X runs when a repost is made, so a
//     repost made as B in this session is remembered here.
//  2. The status itself, when it says it is reposted (-seenAsRetweeted) and
//     carries -retweetID. That is the view of the account it was loaded for,
//     so the caller passes the status from B's own stream.
//  Without one, nothing is sent.
//

#import "HookHelpers.h"

extern BOOL NFBUnifiedIsActive(void);

// 7.3.151: everything here acts only while the unified mode is in use. B's
// reposts are remembered only when made from the unified mode (or while it is
// in use), for the B they were made with, and only the newest kMaxRemembered.
static const NSUInteger kMaxRemembered = 500;
static const NSUInteger kMaxPending = 50;

static NSMutableDictionary<NSNumber*, NSNumber*>* gBRepostIDs;  // original ID -> B's repost ID
static NSMutableArray<NSNumber*>* gBRepostOrder;                // original IDs, oldest first
static NSString* gBRepostOwner;                                 // the B (user ID) the IDs above belong to
static NSMutableArray<NSNumber*>* gBPending;                    // originals a repost was sent for as B from the unified mode
static NSString* gBPendingOwner;
static NSUInteger gRepostsNotRecorded;                          // B's reposts seen outside the unified mode (left alone)
static BOOL gRepostActive;
static CFAbsoluteTime gRepostActiveAt;
static NSMutableArray<NSString*>* gRepostLog;

// 7.3.151: a lock of this file's own (was [NSObject class], shared process-wide).
static id URLock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    return lock;
}

static void URLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized(URLock()) {
        if (!gRepostLog) gRepostLog = [NSMutableArray array];
        [gRepostLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        while (gRepostLog.count > 20) [gRepostLog removeObjectAtIndex:0];
    }
}

static id URGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static long long URNumber(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    const char* type = [object methodSignatureForSelector:selector].methodReturnType;
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

static BOOL URBool(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return NO;
    }
}

static NSString* URAccountID(id account) {
    long long userID = URNumber(account, @"userID");
    if (userID <= 0) userID = URNumber(URGetter(account, @"user"), @"userID");
    return userID > 0 ? [NSString stringWithFormat:@"%lld", userID] : nil;
}

static id URCurrentAccount(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) return nil;
    id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
    return URGetter(host, @"currentAccount");
}

// The original a like or repost is about (a repost item shows the original).
static id UROriginal(id status) {
    id original = URGetter(status, @"retweetedStatus") ?: URGetter(status, @"representedStatus");
    return original ?: status;
}

// Whether the unified mode is in use. It looks at the account in use, so it is
// read on the main thread and remembered (1s) for callers on other threads.
static BOOL URModeActive(void) {
    if ([NSThread isMainThread]) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        BOOL stale;
        @synchronized(URLock()) {
            stale = now - gRepostActiveAt > 1.0;
        }
        if (stale) {
            BOOL active = NO;
            @try {
                active = NFBUnifiedIsActive();
            } @catch (__unused NSException* exception) {
            }
            @synchronized(URLock()) {
                gRepostActive = active;
                gRepostActiveAt = now;
            }
        }
    }
    @synchronized(URLock()) {
        return gRepostActive;
    }
}

BOOL NFBUnifiedUndoRepostAsB(id bAccount, id status, NSString** why) {
    // 7.3.151: only from the unified mode. This is a button's action, so it
    // runs on the main thread, where the mode can be read directly.
    BOOL active = NO;
    if ([NSThread isMainThread]) {
        @try {
            active = NFBUnifiedIsActive();
        } @catch (__unused NSException* exception) {
        }
    }
    if (!active) {
        URLog(@"undo stopped: mode inactive");
        if (why) *why = @"A/B 통합 모드가 아니어서 재게시 취소를 막았어요";
        return NO;
    }
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
    NSString* sendingID = URAccountID(bAccount);
    id current = URCurrentAccount();
    NSString* currentID = URAccountID(current);
    // Only B's own account as saved right now, and never the one in use (by
    // object and by user ID; an unknown account in use also stops it). Nothing
    // below waits, so this holds at the moment of sending.
    if (!bAccount || bID.length == 0 || sendingID.length == 0 || ![sendingID isEqualToString:bID] || !current ||
        currentID.length == 0 || bAccount == current || [currentID isEqualToString:sendingID]) {
        URLog([NSString stringWithFormat:@"undo stopped: not B's account (account=%d savedB=%d same=%d inUseKnown=%d inUse=%d)",
                                         bAccount != nil, bID.length > 0,
                                         sendingID.length > 0 && bID.length > 0 && [sendingID isEqualToString:bID],
                                         currentID.length > 0,
                                         bAccount == current || (currentID.length > 0 && [currentID isEqualToString:sendingID])]);
        if (why) *why = @"B 계정을 확인하지 못해서 재게시 취소를 막았어요";
        return NO;
    }
    SEL undo = NSSelectorFromString(@"unretweetID:statusID:responseBlock:");
    if (![bAccount respondsToSelector:undo]) {
        URLog(@"undo stopped: no unretweetID:statusID:responseBlock:");
        if (why) *why = @"이 X 버전에서는 B로 재게시 취소를 보낼 수 없어요";
        return NO;
    }
    id original = UROriginal(status);
    long long originalID = URNumber(original, @"statusID");
    if (originalID <= 0) {
        if (why) *why = @"게시물을 확인하지 못했어요";
        return NO;
    }
    long long repostID = 0;
    NSString* source = nil;
    @synchronized(URLock()) {
        // Only IDs remembered for this B (a changed B never reuses another's).
        if ([gBRepostOwner isEqualToString:bID]) repostID = gBRepostIDs[@(originalID)].longLongValue;
    }
    if (repostID > 0) {
        source = @"made as B this session";
    } else if (URBool(original, @"seenAsRetweeted") && URNumber(original, @"retweetID") > 0) {
        repostID = URNumber(original, @"retweetID");
        source = @"status (B's stream)";
    }
    if (repostID <= 0 || repostID == originalID) {
        URLog([NSString stringWithFormat:@"undo stopped: no repost ID for %lld", originalID]);
        if (why) *why = @"B의 재게시 ID를 찾지 못했어요. B로 전환해서 취소해주세요";
        return NO;
    }
    void (^response)(void) = ^{
    };
    @try {
        ((void (*)(id, SEL, long long, long long, id))objc_msgSend)(bAccount, undo, repostID, originalID, response);
    } @catch (NSException* exception) {
        URLog([NSString stringWithFormat:@"undo threw %@", exception.name]);
        if (why) *why = @"B로 재게시 취소를 보내지 못했어요";
        return NO;
    }
    @synchronized(URLock()) {
        [gBRepostIDs removeObjectForKey:@(originalID)];
        [gBRepostOrder removeObject:@(originalID)];
    }
    URLog([NSString stringWithFormat:@"undo sent as B: repost %lld of %lld (%@)", repostID, originalID, source]);
    return YES;
}

NSString* NFBUnifiedRepostDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    BOOL active = URModeActive();
    @synchronized(URLock()) {
        [out appendFormat:@"B reposts remembered: %lu (max %lu, for B %@) pending=%lu notRecorded(mode inactive)=%lu modeActive=%d\n",
                          (unsigned long)gBRepostIDs.count, (unsigned long)kMaxRemembered,
                          gBRepostOwner.length ? @"set" : @"-", (unsigned long)gBPending.count,
                          (unsigned long)gRepostsNotRecorded, active];
        [out appendFormat:@"%@\n", gRepostLog.count ? [gRepostLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

%hook TFNTwitterAccount

// 7.3.151: a repost sent with B's account while the unified mode is in use (the
// unified timeline's own repost-as-B goes through here). The original's ID is
// noted so that the answer, which comes later and maybe on another thread or
// after the mode was left, is still known to be the unified mode's. Nothing is
// changed about the request itself.
- (void)retweetWithStatusID:(long long)statusID responseBlock:(id)responseBlock {
    @try {
        NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
        if (statusID > 0 && bID.length && [NSThread isMainThread] && [URAccountID(self) isEqualToString:bID] &&
            URModeActive()) {
            @synchronized(URLock()) {
                if (!gBPending || ![gBPendingOwner isEqualToString:bID]) {
                    gBPending = [NSMutableArray array];
                    gBPendingOwner = [bID copy];
                }
                [gBPending removeObject:@(statusID)];
                [gBPending addObject:@(statusID)];
                while (gBPending.count > kMaxPending) [gBPending removeObjectAtIndex:0];
            }
        }
    } @catch (__unused NSException* exception) {
    }
    %orig;
}

// X updates the account's state here once a repost is made; for B's account,
// remember B's repost ID of the original.
// 7.3.151: only for a repost the unified mode sent as B (noted above), or one
// made while the mode is in use. A repost made while simply on B alone (or on
// any other account) is not recorded.
- (void)_updateStatesForRetweetStatus:(id)retweetStatus originalStatus:(id)originalStatus {
    %orig;
    @try {
        NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
        if (bID.length == 0 || ![URAccountID(self) isEqualToString:bID]) return;
        long long repostID = URNumber(retweetStatus, @"statusID");
        long long givenID = URNumber(originalStatus, @"statusID");
        long long originalID = URNumber(UROriginal(originalStatus), @"statusID");
        if (repostID <= 0 || originalID <= 0 || repostID == originalID) return;
        BOOL active = URModeActive();
        BOOL pending = NO;
        @synchronized(URLock()) {
            if ([gBPendingOwner isEqualToString:bID]) {
                pending = [gBPending containsObject:@(originalID)] || (givenID > 0 && [gBPending containsObject:@(givenID)]);
                [gBPending removeObject:@(originalID)];
                if (givenID > 0) [gBPending removeObject:@(givenID)];
            }
            if (!pending && !active) {
                gRepostsNotRecorded++;
            } else {
                if (!gBRepostIDs || ![gBRepostOwner isEqualToString:bID]) {
                    // Another B than the one the IDs were kept for: start over.
                    gBRepostIDs = [NSMutableDictionary dictionary];
                    gBRepostOrder = [NSMutableArray array];
                    gBRepostOwner = [bID copy];
                }
                [gBRepostOrder removeObject:@(originalID)];
                [gBRepostOrder addObject:@(originalID)];
                gBRepostIDs[@(originalID)] = @(repostID);
                while (gBRepostOrder.count > kMaxRemembered) {
                    [gBRepostIDs removeObjectForKey:gBRepostOrder.firstObject];
                    [gBRepostOrder removeObjectAtIndex:0];
                }
            }
        }
        // Outside the mode only the count above is kept (no IDs, no log line).
        if (!pending && !active) return;
        URLog([NSString stringWithFormat:@"B reposted %lld as %lld (%@)", originalID, repostID,
                                         pending ? @"sent from the unified mode" : @"mode active"]);
    } @catch (__unused NSException* exception) {
    }
}

%end
