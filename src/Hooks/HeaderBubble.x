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
extern void NFBRecentTick(void);
extern UIImage* NFBRenderLogoSVG(NSString* fileName, CGSize size, UIColor* color);
void NFBIslandLogoJiggle(void);
static NSString* IslandDebugText(void);

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

// The note is the picture "nfb_note.png" from the tweak bundle (a plain black note on
// transparent), painted in the accent colour. All the movement is on this view as a whole.
static UIImage* NoteImage(void) {
    static UIImage* image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL* url = [[BHTBundle sharedBundle] pathForFile:@"nfb_note.png"];
        UIImage* loaded = url ? [UIImage imageWithContentsOfFile:url.path] : nil;
        image = [loaded imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return image;
}

static UIView* NoteView(CGFloat size, UIColor* color) {
    UIView* view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    view.userInteractionEnabled = NO;
    UIImage* image = NoteImage();
    if (image) {
        UIImageView* note = [[UIImageView alloc] initWithImage:image];
        note.tintColor = color;
        note.contentMode = UIViewContentModeScaleAspectFit;
        note.frame = view.bounds;
        [view addSubview:note];
    } else {
        UILabel* fallback = [UILabel new];
        fallback.text = @"♪";
        fallback.textColor = color;
        fallback.font = [UIFont systemFontOfSize:size weight:UIFontWeightHeavy];
        fallback.textAlignment = NSTextAlignmentCenter;
        fallback.frame = view.bounds;
        [view addSubview:fallback];
    }
    return view;
}

// A note pops out like jelly, sways up and to the left, then goes "pop" in a few sparkles.
// The small one is a little smaller, a little later, and goes its own way.
static void FloatNote(UIWindow* window, CGFloat left, CGFloat midY, BOOL small) {
    CGFloat size = small ? 12 : 17.5;
    UIView* note = NoteView(size, CurrentAccentColor());
    CGFloat sideways = MAX(0, MIN(34, left - 64));
    CGPoint start = CGPointMake(left - (small ? 5 : 9), midY + (small ? 6 : -3));
    CGPoint end = CGPointMake(start.x - sideways * (small ? 0.55 : 1.0), midY - (small ? 22 : 14));
    note.center = start;
    note.alpha = 0;
    [window addSubview:note];

    // Jelly pop: it overshoots, squashes, and settles, with a little wobble.
    CAKeyframeAnimation* jelly = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    jelly.values = @[ @0.0, @1.4, @0.82, @1.12, @0.96, @1.0 ];
    jelly.keyTimes = @[ @0, @0.28, @0.5, @0.7, @0.85, @1 ];
    CAKeyframeAnimation* wobble = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
    CGFloat tilt = small ? 0.4 : -0.3;
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
            controlPoint2:CGPointMake(end.x + (small ? -4 : 5), end.y + 8)];
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

// Two notes, a big one and a small one right behind it, once.
static void StartNoteEffect(UIWindow* window, CGFloat left, CGFloat midY) {
    static const double times[] = {0.25};
    for (int i = 0; i < 1; i++) {
        for (int k = 0; k < 2; k++) {
            BOOL small = k == 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)((times[i] + (small ? 0.18 : 0)) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               if (gTransientSpotify && [window viewWithTag:kBubbleTag]) {
                                   FloatNote(window, left, midY, small);
                               }
                           });
        }
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
    NFBIslandLogoJiggle(); // the slime under the island gives a little tug
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
extern void NFBChatNote(NSString* line);
static NSString* gDMBadgeRaw;

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
                    if ([kind isEqualToString:@"dm"]) {
                        gDMBadgeRaw = [NSString stringWithFormat:@"%@ | %@ | %@", NSStringFromClass(view.class), label,
                                                                 view.accessibilityValue ?: @"-"];
                    }
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
static NSString* gSpotifyLog;
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
    [out appendFormat:@"spotify: connected=%d last=%@%c", [BHTSpotify shared].isConnected, gSpotifyLog, 10];
    [out appendFormat:@"keepPosition=%d mediaOnly=%d%c", [BHTSettings boolForKey:@"kemo_keep_position"], [BHTSettings boolForKey:@"kemo_media_only"], 10];
    [out appendFormat:@"account=%@ badgeLast=%@ lastScan=%@%c", gAccountKey, gBadgeLast, gLastScanText, 10];
    [out appendFormat:@"%@%c", IslandDebugText(), 10];
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
    static NSNumber* lastDM;
    if (now[@"dm"] && ![now[@"dm"] isEqual:lastDM]) {
        NFBChatNote([NSString stringWithFormat:@"tab badge dm %@ -> %@ [%@]", lastDM ?: @"?", now[@"dm"], gDMBadgeRaw]);
        lastDM = now[@"dm"];
    }
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
    if (![BHTSettings boolForKey:@"kemo_bubble_spotify"]) {
        return;
    }
    if (![BHTSpotify shared].isConnected) {
        gSpotifyLog = @"not connected (no login)";
        return;
    }
    if (gSpotifyAt && -[gSpotifyAt timeIntervalSinceNow] < interval) {
        return;
    }
    UIWindow* window = NFBKeyWindow();
    if (!window || !HeaderLogoInWindow(window)) {
        gSpotifyLog = @"waiting: the home logo is not on screen";
        return;
    }
    gSpotifyAt = [NSDate date];
    [[BHTSpotify shared]
        fetchCurrentlyPlaying:^(NSString* title, NSString* artist, NSString* shareURL, NSError* error) {
            NSString* when = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                            dateStyle:NSDateFormatterNoStyle
                                                            timeStyle:NSDateFormatterMediumStyle];
            if (error) {
                gSpotifyLog = [NSString stringWithFormat:@"%@ error: %@", when, error.localizedDescription];
                // Too many requests: wait as long as Spotify says before asking again.
                NSNumber* retry = error.userInfo[@"retryAfter"];
                if (error.code == 429) {
                    gSpotifyAt = [NSDate dateWithTimeIntervalSinceNow:MAX(retry.doubleValue, 30) - interval];
                }
                return;
            }
            if (title.length == 0) {
                // Nothing is playing. The next song after this counts as a change.
                gLastTrack = @"";
                gSpotifyLog = [NSString stringWithFormat:@"%@ nothing playing", when];
                return;
            }
            NSString* track = [NSString stringWithFormat:@"%@|%@", title, artist ?: @""];
            BOOL changed = gLastTrack && ![gLastTrack isEqualToString:track];
            gSpotifyLog = [NSString stringWithFormat:@"%@ playing: %@ (%@)", when, track,
                                                     changed ? @"changed, showing" : @"same or first"];
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
    NFBRecentTick();
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


// MARK: Slime fox peeking out under the Dynamic Island
//
// With kemo_island_logo on (iPhone with a Dynamic Island, portrait), a black fox (형's
// artwork, its upper body, island_fox.png) peeks out under the island, right side up, as
// if the island were made of the same slime:
// - it comes out as a drop that swells out of the island, stretches down and takes on the
//   fox's shape (its outline is morphed from the drop's, point for point), landing with a
//   little squash; the picture fades in under the outline as the two meet;
// - out, it just lives there: breathes, blinks now and then, sways a little;
// - going in, the fox melts back into a drop and is drawn up into the island;
// - it follows the navigation bar: in when the bar slides away while scrolling, out again
//   with it, and now and then it goes in and comes back out on its own.
// Its ear tips sit in the island; where they meet its underside, and where the goo column
// leaves it, concave fillets tangent to the island's flat underside round the joins off,
// so there is never a corner. Reduce Motion: it is simply out (or in), with no motion.
//
// It is a layer of its own on the key window; the real header logo stays where it was
// (the right end), only hidden, so the speech bubble keeps its place beside it.
//
// The island's bottom edge is taken as 11pt above the top safe area inset (59 -> 48 on
// the first island phones, 62 -> 51 later) and the island as centred; no API reports it.

static const CGFloat kFoxHang = 6.72;                          // the notch between the ears, below the island
static const CGPoint kFoxNotch = {18.72, 12.96};                // the notch in the picture, from its top left
static const CGRect kFoxLid = {{2.88, 12.48}, {11.04, 8.16}};   // the eye, from the notch
static const CGFloat kFoxDropRX = 15, kFoxDropRY = 20;          // the drop it comes out as
static const CFTimeInterval kFoxEmerge = 1.25, kFoxAbsorb = 1.2;

// The fox's outline (pt from the notch), and for each point where it sits on the drop
// (cos, sin of its angle), so the two line up point for point when morphing.
static const CGFloat kFoxContour[][4] = { // x, y (pt from the notch), blob cos, sin
    {6.00,36.72,0.115,0.993}, {3.99,36.72,-0.021,1.000}, {2.08,36.48,-0.150,0.989}, {0.27,36.00,-0.271,0.963}, {-1.44,35.28,-0.382,0.924}, {-3.14,34.54,-0.483,0.876},
    {-4.78,33.62,-0.573,0.819}, {-6.48,32.88,-0.651,0.759}, {-5.91,31.11,-0.662,0.750}, {-5.14,29.76,-0.658,0.753}, {-6.48,29.09,-0.719,0.695}, {-7.38,27.84,-0.768,0.640},
    {-9.39,27.84,-0.815,0.579}, {-8.90,26.66,-0.824,0.566}, {-10.46,26.02,-0.861,0.509}, {-12.23,25.45,-0.892,0.453}, {-14.00,24.88,-0.915,0.404}, {-15.64,23.96,-0.935,0.355},
    {-16.80,22.44,-0.953,0.303}, {-15.39,21.15,-0.957,0.291}, {-13.97,19.73,-0.962,0.273}, {-14.40,18.48,-0.972,0.234}, {-15.96,17.40,-0.982,0.188}, {-17.21,15.91,-0.990,0.140},
    {-18.13,14.27,-0.995,0.095}, {-17.68,12.88,-0.998,0.062}, {-15.98,12.14,-0.999,0.046}, {-15.12,10.97,-1.000,0.015}, {-15.60,9.15,-0.999,-0.037}, {-16.08,7.34,-0.996,-0.085},
    {-16.32,5.43,-0.991,-0.135}, {-16.32,3.42,-0.982,-0.188}, {-16.32,1.41,-0.971,-0.239}, {-16.08,-0.50,-0.958,-0.288}, {-15.60,-2.31,-0.941,-0.338}, {-15.12,-4.12,-0.922,-0.387},
    {-14.52,-5.88,-0.899,-0.437}, {-13.78,-7.58,-0.873,-0.488}, {-12.87,-9.21,-0.842,-0.540}, {-11.55,-10.56,-0.803,-0.596}, {-9.70,-10.18,-0.771,-0.637}, {-8.07,-9.27,-0.746,-0.666},
    {-6.51,-8.19,-0.719,-0.695}, {-5.02,-6.94,-0.691,-0.723}, {-3.52,-5.68,-0.654,-0.756}, {-2.27,-4.19,-0.625,-0.781}, {-1.02,-2.70,-0.585,-0.811}, {0.24,-2.01,-0.502,-0.865},
    {1.04,-3.68,-0.380,-0.925}, {1.96,-5.32,-0.256,-0.967}, {3.04,-6.88,-0.129,-0.992}, {4.29,-8.37,-0.001,-1.000}, {5.71,-9.79,0.124,-0.992}, {7.27,-10.87,0.242,-0.970},
    {8.83,-11.95,0.340,-0.940}, {10.62,-12.48,0.442,-0.897}, {12.00,-11.28,0.535,-0.845}, {13.08,-9.72,0.614,-0.789}, {13.99,-8.09,0.683,-0.731}, {14.73,-6.39,0.742,-0.670},
    {15.36,-4.64,0.795,-0.607}, {15.84,-2.82,0.841,-0.541}, {16.32,-1.01,0.882,-0.471}, {16.56,0.90,0.917,-0.400}, {16.54,2.86,0.945,-0.328}, {14.91,1.95,0.912,-0.409},
    {13.20,1.35,0.868,-0.497}, {12.96,-0.56,0.815,-0.580}, {12.50,-2.38,0.752,-0.659}, {12.00,-4.18,0.685,-0.729}, {11.35,-5.93,0.610,-0.792}, {10.56,-7.61,0.527,-0.850},
    {9.19,-7.75,0.433,-0.901}, {7.87,-6.43,0.354,-0.935}, {6.62,-4.94,0.260,-0.966}, {5.52,-3.38,0.156,-0.988}, {4.79,-1.67,0.073,-0.997}, {5.79,-1.23,0.223,-0.975},
    {7.71,-1.44,0.456,-0.890}, {8.70,-0.54,0.582,-0.813}, {7.75,1.03,0.547,-0.837}, {9.58,1.44,0.723,-0.690}, {11.40,1.92,0.830,-0.558}, {13.20,2.40,0.892,-0.451},
    {14.91,3.15,0.933,-0.360}, {16.53,4.08,0.960,-0.280}, {18.10,5.14,0.978,-0.211}, {19.59,6.39,0.989,-0.147}, {20.91,7.71,0.996,-0.092}, {20.56,8.88,0.999,-0.054},
    {19.52,9.68,1.000,-0.029}, {20.94,11.10,1.000,0.022}, {21.85,12.73,0.997,0.072}, {21.79,14.16,0.993,0.118}, {19.82,14.06,0.992,0.129}, {20.47,14.88,0.988,0.151},
    {22.29,15.33,0.989,0.150}, {22.13,16.32,0.983,0.181}, {20.22,16.56,0.978,0.210}, {20.72,18.08,0.968,0.251}, {22.28,18.28,0.972,0.236}, {22.56,19.62,0.963,0.270},
    {22.20,21.48,0.945,0.326}, {20.71,22.73,0.922,0.386}, {19.15,23.81,0.893,0.450}, {17.45,24.55,0.857,0.515}, {15.70,25.20,0.810,0.586}, {13.89,25.68,0.748,0.664},
    {12.06,26.10,0.663,0.748}, {11.73,26.85,0.629,0.777}, {13.29,27.93,0.677,0.736}, {14.64,29.38,0.699,0.715}, {13.53,30.57,0.634,0.773}, {14.88,31.88,0.662,0.750},
    {15.62,33.38,0.662,0.750}, {15.14,34.54,0.627,0.779}, {13.44,35.28,0.550,0.835}, {11.73,36.00,0.461,0.887}, {9.92,36.48,0.360,0.933}, {8.01,36.72,0.245,0.970},
};

// Where the ears cross the island's underside: left and right edge, and the row (pt from the notch).
static const CGFloat kFoxEarRuns[][3] = { // left x, right x, y (pt from the notch) where the ears meet the island
    {-14.16, -4.80, -4.72},
    {2.88, 8.16, -4.72},
    {11.04, 14.64, -4.72},
};
static const NSInteger kFoxPoints = sizeof(kFoxContour) / sizeof(kFoxContour[0]);
static const NSInteger kFoxEars = sizeof(kFoxEarRuns) / sizeof(kFoxEarRuns[0]);

static BOOL IslandLogoOn(UIWindow* window) {
    if (![BHTSettings boolForKey:@"kemo_island_logo"] || !window) {
        return NO;
    }
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) {
        return NO;
    }
    if (CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds)) {
        return NO;
    }
    return window.safeAreaInsets.top >= 54;
}

static CGFloat IslandBottom(UIWindow* window) {
    return window.safeAreaInsets.top - 11.0;
}

static UIImage* SlimeImage(void) {
    static UIImage* image;
    if (!image) {
        NSURL* url = [[BHTBundle sharedBundle] pathForFile:@"island_fox.png"];
        NSData* data = url ? [NSData dataWithContentsOfURL:url] : nil;
        image = data ? [UIImage imageWithData:data scale:3.0] : nil;
    }
    return image;
}

// Set on the header logo while the slime has hidden it, so only that is undone.
static const void* kHiddenByIslandKey = &kHiddenByIslandKey;

static void SetLogoHiddenByIsland(UIImageView* logo, BOOL hide) {
    if (!logo || [objc_getAssociatedObject(logo, kHiddenByIslandKey) boolValue] == hide) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    logo.layer.opacity = hide ? 0 : 1;
    [CATransaction commit];
    objc_setAssociatedObject(logo, kHiddenByIslandKey, @(hide), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat FoxSmooth(CGFloat x, CGFloat a, CGFloat b) {
    CGFloat t = MAX(0, MIN(1, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
}

static CGFloat FoxEaseOut(CGFloat x) {
    x = MAX(0, MIN(1, x));
    return 1 - pow(1 - x, 3);
}

static CGFloat FoxLerp(CGFloat a, CGFloat b, CGFloat t) {
    return a + (b - a) * t;
}

// The goo column from the island down to (x, bottom). It leaves the island's flat
// underside through concave fillets of radius r, tangent to it, so there is no corner.
// Every piece here is drawn the same way round, so overlapping pieces fill as one.
static void AddFoxNeck(CGMutablePathRef path, CGFloat island, CGFloat x, CGFloat bottom, CGFloat wBottom, CGFloat wTop, CGFloat r) {
    CGFloat yb = island - 0.5;
    CGPathMoveToPoint(path, NULL, x - wTop - r - 2, island - 4);
    CGPathAddLineToPoint(path, NULL, x - wTop - r, yb);
    CGPathAddQuadCurveToPoint(path, NULL, x - wTop, yb, x - wTop, yb + r);
    CGPathAddLineToPoint(path, NULL, x - wBottom, bottom);
    CGPathAddLineToPoint(path, NULL, x + wBottom, bottom);
    CGPathAddLineToPoint(path, NULL, x + wTop, yb + r);
    CGPathAddQuadCurveToPoint(path, NULL, x + wTop, yb, x + wTop + r, yb);
    CGPathAddLineToPoint(path, NULL, x + wTop + r + 2, island - 4);
    CGPathCloseSubpath(path);
}

typedef NS_ENUM(NSInteger, FoxPhase) {
    FoxPhaseInside,
    FoxPhaseEmerging,
    FoxPhaseOut,
    FoxPhaseAbsorbing,
};

@interface NFBIslandSlime : NSObject
@property (nonatomic, strong) CADisplayLink* link;
@property (nonatomic, weak) UIWindow* window;
@property (nonatomic, weak) UIView* bar;
@property (nonatomic, weak) UIImageView* logo; // the header logo hidden while the slime shows
@property (nonatomic, strong) CALayer* container;
@property (nonatomic, strong) CALayer* fox;
@property (nonatomic, strong) CALayer* lid;
@property (nonatomic, strong) CAShapeLayer* dropShape; // the drop, or the fox's outline while morphing
@property (nonatomic, strong) CAShapeLayer* neck;  // the goo column out of the island
@property (nonatomic, strong) CAShapeLayer* ears;  // the fillets where the ears meet the island
@property (nonatomic, assign) FoxPhase phase;
@property (nonatomic, assign) CFTimeInterval t;     // time in the phase
@property (nonatomic, assign) CFTimeInterval clock;
@property (nonatomic, assign) CGFloat squash;       // 1 at rest; a spring
@property (nonatomic, assign) CGFloat squashVelocity;
@property (nonatomic, assign) BOOL landed;
@property (nonatomic, assign) CFTimeInterval peekUntil;
@property (nonatomic, assign) CFTimeInterval nextPeek;
@property (nonatomic, assign) CFTimeInterval nextBlink;
@property (nonatomic, assign) CFTimeInterval blinkAt;
@property (nonatomic, copy) NSString* debug;
@end

@implementation NFBIslandSlime

// Removes the slime at once (the option was turned off, or there is no island) and
// puts the header logo back.
- (void)stop {
    [self.link invalidate];
    self.link = nil;
    [self.container removeFromSuperlayer];
    self.container = nil;
    SetLogoHiddenByIsland(self.logo, NO);
}

- (void)start {
    if (!self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CFTimeInterval now = CACurrentMediaTime();
        self.nextPeek = now + 30 + arc4random_uniform(30);
        self.nextBlink = now + 1.5;
        self.blinkAt = -10;
    }
}

// Starts it inside the island; it comes out once the bar is there.
- (void)drop {
    self.phase = UIAccessibilityIsReduceMotionEnabled() ? FoxPhaseOut : FoxPhaseInside;
    self.t = 0;
    self.squash = 1;
    self.squashVelocity = 0;
}

// A little squash, for when something happens (the speech bubble opening).
- (void)jiggle {
    if (UIAccessibilityIsReduceMotionEnabled() || self.phase != FoxPhaseOut) {
        return;
    }
    self.squashVelocity -= 1.2;
}

// 1 while the navigation bar sits at the top, falling to 0 as it slides away or fades.
- (CGFloat)barShown {
    UIView* bar = self.bar;
    UIWindow* window = self.window;
    if (!bar || !bar.window || !window) {
        return 0;
    }
    CGFloat alpha = 1;
    for (UIView* view = bar; view; view = view.superview) {
        if (view.hidden) {
            return 0;
        }
        alpha *= view.alpha;
    }
    CALayer* shown = bar.layer.presentationLayer ?: bar.layer;
    CALayer* base = window.layer.presentationLayer ?: window.layer;
    CGRect frame = [shown convertRect:shown.bounds toLayer:base];
    CGFloat height = MAX(CGRectGetHeight(frame), 1);
    CGFloat slid = (window.safeAreaInsets.top - CGRectGetMinY(frame)) / height;
    return MAX(0, MIN(1, 1 - slid)) * MIN(1, alpha * 1.25);
}

- (CAShapeLayer*)gooLayer {
    CAShapeLayer* layer = [CAShapeLayer layer];
    layer.fillColor = [UIColor blackColor].CGColor;
    layer.fillRule = kCAFillRuleNonZero;
    [self.container addSublayer:layer];
    return layer;
}

- (void)buildLayersIn:(UIWindow*)window {
    UIImage* image = SlimeImage();
    self.container = [CALayer layer];
    self.container.zPosition = 9999;
    self.container.frame = window.bounds;
    self.fox = [CALayer layer];
    self.fox.contents = (__bridge id)image.CGImage;
    self.fox.contentsScale = 3.0;
    self.fox.contentsGravity = kCAGravityResize;
    self.fox.bounds = CGRectMake(0, 0, image.size.width, image.size.height);
    self.fox.anchorPoint = CGPointMake(kFoxNotch.x / MAX(image.size.width, 1), kFoxNotch.y / MAX(image.size.height, 1));
    self.fox.allowsEdgeAntialiasing = YES;
    [self.container addSublayer:self.fox];
    // The eyelid: black, over the eye (a hole in the picture), closing from the top.
    self.lid = [CALayer layer];
    self.lid.backgroundColor = [UIColor blackColor].CGColor;
    self.lid.anchorPoint = CGPointMake(0.5, 0);
    self.lid.bounds = CGRectMake(0, 0, kFoxLid.size.width, kFoxLid.size.height + 1);
    self.lid.position = CGPointMake(kFoxNotch.x + CGRectGetMidX(kFoxLid), kFoxNotch.y + kFoxLid.origin.y - 1);
    [self.fox addSublayer:self.lid];
    self.dropShape = [self gooLayer];
    self.neck = [self gooLayer];
    self.ears = [self gooLayer];
}

// The fox's pose: where the notch hangs, its sway, and its scale (squash and breath).
- (CGPoint)place:(CGPoint)p hang:(CGPoint)hang sway:(CGFloat)sway sx:(CGFloat)sx sy:(CGFloat)sy {
    CGFloat x = p.x * sx, y = p.y * sy, c = cos(sway), s = sin(sway);
    return CGPointMake(hang.x + c * x - s * y, hang.y + s * x + c * y);
}

// The drop (an ellipse) morphed toward the fox's outline by `toFox`.
- (CGPathRef)newOutlineWithDrop:(CGPoint)center rx:(CGFloat)rx ry:(CGFloat)ry toFox:(CGFloat)toFox
                          hang:(CGPoint)hang sway:(CGFloat)sway sx:(CGFloat)sx sy:(CGFloat)sy CF_RETURNS_RETAINED {
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSInteger i = 0; i < kFoxPoints; i++) {
        CGPoint a = CGPointMake(center.x + rx * kFoxContour[i][2], center.y + ry * kFoxContour[i][3]);
        CGPoint b = toFox > 0 ? [self place:CGPointMake(kFoxContour[i][0], kFoxContour[i][1]) hang:hang sway:sway sx:sx sy:sy] : a;
        CGPoint p = CGPointMake(FoxLerp(a.x, b.x, toFox), FoxLerp(a.y, b.y, toFox));
        if (i == 0) {
            CGPathMoveToPoint(path, NULL, p.x, p.y);
        } else {
            CGPathAddLineToPoint(path, NULL, p.x, p.y);
        }
    }
    CGPathCloseSubpath(path);
    return path;
}

- (CGPathRef)newEarFilletsAt:(CGFloat)island hang:(CGPoint)hang sway:(CGFloat)sway sx:(CGFloat)sx sy:(CGFloat)sy CF_RETURNS_RETAINED {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat r = 2.0, yb = island - 0.5;
    for (NSInteger i = 0; i < kFoxEars; i++) {
        CGFloat ax = [self place:CGPointMake(kFoxEarRuns[i][0], kFoxEarRuns[i][2]) hang:hang sway:sway sx:sx sy:sy].x;
        CGFloat bx = [self place:CGPointMake(kFoxEarRuns[i][1], kFoxEarRuns[i][2]) hang:hang sway:sway sx:sx sy:sy].x;
        CGPathMoveToPoint(path, NULL, ax - r, yb - 3);
        CGPathAddLineToPoint(path, NULL, ax - r, yb);
        CGPathAddQuadCurveToPoint(path, NULL, ax, yb, ax, yb + r);
        CGPathAddLineToPoint(path, NULL, bx, yb + r);
        CGPathAddQuadCurveToPoint(path, NULL, bx, yb, bx + r, yb);
        CGPathAddLineToPoint(path, NULL, bx + r, yb - 3);
        CGPathCloseSubpath(path);
    }
    return path;
}

- (void)step:(CADisplayLink*)link {
    UIWindow* window = self.window;
    if (!window || !IslandLogoOn(window) || !SlimeImage()) {
        [self stop];
        return;
    }
    if (!self.container) {
        [self buildLayersIn:window];
    }
    if (self.container.superlayer != window.layer) {
        [window.layer addSublayer:self.container];
    }
    BOOL dark = window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    CGFloat dt = MIN(1.0 / 30.0, MAX(1.0 / 240.0, link.targetTimestamp - link.timestamp));
    CFTimeInterval now = CACurrentMediaTime();
    self.clock += dt;
    self.t += dt;

    BOOL wanted = [self barShown] > 0.5;
    if (!still && wanted && self.phase == FoxPhaseOut && now > self.nextPeek) {
        // Go in for a moment, then come back out.
        self.peekUntil = now + kFoxAbsorb + 0.5;
        self.nextPeek = now + 40 + arc4random_uniform(40);
    }
    if (now < self.peekUntil) {
        wanted = NO;
    }
    if (still) {
        self.phase = wanted ? FoxPhaseOut : FoxPhaseInside;
        self.t = 0;
    } else if (self.phase == FoxPhaseInside && wanted) {
        self.phase = FoxPhaseEmerging;
        self.t = 0;
        self.landed = NO;
    } else if (self.phase == FoxPhaseOut && !wanted) {
        self.phase = FoxPhaseAbsorbing;
        self.t = 0;
    } else if (self.phase == FoxPhaseEmerging && self.t >= kFoxEmerge) {
        self.phase = FoxPhaseOut;
        self.t = 0;
    } else if (self.phase == FoxPhaseAbsorbing && self.t >= kFoxAbsorb) {
        self.phase = FoxPhaseInside;
        self.t = 0;
        self.squash = 1;
        self.squashVelocity = 0;
    }

    CGFloat island = IslandBottom(window);
    CGFloat midX = CGRectGetMidX(window.bounds);
    CGPoint hang = CGPointMake(midX, island + kFoxHang);
    CGFloat t = self.t;
    if (!still) {
        self.squashVelocity += (170 * (1 - self.squash) - 9 * self.squashVelocity) * dt;
        self.squash += self.squashVelocity * dt;
    }
    CGFloat breath = still ? 0 : 0.035 * sin(self.clock * 2.4);
    CGFloat sway = still ? 0 : 0.05 * sin(self.clock * 1.6);
    CGFloat squash = self.squash;

    CGFloat foxOpacity = 0, dropOpacity = 0, neckOpacity = 0, earsOpacity = 0;
    CGPathRef dropPath = NULL, neckPath = NULL;
    CGMutablePathRef neck = CGPathCreateMutable();
    switch (self.phase) {
        case FoxPhaseInside:
            break;
        case FoxPhaseEmerging: {
            CGFloat k = 0.5;
            if (t < k) {
                // A drop swells out of the island and stretches down.
                CGFloat e = FoxEaseOut(t / k), ry = FoxLerp(1.5, kFoxDropRY, e), rx = FoxLerp(7, kFoxDropRX, e);
                dropPath = [self newOutlineWithDrop:CGPointMake(midX, island - 2 + ry) rx:rx ry:ry toFox:0 hang:hang sway:0 sx:1 sy:1];
                dropOpacity = 1;
                AddFoxNeck(neck, island, midX, island + ry * 0.6, rx * 0.7, rx * 0.8, FoxLerp(2, 5, e));
                neckOpacity = 1;
            } else {
                // ...and takes on the fox's shape, landing with a squash.
                if (!self.landed) {
                    self.landed = YES;
                    self.squash = squash = 1.18;
                    self.squashVelocity = -1.5;
                    if ([BHTSettings boolForKey:@"kemo_haptics"] && !NSProcessInfo.processInfo.isLowPowerModeEnabled) {
                        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft] impactOccurred];
                    }
                }
                CGFloat e = FoxSmooth(t, k, kFoxEmerge - 0.25), f = FoxSmooth(t, kFoxEmerge - 0.4, kFoxEmerge);
                CGFloat sx = (1 + breath) / sqrt(squash), sy = squash * (1 + breath * 0.5);
                dropPath = [self newOutlineWithDrop:CGPointMake(midX, island - 2 + kFoxDropRY) rx:kFoxDropRX ry:kFoxDropRY
                                              toFox:FoxEaseOut(e) hang:hang sway:sway sx:sx sy:sy];
                dropOpacity = 1 - f;
                foxOpacity = f > 0 ? 1 : 0;
                AddFoxNeck(neck, island, midX, island + FoxLerp(8, 2, e), FoxLerp(8, 5, e), FoxLerp(9, 6, e), FoxLerp(5, 3, e));
                neckOpacity = 1 - FoxSmooth(e, 0.6, 1);
                earsOpacity = f;
            }
            break;
        }
        case FoxPhaseOut:
            foxOpacity = 1;
            earsOpacity = 1;
            break;
        case FoxPhaseAbsorbing: {
            CGFloat k = 0.45;
            sway *= 1 - FoxSmooth(t, 0, k);
            if (t < k) {
                // The fox melts back into a drop...
                CGFloat e = FoxSmooth(t, 0, k), f = 1 - FoxSmooth(t, 0, 0.15);
                squash = FoxLerp(1, 0.88, e);
                CGFloat sx = (1 + breath) / sqrt(squash), sy = squash * (1 + breath * 0.5);
                dropPath = [self newOutlineWithDrop:CGPointMake(midX, island - 2 + kFoxDropRY) rx:kFoxDropRX - 1 ry:kFoxDropRY
                                              toFox:1 - e hang:hang sway:sway sx:sx sy:sy];
                dropOpacity = 1 - f;
                foxOpacity = f > 0 ? 1 : 0;
                AddFoxNeck(neck, island, midX, island + FoxLerp(2, 9, e), FoxLerp(5, 8, e), FoxLerp(6, 9, e), FoxLerp(3, 4, e));
                neckOpacity = FoxSmooth(e, 0, 0.4);
                earsOpacity = 1 - FoxSmooth(e, 0, 0.4);
            } else {
                // ...that is drawn up into the island.
                CGFloat e = FoxSmooth(t, k, kFoxAbsorb), ry = FoxLerp(kFoxDropRY, 1, e), rx = FoxLerp(kFoxDropRX - 1, 5, e);
                dropPath = [self newOutlineWithDrop:CGPointMake(midX, island - 2 + ry * (1 - 0.4 * e)) rx:rx ry:ry
                                              toFox:0 hang:hang sway:0 sx:1 sy:1];
                dropOpacity = 1;
                AddFoxNeck(neck, island, midX, island + ry * 0.6, rx * 0.75, rx * 0.85, FoxLerp(4, 1.5, e));
                neckOpacity = 1;
            }
            break;
        }
    }
    neckPath = neck;

    // Blinks, now and then; sometimes twice.
    if (!still && now > self.nextBlink) {
        self.blinkAt = now;
        self.nextBlink = now + (arc4random_uniform(4) == 0 ? 0.35 : 2.0 + arc4random_uniform(30) / 10.0);
    }
    CGFloat blink = (now - self.blinkAt < 0.17) ? sin((now - self.blinkAt) / 0.17 * M_PI) : 0;

    CGFloat sx = (1 + breath) / sqrt(squash), sy = squash * (1 + breath * 0.5);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.container.frame = window.bounds;
    self.container.hidden = self.phase == FoxPhaseInside;
    self.fox.position = hang;
    self.fox.transform = CATransform3DScale(CATransform3DMakeRotation(sway, 0, 0, 1), sx, sy, 1);
    self.fox.opacity = foxOpacity;
    self.lid.hidden = blink <= 0.01;
    self.lid.transform = CATransform3DMakeScale(1, MAX(blink, 0.01), 1);
    self.dropShape.path = dropPath;
    self.dropShape.opacity = dropOpacity;
    self.neck.path = neckPath;
    self.neck.opacity = neckOpacity;
    if (earsOpacity > 0) {
        CGPathRef ears = [self newEarFilletsAt:island hang:hang sway:sway sx:sx sy:sy];
        self.ears.path = ears;
        CGPathRelease(ears);
    }
    self.ears.opacity = earsOpacity;
    // Only draw from a little above the island's bottom edge (the island hides the rest),
    // so nothing ever shows in the status bar beside it.
    if (!self.container.mask) {
        self.container.mask = [CALayer layer];
        self.container.mask.backgroundColor = [UIColor blackColor].CGColor;
    }
    CGFloat clipTop = island - 30;
    self.container.mask.frame = CGRectMake(0, clipTop, CGRectGetWidth(window.bounds), CGRectGetHeight(window.bounds) - clipTop);
    // Black on a black bar would vanish: a faint light edge keeps it readable in dark mode.
    self.container.shadowColor = [UIColor whiteColor].CGColor;
    self.container.shadowOffset = CGSizeZero;
    self.container.shadowRadius = 1.5;
    self.container.shadowOpacity = dark ? 0.55 : 0;
    [CATransaction commit];
    if (dropPath) {
        CGPathRelease(dropPath);
    }
    CGPathRelease(neck);

    self.debug = [NSString stringWithFormat:@"islandBottom=%.1f phase=%ld t=%.2f squash=%.2f dark=%d",
                                            island, (long)self.phase, t, squash, dark];
}

@end

static NFBIslandSlime* gIsland;

void NFBIslandLogoJiggle(void) {
    [gIsland jiggle];
}

static NSString* IslandDebugText(void) {
    return gIsland ? [@"island: " stringByAppendingString:gIsland.debug ?: @"starting"] : @"island: off";
}

// Called on every header logo layout. Hides the real logo while the slime is shown and
// keeps the slime attached to this window and bar.
static void UpdateIslandSlime(UIView* control, UIImageView* logo) {
    UIWindow* window = control.window;
    BOOL on = IslandLogoOn(window) && SlimeImage() != nil;
    // Only undo what was done here, so other effects on the logo are left alone.
    SetLogoHiddenByIsland(logo, on);
    if (!on) {
        if (gIsland) {
            [gIsland stop];
            gIsland = nil;
        }
        return;
    }
    UIView* bar = control.superview;
    while (bar && ![bar isKindOfClass:[UINavigationBar class]]) {
        bar = bar.superview;
    }
    BOOL fresh = !gIsland;
    if (fresh) {
        gIsland = [NFBIslandSlime new];
    }
    gIsland.window = window;
    gIsland.logo = logo;
    if (bar) {
        gIsland.bar = bar;
    }
    if (fresh) {
        [gIsland drop];
    }
    [gIsland start];
}

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

    // Why a layer transform on the children and not a view transform on the control: UIKit
    // sets the title's frame again on every layout, and for a view with a transform that
    // moves its centre to cancel the transform. The shift was cancelled, the next pass added
    // it again, and the logo ran off the screen. A sublayer transform is not part of the
    // frame, so UIKit never sees it and never cancels it.
    if (!CGAffineTransformIsIdentity(control.transform)) {
        [UIView performWithoutAnimation:^{
            control.transform = CGAffineTransformIdentity;
        }];
    }
    if (!CGAffineTransformIsIdentity(logo.transform)) {
        [UIView performWithoutAnimation:^{
            logo.transform = CGAffineTransformIdentity;
        }];
    }

    BOOL enabled = BubbleEnabled();
    CATransform3D current = control.layer.sublayerTransform;
    UpdateIslandSlime(control, logo);
    if (!enabled) {
        if (!CATransform3DIsIdentity(current)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            control.layer.sublayerTransform = CATransform3DIdentity;
            [CATransaction commit];
        }
        return;
    }

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
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        control.layer.opacity = flying ? 0 : 1;
        [CATransaction commit];
        __weak UIView* weakControl = control;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (weakControl) {
                               ApplyLogoShift(weakControl);
                           }
                       });
        return;
    }

    // At rest: the shift is corrected by the remaining gap, so it does not matter how UIKit
    // has placed or sized the title. The size is the wanted 40pt over however big it is laid
    // out (about the control's centre, where the logo sits).
    CGPoint logoCenter = [reference convertPoint:middle fromView:logo];
    CGFloat gap = target - logoCenter.x;
    CGFloat tx = current.m41;
    CGFloat newTx = fabs(gap) > 0.5 ? tx + gap : tx;
    CGFloat scale = kLogoSize / MAX(CGRectGetWidth(logo.bounds), 1);
    gLogoShiftDebug = [NSString stringWithFormat:@"ref=%@ refWidth=%.0f logoX=%.1f target=%.1f gap=%.1f tx=%.1f scale=%.2f logo=%.1f control=%@",
                                                 NSStringFromClass(reference.class),
                                                 CGRectGetWidth(reference.bounds), logoCenter.x, target, gap,
                                                 newTx, scale, CGRectGetWidth(logo.bounds),
                                                 NSStringFromCGRect(control.frame)];
    if (control.layer.opacity < 1) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        control.layer.opacity = 1;
        [CATransaction commit];
    }
    if (fabs(newTx - tx) > 0.5 || fabs(scale - current.m11) > 0.01) {
        CATransform3D wanted = CATransform3DScale(CATransform3DMakeTranslation(newTx, 0, 0), scale, scale, 1);
        [CATransaction begin];
        if (fabs(gap) < 30 && fabs(scale - current.m11) < 0.01) {
            // A small correction (a few points, like the drawer opening and closing) eases in.
            [CATransaction setAnimationDuration:0.18];
        } else {
            [CATransaction setDisableActions:YES];
        }
        control.layer.sublayerTransform = wanted;
        [CATransaction commit];
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
                    if (gIsland) {
                        [gIsland drop];
                    }
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
