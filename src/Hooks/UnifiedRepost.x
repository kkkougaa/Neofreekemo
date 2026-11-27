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

static NSMutableDictionary<NSNumber*, NSNumber*>* gBRepostIDs;  // original ID -> B's repost ID
static NSMutableArray<NSString*>* gRepostLog;

static void URLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized([NSObject class]) {
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

BOOL NFBUnifiedUndoRepostAsB(id bAccount, id status, NSString** why) {
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
    // Only B's own account, and never the one in use.
    if (!bAccount || bID.length == 0 || ![URAccountID(bAccount) isEqualToString:bID] || bAccount == URCurrentAccount()) {
        URLog(@"undo stopped: not B's account");
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
    @synchronized([NSObject class]) {
        repostID = gBRepostIDs[@(originalID)].longLongValue;
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
    @synchronized([NSObject class]) {
        [gBRepostIDs removeObjectForKey:@(originalID)];
    }
    URLog([NSString stringWithFormat:@"undo sent as B: repost %lld of %lld (%@)", repostID, originalID, source]);
    return YES;
}

NSString* NFBUnifiedRepostDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    @synchronized([NSObject class]) {
        [out appendFormat:@"B reposts remembered: %lu\n", (unsigned long)gBRepostIDs.count];
        [out appendFormat:@"%@\n", gRepostLog.count ? [gRepostLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

%hook TFNTwitterAccount

// X updates the account's state here once a repost is made; for B's account,
// remember B's repost ID of the original.
- (void)_updateStatesForRetweetStatus:(id)retweetStatus originalStatus:(id)originalStatus {
    %orig;
    NSString* bID = [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
    if (bID.length == 0 || ![URAccountID(self) isEqualToString:bID]) return;
    long long repostID = URNumber(retweetStatus, @"statusID");
    long long originalID = URNumber(UROriginal(originalStatus), @"statusID");
    if (repostID <= 0 || originalID <= 0 || repostID == originalID) return;
    @synchronized([NSObject class]) {
        if (!gBRepostIDs) gBRepostIDs = [NSMutableDictionary dictionary];
        gBRepostIDs[@(originalID)] = @(repostID);
    }
    URLog([NSString stringWithFormat:@"B reposted %lld as %lld", originalID, repostID]);
}

%end
