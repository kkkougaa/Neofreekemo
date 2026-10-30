//
//  HeaderBubble.x
//  NeoFreeBird
//

#import "Core/BHTEvents.h"
#import "Core/BHTSpotify.h"
#import "HookHelpers.h"

// MARK: - Header logo speech bubble

// The home logo sits at the right end of the top bar (mirroring the profile button) and
// "talks": a small accent-colored bubble opens in the empty space to its left with short
// notices. Everything here reads what the app already shows; the only network call is the
// optional Spotify now-playing check, which talks to Spotify and not to X.

extern UIImageView* HeaderLogoInWindow(UIWindow* window);
extern UIWindow* NFBKeyWindow(void);

static const NSInteger kBubbleTag = 0x4E464C42;
static const NSInteger kBubbleHostTag = 0x4E464C48;
static const CGFloat kBubbleHeight = 30.0;
static const CGFloat kBubbleTail = 8.0;
static const CGFloat kEdgeMargin = 20.0;
static const CGFloat kLeftLimit = 72.0; // profile button and a little air

static BOOL BubbleEnabled(void) {
    return [BHTSettings boolForKey:@"kemo_header_bubble"];
}

// MARK: Bubble view

@interface NFBBubbleView : UIView
@end

@implementation NFBBubbleView
@end

static UIBezierPath* BubblePath(CGFloat width, CGFloat height) {
    CGFloat bodyWidth = width - kBubbleTail;
    UIBezierPath* path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, bodyWidth, height)
                                                    cornerRadius:height / 2];
    // A soft, leaf-shaped tail pointing right at the logo.
    CGFloat midY = height / 2;
    UIBezierPath* tail = [UIBezierPath bezierPath];
    [tail moveToPoint:CGPointMake(bodyWidth - 7, midY - 7)];
    [tail addCurveToPoint:CGPointMake(width, midY + 1)
            controlPoint1:CGPointMake(bodyWidth - 1, midY - 6)
            controlPoint2:CGPointMake(bodyWidth + 4, midY - 3)];
    [tail addCurveToPoint:CGPointMake(bodyWidth - 7, midY + 7)
            controlPoint1:CGPointMake(bodyWidth + 3, midY + 4)
            controlPoint2:CGPointMake(bodyWidth - 1, midY + 7)];
    [tail closePath];
    [path appendPath:tail];
    return path;
}

// What the bubble says: a short notice (transient) wins over the new-tweets count.
static NSString* gTransientText;
static NSString* gPersistentText;
static NSString* gShownText;
static BOOL gTransientSpotify; // the notice is a song change: Spotify mark and floating notes

// The official Spotify mark, shipped as nfb_spotify_logo.png in the tweak bundle.
static UIImage* SpotifyMark(void) {
    NSURL* url = [[BHTBundle sharedBundle] pathForFile:@"nfb_spotify_logo.png"];
    UIImage* image = url ? [UIImage imageWithContentsOfFile:url.path] : nil;
    return image.CGImage ? [UIImage imageWithCGImage:image.CGImage
                                               scale:6.0
                                         orientation:UIImageOrientationUp]
                         : nil;
}

// One or two notes pop out to the left of the bubble and drift up, now and then.
static void FloatNote(UIWindow* window, CGFloat left, CGFloat midY, BOOL second) {
    UILabel* note = [UILabel new];
    note.text = second ? @"♫" : @"♪";
    note.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    note.textColor = CurrentAccentColor();
    [note sizeToFit];
    CGFloat sideways = MAX(0, MIN(18, left - 70));
    note.center = CGPointMake(left - 2, midY + (second ? 4 : -2));
    note.alpha = 0;
    note.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [window addSubview:note];

    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.5
          initialSpringVelocity:0
                        options:0
                     animations:^{
                         note.alpha = 1;
                         note.transform = CGAffineTransformMakeRotation(second ? 0.3 : -0.3);
                     }
                     completion:nil];
    [UIView animateWithDuration:0.9
        delay:0.25
        options:UIViewAnimationOptionCurveEaseOut
        animations:^{
            note.center = CGPointMake(left - 2 - sideways * (second ? 0.6 : 1.0),
                                      midY - (second ? 20 : 15));
            note.alpha = 0;
            note.transform = CGAffineTransformMakeRotation(second ? -0.2 : 0.2);
        }
        completion:^(BOOL finished) {
            [note removeFromSuperview];
        }];
}

static void StartNoteEffect(UIWindow* window, CGFloat left, CGFloat midY) {
    static const double times[] = {0.25, 0.95, 1.65, 2.35, 3.05, 3.75};
    for (int i = 0; i < 6; i++) {
        BOOL second = i % 2 == 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(times[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (gTransientSpotify && [window viewWithTag:kBubbleTag]) {
                               FloatNote(window, left, midY, second);
                           }
                       });
    }
}

// The bubble lives inside a host strip that follows the logo: when the top bar slides away
// or fades while scrolling, the host moves and fades with it.
@interface NFBBubbleFollow : NSObject
@property (nonatomic, strong) CADisplayLink* link;
@property (nonatomic, weak) UIView* host;
@property (nonatomic, weak) UIView* logo;
@property (nonatomic, assign) CGFloat baseLogoX;
@property (nonatomic, assign) CGFloat baseHostX;
@end

@implementation NFBBubbleFollow

- (void)step:(CADisplayLink*)link {
    UIView* host = self.host;
    UIView* logo = self.logo;
    UIWindow* window = host.window;
    if (!host || !logo || !logo.window || !window) {
        [self stop];
        [host removeFromSuperview];
        return;
    }
    CGFloat alpha = 1;
    for (UIView* view = logo; view; view = view.superview) {
        if (view.hidden) {
            alpha = 0;
            break;
        }
        alpha *= view.alpha;
    }
    CGRect logoFrame = [window convertRect:logo.bounds fromView:logo];
    host.alpha = alpha;
    host.center = CGPointMake(self.baseHostX + (CGRectGetMidX(logoFrame) - self.baseLogoX),
                              CGRectGetMidY(logoFrame));
}

- (void)attachHost:(UIView*)host logo:(UIView*)logo {
    self.host = host;
    self.logo = logo;
    UIWindow* window = host.window;
    self.baseLogoX = window ? CGRectGetMidX([window convertRect:logo.bounds fromView:logo]) : 0;
    self.baseHostX = host.center.x;
    if (!self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)stop {
    [self.link invalidate];
    self.link = nil;
}

@end

static NFBBubbleFollow* gFollow;

static void RemoveHostOf(UIView* bubble) {
    UIView* host = bubble.superview;
    [(host.tag == kBubbleHostTag ? host : bubble) removeFromSuperview];
}

static void RemoveBubble(UIView* bubble) {
    bubble.tag = 0;
    UIWindow* window = bubble.window;
    [UIView animateWithDuration:0.375
        animations:^{
            bubble.alpha = 0;
            bubble.transform = CGAffineTransformMakeScale(0.85, 0.85);
        }
        completion:^(BOOL finished) {
            RemoveHostOf(bubble);
            if (![window viewWithTag:kBubbleHostTag]) {
                [gFollow stop];
            }
        }];
}

static void RenderBubble(void) {
    // A notice and the new-tweets count at the same time share one bubble.
    NSString* text = (gTransientText && gPersistentText)
                         ? [NSString stringWithFormat:@"%@ · %@", gPersistentText, gTransientText]
                         : (gTransientText ?: gPersistentText);
    UIWindow* window = NFBKeyWindow();
    UIImageView* logo = window ? HeaderLogoInWindow(window) : nil;
    UIView* existing = [window viewWithTag:kBubbleTag];

    if (text.length == 0 || !logo || !logo.window) {
        if (existing) {
            RemoveBubble(existing);
        }
        gShownText = nil;
        return;
    }
    BOOL withMark = gTransientText && gTransientSpotify;
    NSString* shownKey = [NSString stringWithFormat:@"%@|%d", text, withMark];
    if (existing && [gShownText isEqualToString:shownKey]) {
        return;
    }

    CGRect logoFrame = [window convertRect:logo.bounds fromView:logo];
    CGFloat right = CGRectGetMinX(logoFrame) - 6;
    CGFloat available = right - kLeftLimit;
    if (available < 60) {
        return;
    }

    UILabel* label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor whiteColor];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    CGFloat textWidth = ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, kBubbleHeight)].width);
    // The Spotify mark takes the place of the music note in front of the title.
    CGFloat markSpace = withMark ? 24 : 0;
    CGFloat width = MIN(textWidth + 24 + markSpace + kBubbleTail, available);

    NFBBubbleView* bubble = [[NFBBubbleView alloc]
        initWithFrame:CGRectMake(right - width, 0, width, kBubbleHeight)];
    bubble.tag = kBubbleTag;
    bubble.userInteractionEnabled = NO;

    CAShapeLayer* shape = [CAShapeLayer layer];
    shape.path = BubblePath(width, kBubbleHeight).CGPath;
    shape.fillColor = CurrentAccentColor().CGColor;
    [bubble.layer addSublayer:shape];

    label.frame = CGRectMake(12 + markSpace, 0, width - 24 - markSpace - kBubbleTail, kBubbleHeight);
    [bubble addSubview:label];
    if (withMark) {
        UIImageView* mark = [[UIImageView alloc] initWithImage:SpotifyMark()];
        mark.frame = CGRectMake(10, (kBubbleHeight - 18) / 2, 18, 18);
        [bubble addSubview:mark];
    }

    // Opens out of the logo: scales from the tail side.
    bubble.layer.anchorPoint = CGPointMake(1, 0.5);
    bubble.layer.position = CGPointMake(right, kBubbleHeight / 2);

    // A strip across the screen at the logo's height that carries the bubble.
    UIView* host = [[UIView alloc]
        initWithFrame:CGRectMake(0, CGRectGetMidY(logoFrame) - kBubbleHeight / 2,
                                 CGRectGetWidth(window.bounds), kBubbleHeight)];
    host.tag = kBubbleHostTag;
    host.userInteractionEnabled = NO;
    [host addSubview:bubble];
    [window addSubview:host];
    if (!gFollow) {
        gFollow = [NFBBubbleFollow new];
    }
    [gFollow attachHost:host logo:logo];

    if (existing) {
        // Just a change of words (or of the count): swapped in place.
        RemoveHostOf(existing);
    } else {
        bubble.alpha = 0;
        bubble.transform = CGAffineTransformMakeScale(0.6, 0.6);
        [UIView animateWithDuration:0.35
                              delay:0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0
                            options:0
                         animations:^{
                             bubble.alpha = 1;
                             bubble.transform = CGAffineTransformIdentity;
                         }
                         completion:nil];
    }
    gShownText = shownKey;
    if (withMark && !existing) {
        StartNoteEffect(window, right - width, CGRectGetMidY(logoFrame));
    }
}

// MARK: Queue

static NSMutableArray<NSDictionary*>* gQueue;
static BOOL gShowing;

static void PumpQueue(void) {
    if (gShowing || gQueue.count == 0) {
        return;
    }
    // Everything waiting is said in one go ("새 DM 2건 · 새 알림 3건"); stale notices drop.
    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    BOOL spotify = NO;
    for (NSDictionary* queued in gQueue) {
        if (-[queued[@"at"] timeIntervalSinceNow] <= 20 && parts.count < 3) {
            [parts addObject:queued[@"text"]];
            spotify = spotify || [queued[@"icon"] isEqualToString:@"spotify"];
        }
    }
    [gQueue removeAllObjects];
    if (parts.count == 0) {
        return;
    }
    gShowing = YES;
    gTransientText = [parts componentsJoinedByString:@" · "];
    gTransientSpotify = spotify;
    RenderBubble();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       gTransientText = nil;
                       gTransientSpotify = NO;
                       RenderBubble();
                       gShowing = NO;
                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                                      dispatch_get_main_queue(), ^{
                                          PumpQueue();
                                      });
                   });
}

void NFBShowBubbleWithIcon(NSString* text, NSString* icon) {
    if (!BubbleEnabled() || text.length == 0) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // The same words are not repeated within two minutes.
        static NSMutableDictionary<NSString*, NSDate*>* recent;
        if (!recent) {
            recent = [NSMutableDictionary dictionary];
        }
        NSDate* said = recent[text];
        if (said && -[said timeIntervalSinceNow] < 120) {
            return;
        }
        recent[text] = [NSDate date];
        if (!gQueue) {
            gQueue = [NSMutableArray array];
        }
        for (NSDictionary* queued in gQueue) {
            if ([queued[@"text"] isEqualToString:text]) {
                return;
            }
        }
        [gQueue addObject:@{@"text" : text, @"at" : [NSDate date], @"icon" : icon ?: @""}];
        // A short wait so notices that arrive together are shown together.
        static BOOL pumpScheduled;
        if (!pumpScheduled) {
            pumpScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               pumpScheduled = NO;
                               PumpQueue();
                           });
        }
    });
}

void NFBShowBubble(NSString* text) {
    NFBShowBubbleWithIcon(text, nil);
}

// MARK: New tweets (stays until they have been scrolled past)

static __weak id gNewController;
static NSDictionary<NSString*, NSNumber*>* gNewIndex; // tweet id -> position in the list
static NSArray<NSNumber*>* gNewPositions;               // positions of the new tweets
static NSUInteger gNewCount;
static NSUInteger gNewShown;
static NSDate* gNewAt;

static NSString* NewTweetsText(NSUInteger count) {
    return [NSString stringWithFormat:@"새 트윗 %lu건", (unsigned long)count];
}

static void ClearNewTweets(void) {
    gNewCount = 0;
    gNewShown = 0;
    gNewController = nil;
    gNewIndex = nil;
    gNewPositions = nil;
    gPersistentText = nil;
    RenderBubble();
}

void NFBSetNewTweets(id controller, NSArray<NSString*>* entryIDs, NSArray<NSNumber*>* positions) {
    NSUInteger count = positions.count;
    if (!BubbleEnabled() || ![BHTSettings boolForKey:@"kemo_bubble_new_tweets"] || count == 0) {
        return;
    }
    NSMutableDictionary<NSString*, NSNumber*>* index = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < entryIDs.count; i++) {
        NSString* entryID = entryIDs[i];
        index[[entryID hasPrefix:@"tweet-"] ? [entryID substringFromIndex:6] : entryID] = @(i);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        gNewController = controller;
        gNewIndex = index;
        gNewPositions = positions;
        gNewCount = count;
        gNewShown = count;
        gNewAt = [NSDate date];
        gPersistentText = NewTweetsText(count);
        RenderBubble();
    });
}

// How many of the new tweets are still above the screen: at the very top it is none,
// otherwise the position of the first tweet in view.
static void UpdateNewTweets(void) {
    if (gNewCount == 0) {
        return;
    }
    if (-[gNewAt timeIntervalSinceNow] > 600) {
        ClearNewTweets();
        return;
    }
    UITableView* table = [gNewController valueForKey:@"tableView"];
    if (![table isKindOfClass:[UITableView class]] || !table.window) {
        return;
    }

    NSUInteger remaining = gNewCount;
    CGFloat top = table.contentOffset.y + table.adjustedContentInset.top;
    if (top <= 4) {
        remaining = 0;
    } else {
        CGFloat best = CGFLOAT_MAX;
        NSNumber* position = nil;
        for (UITableViewCell* cell in table.visibleCells) {
            NSNumber* index = gNewIndex[cell.accessibilityIdentifier ?: @""];
            if (index && CGRectGetMaxY(cell.frame) > top && CGRectGetMinY(cell.frame) < best) {
                best = CGRectGetMinY(cell.frame);
                position = index;
            }
        }
        if (position) {
            // New tweets above the first one in view (they need not be all at the top).
            remaining = 0;
            for (NSNumber* newPosition in gNewPositions) {
                if (newPosition.unsignedIntegerValue < position.unsignedIntegerValue) {
                    remaining++;
                }
            }
        }
    }

    if (remaining == gNewShown) {
        return;
    }
    gNewShown = remaining;
    if (remaining == 0) {
        ClearNewTweets();
    } else {
        gPersistentText = NewTweetsText(remaining);
        RenderBubble();
    }
}

// MARK: Refresh marker

static NSDate* gRefreshAt;
static NSUInteger gRefreshGeneration;

void NFBNoteRefreshStarted(void) {
    gRefreshAt = [NSDate date];
    gRefreshGeneration++;
}

// Which pull the current refresh belongs to (every pull gets its own number).
NSUInteger NFBRefreshGeneration(void) {
    return gRefreshGeneration;
}

BOOL NFBRefreshWasRecent(void) {
    return gRefreshAt && -[gRefreshAt timeIntervalSinceNow] < 15;
}

// MARK: Tab bar badges

static NSInteger FirstInteger(NSString* text) {
    if (text.length == 0) {
        return 0;
    }
    NSScanner* scanner = [NSScanner scannerWithString:text];
    NSCharacterSet* digits = [NSCharacterSet decimalDigitCharacterSet];
    [scanner scanUpToCharactersFromSet:digits intoString:nil];
    NSInteger value = 0;
    return [scanner scanInteger:&value] ? value : 0;
}

// Unread counts the tab bar exposes through accessibility, keyed "dm" / "notifications".
static NSDictionary<NSString*, NSNumber*>* ScanBadges(UIWindow* window) {
    NSArray* dmWords = @[ @"쪽지", @"메시지", @"DM", @"Messages", @"Message", @"メッセージ", @"チャット" ];
    NSArray* notificationWords = @[ @"알림", @"Notifications", @"通知", @"お知らせ" ];
    NSMutableDictionary<NSString*, NSNumber*>* found = [NSMutableDictionary dictionary];
    CGFloat bottomEdge = CGRectGetHeight(window.bounds) - 160;

    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 6000) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        NSString* label = view.accessibilityLabel;
        if (label.length > 0 && view.window &&
            CGRectGetMinY([window convertRect:view.bounds fromView:view]) > bottomEdge) {
            NSString* kind = nil;
            for (NSString* word in dmWords) {
                if ([label localizedCaseInsensitiveContainsString:word]) {
                    kind = @"dm";
                }
            }
            for (NSString* word in notificationWords) {
                if (!kind && [label localizedCaseInsensitiveContainsString:word]) {
                    kind = @"notifications";
                }
            }
            if (kind) {
                NSString* source = view.accessibilityValue.length > 0 ? view.accessibilityValue : label;
                NSInteger count = FirstInteger(source);
                if (!found[kind] || count > [found[kind] integerValue]) {
                    found[kind] = @(count);
                }
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return found;
}

static NSMutableDictionary<NSString*, NSNumber*>* gBadgeLast;
static NSString* gAccountKey;

// Identity of the account in use, to notice a switch.
static NSString* CurrentAccountKey(void) {
    Class hostClass = NSClassFromString(@"T1HostViewController");
    if (![hostClass respondsToSelector:@selector(sharedHostViewController)]) {
        return nil;
    }
    id host = [hostClass performSelector:@selector(sharedHostViewController)];
    if (![host respondsToSelector:@selector(currentAccount)]) {
        return nil;
    }
    id account = [host performSelector:@selector(currentAccount)];
    // Something that stays the same for the same account; the object's address does not
    // (it can be a fresh object every call), so without a real id there is no switch check.
    for (NSString* key in @[ @"userID", @"accountID", @"userIdentifier", @"screenName", @"username" ]) {
        if (![account respondsToSelector:NSSelectorFromString(key)]) {
            continue;
        }
        id value = [account valueForKey:key];
        if (value && [[value description] length] > 0 && ![[value description] isEqualToString:@"0"]) {
            return [value description];
        }
    }
    return nil;
}

static void CheckBadges(UIWindow* window) {
    NSDictionary<NSString*, NSNumber*>* now = ScanBadges(window);
    NSString* accountKey = CurrentAccountKey();
    BOOL switched = gAccountKey && accountKey && ![gAccountKey isEqualToString:accountKey];
    gAccountKey = accountKey ?: gAccountKey;
    if (switched) {
        // The other account's unread counts are all news: count them from zero.
        gBadgeLast = [@{@"dm" : @0, @"notifications" : @0} mutableCopy];
    }
    if (!gBadgeLast) {
        gBadgeLast = [now mutableCopy];
        return;
    }
    for (NSString* kind in now) {
        NSInteger count = [now[kind] integerValue];
        NSInteger last = [gBadgeLast[kind] integerValue];
        if (gBadgeLast[kind] && count > last && [BHTSettings boolForKey:@"kemo_bubble_notifications"]) {
            NSString* text = [kind isEqualToString:@"dm"]
                                 ? [NSString stringWithFormat:@"새 DM %ld건", (long)(count - last)]
                                 : [NSString stringWithFormat:@"새 알림 %ld건", (long)(count - last)];
            NFBShowBubble(text);
        }
        gBadgeLast[kind] = @(count);
    }
}

// MARK: D-day

static void CheckDDay(void) {
    if (![BHTSettings boolForKey:@"kemo_bubble_dday"]) {
        return;
    }
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd";
    NSString* today = [formatter stringFromDate:[NSDate date]];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([[defaults stringForKey:@"nfb_bubble_dday_day"] isEqualToString:today]) {
        return;
    }

    UIWindow* window = NFBKeyWindow();
    if (!window || !HeaderLogoInWindow(window)) {
        return;
    }
    [defaults setObject:today forKey:@"nfb_bubble_dday_day"];

    for (NSDictionary* event in [BHTEvents upcoming:4]) {
        NSDate* date = [NSDate dateWithTimeIntervalSince1970:[event[@"time"] doubleValue]];
        NSInteger days = [BHTEvents daysUntil:date];
        if (days == 0) {
            NFBShowBubble([NSString stringWithFormat:@"오늘 D-Day · %@", event[@"name"]]);
        } else if (days == 1) {
            NFBShowBubble([NSString stringWithFormat:@"내일 D-1 · %@", event[@"name"]]);
        }
    }
}

// MARK: Spotify

static NSString* gLastTrack;
static NSDate* gSpotifyAt;

static void CheckSpotify(void) {
    NSInteger interval = MAX([BHTSettings integerForKey:@"kemo_bubble_spotify_interval"], 5);
    if (![BHTSettings boolForKey:@"kemo_bubble_spotify"] || ![BHTSpotify shared].isConnected ||
        (gSpotifyAt && -[gSpotifyAt timeIntervalSinceNow] < interval)) {
        return;
    }
    UIWindow* window = NFBKeyWindow();
    if (!window || !HeaderLogoInWindow(window)) {
        return;
    }
    gSpotifyAt = [NSDate date];
    [[BHTSpotify shared]
        fetchCurrentlyPlaying:^(NSString* title, NSString* artist, NSString* shareURL, NSError* error) {
            if (error || title.length == 0) {
                return;
            }
            NSString* track = [NSString stringWithFormat:@"%@|%@", title, artist ?: @""];
            BOOL changed = gLastTrack && ![gLastTrack isEqualToString:track];
            gLastTrack = track;
            if (changed) {
                NFBShowBubbleWithIcon(title, @"spotify");
            }
        }];
}

static void ApplyLogoShift(UIView* control);

// MARK: Tick

static NSUInteger gTicks;

// Twice a second: the cheap checks every time, the heavier ones every few seconds.
static void Tick(void) {
    if (!BubbleEnabled() ||
        [UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }
    UIWindow* window = NFBKeyWindow();
    if (!window) {
        return;
    }
    gTicks++;
    UIImageView* headerLogo = HeaderLogoInWindow(window);
    if (headerLogo) {
        ApplyLogoShift(headerLogo.superview.superview);
    }
    UpdateNewTweets();
    CheckSpotify();
    if (gTicks % 8 == 0) {
        CheckBadges(window);
        CheckDDay();
    }
}

// MARK: Logo at the right end

// The logo is drawn a little larger than the 32pt it is laid out at, to sit with the 44pt
// profile button on the left.
static const CGFloat kLogoSize = 40.0;
static const CGFloat kLogoLaidOut = 32.0;

static void ApplyLogoShift(UIView* control) {
    UIWindow* window = control.window;
    UIView* parent = control.superview;
    if (!window || !parent) {
        return;
    }

    UIImageView* logo = nil;
    for (UIView* sub in control.subviews) {
        NSMutableArray<UIView*>* stack = [NSMutableArray arrayWithObject:sub];
        while (stack.count > 0 && !logo) {
            UIView* view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:[UIImageView class]] && CGRectGetWidth(view.bounds) >= 24 &&
                CGRectGetWidth(view.bounds) <= 40 && ((UIImageView*)view).image) {
                logo = (UIImageView*)view;
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
    if (!logo) {
        return;
    }

    BOOL enabled = BubbleEnabled();
    CGFloat shift = 0;
    CGFloat scale = 1;
    if (enabled) {
        // Measured inside the navigation bar, not the window: while the side drawer slides
        // the whole screen sideways, but the bar's own coordinates stay put.
        UIView* reference = parent;
        while (reference && ![reference isKindOfClass:[UINavigationBar class]]) {
            reference = reference.superview;
        }
        reference = reference ?: window;
        // Centre of the control with no transform.
        CGPoint center = [parent convertPoint:control.center toView:reference];
        // Mirrors the 44pt profile button that sits 20pt from the left edge.
        CGFloat target = CGRectGetWidth(reference.bounds) - kEdgeMargin - 22;
        shift = target - center.x;
        scale = kLogoSize / kLogoLaidOut;
    }

    // Compared against the live transform: UIKit resets it on its own now and then.
    CGAffineTransform wanted =
        CGAffineTransformScale(CGAffineTransformMakeTranslation(shift, 0), scale, scale);
    if (!CGAffineTransformEqualToTransform(control.transform, wanted) &&
        !(fabs(control.transform.tx - shift) < 0.5 && fabs(control.transform.a - scale) < 0.01)) {
        control.transform = wanted;
    }
}

%hook _UINavigationBarTitleControl

- (void)layoutSubviews {
    %orig;
    ApplyLogoShift(self);
}

- (void)setCenter:(CGPoint)center {
    %orig;
    ApplyLogoShift(self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    ApplyLogoShift(self);
}

- (void)didMoveToWindow {
    %orig;
    ApplyLogoShift(self);
}

%end

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
                    static NSTimer* timer;
                    if (!timer) {
                        timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                                repeats:YES
                                                                  block:^(NSTimer* t) {
                                                                      Tick();
                                                                  }];
                    }
                }];
}
