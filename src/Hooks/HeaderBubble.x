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
extern UIImage* NFBRenderLogoSVG(NSString* fileName, CGSize size, UIColor* color);

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
// Set when the bubble shows the new-tweets count: the number gets its own label so it can
// roll to the next value.
@property (nonatomic, strong) UILabel* numberLabel;
@property (nonatomic, assign) NSUInteger digitCount;
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
static NSUInteger gNewShown; // how many new tweets are still above the screen
static NSString* gShownText;
static BOOL gTransientSpotify; // the notice is a song change: Spotify mark and floating notes
static NSString* gTransientSymbol; // otherwise: SF Symbol name for a notice, or nil

// The official Spotify mark, shipped as nfb_spotify_logo.png in the tweak bundle.
static UIImage* SpotifyMark(void) {
    NSURL* url = [[BHTBundle sharedBundle] pathForFile:@"nfb_spotify_logo.png"];
    UIImage* image = url ? [UIImage imageWithContentsOfFile:url.path] : nil;
    return image.CGImage ? [UIImage imageWithCGImage:image.CGImage
                                               scale:6.0
                                         orientation:UIImageOrientationUp]
                         : nil;
}

// A note pops out like jelly, sways up and to the left, then goes "pop" in a few sparkles.
static void SparkleBurst(UIWindow* window, CGPoint at) {
    UIColor* color = CurrentAccentColor();
    for (int i = 0; i < 5; i++) {
        CGFloat angle = (M_PI * 2 / 5) * i + 0.4;
        UIView* dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, i % 2 ? 3 : 4.5, i % 2 ? 3 : 4.5)];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = CGRectGetWidth(dot.bounds) / 2;
        dot.center = at;
        dot.alpha = 1;
        [window addSubview:dot];
        CGFloat distance = 9 + (i % 2) * 4;
        [UIView animateWithDuration:0.4
            delay:0
            options:UIViewAnimationOptionCurveEaseOut
            animations:^{
                dot.center = CGPointMake(at.x + cos(angle) * distance, at.y + sin(angle) * distance);
                dot.alpha = 0;
                dot.transform = CGAffineTransformMakeScale(0.2, 0.2);
            }
            completion:^(BOOL finished) {
                [dot removeFromSuperview];
            }];
    }
}

static void FloatNote(UIWindow* window, CGFloat left, CGFloat midY, BOOL second) {
    UILabel* note = [UILabel new];
    note.text = second ? @"♫" : @"♪";
    note.font = [UIFont systemFontOfSize:second ? 12 : 14 weight:UIFontWeightHeavy];
    note.textColor = CurrentAccentColor();
    [note sizeToFit];
    CGFloat sideways = MAX(0, MIN(34, left - 64));
    CGPoint start = CGPointMake(left - 8, midY + (second ? 3 : -3));
    CGPoint end = CGPointMake(start.x - sideways * (second ? 0.7 : 1.0), midY - (second ? 19 : 14));
    note.center = start;
    note.alpha = 0;
    [window addSubview:note];

    // Jelly pop: it overshoots, squashes, and settles, with a little wobble.
    CAKeyframeAnimation* jelly = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    jelly.values = @[ @0.0, @1.4, @0.82, @1.12, @0.96, @1.0 ];
    jelly.keyTimes = @[ @0, @0.28, @0.5, @0.7, @0.85, @1 ];
    CAKeyframeAnimation* wobble = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
    CGFloat tilt = second ? 0.35 : -0.35;
    wobble.values = @[ @(tilt * 2), @(-tilt), @(tilt * 0.6), @(-tilt * 0.3), @0 ];
    wobble.keyTimes = @[ @0, @0.3, @0.55, @0.8, @1 ];
    CAAnimationGroup* pop = [CAAnimationGroup animation];
    pop.animations = @[ jelly, wobble ];
    pop.duration = 0.55;
    note.alpha = 1;
    [note.layer addAnimation:pop forKey:@"pop"];

    // Drifts along a soft curve while bobbing.
    UIBezierPath* path = [UIBezierPath bezierPath];
    [path moveToPoint:start];
    [path addCurveToPoint:end
            controlPoint1:CGPointMake(start.x + 3, start.y - 10)
            controlPoint2:CGPointMake(end.x + (second ? -4 : 5), end.y + 8)];
    CAKeyframeAnimation* drift = [CAKeyframeAnimation animationWithKeyPath:@"position"];
    drift.path = path.CGPath;
    drift.duration = 1.0;
    drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    drift.fillMode = kCAFillModeForwards;
    drift.removedOnCompletion = NO;
    [note.layer addAnimation:drift forKey:@"drift"];

    // Then it swells for an instant and bursts.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [UIView animateWithDuration:0.12
                           animations:^{
                               note.transform = CGAffineTransformMakeScale(1.5, 1.5);
                           }
                           completion:^(BOOL finished) {
                               [note.layer removeAllAnimations];
                               [note removeFromSuperview];
                               SparkleBurst(window, end);
                           }];
                   });
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
    // A small swell first, then it shrinks away.
    [UIView animateWithDuration:0.15
        delay:0
        options:UIViewAnimationOptionCurveEaseOut
        animations:^{
            bubble.transform = CGAffineTransformMakeScale(1.08, 1.08);
        }
        completion:^(BOOL swelled) {
            [UIView animateWithDuration:0.375
                delay:0
                options:UIViewAnimationOptionCurveEaseIn
                animations:^{
                    bubble.alpha = 0;
                    bubble.transform = CGAffineTransformMakeScale(0.8, 0.8);
                }
                completion:^(BOOL finished) {
                    RemoveHostOf(bubble);
                    if (![window viewWithTag:kBubbleHostTag]) {
                        [gFollow stop];
                    }
                }];
        }];
}

// The logo blinks once as the bubble opens: the eye is squashed for a moment (a second
// bundled drawing with the eye closed), then the normal logo is back. Nothing runs
// between bubbles.
static void BlinkLogo(UIImageView* logo) {
    if (!logo.image || [logo viewWithTag:0x4E464C44]) {
        return; // the loading dots own the logo image right now
    }
    UIColor* color = logo.tintColor ?: CurrentAccentColor();
    UIImage* closed = NFBRenderLogoSVG(@"logo_blink.svg", logo.bounds.size, color);
    if (!closed) {
        return;
    }
    UIImage* open = logo.image;
    __weak UIImageView* weakLogo = logo;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIImageView* current = weakLogo;
                       if (!current || current.image != open || [current viewWithTag:0x4E464C44]) {
                           return;
                       }
                       current.image = closed;
                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.13 * NSEC_PER_SEC)),
                                      dispatch_get_main_queue(), ^{
                                          if (current.image == closed) {
                                              current.image = open;
                                          }
                                      });
                   });
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
    BOOL withSpotify = gTransientText && gTransientSpotify;
    NSString* symbol = (gTransientText && !gTransientSpotify) ? gTransientSymbol : nil;
    BOOL withMark = withSpotify || symbol.length > 0;
    NSString* shownKey = [NSString stringWithFormat:@"%@|%d|%@", text, withSpotify, symbol ?: @""];
    if (existing && [gShownText isEqualToString:shownKey]) {
        return;
    }

    // The count on its own (no notice mixed in) rolls from one number to the next.
    BOOL splitMode = !gTransientText && gPersistentText.length > 0 && gNewShown > 0;
    NSString* numberText = splitMode ? [NSString stringWithFormat:@"%lu", (unsigned long)gNewShown] : nil;
    if (existing && splitMode && [existing isKindOfClass:[NFBBubbleView class]]) {
        NFBBubbleView* current = (NFBBubbleView*)existing;
        if (current.numberLabel && current.digitCount == numberText.length) {
            NSString* oldText = current.numberLabel.text;
            if (![oldText isEqualToString:numberText]) {
                CATransition* roll = [CATransition animation];
                roll.type = kCATransitionPush;
                roll.subtype = numberText.integerValue < oldText.integerValue ? kCATransitionFromTop
                                                                              : kCATransitionFromBottom;
                roll.duration = 0.32;
                roll.timingFunction =
                    [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [current.numberLabel.layer addAnimation:roll forKey:@"roll"];
                current.numberLabel.text = numberText;
            }
            gShownText = shownKey;
            return;
        }
    }

    CGRect logoFrame = [window convertRect:logo.bounds fromView:logo];
    CGFloat right = CGRectGetMinX(logoFrame) - 6;
    CGFloat available = right - kLeftLimit;
    if (available < 60) {
        return;
    }

    UIFont* font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    UILabel* label = [UILabel new];
    UILabel* prefixLabel = nil;
    UILabel* numberLabel = nil;
    UILabel* suffixLabel = nil;
    CGFloat prefixWidth = 0;
    CGFloat numberWidth = 0;
    CGFloat suffixWidth = 0;
    CGFloat textWidth = 0;
    if (splitMode) {
        prefixLabel = [UILabel new];
        prefixLabel.text = @"새 트윗 ";
        prefixLabel.font = font;
        numberLabel = [UILabel new];
        numberLabel.text = numberText;
        numberLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
        numberLabel.clipsToBounds = YES;
        suffixLabel = [UILabel new];
        suffixLabel.text = @"건";
        suffixLabel.font = font;
        for (UILabel* part in @[ prefixLabel, numberLabel, suffixLabel ]) {
            part.textColor = [UIColor whiteColor];
        }
        prefixWidth = ceil([prefixLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, kBubbleHeight)].width);
        numberWidth = ceil([numberLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, kBubbleHeight)].width);
        suffixWidth = ceil([suffixLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, kBubbleHeight)].width);
        textWidth = prefixWidth + numberWidth + suffixWidth;
    } else {
        label.text = text;
        label.font = font;
        label.textColor = [UIColor whiteColor];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        textWidth = ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, kBubbleHeight)].width);
    }
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

    if (splitMode) {
        prefixLabel.frame = CGRectMake(12, 0, prefixWidth, kBubbleHeight);
        numberLabel.frame = CGRectMake(12 + prefixWidth, 0, numberWidth, kBubbleHeight);
        suffixLabel.frame = CGRectMake(12 + prefixWidth + numberWidth, 0, suffixWidth, kBubbleHeight);
        [bubble addSubview:prefixLabel];
        [bubble addSubview:numberLabel];
        [bubble addSubview:suffixLabel];
        bubble.numberLabel = numberLabel;
        bubble.digitCount = numberText.length;
    } else {
        label.frame = CGRectMake(12 + markSpace, 0, width - 24 - markSpace - kBubbleTail, kBubbleHeight);
        [bubble addSubview:label];
    }
    if (withMark) {
        UIImage* markImage = SpotifyMark();
        if (!withSpotify) {
            UIImageSymbolConfiguration* config =
                [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
            markImage = [[UIImage systemImageNamed:symbol withConfiguration:config]
                imageWithTintColor:[UIColor whiteColor]
                     renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
        UIImageView* mark = [[UIImageView alloc] initWithImage:markImage];
        mark.contentMode = UIViewContentModeScaleAspectFit;
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
        if ([BHTSettings boolForKey:@"kemo_haptics"]) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft] impactOccurred];
        }
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
    if (withSpotify && !existing) {
        StartNoteEffect(window, right - width, CGRectGetMidY(logoFrame));
    }
    if (!existing) {
        BlinkLogo(logo);
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
    NSMutableSet<NSString*>* icons = [NSMutableSet set];
    for (NSDictionary* queued in gQueue) {
        if (-[queued[@"at"] timeIntervalSinceNow] <= 20 && parts.count < 3) {
            [parts addObject:queued[@"text"]];
            spotify = spotify || [queued[@"icon"] isEqualToString:@"spotify"];
            [icons addObject:queued[@"icon"] ?: @""];
        }
    }
    [gQueue removeAllObjects];
    if (parts.count == 0) {
        return;
    }
    gShowing = YES;
    gTransientText = [parts componentsJoinedByString:@" · "];
    gTransientSpotify = spotify;
    // One kind of notice keeps its own icon; a mix of kinds shows none.
    NSString* only = icons.count == 1 ? icons.anyObject : nil;
    gTransientSymbol = [only isEqualToString:@"dm"]         ? @"envelope.fill"
                       : [only isEqualToString:@"bell"]     ? @"bell.fill"
                       : [only isEqualToString:@"calendar"] ? @"calendar"
                                                            : nil;
    RenderBubble();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       gTransientText = nil;
                       gTransientSpotify = NO;
                       gTransientSymbol = nil;
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
    NSArray* dmWords = @[ @"쪽지", @"메시지", @"DM", @"Messages", @"Message", @"Chat", @"채팅", @"メッセージ", @"チャット" ];
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
                // A badge with words but no number ("새 항목.") is a dot: one thing new.
                if (count == 0 && view.accessibilityValue.length > 0) {
                    count = 1;
                }
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
static NSString* gLastScanText;
static NSString* gLogoShiftDebug;
static NSMutableArray<NSString*>* gNewTweetsLog;

// What the new-tweets counter decided on its last runs (shown in the shake dump).
void NFBNewTweetsLog(NSString* line) {
    if (!gNewTweetsLog) {
        gNewTweetsLog = [NSMutableArray array];
    }
    [gNewTweetsLog addObject:line];
    while (gNewTweetsLog.count > 8) {
        [gNewTweetsLog removeObjectAtIndex:0];
    }
}

NSString* NFBBubbleDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"bubble=%d newTweets=%d notifications=%d dday=%d spotify=%d interval=%ld%c",
                      BubbleEnabled(), [BHTSettings boolForKey:@"kemo_bubble_new_tweets"],
                      [BHTSettings boolForKey:@"kemo_bubble_notifications"],
                      [BHTSettings boolForKey:@"kemo_bubble_dday"],
                      [BHTSettings boolForKey:@"kemo_bubble_spotify"],
                      (long)[BHTSettings integerForKey:@"kemo_bubble_spotify_interval"], 10];
    [out appendFormat:@"logoShift: %@%c", gLogoShiftDebug, 10];
    [out appendFormat:@"keepPosition=%d mediaOnly=%d%c", [BHTSettings boolForKey:@"kemo_keep_position"], [BHTSettings boolForKey:@"kemo_media_only"], 10];
    [out appendFormat:@"account=%@ badgeLast=%@ lastScan=%@%c", gAccountKey, gBadgeLast, gLastScanText, 10];
    [out appendFormat:@"newCount=%lu shown=%lu persistent=%@%c", (unsigned long)gNewCount,
                      (unsigned long)gNewShown, gPersistentText, 10];
    for (NSString* line in gNewTweetsLog) {
        [out appendFormat:@"newTweets: %@%c", line, 10];
    }
    return out;
}

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
    gLastScanText = [NSString stringWithFormat:@"%@ at %@", now, [NSDate date]];
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
            NFBShowBubbleWithIcon(text, [kind isEqualToString:@"dm"] ? @"dm" : @"bell");
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
            NFBShowBubbleWithIcon([NSString stringWithFormat:@"오늘 D-Day · %@", event[@"name"]], @"calendar");
        } else if (days == 1) {
            NFBShowBubbleWithIcon([NSString stringWithFormat:@"내일 D-1 · %@", event[@"name"]], @"calendar");
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

// The logo is drawn a little larger than it is laid out, to sit with the 44pt profile
// button on the left.
static const CGFloat kLogoSize = 40.0;

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
                CGRectGetWidth(view.bounds) <= 80 && ((UIImageView*)view).image) {
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
    if (enabled) {
        // Measured inside the navigation bar, not the window: while the side drawer slides
        // the whole screen sideways, but the bar's own coordinates stay put.
        UIView* reference = parent;
        while (reference && ![reference isKindOfClass:[UINavigationBar class]]) {
            reference = reference.superview;
        }
        reference = reference ?: window;
        // Where the logo should be: its centre mirrors the centre of the 44pt profile button
        // that sits 20pt from the left edge.
        CGFloat target = CGRectGetWidth(reference.bounds) - kEdgeMargin - 22;
        CGPoint middle = CGPointMake(CGRectGetMidX(logo.bounds), CGRectGetMidY(logo.bounds));

        // While UIKit is animating the title (it slides the title around when a refresh
        // starts) the logo is not chased: it is hidden if it is out flying, left alone if it
        // is near, and put in its place once the animation has ended.
        BOOL animating = NO;
        for (UIView* view = control; view && view != reference; view = view.superview) {
            if (view.layer.animationKeys.count > 0) {
                animating = YES;
                break;
            }
        }
        if (animating) {
            CALayer* shown = logo.layer.presentationLayer ?: logo.layer;
            CALayer* base = reference.layer.presentationLayer ?: reference.layer;
            CGPoint at = [shown convertPoint:middle toLayer:base];
            BOOL flying = fabs(at.x - target) > 40 || at.x < 0 || at.x > CGRectGetWidth(reference.bounds);
            [UIView performWithoutAnimation:^{
                control.layer.opacity = flying ? 0 : 1;
            }];
            __weak UIView* weakControl = control;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               if (weakControl) {
                                   ApplyLogoShift(weakControl);
                               }
                           });
            return;
        }

        // At rest: the shift is corrected by the remaining gap, so it does not matter how
        // UIKit has placed or sized the title.
        CGPoint logoCenter = [reference convertPoint:middle fromView:logo];
        CGFloat gap = target - logoCenter.x;
        shift = fabs(gap) > 0.5 ? control.transform.tx + gap : control.transform.tx;
        gLogoShiftDebug = [NSString stringWithFormat:@"ref=%@ refWidth=%.0f logoX=%.1f target=%.1f gap=%.1f tx=%.1f logo=%.1f control=%@",
                                                     NSStringFromClass(reference.class),
                                                     CGRectGetWidth(reference.bounds), logoCenter.x, target, gap,
                                                     shift, CGRectGetWidth(logo.bounds),
                                                     NSStringFromCGRect(control.frame)];
        if (control.layer.opacity < 1) {
            [UIView performWithoutAnimation:^{
                control.layer.opacity = 1;
            }];
        }
        // A small correction (a few points, like the drawer opening and closing) is eased
        // in; a big one is made at once.
        if (fabs(control.transform.tx - shift) > 0.5 || fabs(control.transform.a - 1) > 0.001) {
            CGAffineTransform wanted = CGAffineTransformMakeTranslation(shift, 0);
            if (fabs(gap) < 30) {
                [UIView animateWithDuration:0.18
                                      delay:0
                                    options:UIViewAnimationOptionBeginFromCurrentState |
                                            UIViewAnimationOptionAllowUserInteraction
                                 animations:^{
                                     control.transform = wanted;
                                 }
                                 completion:nil];
            } else {
                [UIView performWithoutAnimation:^{
                    control.transform = wanted;
                }];
            }
        }
    } else if (fabs(control.transform.tx) > 0.5 || fabs(control.transform.a - 1) > 0.001) {
        [UIView performWithoutAnimation:^{
            control.transform = CGAffineTransformIdentity;
        }];
    }

    CGFloat scale = enabled ? kLogoSize / MAX(CGRectGetWidth(logo.bounds), 1) : 1;
    if (fabs(logo.transform.a - scale) > 0.01 && logo.layer.animationKeys.count == 0) {
        [UIView performWithoutAnimation:^{
            logo.transform = CGAffineTransformMakeScale(scale, scale);
        }];
    }
}

%hook _UINavigationBarTitleControl

- (void)layoutSubviews {
    %orig;
    ApplyLogoShift((UIView*)self);
}

- (void)setCenter:(CGPoint)center {
    %orig;
    ApplyLogoShift((UIView*)self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    ApplyLogoShift((UIView*)self);
}

- (void)didMoveToWindow {
    %orig;
    ApplyLogoShift((UIView*)self);
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
