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

static void RemoveBubble(UIView* bubble) {
    bubble.tag = 0;
    [UIView animateWithDuration:0.25
        animations:^{
            bubble.alpha = 0;
            bubble.transform = CGAffineTransformMakeScale(0.85, 0.85);
        }
        completion:^(BOOL finished) {
            [bubble removeFromSuperview];
        }];
}

static void RenderBubble(void) {
    NSString* text = gTransientText ?: gPersistentText;
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
    if (existing && [gShownText isEqualToString:text]) {
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
    CGFloat width = MIN(textWidth + 24 + kBubbleTail, available);

    NFBBubbleView* bubble = [[NFBBubbleView alloc]
        initWithFrame:CGRectMake(right - width, CGRectGetMidY(logoFrame) - kBubbleHeight / 2, width,
                                 kBubbleHeight)];
    bubble.tag = kBubbleTag;
    bubble.userInteractionEnabled = NO;

    CAShapeLayer* shape = [CAShapeLayer layer];
    shape.path = BubblePath(width, kBubbleHeight).CGPath;
    shape.fillColor = CurrentAccentColor().CGColor;
    [bubble.layer addSublayer:shape];

    label.frame = CGRectMake(12, 0, width - 24 - kBubbleTail, kBubbleHeight);
    [bubble addSubview:label];

    // Opens out of the logo: scales from the tail side.
    bubble.layer.anchorPoint = CGPointMake(1, 0.5);
    bubble.layer.position = CGPointMake(right, CGRectGetMidY(logoFrame));
    [window addSubview:bubble];

    if (existing) {
        // Just a change of words (or of the count): swapped in place.
        [existing removeFromSuperview];
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
    gShownText = text;
}

// MARK: Queue

static NSMutableArray<NSDictionary*>* gQueue;
static BOOL gShowing;

static void PumpQueue(void) {
    if (gShowing || gQueue.count == 0) {
        return;
    }
    NSDictionary* next = gQueue.firstObject;
    [gQueue removeObjectAtIndex:0];
    // Notices that waited too long are stale.
    if (-[next[@"at"] timeIntervalSinceNow] > 20) {
        PumpQueue();
        return;
    }
    gShowing = YES;
    gTransientText = next[@"text"];
    RenderBubble();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       gTransientText = nil;
                       RenderBubble();
                       gShowing = NO;
                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                                      dispatch_get_main_queue(), ^{
                                          PumpQueue();
                                      });
                   });
}

void NFBShowBubble(NSString* text) {
    if (!BubbleEnabled() || text.length == 0) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gQueue) {
            gQueue = [NSMutableArray array];
        }
        for (NSDictionary* queued in gQueue) {
            if ([queued[@"text"] isEqualToString:text]) {
                return;
            }
        }
        [gQueue addObject:@{@"text" : text, @"at" : [NSDate date]}];
        PumpQueue();
    });
}

// MARK: New tweets (stays until they have been scrolled past)

static __weak id gNewController;
static NSDictionary<NSString*, NSNumber*>* gNewIndex; // tweet id -> position in the list
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
    gPersistentText = nil;
    RenderBubble();
}

void NFBSetNewTweets(id controller, NSArray<NSString*>* entryIDs, NSUInteger count) {
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
            remaining = MIN(gNewCount, position.unsignedIntegerValue);
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

void NFBNoteRefreshStarted(void) {
    gRefreshAt = [NSDate date];
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

static void CheckBadges(UIWindow* window) {
    NSDictionary<NSString*, NSNumber*>* now = ScanBadges(window);
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
                NFBShowBubble([@"♪ " stringByAppendingString:title]);
            }
        }];
}

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
    UpdateNewTweets();
    CheckSpotify();
    if (gTicks % 8 == 0) {
        CheckBadges(window);
        CheckDDay();
    }
}

// MARK: Logo at the right end

static const void* kLogoShiftKey = &kLogoShiftKey;

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

    CGFloat shift = 0;
    if (BubbleEnabled()) {
        // Centre of the control with no transform, in window coordinates.
        CGPoint center = [parent convertPoint:control.center toView:window];
        // Mirrors the 44pt profile button that sits 20pt from the left edge.
        CGFloat target = CGRectGetWidth(window.bounds) - kEdgeMargin - 22;
        shift = target - center.x;
    }
    NSNumber* applied = objc_getAssociatedObject(control, kLogoShiftKey);
    if (fabs(shift - applied.doubleValue) < 0.5 && (applied || shift == 0)) {
        return;
    }
    control.transform = CGAffineTransformMakeTranslation(shift, 0);
    objc_setAssociatedObject(control, kLogoShiftKey, @(shift), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _UINavigationBarTitleControl

- (void)layoutSubviews {
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
