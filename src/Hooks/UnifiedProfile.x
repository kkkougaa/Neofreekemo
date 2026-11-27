//
//  UnifiedProfile.x
//  NeoFreeBird
//
//  The profile half of the A/B unified mode (UnifiedTimeline.x has the
//  timelines). While the mode is active (the account in use is A, B is set):
//
//  - A profile shows whether A and B each follow that user: two small chips
//    under the follow button, each with the account's picture and
//    "팔로우 중" / "팔로우 안 함" (or "확인 안 됨" when that account's relationship
//    is not known). A's state is A's own TFSTwitterRelationship on the profile's
//    user; B's comes from B's model context
//    (-[TFSLegacyModelSupport userForUserID:completion:] on B's modelContext).
//  - Blocking, unblocking, muting and unmuting that user from the profile asks
//    which account: A, B, or both. A goes through X's own
//    T1BlockMuteActionPerformer (%orig); B through B's TFNTwitterAccount
//    (blockUserWithUserReference:impressionID:isEarned:responseBlock: and the
//    unblock / mute / unmute ones). Before anything is sent as B, the account
//    object is checked to be B's (user ID); if it is not, or a selector is
//    missing, nothing is sent and a notice says so. A is never used in B's
//    place.
//

#import "HookHelpers.h"

// MARK: - Helpers (local copies; UnifiedTimeline.x keeps its own)

static id UPGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static long long UPNumber(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* type = signature.methodReturnType;
    if (!type) return 0;
    @try {
        switch (type[0]) {
            case 'q':
            case 'l':
                return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
            case 'Q':
            case 'L':
                return (long long)((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector);
            case 'i':
                return ((int (*)(id, SEL))objc_msgSend)(object, selector);
            case 'B':
            case 'c':
                return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
            case '@': {
                id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
                if ([value respondsToSelector:@selector(longLongValue)]) return [value longLongValue];
                return 0;
            }
            default:
                return 0;
        }
    } @catch (__unused NSException* exception) {
        return 0;
    }
}

static id UPIvar(id object, const char* name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return nil;
    const char* type = ivar_getTypeEncoding(ivar);
    if (type && type[0] && type[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

static id UPCurrentAccount(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) return nil;
    id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
    return UPGetter(host, @"currentAccount");
}

static NSArray* UPAccounts(void) {
    Class twitterClass = objc_getClass("TFNTwitter");
    if (!twitterClass || ![twitterClass respondsToSelector:@selector(sharedTwitter)]) return nil;
    id twitter = ((id (*)(id, SEL))objc_msgSend)(twitterClass, @selector(sharedTwitter));
    id accounts = UPGetter(twitter, @"accounts");
    return [accounts isKindOfClass:[NSArray class]] ? accounts : nil;
}

static NSString* UPAccountUserID(id account) {
    id user = UPGetter(account, @"user");
    for (id source in @[ account ?: [NSNull null], user ?: [NSNull null] ]) {
        if (source == [NSNull null]) continue;
        for (NSString* name in @[ @"userID", @"userId", @"userIDString" ]) {
            long long number = UPNumber(source, name);
            if (number > 0) return [NSString stringWithFormat:@"%lld", number];
            id value = UPGetter(source, name);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
        }
    }
    return nil;
}

static id UPAccountForID(NSString* userID) {
    if (userID.length == 0) return nil;
    for (id account in UPAccounts()) {
        if ([UPAccountUserID(account) isEqualToString:userID]) return account;
    }
    return nil;
}

static NSString* UPBID(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
}

static NSString* UPAID(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_a_id"];
}

static NSString* UPBName(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_name"] ?: @"B";
}

static NSString* UPAName(void) {
    id user = UPGetter(UPCurrentAccount(), @"user");
    NSString* name = UPGetter(user, @"username") ?: UPGetter(UPCurrentAccount(), @"username");
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return @"A";
    return [name hasPrefix:@"@"] ? name : [@"@" stringByAppendingString:name];
}

// Same rule as UnifiedTimeline.x: on, mode selected (unset = on), B set and
// not in use, and the account in use is A (or no A picked).
static BOOL UPActive(void) {
    if (![BHTSettings boolForKey:@"kemo_unified_exp"]) return NO;
    id mode = [[NSUserDefaults standardUserDefaults] objectForKey:@"kemo_unified_mode"];
    if (mode && ![mode boolValue]) return NO;
    NSString* bID = UPBID();
    NSString* currentID = UPAccountUserID(UPCurrentAccount());
    if (bID.length == 0 || currentID.length == 0 || [bID isEqualToString:currentID]) return NO;
    NSString* aID = UPAID();
    return aID.length == 0 || [aID isEqualToString:currentID];
}

// B's account object, only if it really is B's.
static id UPBAccount(void) {
    id account = UPAccountForID(UPBID());
    if (!account || ![UPAccountUserID(account) isEqualToString:UPBID()]) return nil;
    if (account == UPCurrentAccount()) return nil;
    return account;
}

static NSMutableArray<NSString*>* gProfileLog;

static void UPLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized([NSObject class]) {
        if (!gProfileLog) gProfileLog = [NSMutableArray array];
        [gProfileLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        while (gProfileLog.count > 30) [gProfileLog removeObjectAtIndex:0];
    }
}

static void UPNotice(NSString* text) {
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

static UIViewController* UPTopController(void) {
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

// An account's picture: AccountBubbles.x keeps them by user ID; a letter in a
// circle otherwise.
static UIImage* UPAvatar(NSString* userID, NSString* letter, UIColor* color) {
    static NSCache<NSString*, UIImage*>* cache;
    if (!cache) cache = [NSCache new];
    NSString* key = userID ?: letter;
    UIImage* image = [cache objectForKey:key];
    if (image) return image;
    if (userID) {
        NSURL* base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
        NSString* path = [[base URLByAppendingPathComponent:@"NFBAccountAvatars"]
                             URLByAppendingPathComponent:[userID stringByAppendingString:@".img"]].path;
        NSData* data = [NSData dataWithContentsOfFile:path];
        image = data.length ? [UIImage imageWithData:data] : nil;
        if (image) {
            [cache setObject:image forKey:key];
            return image;
        }
    }
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

extern UIColor* NFBUnifiedBColor(void);

static UIColor* UPBColor(void) {
    return NFBUnifiedBColor();
}

// MARK: - Follow state

typedef NS_ENUM(NSInteger, UPFollow) {
    UPFollowUnknown = 0,
    UPFollowYes,
    UPFollowNo,
};

// From a user object loaded in some account's context: that account's state.
// followedByCurrentAccountState is 1 for "following" (the URT timelines show
// 1 for followed authors); with no fresh relationship the answer is unknown.
static UPFollow UPFollowFromUser(id user, long long* rawState) {
    id relationship = UPGetter(user, @"relationship");
    if (!relationship) return UPFollowUnknown;
    long long state = UPNumber(relationship, @"followedByCurrentAccountState");
    if (rawState) *rawState = state;
    if ([user respondsToSelector:NSSelectorFromString(@"hasFreshRelationship")] && !UPNumber(user, @"hasFreshRelationship") &&
        state != 1) {
        return UPFollowUnknown;
    }
    return state == 1 ? UPFollowYes : UPFollowNo;
}

static NSMutableDictionary<NSNumber*, NSNumber*>* gBFollowByUser;  // userID -> UPFollow
static NSMutableSet<NSNumber*>* gBFollowAsked;
static NSString* gProfileState = @"(no profile yet)";
static long long gLastProfileUserID;

static void UPAskBFollow(long long userID, void (^done)(void)) {
    if (userID <= 0) return;
    if (!gBFollowByUser) gBFollowByUser = [NSMutableDictionary dictionary];
    if (!gBFollowAsked) gBFollowAsked = [NSMutableSet set];
    if ([gBFollowAsked containsObject:@(userID)]) return;
    [gBFollowAsked addObject:@(userID)];
    // 7.3.148: B's own Following list (UnifiedFollowSync.x) answers without
    // asking anything, and is not stale like a cached user object.
    NSArray* bList = UPBID().length
                         ? [[NSUserDefaults standardUserDefaults] arrayForKey:[@"kemo_unified_follows_" stringByAppendingString:UPBID()]]
                         : nil;
    if (bList.count) {
        UPFollow follow = [bList containsObject:@(userID)] ? UPFollowYes : UPFollowNo;
        gBFollowByUser[@(userID)] = @(follow);
        UPLog([NSString stringWithFormat:@"B follow of %lld: %ld (from B's following list)", userID, (long)follow]);
        if (done) done();
        return;
    }
    id b = UPBAccount();
    id context = UPGetter(b, @"modelContext");
    Class supportClass = objc_getClass("TFSLegacyModelSupport");
    SEL init = NSSelectorFromString(@"initWithModelContext:");
    SEL lookup = NSSelectorFromString(@"userForUserID:completion:");
    if (!b || !context || !supportClass || ![supportClass instancesRespondToSelector:init] ||
        ![supportClass instancesRespondToSelector:lookup]) {
        UPLog(@"B follow: no B model context or lookup");
        return;
    }
    id support = nil;
    @try {
        support = ((id (*)(id, SEL, id))objc_msgSend)([supportClass alloc], init, context);
    } @catch (__unused NSException* exception) {
    }
    if (!support) return;
    __block id keep = support;
    void (^completion)(id) = ^(id user) {
        dispatch_async(dispatch_get_main_queue(), ^{
            long long raw = -1;
            UPFollow follow = user ? UPFollowFromUser(user, &raw) : UPFollowUnknown;
            gBFollowByUser[@(userID)] = @(follow);
            UPLog([NSString stringWithFormat:@"B follow of %lld: %ld (raw %lld, user %@)", userID, (long)follow, raw,
                                             user ? NSStringFromClass([user class]) : @"nil"]);
            keep = nil;
            if (done) done();
        });
    };
    @try {
        ((void (*)(id, SEL, long long, id))objc_msgSend)(support, lookup, userID, completion);
    } @catch (NSException* exception) {
        UPLog([NSString stringWithFormat:@"B follow lookup threw %@", exception.name]);
    }
}

// MARK: - Chips under the follow button

static const NSInteger kChipsTag = 0x4E4650;  // "NFP"

static long long UPProfileUserID(UIViewController* profile) {
    long long userID = UPNumber(UPGetter(profile, @"profileViewControllerUserContext"), @"userID");
    if (userID > 0) return userID;
    id viewModel = UPIvar(profile, "_viewModel");
    userID = UPNumber(viewModel, @"userID");
    if (userID > 0) return userID;
    return UPNumber(UPGetter(viewModel, @"user"), @"userID");
}

static id UPProfileUser(UIViewController* profile) {
    id viewModel = UPIvar(profile, "_viewModel");
    id user = UPGetter(viewModel, @"user");
    if (!user) user = UPGetter(UPGetter(viewModel, @"userDataSource"), @"user");
    return user;
}

static UIView* UPFindFollowButton(UIView* root) {
    __block UIView* found = nil;
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if (found || view.hidden || view.alpha < 0.05 || view.window == nil) return;
        NSString* name = NSStringFromClass([view class]);
        if ([name containsString:@"FollowButton"] || [name isEqualToString:@"TUIFollowControl"] ||
            [view.accessibilityIdentifier containsString:@"FollowButton"]) {
            found = view;
        }
    });
    return found;
}

static UIView* UPChip(NSString* userID, NSString* letter, UIColor* color, NSString* text) {
    UIView* chip = [UIView new];
    chip.backgroundColor = [UIColor secondarySystemFillColor];
    chip.layer.cornerRadius = 11;
    UIImageView* picture = [[UIImageView alloc] initWithFrame:CGRectMake(3, 3, 16, 16)];
    picture.image = UPAvatar(userID, letter, color);
    picture.contentMode = UIViewContentModeScaleAspectFill;
    picture.clipsToBounds = YES;
    picture.layer.cornerRadius = 8;
    [chip addSubview:picture];
    UILabel* label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor labelColor];
    [label sizeToFit];
    label.frame = CGRectMake(23, 0, CGRectGetWidth(label.bounds), 22);
    [chip addSubview:label];
    chip.frame = CGRectMake(0, 0, 23 + CGRectGetWidth(label.bounds) + 8, 22);
    chip.isAccessibilityElement = YES;
    chip.accessibilityLabel = text;
    return chip;
}

static NSString* UPFollowText(UPFollow follow) {
    switch (follow) {
        case UPFollowYes:
            return @"팔로우 중";
        case UPFollowNo:
            return @"팔로우 안 함";
        default:
            return @"확인 안 됨";
    }
}

static void UPUpdateChips(UIViewController* profile) {
    UIView* root = profile.viewIfLoaded;
    if (!root) return;
    UIView* existing = [root viewWithTag:kChipsTag];
    long long userID = UPProfileUserID(profile);
    NSString* aID = UPAccountUserID(UPCurrentAccount());
    NSString* bID = UPBID();
    BOOL own = userID > 0 && ([[NSString stringWithFormat:@"%lld", userID] isEqualToString:aID] ||
                              [[NSString stringWithFormat:@"%lld", userID] isEqualToString:bID]);
    if (!UPActive() || userID <= 0 || own) {
        existing.hidden = YES;
        return;
    }
    UIView* follow = UPFindFollowButton(root);
    if (!follow) {
        existing.hidden = YES;
        gProfileState = [NSString stringWithFormat:@"user %lld: follow button not found", userID];
        return;
    }
    long long rawA = -1;
    UPFollow aFollow = UPFollowFromUser(UPProfileUser(profile), &rawA);
    NSNumber* bKnown = gBFollowByUser[@(userID)];
    UPFollow bFollow = bKnown ? (UPFollow)bKnown.integerValue : UPFollowUnknown;
    if (!bKnown) {
        __weak UIViewController* weakProfile = profile;
        UPAskBFollow(userID, ^{
            if (weakProfile) UPUpdateChips(weakProfile);
        });
    }
    gLastProfileUserID = userID;
    gProfileState = [NSString stringWithFormat:@"user %lld: A=%ld (raw %lld) B=%ld follow=%@ %@", userID, (long)aFollow, rawA,
                                               (long)bFollow, NSStringFromClass([follow class]),
                                               NSStringFromCGRect(follow.frame)];

    // 7.3.149: inside the follow button, on its left (below it there was no
    // room: the profile's tab strip sits right under the button). A and B as
    // small pictures, a check on the ones that follow, dim for the ones that do not.
    UIView* holder = follow;
    if (existing && existing.superview != holder) {
        [existing removeFromSuperview];
        existing = nil;
    }
    if (!existing) {
        existing = [UIView new];
        existing.tag = kChipsTag;
        existing.userInteractionEnabled = NO;
        [holder addSubview:existing];
    }
    [existing.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    const CGFloat size = 20, step = 15;
    NSArray* rows = @[ @[ aID ?: @"", @"A", [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1], @(aFollow) ],
                       @[ bID ?: @"", @"B", UPBColor(), @(bFollow) ] ];
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSArray* row = rows[i];
        UPFollow state = (UPFollow)[row[3] integerValue];
        UIImageView* picture = [[UIImageView alloc] initWithFrame:CGRectMake(i * step, 0, size, size)];
        picture.image = UPAvatar(row[0], row[1], row[2]);
        picture.contentMode = UIViewContentModeScaleAspectFill;
        picture.clipsToBounds = YES;
        picture.layer.cornerRadius = size / 2;
        picture.layer.borderWidth = 1.5;
        picture.layer.borderColor = (follow.backgroundColor ?: [UIColor systemBackgroundColor]).CGColor;
        picture.alpha = state == UPFollowYes ? 1.0 : 0.35;
        [existing addSubview:picture];
        if (state == UPFollowYes) {
            UILabel* check = [[UILabel alloc] initWithFrame:CGRectMake(i * step + size - 9, size - 9, 11, 11)];
            check.text = @"✓";
            check.font = [UIFont systemFontOfSize:8 weight:UIFontWeightBlack];
            check.textAlignment = NSTextAlignmentCenter;
            check.textColor = UIColor.whiteColor;
            check.backgroundColor = [UIColor systemGreenColor];
            check.layer.cornerRadius = 5.5;
            check.clipsToBounds = YES;
            [existing addSubview:check];
        }
    }
    CGFloat width = size + step * (rows.count - 1) + 2;
    existing.frame = CGRectMake(12, (CGRectGetHeight(follow.bounds) - size) / 2, width, size + 2);
    existing.isAccessibilityElement = YES;
    existing.accessibilityLabel = [NSString stringWithFormat:@"A %@, B %@", UPFollowText(aFollow), UPFollowText(bFollow)];
    existing.hidden = NO;
    [holder bringSubviewToFront:existing];
}

// MARK: - Block / mute as A, B or both

static __weak UIViewController* gVisibleProfile;

// Whether the block / mute about to run is for the profile on screen.
static BOOL UPIsVisibleProfileUser(long long userID) {
    UIViewController* profile = gVisibleProfile;
    if (!profile || !profile.viewIfLoaded.window || userID <= 0) return NO;
    return UPProfileUserID(profile) == userID;
}

typedef NS_ENUM(NSInteger, UPAction) {
    UPActionBlock,
    UPActionUnblock,
    UPActionMute,
    UPActionUnmute,
};

static NSString* UPActionTitle(UPAction action) {
    switch (action) {
        case UPActionBlock:
            return @"차단";
        case UPActionUnblock:
            return @"차단 해제";
        case UPActionMute:
            return @"뮤트";
        case UPActionUnmute:
            return @"뮤트 해제";
    }
    return @"";
}

// The same action as B, with B's own account. Stops (and says so) unless the
// account is B's and has the method.
static void UPDoAsB(UPAction action, id userReference) {
    id b = UPBAccount();
    if (!b) {
        UPLog(@"as B stopped: B account not found");
        UPNotice(@"B 계정을 찾지 못해서 B로는 보내지 않았어요");
        return;
    }
    if (!userReference) {
        UPLog(@"as B stopped: no user reference");
        UPNotice(@"대상 계정을 확인하지 못해서 B로는 보내지 않았어요");
        return;
    }
    NSString* name = nil;
    switch (action) {
        case UPActionBlock:
            name = @"blockUserWithUserReference:impressionID:isEarned:responseBlock:";
            break;
        case UPActionUnblock:
            name = @"unblockUserWithUserReference:impressionID:isEarned:responseBlock:";
            break;
        case UPActionMute:
            name = @"muteUserWithUserReference:impressionID:isEarned:responseBlock:";
            break;
        case UPActionUnmute:
            name = @"unmuteUserWithUserReference:impressionID:isEarned:responseBlock:";
            break;
    }
    SEL selector = NSSelectorFromString(name);
    if (![b respondsToSelector:selector]) {
        UPLog([NSString stringWithFormat:@"as B stopped: no %@", name]);
        UPNotice(@"이 X 버전에서는 B로 보낼 수 없어요");
        return;
    }
    void (^response)(void) = ^{
    };
    @try {
        ((void (*)(id, SEL, id, id, BOOL, id))objc_msgSend)(b, selector, userReference, nil, NO, response);
        UPLog([NSString stringWithFormat:@"%@ as B sent", UPActionTitle(action)]);
        UPNotice([NSString stringWithFormat:@"%@로 %@ 요청을 보냈어요", UPBName(), UPActionTitle(action)]);
    } @catch (NSException* exception) {
        UPLog([NSString stringWithFormat:@"%@ as B threw %@", UPActionTitle(action), exception.name]);
        UPNotice([NSString stringWithFormat:@"%@로 %@하지 못했어요", UPBName(), UPActionTitle(action)]);
    }
    if (action == UPActionBlock || action == UPActionUnblock) {
        // B's view of this user changed; ask again next time.
        [gBFollowAsked removeAllObjects];
        [gBFollowByUser removeAllObjects];
    }
}

extern void NFBPresentAccountSheet(NSString* title, NSString* message, NSArray<NSDictionary*>* rows);

// A, B or both. asA runs X's own path (as the account in use, A).
static void UPAskWhich(UPAction action, void (^asA)(void), void (^asB)(void)) {
    NSString* title = [NSString stringWithFormat:@"어느 계정으로 %@할까요?", UPActionTitle(action)];
    UIColor* purple = [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1];
    NFBPresentAccountSheet(title, nil, @[
        @{ @"title" : [NSString stringWithFormat:@"%@ (A)", aName],
           @"image" : UPAvatar(aAtAsk, @"A", purple),
           @"action" : ^{
               if (same()) asA();
           } },
        @{ @"title" : [NSString stringWithFormat:@"%@ (B)", bName],
           @"image" : UPAvatar(UPBID(), @"B", UPBColor()),
           @"action" : ^{
               if (same()) asB();
           } },
        @{ @"title" : @"둘 다",
           @"detail" : [NSString stringWithFormat:@"%@ + %@", aName, bName],
           @"action" : ^{
               if (!same()) return;
               asA();
               asB();
           } },
    ]);
}

static id UPContextUserReference(id context) {
    return UPGetter(context, @"targetUserReference") ?: UPIvar(context, "_targetUserReference");
}

static long long UPReferenceUserID(id reference) {
    long long userID = UPNumber(reference, @"userID");
    if (userID <= 0) userID = UPNumber(reference, @"userIDNumber");
    return userID;
}

// Only X's performer for the account in use (A) is asked about; one made for
// another account is left alone.
static BOOL UPShouldAsk(id performer, long long userID) {
    if (!UPActive()) return NO;
    if (UPGetter(performer, @"account") != UPCurrentAccount()) return NO;
    return UPIsVisibleProfileUser(userID);
}

// MARK: - Hooks

%hook T1ProfileViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gVisibleProfile = (UIViewController*)self;
    UPUpdateChips((UIViewController*)self);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (gVisibleProfile == (UIViewController*)self) gVisibleProfile = nil;
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController* controller = (UIViewController*)self;
    if (UPActive() || [controller.viewIfLoaded viewWithTag:kChipsTag]) UPUpdateChips(controller);
}

%end

%hook T1BlockMuteActionPerformer

- (void)showBlockAlertForContext:(id)context {
    id reference = UPContextUserReference(context);
    long long userID = UPReferenceUserID(reference);
    if (!UPShouldAsk(self, userID)) {
        %orig;
        return;
    }
    UPLog([NSString stringWithFormat:@"block %lld: asking which account", userID]);
    UPAskWhich(UPActionBlock, ^{
        %orig;
    }, ^{
        UPDoAsB(UPActionBlock, reference);
    });
}

- (void)unblockForContext:(id)context completion:(id)completion {
    id reference = UPContextUserReference(context);
    long long userID = UPReferenceUserID(reference);
    if (!UPShouldAsk(self, userID)) {
        %orig;
        return;
    }
    UPLog([NSString stringWithFormat:@"unblock %lld: asking which account", userID]);
    UPAskWhich(UPActionUnblock, ^{
        %orig;
    }, ^{
        UPDoAsB(UPActionUnblock, reference);
    });
}

- (void)muteActionForUser:(id)user
                   isMuting:(BOOL)isMuting
    showConfirmationIfNeeded:(BOOL)confirm
               impressionID:(id)impressionID
                 isPromoted:(BOOL)isPromoted
                   isEarned:(BOOL)isEarned
                 scribePage:(id)scribePage
              scribeSection:(id)scribeSection
            scribeComponent:(id)scribeComponent
           scribeParameters:(id)scribeParameters
                 completion:(id)completion {
    long long userID = UPNumber(user, @"userID");
    id reference = UPGetter(user, @"userReference");
    if (!UPShouldAsk(self, userID)) {
        %orig;
        return;
    }
    // 7.3.149: isMuting is whether the user is muted now (7.3.145 read it as
    // the wish and asked "unmute?" when muting).
    UPAction action = isMuting ? UPActionUnmute : UPActionMute;
    UPLog([NSString stringWithFormat:@"%@ %lld: asking which account", UPActionTitle(action), userID]);
    UPAskWhich(action, ^{
        %orig;
    }, ^{
        UPDoAsB(action, reference);
    });
}

%end

// MARK: - Follow / unfollow as A or B (the follow button opens a sheet)

static void UPRememberBFollow(long long userID, BOOL following) {
    if (!gBFollowByUser) gBFollowByUser = [NSMutableDictionary dictionary];
    gBFollowByUser[@(userID)] = @(following ? UPFollowYes : UPFollowNo);
    NSString* key = [@"kemo_unified_follows_" stringByAppendingString:UPBID() ?: @""];
    NSMutableSet* list = [NSMutableSet setWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:key] ?: @[]];
    if (following) [list addObject:@(userID)];
    else [list removeObject:@(userID)];
    if (UPBID().length) [[NSUserDefaults standardUserDefaults] setObject:[list allObjects] forKey:key];
    extern void NFBUnifiedAddKnownFollows(NSString* accountID, NSSet<NSNumber*>* userIDs);
    if (UPBID().length) NFBUnifiedAddKnownFollows(UPBID(), list);
}

// B follows or unfollows with B's own account; stops unless that is sure.
static void UPFollowAsB(BOOL follow, long long userID, id reference) {
    id b = UPBAccount();
    if (!b || !reference || userID <= 0) {
        UPLog(@"follow as B stopped: B account or user missing");
        UPNotice(@"B 계정이나 대상을 확인하지 못해서 보내지 않았어요");
        return;
    }
    SEL selector = NSSelectorFromString(follow ? @"followUserWithUserReference:impressionID:isEarned:supportsChallenges:responseBlock:"
                                               : @"unfollowUserWithUserReference:impressionID:isEarned:associatedStatusForLeaveBehindConfirmation:responseBlock:");
    if (![b respondsToSelector:selector]) {
        UPNotice(@"이 X 버전에서는 B로 보낼 수 없어요");
        return;
    }
    void (^response)(void) = ^{
    };
    @try {
        if (follow) {
            ((void (*)(id, SEL, id, id, BOOL, BOOL, id))objc_msgSend)(b, selector, reference, nil, NO, NO, response);
        } else {
            ((void (*)(id, SEL, id, id, BOOL, id, id))objc_msgSend)(b, selector, reference, nil, NO, nil, response);
        }
        UPRememberBFollow(userID, follow);
        UPLog([NSString stringWithFormat:@"%@ %lld as B sent", follow ? @"follow" : @"unfollow", userID]);
        UPNotice([NSString stringWithFormat:@"%@로 %@ 요청을 보냈어요", UPBName(), follow ? @"팔로우" : @"언팔로우"]);
    } @catch (NSException* exception) {
        UPLog([NSString stringWithFormat:@"follow as B threw %@", exception.name]);
        UPNotice(@"B로 보내지 못했어요");
    }
}

static UIViewController* UPProfileOf(UIView* view) {
    for (UIResponder* responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            for (UIViewController* controller = (UIViewController*)responder; controller; controller = controller.parentViewController) {
                if ([NSStringFromClass([controller class]) isEqualToString:@"T1ProfileViewController"]) return controller;
            }
            return nil;
        }
    }
    return nil;
}

// YES when the sheet was shown instead of X's own follow / unfollow.
static BOOL UPShowFollowSheet(UIView* button, void (^asA)(void)) {
    if (!UPActive()) return NO;
    UIViewController* profile = UPProfileOf(button);
    if (!profile || profile != gVisibleProfile) return NO;
    // The button must be the account in use's (A's), so X's own path is A.
    if (UPGetter(button, @"account") != UPCurrentAccount()) return NO;
    long long userID = UPProfileUserID(profile);
    NSString* aID = UPAccountUserID(UPCurrentAccount());
    NSString* idText = [NSString stringWithFormat:@"%lld", userID];
    if (userID <= 0 || [idText isEqualToString:aID] || [idText isEqualToString:UPBID()]) return NO;
    long long raw = -1;
    UPFollow aFollow = UPFollowFromUser(UPProfileUser(profile), &raw);
    NSNumber* bKnown = gBFollowByUser[@(userID)];
    UPFollow bFollow = bKnown ? (UPFollow)bKnown.integerValue : UPFollowUnknown;
    id reference = UPGetter(UPProfileUser(profile), @"userReference");
    NSString* aName = UPAName(), *bName = UPBName();
    NSString* aAtAsk = aID;
    BOOL (^same)(void) = ^BOOL {
        if (UPActive() && [UPAccountUserID(UPCurrentAccount()) isEqualToString:aAtAsk]) return YES;
        UPNotice(@"계정이 바뀌어서 보내지 않았어요");
        return NO;
    };
    NSMutableArray* rows = [NSMutableArray array];
    // A: X's own button action, which follows or unfollows as A.
    [rows addObject:@{
        @"title" : [NSString stringWithFormat:@"%@ (A) %@", aName, aFollow == UPFollowYes ? @"언팔로우" : @"팔로우"],
        @"detail" : [NSString stringWithFormat:@"지금: %@", UPFollowText(aFollow)],
        @"image" : UPAvatar(aID, @"A", [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1]),
        @"destructive" : @(aFollow == UPFollowYes),
        @"action" : ^{
            if (same()) asA();
        }
    }];
    if (bFollow != UPFollowUnknown) {
        BOOL bFollows = bFollow == UPFollowYes;
        [rows addObject:@{
            @"title" : [NSString stringWithFormat:@"%@ (B) %@", bName, bFollows ? @"언팔로우" : @"팔로우"],
            @"detail" : [NSString stringWithFormat:@"지금: %@", UPFollowText(bFollow)],
            @"image" : UPAvatar(UPBID(), @"B", UPBColor()),
            @"destructive" : @(bFollows),
            @"action" : ^{
                if (same()) UPFollowAsB(!bFollows, userID, reference);
                [profile.viewIfLoaded setNeedsLayout];
            }
        }];
    }
    NFBPresentAccountSheet(@"어느 계정으로 할까요?", nil, rows);
    UPLog([NSString stringWithFormat:@"follow sheet for %lld (A=%ld B=%ld)", userID, (long)aFollow, (long)bFollow]);
    return YES;
}

%hook TUIFollowButtonV2

- (void)buttonTapped {
    if (UPShowFollowSheet((UIView*)self, ^{
            %orig;
        }))
        return;
    %orig;
}

%end

// MARK: - Debug

NSString* NFBUnifiedProfileDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"active=%d B=%@ visibleProfile=%@\n", UPActive(), UPBAccount() ? @"found" : @"missing",
                      gVisibleProfile ? NSStringFromClass([gVisibleProfile class]) : @"-"];
    [out appendFormat:@"last: %@\n", gProfileState];
    [out appendFormat:@"B follow known for %lu users\n", (unsigned long)gBFollowByUser.count];
    @synchronized([NSObject class]) {
        [out appendFormat:@"%@\n", gProfileLog.count ? [gProfileLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}
