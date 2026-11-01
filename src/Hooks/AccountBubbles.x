//
//  AccountBubbles.x
//  NeoFreeBird
//
//  Long-pressing the profile picture at the top left normally opens X's account
//  list. When this is on, the accounts pop out as circles instead: drag onto one
//  and let go to switch, or let go first and tap one. Switching uses X's own
//  -[T1HostViewController viewAccount:animated:].
//
//  7.3.20 hooked -[T1TabNavigationController _t1_action_didLongPressDashButton:],
//  which this X build never calls, and fanned the circles upward from the top
//  left corner, off screen. This version puts its own long press on the avatar
//  button in the navigation bar, makes X's own long press wait for it, and fans
//  the circles toward the middle of the screen. With fewer than two accounts the
//  press stands aside and X's sheet opens as before.
//
//  7.3.22: on iOS 26 the avatar sits in a SwiftUI platter and X's sheet still
//  won. Now X's sheet itself is caught when it is presented after a held
//  finger, and the circles open in its place, following that finger.
//
//  7.3.23: profile pictures (from X's on-screen avatars, or any getter giving a
//  profile_images address), an unread badge per account, and circles pushed
//  apart so five or more never overlap near a corner.
//
//  7.3.24: one even arc (quarter circle from a corner) that slides as a whole
//  to stay on screen; unread badges read off X's own account list rows; the
//  name tag sits above the arc, away from the thumb.

#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import "HookHelpers.h"

static const NSInteger kBubbleLimit = 8;
static const CGFloat kBubbleSize = 56.0;
static const CGFloat kHitRadius = 44.0;

static BOOL BubblesOn(void) {
    return [BHTSettings boolForKey:@"kemo_account_bubbles"];
}

// MARK: - Account data

static id ObjectProp(id object, NSString* selectorName) {
    if (!object) {
        return nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* returnType = signature.methodReturnType;
    if (!returnType || returnType[0] != '@') {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static NSString* StringProp(id object, NSString* selectorName) {
    id value = ObjectProp(object, selectorName);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSArray* TwitterAccounts(void) {
    Class twitterClass = objc_getClass("TFNTwitter");
    if (!twitterClass || ![twitterClass respondsToSelector:@selector(sharedTwitter)]) {
        return nil;
    }
    id twitter = ((id (*)(id, SEL))objc_msgSend)(twitterClass, @selector(sharedTwitter));
    id accounts = ObjectProp(twitter, @"accounts");
    if (![accounts isKindOfClass:[NSArray class]] || [accounts count] == 0) {
        return nil;
    }
    return accounts;
}

static id HostController(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
}

static id CurrentAccount(void) {
    return ObjectProp(HostController(), @"currentAccount");
}

static NSString* AccountKey(id account) {
    id user = ObjectProp(account, @"user");
    for (id source in @[ account ?: [NSNull null], user ?: [NSNull null] ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in @[ @"userID", @"userId", @"userIDString", @"username", @"screenName" ]) {
            SEL selector = NSSelectorFromString(name);
            if (![source respondsToSelector:selector]) {
                continue;
            }
            NSMethodSignature* signature = [source methodSignatureForSelector:selector];
            const char* type = signature.methodReturnType;
            if (!type) {
                continue;
            }
            if (type[0] == '@') {
                id value = ObjectProp(source, name);
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                    return [value lowercaseString];
                }
                if ([value isKindOfClass:[NSNumber class]]) {
                    return [value stringValue];
                }
            } else if (type[0] == 'q' || type[0] == 'Q' || type[0] == 'l' || type[0] == 'L') {
                long long value = ((long long (*)(id, SEL))objc_msgSend)(source, selector);
                if (value != 0) {
                    return [NSString stringWithFormat:@"%lld", value];
                }
            }
        }
    }
    return nil;
}

static BOOL SameAccount(id a, id b) {
    if (!a || !b) {
        return NO;
    }
    if (a == b) {
        return YES;
    }
    NSString* keyA = AccountKey(a);
    NSString* keyB = AccountKey(b);
    return keyA && keyB && [keyA isEqualToString:keyB];
}

static BOOL SwitchToAccount(id account) {
    id host = HostController();
    SEL selector = @selector(viewAccount:animated:);
    if (!account || !host || ![host respondsToSelector:selector]) {
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(host, selector, account, YES);
        return YES;
    } @catch (__unused NSException* exception) {
        return NO;
    }
}

static NSString* AccountTitle(id account) {
    id user = ObjectProp(account, @"user");
    for (id source in @[ user ?: [NSNull null], account ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in @[ @"username", @"screenName", @"displayUsername" ]) {
            NSString* value = StringProp(source, name);
            if (value.length > 0) {
                return [value hasPrefix:@"@"] ? value : [@"@" stringByAppendingString:value];
            }
        }
        for (NSString* name in @[ @"fullName", @"displayFullName", @"name" ]) {
            NSString* value = StringProp(source, name);
            if (value.length > 0) {
                return value;
            }
        }
    }
    return @"";
}

static NSString* ProbedImageString(id account);

static NSURL* AccountImageURL(id account) {
    id user = ObjectProp(account, @"user");
    for (id source in @[ user ?: [NSNull null], account ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in @[ @"profileImageURL", @"profileImageUrl", @"profileImageURLString",
                                  @"profileImageURLHTTPS", @"avatarURL", @"avatarImageURL" ]) {
            id value = ObjectProp(source, name);
            NSString* string = nil;
            if ([value isKindOfClass:[NSURL class]]) {
                string = [value absoluteString];
            } else if ([value isKindOfClass:[NSString class]]) {
                string = value;
            }
            if (string.length == 0) {
                continue;
            }
            // The stored URL is usually the 48px "_normal" size.
            string = [string stringByReplacingOccurrencesOfString:@"_normal." withString:@"_bigger."];
            if ([string hasPrefix:@"http://"]) {
                string = [@"https://" stringByAppendingString:[string substringFromIndex:7]];
            }
            NSURL* url = [NSURL URLWithString:string];
            if (url) {
                return url;
            }
        }
    }
    // Names differ between X builds: look for any getter giving a profile_images address.
    NSString* probed = ProbedImageString(account);
    if (probed.length > 0) {
        probed = [probed stringByReplacingOccurrencesOfString:@"_normal." withString:@"_bigger."];
        if ([probed hasPrefix:@"http://"]) {
            probed = [@"https://" stringByAppendingString:[probed substringFromIndex:7]];
        }
        return [NSURL URLWithString:probed];
    }
    return nil;
}

// What the last probe found, for the shake dump.
static NSMutableArray<NSString*>* gProbeLog = nil;

static void ProbeNote(NSString* line) {
    if (!gProbeLog) {
        gProbeLog = [NSMutableArray array];
    }
    if (![gProbeLog containsObject:line]) {
        [gProbeLog addObject:line];
        if (gProbeLog.count > 24) {
            [gProbeLog removeObjectAtIndex:0];
        }
    }
}

// Zero-argument getters on the class chain (stopping at NSObject) whose name
// contains one of the words.
static NSArray<NSString*>* GettersMatching(id object, NSArray<NSString*>* words) {
    NSMutableArray* names = [NSMutableArray array];
    for (Class cls = object_getClass(object); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method* methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString* name = NSStringFromSelector(method_getName(methods[i]));
            if ([name containsString:@":"] || [name hasPrefix:@"set"] || [name hasPrefix:@"_"] ||
                [names containsObject:name]) {
                continue;
            }
            NSString* lower = name.lowercaseString;
            for (NSString* word in words) {
                if ([lower containsString:word]) {
                    [names addObject:name];
                    break;
                }
            }
        }
        free(methods);
    }
    return names;
}

static NSString* ProfileImageString(id value) {
    NSString* string = nil;
    if ([value isKindOfClass:[NSURL class]]) {
        string = [value absoluteString];
    } else if ([value isKindOfClass:[NSString class]]) {
        string = value;
    }
    return [string containsString:@"profile_images"] ? string : nil;
}

// Any getter on the user or account that hands back a pbs.twimg.com
// profile_images address.
static NSString* ProbedImageString(id account) {
    id user = ObjectProp(account, @"user");
    for (id source in @[ user ?: [NSNull null], account ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in GettersMatching(source, @[ @"image", @"avatar" ])) {
            NSString* string = ProfileImageString(ObjectProp(source, name));
            if (string) {
                ProbeNote([NSString stringWithFormat:@"image: -[%@ %@]", NSStringFromClass([source class]), name]);
                return string;
            }
        }
    }
    ProbeNote([NSString stringWithFormat:@"image: none on %@ / %@", NSStringFromClass([user class]),
                                         NSStringFromClass([account class])]);
    return nil;
}

// X's own avatar views carry the user ID: "TUIAvatarImageView.<id>".
static UIImage* OnScreenAvatar(NSString* key) {
    if (key.length == 0) {
        return nil;
    }
    NSString* wanted = [@"TUIAvatarImageView." stringByAppendingString:key];
    for (UIWindow* window in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
        NSInteger budget = 6000;
        while (queue.count > 0 && budget-- > 0) {
            UIView* view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([view isKindOfClass:[UIImageView class]] && [view.accessibilityIdentifier isEqualToString:wanted]) {
                UIImage* image = ((UIImageView*)view).image;
                if (image) {
                    return image;
                }
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
    return nil;
}

static NSInteger NumberFromGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) {
        return -1;
    }
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* type = signature.methodReturnType;
    if (!type) {
        return -1;
    }
    @try {
        switch (type[0]) {
            case 'q':
                return (NSInteger)((long long (*)(id, SEL))objc_msgSend)(object, selector);
            case 'Q':
                return (NSInteger)((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector);
            case 'i': case 'l':
                return (NSInteger)((int (*)(id, SEL))objc_msgSend)(object, selector);
            case 'I': case 'L':
                return (NSInteger)((unsigned int (*)(id, SEL))objc_msgSend)(object, selector);
            case '@': {
                id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
                return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : -1;
            }
            default:
                return -1;
        }
    } @catch (__unused NSException* exception) {
        return -1;
    }
}

// Unread notifications for an account, from whatever count getter it has.
// Prefers notification counts over other unread counts; -1 when none found.
static NSInteger AccountUnreadCount(id account) {
    for (NSArray<NSString*>* words in @[ @[ @"unreadnotification", @"notificationsunread", @"notificationbadge",
                                            @"notificationcount", @"notificationscount" ],
                                         @[ @"unread", @"badge" ] ]) {
        for (NSString* name in GettersMatching(account, words)) {
            NSString* lower = name.lowercaseString;
            if ([lower containsString:@"dm"] || [lower containsString:@"message"] ||
                [lower containsString:@"enabled"] || [lower containsString:@"should"] ||
                [lower hasPrefix:@"is"] || [lower hasPrefix:@"has"]) {
                continue;
            }
            NSInteger value = NumberFromGetter(account, name);
            if (value >= 0) {
                ProbeNote([NSString stringWithFormat:@"badge: -[%@ %@]", NSStringFromClass([account class]), name]);
                return value;
            }
        }
    }
    ProbeNote([NSString stringWithFormat:@"badge: none on %@", NSStringFromClass([account class])]);
    return -1;
}

// Unread counts read off X's own account list (T1PickableAccountEntryCell:
// a TUIAvatarImageView.<user id> plus a TFNBadgeView with the number).
static NSMutableDictionary<NSString*, NSNumber*>* gSheetCounts = nil;

static NSInteger HarvestSheetCounts(UIView* root) {
    if (!root) {
        return 0;
    }
    NSInteger cells = 0;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 3000;
    while (queue.count > 0 && budget-- > 0) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (![view isKindOfClass:[UITableViewCell class]] ||
            ![NSStringFromClass(view.class) containsString:@"AccountEntryCell"]) {
            [queue addObjectsFromArray:view.subviews];
            continue;
        }
        NSString* key = nil;
        NSInteger count = 0;
        NSMutableArray<UIView*>* inner = [NSMutableArray arrayWithObject:view];
        while (inner.count > 0) {
            UIView* sub = inner.firstObject;
            [inner removeObjectAtIndex:0];
            NSString* identifier = sub.accessibilityIdentifier;
            if (!key && [identifier hasPrefix:@"TUIAvatarImageView."]) {
                key = [identifier substringFromIndex:@"TUIAvatarImageView.".length];
            }
            if (!sub.hidden && sub.alpha > 0.01 && [NSStringFromClass(sub.class) containsString:@"BadgeView"]) {
                NSMutableArray<UIView*>* labels = [NSMutableArray arrayWithObject:sub];
                while (labels.count > 0) {
                    UIView* label = labels.firstObject;
                    [labels removeObjectAtIndex:0];
                    if ([label isKindOfClass:[UILabel class]] && ((UILabel*)label).text.integerValue > 0) {
                        count = ((UILabel*)label).text.integerValue;
                        break;
                    }
                    [labels addObjectsFromArray:label.subviews];
                }
            }
            [inner addObjectsFromArray:sub.subviews];
        }
        if (key.length > 0) {
            if (!gSheetCounts) {
                gSheetCounts = [NSMutableDictionary dictionary];
            }
            gSheetCounts[key] = @(count);
            cells++;
        }
    }
    if (cells > 0) {
        ProbeNote([NSString stringWithFormat:@"badge: read %ld rows of X's account list", (long)cells]);
    }
    return cells;
}

static NSInteger BadgeCountFor(id account) {
    NSString* key = AccountKey(account);
    NSNumber* seen = key ? gSheetCounts[key] : nil;
    if (seen) {
        return seen.integerValue;
    }
    return AccountUnreadCount(account);
}

static NSCache<NSString*, UIImage*>* AvatarCache(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 40;
    });
    return cache;
}

static UIVisualEffect* BubbleEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (glassClass) {
        id effect = nil;
        SEL styled = NSSelectorFromString(@"effectWithStyle:");
        if ([glassClass respondsToSelector:styled]) {
            effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, styled, 0);
        }
        if (!effect) {
            effect = [[glassClass alloc] init];
        }
        if ([effect isKindOfClass:[UIVisualEffect class]]) {
            return effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

static UIColor* AccentColor(void) {
    UIWindow* window = UIApplication.sharedApplication.windows.firstObject;
    return window.tintColor ?: [UIColor systemBlueColor];
}

static void Tick(void) {
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        return;
    }
    UISelectionFeedbackGenerator* tap = [UISelectionFeedbackGenerator new];
    [tap selectionChanged];
}

// MARK: - Bubble views

@interface NFBAccountBubble : UIView
@property (nonatomic, strong) id account;
@property (nonatomic, assign) CGPoint slot;
@property (nonatomic, assign) BOOL settled;
@property (nonatomic, assign) BOOL current;
@property (nonatomic, strong) UIImageView* avatar;
@property (nonatomic, strong) UILabel* initial;
@property (nonatomic, strong) UILabel* badge;
- (void)setCount:(NSInteger)count;
@end

@implementation NFBAccountBubble

- (instancetype)initWithAccount:(id)account current:(BOOL)current {
    if ((self = [super initWithFrame:CGRectMake(0, 0, kBubbleSize, kBubbleSize)])) {
        _account = account;
        _current = current;
        self.userInteractionEnabled = NO;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.22;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        UIVisualEffectView* glass = [[UIVisualEffectView alloc] initWithEffect:BubbleEffect()];
        glass.frame = self.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerRadius = kBubbleSize / 2.0;
        glass.clipsToBounds = YES;
        glass.layer.borderWidth = current ? 2.5 : 1.0;
        glass.layer.borderColor =
            current ? AccentColor().CGColor : [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        [self addSubview:glass];

        NSString* title = AccountTitle(account);
        _initial = [[UILabel alloc] initWithFrame:self.bounds];
        _initial.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _initial.textAlignment = NSTextAlignmentCenter;
        _initial.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        _initial.textColor = [UIColor labelColor];
        NSString* letters = [title stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"@"]];
        _initial.text = letters.length > 0 ? [[letters substringToIndex:1] uppercaseString] : @"?";
        [self addSubview:_initial];

        _avatar = [[UIImageView alloc] initWithFrame:CGRectInset(self.bounds, 4, 4)];
        _avatar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _avatar.layer.cornerRadius = CGRectGetWidth(_avatar.bounds) / 2.0;
        _avatar.clipsToBounds = YES;
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        [self addSubview:_avatar];

        // Unread notifications, top right, like X's own badge.
        _badge = [UILabel new];
        _badge.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        _badge.textColor = [UIColor whiteColor];
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.backgroundColor = AccentColor();
        _badge.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
        _badge.layer.borderWidth = 2;
        _badge.clipsToBounds = YES;
        _badge.hidden = YES;
        [self addSubview:_badge];

        self.isAccessibilityElement = YES;
        self.accessibilityLabel = title;
    }
    return self;
}

- (void)setCount:(NSInteger)count {
    if (count <= 0) {
        self.badge.hidden = YES;
        return;
    }
    self.badge.text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    CGFloat height = 22;
    CGFloat width = MAX(height, [self.badge.text sizeWithAttributes:@{NSFontAttributeName : self.badge.font}].width + 12);
    self.badge.frame = CGRectMake(kBubbleSize - width + 6, -4, width, height);
    self.badge.layer.cornerRadius = height / 2.0;
    self.badge.hidden = NO;
    self.accessibilityValue = self.badge.text;
}

- (void)setImage:(UIImage*)image {
    self.avatar.image = image;
    self.initial.hidden = image != nil;
}

@end

@interface NFBAccountFan : UIView
@property (nonatomic, strong) NSArray<NFBAccountBubble*>* bubbles;
@property (nonatomic, weak) NFBAccountBubble* hovered;
@property (nonatomic, strong) UIView* dim;
@property (nonatomic, strong) UILabel* nameTag;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, assign) CGPoint tagAnchor;
- (void)refreshCounts;
@end

static __weak NFBAccountFan* gLiveFan = nil;

@implementation NFBAccountFan

- (instancetype)initWithFrame:(CGRect)frame
                     accounts:(NSArray*)accounts
                       origin:(CGPoint)origin
                         safe:(UIEdgeInsets)safe {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
        _dim.alpha = 0;
        [self addSubview:_dim];
        [UIView animateWithDuration:0.2 animations:^{
            self.dim.alpha = 1;
        }];

        id current = CurrentAccount();
        NSInteger count = MIN((NSInteger)accounts.count, kBubbleLimit);

        // One even arc around the finger. From a corner it is a quarter circle
        // pointing into the screen; elsewhere it opens toward the middle. The
        // radius grows until neighbours are a full circle apart, then the whole
        // arc slides (never squashes) to stay on screen.
        CGFloat pad = kBubbleSize / 2.0 + 8.0;
        CGRect allowed = UIEdgeInsetsInsetRect(frame, UIEdgeInsetsMake(safe.top + pad, safe.left + pad,
                                                                        safe.bottom + pad, safe.right + pad));
        CGFloat width = CGRectGetWidth(frame);
        CGFloat height = CGRectGetHeight(frame);
        BOOL nearLeft = origin.x < width * 0.3, nearRight = origin.x > width * 0.7;
        BOOL nearTop = origin.y < height * 0.3, nearBottom = origin.y > height * 0.7;
        BOOL corner = (nearLeft || nearRight) && (nearTop || nearBottom);
        CGPoint pivot = CGPointMake(MAX(CGRectGetMinX(allowed) + 8, MIN(origin.x, CGRectGetMaxX(allowed) - 8)),
                                    MAX(CGRectGetMinY(allowed) + 8, MIN(origin.y, CGRectGetMaxY(allowed) - 8)));
        CGFloat aim, spread;
        if (corner) {
            aim = atan2(nearTop ? 1.0 : -1.0, nearLeft ? 1.0 : -1.0);
            spread = MIN((CGFloat)M_PI_2, (CGFloat)(count - 1) * (CGFloat)(M_PI / 6.0));
        } else {
            aim = atan2(CGRectGetMidY(frame) - pivot.y, CGRectGetMidX(frame) - pivot.x);
            spread = MIN((CGFloat)(M_PI * 5.0 / 6.0), (CGFloat)(count - 1) * (CGFloat)(M_PI * 35.0 / 180.0));
        }
        CGFloat gap = kBubbleSize + 16.0;
        CGFloat step = count > 1 ? spread / (CGFloat)(count - 1) : 0;
        CGFloat radius = count > 1 ? MAX(120.0, gap / (2.0 * sin(step / 2.0))) : 120.0;

        CGPoint slots[kBubbleLimit];
        CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
        for (NSInteger i = 0; i < count; i++) {
            CGFloat angle = aim - spread / 2.0 + step * (CGFloat)i;
            slots[i] = CGPointMake(pivot.x + cos(angle) * radius, pivot.y + sin(angle) * radius);
            minX = MIN(minX, slots[i].x);
            maxX = MAX(maxX, slots[i].x);
            minY = MIN(minY, slots[i].y);
            maxY = MAX(maxY, slots[i].y);
        }
        CGFloat shiftX = MAX(0, CGRectGetMinX(allowed) - minX) - MAX(0, maxX - CGRectGetMaxX(allowed));
        CGFloat shiftY = MAX(0, CGRectGetMinY(allowed) - minY) - MAX(0, maxY - CGRectGetMaxY(allowed));
        for (NSInteger i = 0; i < count; i++) {
            slots[i].x += shiftX;
            slots[i].y += shiftY;
        }
        // The name tag sits above the whole arc: clear of the circles, and of
        // the thumb, which always comes from below.
        _tagAnchor = CGPointMake((minX + maxX) / 2.0 + shiftX, minY + shiftY - kBubbleSize / 2.0 - 26);

        NSMutableArray* bubbles = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) {
            id account = accounts[i];
            NFBAccountBubble* bubble = [[NFBAccountBubble alloc] initWithAccount:account
                                                                         current:SameAccount(account, current)];
            CGPoint slot = slots[i];
            bubble.slot = slot;
            bubble.center = origin;
            bubble.transform = CGAffineTransformMakeScale(0.15, 0.15);
            bubble.alpha = 0;
            [self addSubview:bubble];
            [bubbles addObject:bubble];
            [UIView animateWithDuration:0.46
                delay:i * 0.04
                usingSpringWithDamping:0.64
                initialSpringVelocity:0.7
                options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                animations:^{
                    bubble.center = bubble.slot;
                    bubble.alpha = 1;
                    bubble.transform = CGAffineTransformIdentity;
                }
                completion:^(BOOL finished) {
                    bubble.settled = YES;
                }];
            [self loadImageForBubble:bubble];
            [bubble setCount:bubble.current ? 0 : BadgeCountFor(account)];
        }
        _bubbles = bubbles;

        gLiveFan = self;

        _nameTag = [UILabel new];
        _nameTag.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _nameTag.textColor = [UIColor whiteColor];
        _nameTag.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
        _nameTag.textAlignment = NSTextAlignmentCenter;
        _nameTag.layer.cornerRadius = 14;
        _nameTag.clipsToBounds = YES;
        _nameTag.alpha = 0;
        [self addSubview:_nameTag];
    }
    return self;
}

- (void)refreshCounts {
    for (NFBAccountBubble* bubble in self.bubbles) {
        [bubble setCount:bubble.current ? 0 : BadgeCountFor(bubble.account)];
    }
}

- (void)loadImageForBubble:(NFBAccountBubble*)bubble {
    NSString* key = AccountKey(bubble.account);
    UIImage* known = key ? [AvatarCache() objectForKey:key] : nil;
    if (!known) {
        known = OnScreenAvatar(key);
        if (known) {
            [AvatarCache() setObject:known forKey:key];
        }
    }
    if (known) {
        [bubble setImage:known];
    }
    NSURL* url = AccountImageURL(bubble.account);
    if (!url) {
        return;
    }
    UIImage* cached = [AvatarCache() objectForKey:url.absoluteString];
    if (cached) {
        [bubble setImage:cached];
        return;
    }
    __weak NFBAccountBubble* weakBubble = bubble;
    [[[NSURLSession sharedSession]
          dataTaskWithURL:url
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            UIImage* image = data.length > 0 && !error ? [UIImage imageWithData:data] : nil;
            if (!image) {
                NSString* line = [NSString stringWithFormat:@"download failed %@: %@", url.host,
                                                            error.localizedDescription ?: @"no image data"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    ProbeNote(line);
                });
                return;
            }
            [AvatarCache() setObject:image forKey:url.absoluteString];
            if (key) {
                [AvatarCache() setObject:image forKey:key];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakBubble setImage:image];
            });
        }] resume];
}

- (NFBAccountBubble*)bubbleNear:(CGPoint)point {
    NFBAccountBubble* best = nil;
    CGFloat bestDistance = kHitRadius;
    for (NFBAccountBubble* bubble in self.bubbles) {
        CGFloat distance = hypot(point.x - bubble.slot.x, point.y - bubble.slot.y);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = bubble;
        }
    }
    return best;
}

- (void)showName:(NFBAccountBubble*)bubble {
    if (!bubble) {
        [UIView animateWithDuration:0.12 animations:^{
            self.nameTag.alpha = 0;
        }];
        return;
    }
    self.nameTag.text = bubble.accessibilityLabel;
    [self.nameTag sizeToFit];
    CGRect frame = self.nameTag.frame;
    frame.size.width = MIN(frame.size.width + 24, CGRectGetWidth(self.bounds) - 32);
    frame.size.height = 28;
    self.nameTag.frame = frame;
    // Above the arc (see tagAnchor). If that is off the top, above the circle.
    CGPoint center = self.tagAnchor;
    if (center.y - 14 < self.safeAreaInsets.top + 8) {
        center = CGPointMake(bubble.slot.x, bubble.slot.y - kBubbleSize / 2.0 - 30);
        if (center.y - 14 < self.safeAreaInsets.top + 8) {
            center.y = bubble.slot.y + kBubbleSize / 2.0 + 30;
        }
    }
    CGFloat half = frame.size.width / 2.0;
    center.x = MAX(16 + half, MIN(center.x, CGRectGetWidth(self.bounds) - 16 - half));
    self.nameTag.center = center;
    [UIView animateWithDuration:0.12 animations:^{
        self.nameTag.alpha = 1;
    }];
}

- (void)hoverAt:(CGPoint)point {
    NFBAccountBubble* next = [self bubbleNear:point];
    if (next == self.hovered) {
        return;
    }
    self.hovered = next;
    for (NFBAccountBubble* bubble in self.bubbles) {
        if (!bubble.settled) {
            continue;
        }
        [UIView animateWithDuration:0.14
                         animations:^{
                             bubble.transform = bubble == next ? CGAffineTransformMakeScale(1.2, 1.2)
                                                               : CGAffineTransformIdentity;
                         }];
    }
    [self showName:next];
    if (next) {
        Tick();
    }
}

// Released without picking: keep the circles up and let the user tap one.
- (void)waitForTap {
    self.userInteractionEnabled = YES;
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(tapped:)];
    [self addGestureRecognizer:tap];
}

- (void)tapped:(UITapGestureRecognizer*)tap {
    NFBAccountBubble* bubble = [self bubbleNear:[tap locationInView:self]];
    if (bubble) {
        self.hovered = bubble;
        Tick();
        [self finishWith:bubble];
    } else {
        [self finishWith:nil];
    }
}

- (void)finishWith:(NFBAccountBubble*)chosen {
    if (self.closing) {
        return;
    }
    self.closing = YES;
    self.userInteractionEnabled = NO;
    id account = chosen && !chosen.current ? chosen.account : nil;
    [UIView animateWithDuration:0.2
        animations:^{
            self.alpha = 0;
            for (NFBAccountBubble* bubble in self.bubbles) {
                bubble.transform = bubble == chosen ? CGAffineTransformMakeScale(1.35, 1.35)
                                                    : CGAffineTransformMakeScale(0.3, 0.3);
            }
        }
        completion:^(BOOL finished) {
            [self removeFromSuperview];
            if (account) {
                SwitchToAccount(account);
            }
        }];
}

@end

// MARK: - Long press on the avatar button

@interface NFBAccountPress : UILongPressGestureRecognizer
@end

@implementation NFBAccountPress
@end

@interface NFBAccountPressHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NFBAccountFan* fan;
@property (nonatomic, assign) BOOL moved;
@property (nonatomic, assign) CGPoint start;
+ (instancetype)shared;
@end

@implementation NFBAccountPressHandler

+ (instancetype)shared {
    static NFBAccountPressHandler* handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handler = [NFBAccountPressHandler new];
    });
    return handler;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    if (!BubblesOn() || !gesture.view.window || self.fan.superview) {
        return NO;
    }
    // With one account there is nothing to switch to; X's sheet can add one.
    return TwitterAccounts().count >= 2;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return NO;
}

// X's own long press (the account sheet) and the bar-wide settings long press
// wait for this one, so they do not fire when the circles open.
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer*)other {
    if (other == gesture || [other isKindOfClass:[NFBAccountPress class]]) {
        return NO;
    }
    NSString* name = NSStringFromClass(other.class);
    BOOL pressLike = [other isKindOfClass:[UILongPressGestureRecognizer class]] ||
                     [name containsString:@"LongPress"] || [name containsString:@"ContextMenu"] ||
                     [name containsString:@"Preview"];
    if (!pressLike || !other.view || !gesture.view) {
        return NO;
    }
    return [other.view isDescendantOfView:gesture.view] || [gesture.view isDescendantOfView:other.view];
}

- (void)pressed:(NFBAccountPress*)press {
    UIWindow* window = press.view.window;
    switch (press.state) {
        case UIGestureRecognizerStateBegan: {
            NSArray* accounts = TwitterAccounts();
            if (!window || accounts.count < 2) {
                return;
            }
            UIView* avatar = press.view;
            CGPoint origin = [avatar convertPoint:CGPointMake(CGRectGetMidX(avatar.bounds),
                                                              CGRectGetMidY(avatar.bounds))
                                           toView:window];
            if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
                UIImpactFeedbackGenerator* thump =
                    [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [thump impactOccurred];
            }
            self.fan = [[NFBAccountFan alloc] initWithFrame:window.bounds
                                                   accounts:accounts
                                                     origin:origin
                                                       safe:window.safeAreaInsets];
            [window addSubview:self.fan];
            self.start = [press locationInView:window];
            self.moved = NO;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint point = [press locationInView:window];
            if (hypot(point.x - self.start.x, point.y - self.start.y) > 12) {
                self.moved = YES;
            }
            [self.fan hoverAt:point];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            NFBAccountFan* fan = self.fan;
            self.fan = nil;
            if (fan.hovered) {
                [fan finishWith:fan.hovered];
            } else if (!self.moved) {
                [fan waitForTap];
            } else {
                [fan finishWith:nil];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.fan finishWith:nil];
            self.fan = nil;
            break;
        }
        default:
            break;
    }
}

@end

static BOOL LooksLikeAvatar(UIView* view) {
    NSString* name = NSStringFromClass(view.class);
    if ([name rangeOfString:@"Avatar" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return NO;
    }
    CGSize size = view.bounds.size;
    return !view.hidden && view.alpha > 0.01 && size.width >= 20 && size.width <= 64 && size.height >= 20 &&
           size.height <= 64;
}

// The view that should carry the press: the avatar's biggest small ancestor
// below the bar, preferring a control, that takes touches.
static UIView* PressHost(UIView* avatar, UINavigationBar* bar) {
    UIView* host = nil;
    UIView* control = nil;
    for (UIView* view = avatar; view && view != bar; view = view.superview) {
        CGSize size = view.bounds.size;
        if (size.width > 80 || size.height > 80) {
            break;
        }
        if (view.userInteractionEnabled) {
            host = view;
            if ([view isKindOfClass:[UIControl class]]) {
                control = view;
            }
        } else {
            host = nil;
        }
    }
    return control ?: host;
}

@interface NFBWeakView : NSObject
@property (nonatomic, weak) UIView* view;
@end

@implementation NFBWeakView
@end

static const void* kPressHostKey = &kPressHostKey;

static BOOL HasAccountPress(UIView* host) {
    for (UIGestureRecognizer* existing in host.gestureRecognizers) {
        if ([existing isKindOfClass:[NFBAccountPress class]]) {
            return YES;
        }
    }
    return NO;
}

static void AttachAccountPress(UINavigationBar* bar) {
    NFBWeakView* known = objc_getAssociatedObject(bar, kPressHostKey);
    if (known.view && [known.view isDescendantOfView:bar] && HasAccountPress(known.view)) {
        return;
    }
    UIView* found = nil;
    BOOL rtl = bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithArray:bar.subviews];
    NSInteger budget = 300;
    while (queue.count > 0 && budget-- > 0) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view.hidden) {
            continue;
        }
        if (LooksLikeAvatar(view)) {
            CGRect frame = [view convertRect:view.bounds toView:bar];
            BOOL leading = rtl ? CGRectGetMaxX(frame) > CGRectGetWidth(bar.bounds) - 96
                               : CGRectGetMinX(frame) < 96;
            if (leading) {
                found = view;
                break;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    UIView* host = found ? PressHost(found, bar) : nil;
    if (!host) {
        return;
    }
    if (!HasAccountPress(host)) {
        NFBAccountPressHandler* handler = [NFBAccountPressHandler shared];
        NFBAccountPress* press = [[NFBAccountPress alloc] initWithTarget:handler action:@selector(pressed:)];
        press.minimumPressDuration = 0.35;
        press.cancelsTouchesInView = YES;
        press.delegate = handler;
        [host addGestureRecognizer:press];
    }
    NFBWeakView* box = known ?: [NFBWeakView new];
    box.view = host;
    objc_setAssociatedObject(bar, kPressHostKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Catching X's account sheet
//
// On iOS 26 the avatar button lives in a SwiftUI platter, and the press above
// may never get the touch. So also watch for X presenting its account sheet
// (AccountSwitcherTrayContentViewController) while a finger has been held: skip
// the sheet and open the circles there instead, following the same finger.

static NSTimeInterval gTouchStart = 0;
static NSTimeInterval gTouchEnd = 0;
static CGPoint gTouchStartPoint;
static BOOL gTouchDown = NO;
static __weak UITouch* gTrackedTouch = nil;
static NFBAccountFan* gCaughtFan = nil;
static BOOL gCaughtMoved = NO;
static NSString* gBubbleLog = @"(no account sheet seen)";

NSString* NFBAccountBubblesDebugText(void) {
    NFBWeakView* known = nil;
    for (UIWindow* window in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
        NSInteger budget = 4000;
        while (queue.count > 0 && budget-- > 0 && !known) {
            UIView* view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([view isKindOfClass:[UINavigationBar class]]) {
                NFBWeakView* box = objc_getAssociatedObject(view, kPressHostKey);
                if (box.view) {
                    known = box;
                }
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
    return [NSString stringWithFormat:@"on=%d accounts=%lu pressHost=%@ last=%@%c%@", BubblesOn(),
                                      (unsigned long)TwitterAccounts().count,
                                      known.view ? NSStringFromClass(known.view.class) : @"(none)", gBubbleLog, 10,
                                      gProbeLog.count ? [gProbeLog componentsJoinedByString:@"\n"] : @"(no probes yet)"];
}

static BOOL IsAccountSheet(UIViewController* controller, NSInteger depth) {
    if (!controller || depth > 6) {
        return NO;
    }
    if ([NSStringFromClass(controller.class) containsString:@"AccountSwitcherTray"]) {
        return YES;
    }
    for (UIViewController* child in controller.childViewControllers) {
        if (IsAccountSheet(child, depth + 1)) {
            return YES;
        }
    }
    for (NSString* name in @[ @"viewControllers" ]) {
        id list = ObjectProp(controller, name);
        if ([list isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray*)list) {
                if ([item isKindOfClass:[UIViewController class]] && IsAccountSheet(item, depth + 1)) {
                    return YES;
                }
            }
        }
    }
    for (NSString* name in @[ @"rootViewController", @"contentViewController", @"topViewController" ]) {
        id item = ObjectProp(controller, name);
        if (item != controller && [item isKindOfClass:[UIViewController class]] && IsAccountSheet(item, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

// A held finger (not a quick tap) that is still down or only just lifted.
static BOOL FingerHeld(NSTimeInterval grace) {
    if (gTouchStart <= 0) {
        return NO;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!gTouchDown && now - gTouchEnd > grace) {
        return NO;
    }
    return (gTouchDown ? now : gTouchEnd) - gTouchStart >= 0.25;
}

static BOOL FanIsUp(void) {
    return [NFBAccountPressHandler shared].fan.superview != nil || gCaughtFan.superview != nil;
}

static BOOL OpenCaughtFan(UIWindow* window) {
    NSArray* accounts = TwitterAccounts();
    if (!window || accounts.count < 2) {
        return NO;
    }
    if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        UIImpactFeedbackGenerator* thump =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [thump impactOccurred];
    }
    NFBAccountFan* fan = [[NFBAccountFan alloc] initWithFrame:window.bounds
                                                     accounts:accounts
                                                       origin:gTouchStartPoint
                                                         safe:window.safeAreaInsets];
    [window addSubview:fan];
    if (gTouchDown) {
        gCaughtFan = fan;
        gCaughtMoved = NO;
    } else {
        [fan waitForTap];
    }
    return YES;
}

// The sheet X wanted to show is never presented, but its view can still be
// built off screen so its rows (and their unread badges) can be read.
static UIViewController* gOffscreenSheet = nil;

static void LayoutTree(UIView* view, NSInteger depth) {
    if (depth > 30) {
        return;
    }
    [view layoutIfNeeded];
    for (UIView* sub in view.subviews) {
        LayoutTree(sub, depth + 1);
    }
}

static void ReadCountsOffscreen(UIViewController* sheet, CGRect bounds) {
    if (!sheet || gOffscreenSheet) {
        return;
    }
    gOffscreenSheet = sheet;
    @try {
        sheet.view.frame = bounds;
        LayoutTree(sheet.view, 0);
        HarvestSheetCounts(sheet.view);
    } @catch (__unused NSException* exception) {
        ProbeNote(@"badge: building X's list off screen threw");
    }
    [gLiveFan refreshCounts];
    // Rows may fill in a moment later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            LayoutTree(sheet.view, 0);
            if (HarvestSheetCounts(sheet.view) == 0) {
                ProbeNote(@"badge: X's list had no rows off screen");
            }
        } @catch (__unused NSException* exception) {
        }
        [gLiveFan refreshCounts];
        gOffscreenSheet = nil;
    });
}

static void TrackTouches(UIWindow* window, UIEvent* event) {
    for (UITouch* touch in event.allTouches) {
        if (touch.phase == UITouchPhaseBegan && !gTouchDown) {
            gTrackedTouch = touch;
            gTouchDown = YES;
            gTouchStart = touch.timestamp;
            gTouchStartPoint = [touch locationInView:nil];
            continue;
        }
        if (touch != gTrackedTouch) {
            continue;
        }
        NFBAccountFan* fan = gCaughtFan;
        if (touch.phase == UITouchPhaseMoved && fan) {
            CGPoint point = [touch locationInView:fan];
            if (hypot(point.x - gTouchStartPoint.x, point.y - gTouchStartPoint.y) > 12) {
                gCaughtMoved = YES;
            }
            [fan hoverAt:point];
        } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
            gTouchDown = NO;
            gTouchEnd = NSProcessInfo.processInfo.systemUptime;
            gTrackedTouch = nil;
            gCaughtFan = nil;
            if (fan) {
                if (fan.hovered) {
                    [fan finishWith:fan.hovered];
                } else if (!gCaughtMoved && touch.phase == UITouchPhaseEnded) {
                    [fan waitForTap];
                } else {
                    [fan finishWith:nil];
                }
            }
        }
    }
}

%hook UINavigationBar

- (void)layoutSubviews {
    %orig;
    if (BubblesOn()) {
        AttachAccountPress(self);
    }
}

%end

%hook UIWindow

- (void)sendEvent:(UIEvent*)event {
    if (event.type == UIEventTypeTouches && BubblesOn()) {
        TrackTouches(self, event);
    }
    %orig;
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController*)controller
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    if (BubblesOn() && IsAccountSheet(controller, 0)) {
        BOOL held = FingerHeld(0.6);
        if (FanIsUp()) {
            gBubbleLog = @"sheet skipped, circles already up";
            return;
        }
        if (held) {
            UIWindow* window = self.view.window ?: UIApplication.sharedApplication.keyWindow;
            if (OpenCaughtFan(window)) {
                ReadCountsOffscreen(controller, window.bounds);
                gBubbleLog = [NSString stringWithFormat:@"sheet replaced by circles (from %@)",
                                                        NSStringFromClass(self.class)];
                return;
            }
        }
        gBubbleLog = [NSString stringWithFormat:@"sheet shown: held=%d accounts=%lu", held,
                                                (unsigned long)TwitterAccounts().count];
    }
    %orig;
}

// Fallback for a sheet that came up some other way than presentViewController.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!BubblesOn() || ![NSStringFromClass(self.class) containsString:@"AccountSwitcherTrayContent"]) {
        return;
    }
    // Whenever X's list is on screen, remember its unread numbers.
    HarvestSheetCounts(self.view);
    if (FanIsUp() || !FingerHeld(1.0) || TwitterAccounts().count < 2) {
        __weak UIView* weakView = self.view;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HarvestSheetCounts(weakView);
            [gLiveFan refreshCounts];
        });
        return;
    }
    UIViewController* top = self;
    while (top.parentViewController) {
        top = top.parentViewController;
    }
    UIWindow* window = top.presentingViewController.view.window ?: self.view.window;
    if (top.presentingViewController) {
        [top dismissViewControllerAnimated:NO completion:nil];
    }
    if (OpenCaughtFan(window)) {
        gBubbleLog = @"sheet closed after appearing, circles opened";
    }
}

%end
