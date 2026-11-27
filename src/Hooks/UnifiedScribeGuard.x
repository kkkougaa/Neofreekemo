//
//  UnifiedScribeGuard.x
//  NeoFreeBird
//
//  A/B unified mode: a tweet only B has is shown in A's lists, so X would
//  record it as something A saw or touched and send that to X as A. This file
//  keeps those records from being written:
//
//  - item impressions (-[TFNTwitterScribeImpressionLogger logItemImpression:…],
//    logItemLingerImpression:… and the private _logItemImpression:… they share;
//    selectors as in X 12.44, where the private one gained cachesImpression:),
//  - the "seen" record a row leaves after staying on screen
//    (-[T1LingerScriber _t1_recordLingerInImpressionCache]),
//  - action events that name such a tweet (-[TFNTwitterScribe logAction:…
//    parameters:] and logEvent:parameters:).
//
//  The rule is the unified mode's: only when the record is provably B's (B's
//  own impression logger, B's own scribe) does it go through; anything else
//  about a B-only tweet is dropped, never sent as A. Nothing is added to what X
//  sends and no request is made here. The IDs come from UnifiedTimeline.x's
//  merges. It acts only while the unified mode is in use: with A alone or B
//  alone on screen every record goes through as X writes it.
//

#import "HookHelpers.h"

static NSSet<NSNumber*>* gGuardIDs;  // immutable; swapped under GuardLock()
static NSString* gGuardBID;
static id gGuardBLogger;
static NSUInteger gDroppedImpressions;
static NSUInteger gDroppedLingers;
static NSUInteger gDroppedActions;
static NSUInteger gPassedAsB;
static NSString* gLastDrop = @"-";

static NSObject* GuardLock(void) {
    static NSObject* lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    return lock;
}

static long long UGNumber(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    @try {
        NSMethodSignature* signature = [object methodSignatureForSelector:selector];
        if (signature.numberOfArguments != 2) return 0;
        char type = signature.methodReturnType[0];
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

static id UGObject(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        NSMethodSignature* signature = [object methodSignatureForSelector:selector];
        if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

// From UnifiedTimeline.x, on the main thread, after each merge: the tweets
// only B has (their own IDs and their originals'), and B's account.
void NFBUnifiedGuardNote(NSSet<NSNumber*>* ids, id bAccount) {
    if (ids.count == 0) return;
    long long userID = UGNumber(bAccount, @"userID");
    if (userID <= 0) userID = UGNumber(UGObject(bAccount, @"user"), @"userID");
    NSString* bID = userID > 0 ? [NSString stringWithFormat:@"%lld", userID] : nil;
    id logger = UGObject(bAccount, @"impressionLogger");
    @synchronized(GuardLock()) {
        if (gGuardIDs && [ids isSubsetOfSet:gGuardIDs]) {
            gGuardBID = bID;
            gGuardBLogger = logger;
            return;
        }
        NSMutableSet* all = gGuardIDs ? [gGuardIDs mutableCopy] : [NSMutableSet set];
        [all unionSet:ids];
        gGuardIDs = [all copy];
        gGuardBID = bID;
        gGuardBLogger = logger;
    }
}

// 7.3.153, from UnifiedTimeline.x when the mode stops or the pair changes:
// nothing noted for the old pair is kept (the IDs only ever grew before).
void NFBUnifiedGuardReset(void) {
    @synchronized(GuardLock()) {
        gGuardIDs = nil;
        gGuardBID = nil;
        gGuardBLogger = nil;
    }
}

extern BOOL NFBUnifiedIsActive(void);

// Only while the unified mode is in use: on A alone or B alone nothing here
// acts, whatever was shown earlier. The mode is read on the main thread (it
// looks at the account in use) and remembered for callers on other threads.
static BOOL gGuardActive;
static CFAbsoluteTime gGuardActiveAt;

static BOOL GuardActive(void) {
    if ([NSThread isMainThread]) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        BOOL stale;
        @synchronized(GuardLock()) {
            stale = now - gGuardActiveAt > 1.0;
        }
        if (stale) {
            BOOL active = NO;
            @try {
                active = NFBUnifiedIsActive();
            } @catch (__unused NSException* exception) {
            }
            @synchronized(GuardLock()) {
                gGuardActive = active;
                gGuardActiveAt = now;
            }
        }
    }
    @synchronized(GuardLock()) {
        return gGuardActive;
    }
}

static NSSet<NSNumber*>* GuardIDs(void) {
    if (!GuardActive()) return nil;
    @synchronized(GuardLock()) {
        return gGuardIDs;
    }
}

static BOOL GuardedNumber(long long value, NSSet<NSNumber*>* ids) {
    return value > 1000000000LL && [ids containsObject:@(value)];
}

// A value (dictionary, array, number, digit string) that names one of the IDs.
static BOOL HoldsGuarded(id value, int depth, NSSet<NSNumber*>* ids) {
    if (!value || depth > 4) return NO;
    if ([value isKindOfClass:[NSNumber class]]) return GuardedNumber([value longLongValue], ids);
    if ([value isKindOfClass:[NSString class]]) {
        NSString* text = value;
        if (text.length < 10 || text.length > 19) return NO;
        for (NSUInteger i = 0; i < text.length; i++) {
            unichar c = [text characterAtIndex:i];
            if (c < '0' || c > '9') return NO;
        }
        return GuardedNumber(text.longLongValue, ids);
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSUInteger seen = 0;
        for (id key in (NSDictionary*)value) {
            if (seen++ > 64) break;
            if (HoldsGuarded(((NSDictionary*)value)[key], depth + 1, ids)) return YES;
        }
        return NO;
    }
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
        NSUInteger seen = 0;
        for (id element in value) {
            if (seen++ > 64) break;
            if (HoldsGuarded(element, depth + 1, ids)) return YES;
        }
    }
    return NO;
}

// What X records an impression of: a status, a status view model, a module.
static BOOL ItemIsGuarded(id item, NSSet<NSNumber*>* ids) {
    if (!item) return NO;
    if (HoldsGuarded(item, 0, ids)) return YES;
    if (GuardedNumber(UGNumber(item, @"statusID"), ids)) return YES;
    for (NSString* name in @[ @"status", @"representedStatus" ]) {
        id status = UGObject(item, name);
        if (GuardedNumber(UGNumber(status, @"statusID"), ids)) return YES;
        if (GuardedNumber(UGNumber(UGObject(status, @"representedStatus"), @"statusID"), ids)) return YES;
    }
    return HoldsGuarded(UGObject(item, @"scribeItem"), 0, ids);
}

static void NoteDrop(NSUInteger* counter, NSString* what) {
    @synchronized(GuardLock()) {
        (*counter)++;
        gLastDrop = what;
    }
}

// YES: do not record it. `logger` is the impression logger about to record.
static BOOL DropImpression(id logger, id item, id parameters, NSString* what) {
    NSSet<NSNumber*>* ids = GuardIDs();
    if (ids.count == 0) return NO;
    @try {
        if (!ItemIsGuarded(item, ids) && !HoldsGuarded(parameters, 0, ids)) return NO;
    } @catch (__unused NSException* exception) {
        return NO;
    }
    @synchronized(GuardLock()) {
        if (logger && logger == gGuardBLogger) {
            gPassedAsB++;
            return NO;
        }
    }
    NoteDrop(&gDroppedImpressions, what);
    return YES;
}

static BOOL DropAction(id scribe, id first, id parameters, id label) {
    NSSet<NSNumber*>* ids = GuardIDs();
    if (ids.count == 0) return NO;
    @try {
        if (!HoldsGuarded(parameters, 0, ids) && !HoldsGuarded(first, 0, ids)) return NO;
        NSString* accountID = UGObject(scribe, @"accountID");
        @synchronized(GuardLock()) {
            if ([accountID isKindOfClass:[NSString class]] && gGuardBID && [accountID isEqualToString:gGuardBID]) {
                gPassedAsB++;
                return NO;
            }
        }
    } @catch (__unused NSException* exception) {
        return NO;
    }
    NoteDrop(&gDroppedActions, [NSString stringWithFormat:@"action %@", label]);
    return YES;
}

NSString* NFBUnifiedGuardDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    @synchronized(GuardLock()) {
        [out appendFormat:@"active=%d guarded ids=%lu B=%@ B logger=%@\n", gGuardActive, (unsigned long)gGuardIDs.count, gGuardBID ?: @"-",
                          gGuardBLogger ? @"found" : @"missing"];
        [out appendFormat:@"dropped: impressions=%lu seen records=%lu actions=%lu | passed as B=%lu | last drop: %@\n",
                          (unsigned long)gDroppedImpressions, (unsigned long)gDroppedLingers, (unsigned long)gDroppedActions,
                          (unsigned long)gPassedAsB, gLastDrop];
    }
    // Which of the hooked methods this X version has.
    NSArray<NSArray<NSString*>*>* hooks = @[
        @[ @"TFNTwitterScribeImpressionLogger", @"logItemImpression:page:section:component:element:itemParameters:" ],
        @[ @"TFNTwitterScribeImpressionLogger", @"logItemImpression:page:section:component:element:itemParameters:deduplicate:" ],
        @[ @"TFNTwitterScribeImpressionLogger",
           @"logItemLingerImpression:page:section:component:element:itemParameters:firstImpressionParameterKey:"
           @"firstImpressionCache:forceFirstImpression:" ],
        @[ @"TFNTwitterScribeImpressionLogger",
           @"_logItemImpression:page:section:component:element:itemParameters:deduplicate:cachesImpression:"
           @"firstImpressionParameterKey:firstImpressionCache:forceFirstImpression:" ],
        @[ @"TFNTwitterScribeImpressionLogger", @"logItemImpression:page:section:component:element:itemParameters:cachesImpression:" ],
        @[ @"T1LingerScriber", @"_t1_recordLingerInImpressionCache" ],
        @[ @"TFNTwitterScribe", @"logAction:page:section:component:parameters:" ],
        @[ @"TFNTwitterScribe", @"logAction:page:section:component:element:parameters:" ],
        @[ @"TFNTwitterScribe", @"logEvent:parameters:" ],
    ];
    NSMutableArray* missing = [NSMutableArray array];
    for (NSArray<NSString*>* hook in hooks) {
        Class cls = objc_getClass(hook[0].UTF8String);
        if (!cls || !class_getInstanceMethod(cls, NSSelectorFromString(hook[1]))) {
            [missing addObject:[NSString stringWithFormat:@"%@ %@", hook[0], [hook[1] componentsSeparatedByString:@":"].firstObject]];
        }
    }
    [out appendFormat:@"hooks missing in this X: %@\n", missing.count ? [missing componentsJoinedByString:@", "] : @"none"];
    return out;
}

%hook TFNTwitterScribeImpressionLogger

- (void)logItemImpression:(id)item
                     page:(id)page
                  section:(id)section
                component:(id)component
                  element:(id)element
           itemParameters:(id)parameters {
    if (DropImpression(self, item, parameters, @"impression")) return;
    %orig;
}

- (void)logItemImpression:(id)item
                     page:(id)page
                  section:(id)section
                component:(id)component
                  element:(id)element
           itemParameters:(id)parameters
              deduplicate:(BOOL)deduplicate {
    if (DropImpression(self, item, parameters, @"impression (dedup)")) return;
    %orig;
}

- (void)logItemLingerImpression:(id)item
                           page:(id)page
                        section:(id)section
                      component:(id)component
                        element:(id)element
                 itemParameters:(id)parameters
    firstImpressionParameterKey:(id)key
           firstImpressionCache:(id)cache
           forceFirstImpression:(BOOL)force {
    if (DropImpression(self, item, parameters, @"linger impression")) return;
    %orig;
}

- (void)_logItemImpression:(id)item
                          page:(id)page
                       section:(id)section
                     component:(id)component
                       element:(id)element
                itemParameters:(id)parameters
                   deduplicate:(BOOL)deduplicate
              cachesImpression:(BOOL)caches
   firstImpressionParameterKey:(id)key
          firstImpressionCache:(id)cache
          forceFirstImpression:(BOOL)force {
    if (DropImpression(self, item, parameters, @"impression (inner)")) return;
    %orig;
}

- (void)logItemImpression:(id)item
                     page:(id)page
                  section:(id)section
                component:(id)component
                  element:(id)element
           itemParameters:(id)parameters
         cachesImpression:(BOOL)caches {
    if (DropImpression(self, item, parameters, @"impression (caches)")) return;
    %orig;
}

%end

%hook T1LingerScriber

- (void)_t1_recordLingerInImpressionCache {
    NSSet<NSNumber*>* ids = GuardIDs();
    if (ids.count) {
        BOOL guarded = NO;
        @try {
            guarded = ItemIsGuarded(objectIvar(self, "_target"), ids);
        } @catch (__unused NSException* exception) {
        }
        if (guarded) {
            id logger = objectIvar(self, "_impressionLogger");
            BOOL asB = NO;
            @synchronized(GuardLock()) {
                asB = logger && logger == gGuardBLogger;
                if (asB) gPassedAsB++;
            }
            if (!asB) {
                NoteDrop(&gDroppedLingers, @"seen record");
                return;
            }
        }
    }
    %orig;
}

%end

%hook TFNTwitterScribe

- (void)logAction:(id)action page:(id)page section:(id)section component:(id)component parameters:(id)parameters {
    if (DropAction(self, nil, parameters, action)) return;
    %orig;
}

- (void)logAction:(id)action
             page:(id)page
          section:(id)section
        component:(id)component
          element:(id)element
       parameters:(id)parameters {
    if (DropAction(self, nil, parameters, action)) return;
    %orig;
}

- (void)logEvent:(id)event parameters:(id)parameters {
    if (DropAction(self, event, parameters, @"event")) return;
    %orig;
}

%end
