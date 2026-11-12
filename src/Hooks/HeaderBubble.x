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


// MARK: Slime hanging from the Dynamic Island
//
// With kemo_island_logo on (iPhone with a Dynamic Island, portrait), the character from
// the header logo hangs upside down out of the island, in black, as if the island were
// made of the same slime. island_slime.png is the character cut out of the logo (the
// speech bubble and the motion marks left out), turned upside down so the edge where
// the logo crops its body is at the top, tucked under the island.
//
// It is a layer of its own on the key window; the real header logo stays where it was
// (the right end), only hidden, so the speech bubble keeps its place beside it.
//
// Motion: "how far out" (0 inside, 1 hanging) rides a spring, and a bone rig (below)
// makes the whole body follow it with lag and overlap, like rigged character animation:
// - it comes out on launch and on coming back to the app, ears first, overshoots so the
//   body stretches thin, and wobbles back; going in it is slurped up, body first and
//   the head dragged in last;
// - it follows the navigation bar: when the bar slides away while scrolling it is
//   sucked back into the island, and comes out again with the bar;
// - now and then it ducks in and pops out again, and it gives a little tug when the
//   speech bubble opens;
// - at rest it sways slightly about the island, like something hanging.
// Reduce Motion: it just hangs, no spring, no sway.
//
// The island's bottom edge is taken as 11pt above the top safe area inset (59 -> 48 on
// the first island phones, 62 -> 51 later) and the island as centred; no API reports it.

static const CGFloat kSlimeWidth = 44.0;
static const CGFloat kSlimeTuck = 4.0; // how far its top edge sits up under the island

// The silhouette of island_slime.png, row by row from its top edge (tucked under the
// island) to the ear tips: left and right edge as a fraction of the picture's width
// (the body's own edge: the paw and the phone it holds are left out on the left).
// The liquid junction below hugs these edges.
static const CGFloat kSlimeEdges[][2] = {
    {0.150,0.850}, {0.111,0.910}, {0.094,0.940}, {0.085,0.966}, {0.085,0.979}, {0.100,0.979}, {0.110,0.974},
    {0.130,0.953}, {0.160,0.923}, {0.180,0.936}, {0.200,0.974}, {0.215,0.966}, {0.230,0.936}, {0.240,0.949},
    {0.252,0.979}, {0.256,0.996}, {0.295,0.979}, {0.303,0.944}, {0.325,0.953}, {0.355,0.962}, {0.333,0.966},
    {0.350,0.970}, {0.397,0.970}, {0.397,0.970}, {0.402,0.970}, {0.406,0.966}, {0.415,0.962}, {0.423,0.957},
    {0.436,0.944}, {0.449,0.936}, {0.466,0.919}, {0.487,0.897}, {0.509,0.547},
};
static const NSInteger kSlimeEdgeRows = sizeof(kSlimeEdges) / sizeof(kSlimeEdges[0]) - 1;

static void SlimeEdgesAt(CGFloat v, CGFloat* left, CGFloat* right) {
    v = MAX(0, MIN(1, v)) * kSlimeEdgeRows;
    NSInteger i = MIN((NSInteger)v, kSlimeEdgeRows - 1);
    CGFloat t = v - i;
    *left = kSlimeEdges[i][0] + (kSlimeEdges[i + 1][0] - kSlimeEdges[i][0]) * t;
    *right = kSlimeEdges[i][1] + (kSlimeEdges[i + 1][1] - kSlimeEdges[i][1]) * t;
}

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
        NSURL* url = [[BHTBundle sharedBundle] pathForFile:@"island_slime.png"];
        NSData* data = url ? [NSData dataWithContentsOfURL:url] : nil;
        image = data ? [UIImage imageWithData:data scale:3.0] : nil;
    }
    return image;
}

// The rig: the picture is cut into kSlimeBones horizontal bands, one per bone of a chain
// that starts under the island (its root is pinned there) and ends at the head and ears.
// The joints are points simulated with Verlet integration: gravity pulls them down, soft
// distance constraints keep each bone near its rest length (soft, so the body stretches
// and springs back like slime), and a bend constraint pulls each bone back in line with
// the one above it (stiff near the root, looser at the head, so motion travels down the
// body and the head and ears lag behind and settle last). Each band is drawn along its
// bone, rotated to the bone's angle and stretched to its length; its width shrinks as it
// stretches, so the volume looks kept. Bands overlap a little to hide the seams.
static const NSInteger kSlimeBones = 9;
static const NSInteger kSlimeSubsteps = 4;

// Set on the header logo while the slime has hidden it, so only that is undone.
static const void* kHiddenByIslandKey = &kHiddenByIslandKey;

static void SetLogoHiddenByIsland(UIImageView* logo, BOOL hide) {
    if (!logo) {
        return;
    }
    BOOL ours = [objc_getAssociatedObject(logo, kHiddenByIslandKey) boolValue];
    // Hiding is checked against the layer itself, not only our flag: the app sometimes
    // puts the logo's opacity back on its own (a new bar, a fade), and the logo showed.
    if (hide ? (ours && logo.layer.opacity == 0) : !ours) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    logo.layer.opacity = hide ? 0 : 1;
    [CATransaction commit];
    objc_setAssociatedObject(logo, kHiddenByIslandKey, @(hide), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface NFBIslandSlime : NSObject {
    CGPoint _points[kSlimeBones + 1];
    CGPoint _previous[kSlimeBones + 1];
    CGFloat _widths[kSlimeBones];
    BOOL _pointsReady;
}
@property (nonatomic, strong) CADisplayLink* link;
@property (nonatomic, weak) UIWindow* window;
@property (nonatomic, weak) UIView* bar;
@property (nonatomic, weak) UIImageView* logo; // the header logo hidden while the slime shows
@property (nonatomic, strong) CALayer* container;
@property (nonatomic, strong) NSArray<CALayer*>* bands;
@property (nonatomic, strong) CAShapeLayer* junction; // the liquid join with the island
@property (nonatomic, assign) CGSize slimeSize;
@property (nonatomic, assign) CGFloat out;       // 0 inside the island, 1 hanging (the length)
@property (nonatomic, assign) CGFloat velocity;
@property (nonatomic, assign) CFTimeInterval peekUntil;
@property (nonatomic, assign) CFTimeInterval nextPeek;
@property (nonatomic, assign) CFTimeInterval nextTwitch;
@property (nonatomic, assign) CFTimeInterval clock;
@property (nonatomic, assign) BOOL thumped;
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
    self.bands = nil;
    self.junction = nil;
    _pointsReady = NO;
    SetLogoHiddenByIsland(self.logo, NO);
}

- (void)start {
    if (!self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        CFTimeInterval now = CACurrentMediaTime();
        self.nextPeek = now + 25 + arc4random_uniform(20);
        self.nextTwitch = now + 4 + arc4random_uniform(5);
    }
}

// Starts it inside the island; the spring and the rig bring it out.
- (void)drop {
    self.out = UIAccessibilityIsReduceMotionEnabled() ? 1 : 0;
    self.velocity = 0;
    self.thumped = NO;
    _pointsReady = NO;
}

// A tug at the head, for when something happens (the speech bubble opening).
- (void)jiggle {
    if (UIAccessibilityIsReduceMotionEnabled() || !_pointsReady) {
        return;
    }
    self.velocity += 1.2;
    _previous[kSlimeBones].y -= 3.5;
    self.thumped = YES;
    _previous[kSlimeBones].x += (arc4random_uniform(2) ? 2.5 : -2.5);
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

- (void)buildLayersIn:(UIWindow*)window {
    UIImage* image = SlimeImage();
    CGSize size = image.size;
    CGFloat height = kSlimeWidth * size.height / MAX(size.width, 1);
    self.slimeSize = CGSizeMake(kSlimeWidth, height);
    self.container = [CALayer layer];
    self.container.zPosition = 9999;
    self.container.frame = window.bounds;
    NSMutableArray* bands = [NSMutableArray array];
    CGFloat bandHeight = height / kSlimeBones;
    CGFloat overlap = 1.5; // points of picture shared with the next band
    for (NSInteger i = 0; i < kSlimeBones; i++) {
        CALayer* band = [CALayer layer];
        band.contents = (__bridge id)image.CGImage;
        band.contentsScale = 3.0;
        band.contentsGravity = kCAGravityResize;
        CGFloat extra = (i < kSlimeBones - 1) ? overlap : 0;
        band.contentsRect = CGRectMake(0, i / (CGFloat)kSlimeBones, 1, (bandHeight + extra) / height);
        band.anchorPoint = CGPointMake(0.5, 0);
        band.bounds = CGRectMake(0, 0, kSlimeWidth, bandHeight + extra);
        band.allowsEdgeAntialiasing = YES;
        [self.container addSublayer:band];
        [bands addObject:band];
    }
    self.bands = bands;
    self.junction = [CAShapeLayer layer];
    self.junction.fillColor = [UIColor blackColor].CGColor;
    [self.container addSublayer:self.junction];
}

- (void)simulate:(CGFloat)dt anchor:(CGPoint)anchor length:(CGFloat)length still:(BOOL)still {
    CGFloat rest = self.slimeSize.height / kSlimeBones * length;
    if (!_pointsReady || still) {
        for (NSInteger i = 0; i <= kSlimeBones; i++) {
            _points[i] = CGPointMake(anchor.x, anchor.y + rest * i);
            _previous[i] = _points[i];
        }
        _pointsReady = YES;
        if (still) {
            return;
        }
    }
    CGFloat h = dt / kSlimeSubsteps;
    CGFloat gravity = 1400;
    for (NSInteger sub = 0; sub < kSlimeSubsteps; sub++) {
        _points[0] = anchor;
        _previous[0] = anchor;
        for (NSInteger i = 1; i <= kSlimeBones; i++) {
            CGFloat depth = i / (CGFloat)kSlimeBones;
            // A slow, uneven breeze, stronger toward the head.
            CGFloat breeze = (sin(self.clock * 1.3 + depth * 0.9) + 0.4 * sin(self.clock * 3.1)) * 70 * depth;
            CGPoint p = _points[i];
            CGPoint v = CGPointMake((p.x - _previous[i].x) * 0.975, (p.y - _previous[i].y) * 0.975);
            _previous[i] = p;
            _points[i] = CGPointMake(p.x + v.x + breeze * h * h, p.y + v.y + gravity * h * h);
        }
        for (NSInteger pass = 0; pass < 3; pass++) {
            for (NSInteger i = 0; i < kSlimeBones; i++) {
                // Length: soft, so the body stretches like slime.
                CGPoint a = _points[i], b = _points[i + 1];
                CGFloat dx = b.x - a.x, dy = b.y - a.y;
                CGFloat dist = MAX(sqrt(dx * dx + dy * dy), 0.0001);
                CGFloat push = (dist - rest) / dist * 0.55;
                if (i == 0) {
                    _points[1].x -= dx * push;
                    _points[1].y -= dy * push;
                } else {
                    _points[i].x += dx * push * 0.5;
                    _points[i].y += dy * push * 0.5;
                    _points[i + 1].x -= dx * push * 0.5;
                    _points[i + 1].y -= dy * push * 0.5;
                }
                // Bend: back in line with the bone above (straight down at the root);
                // stiffer near the island, looser at the head.
                CGPoint parent = i == 0 ? CGPointMake(0, 1)
                                        : CGPointMake(_points[i].x - _points[i - 1].x, _points[i].y - _points[i - 1].y);
                CGFloat parentLength = MAX(sqrt(parent.x * parent.x + parent.y * parent.y), 0.0001);
                CGPoint wanted = CGPointMake(_points[i].x + parent.x / parentLength * rest,
                                             _points[i].y + parent.y / parentLength * rest);
                CGFloat stiffness = 0.22 - 0.12 * (i / (CGFloat)kSlimeBones);
                _points[i + 1].x += (wanted.x - _points[i + 1].x) * stiffness;
                _points[i + 1].y += (wanted.y - _points[i + 1].y) * stiffness;
            }
            _points[0] = anchor;
        }
    }
}

- (void)render:(CGFloat)depth {
    CGFloat bandHeight = self.slimeSize.height / kSlimeBones;
    CGFloat squeeze = 1 - 0.3 * depth; // a little narrower while going through the hole
    for (NSInteger i = 0; i < kSlimeBones; i++) {
        CALayer* band = self.bands[i];
        CGPoint a = _points[i], b = _points[i + 1];
        CGFloat dx = b.x - a.x, dy = b.y - a.y;
        CGFloat dist = sqrt(dx * dx + dy * dy);
        CGFloat stretch = dist / MAX(bandHeight, 0.0001);
        CGFloat width = MAX(0.7, MIN(1.3, 1 / sqrt(MAX(stretch, 0.05)))) * squeeze;
        if (stretch < 1) {
            // Squashed bones bulge only a little; the squeeze already narrows them.
            width = MIN(width, 1.15 * squeeze);
        }
        CGFloat angle = atan2(-dx, dy);
        _widths[i] = width;
        band.position = a;
        CATransform3D transform = CATransform3DMakeRotation(angle, 0, 0, 1);
        band.transform = CATransform3DScale(transform, width, MAX(stretch, 0.001), 1);
    }
}

// The liquid join where the body leaves the island's underside. On each side a concave
// fillet runs from the island's flat underside (tangent to it) down into the body's edge
// (tangent to that, arriving upward), so the island flows into the silhouette with no
// corner, step or ledge. `energy` (0 at rest, 1 being sucked in) makes the join thicker
// and longer, so going in it reads as liquid drawn up through a neck, not a slide.
- (CGPathRef)newJunctionAt:(CGFloat)island energy:(CGFloat)energy CF_RETURNS_RETAINED {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat radius = 6 + 7 * energy, depth = 6 + 6 * energy;
    CGFloat y = island + depth;
    // Where the body crosses that row: which bone, and how far down the picture.
    NSInteger bone = -1;
    CGFloat t = 0;
    for (NSInteger i = 0; i < kSlimeBones; i++) {
        CGFloat y0 = _points[i].y, y1 = _points[i + 1].y;
        if (y >= MIN(y0, y1) && y <= MAX(y0, y1) && fabs(y1 - y0) > 0.001) {
            bone = i;
            t = (y - y0) / (y1 - y0);
            break;
        }
    }
    if (bone < 0) {
        return path;
    }
    CGFloat cx = _points[bone].x + (_points[bone + 1].x - _points[bone].x) * t;
    CGFloat left, right;
    SlimeEdgesAt((bone + t) / kSlimeBones, &left, &right);
    CGFloat w = kSlimeWidth * _widths[bone];
    CGFloat edges[2] = {cx + (left - 0.5) * w, cx + (right - 0.5) * w};
    // A thin tip (the ears going in last) only gets a small join, which shrinks away.
    CGFloat scale = MIN(1, MAX(0, (edges[1] - edges[0]) / 8));
    radius *= scale;
    depth *= MAX(scale, 0.3);
    y = island + depth;
    CGFloat yb = island - 0.5;
    for (NSInteger k = 0; k < 2; k++) {
        CGFloat side = k == 0 ? -1 : 1, e = edges[k];
        CGPoint S = CGPointMake(e + side * radius, yb), E = CGPointMake(e, y);
        CGPathMoveToPoint(path, NULL, S.x, island - 3);
        CGPathAddLineToPoint(path, NULL, S.x, S.y);
        CGPathAddCurveToPoint(path, NULL, S.x - side * radius * 0.62, S.y, E.x, E.y - depth * 0.62, E.x, E.y);
        // back up inside the body and the island
        CGPathAddLineToPoint(path, NULL, e - side * 3, E.y);
        CGPathAddLineToPoint(path, NULL, e - side * 3, island - 3);
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
    // Only on the home timeline: once its logo is off screen (another tab, a pushed page
    // such as settings) or something is presented over it, the slime is gone at once.
    UIImageView* logo = self.logo;
    BOOL onTimeline = logo && logo.window == window && !window.rootViewController.presentedViewController;
    if (!onTimeline) {
        self.out = 0;
        self.velocity = 0;
        self.thumped = NO;
        _pointsReady = NO;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.container.hidden = YES;
        [CATransaction commit];
        return;
    }
    SetLogoHiddenByIsland(logo, YES);
    if (self.container.superlayer != window.layer) {
        [window.layer addSublayer:self.container];
    }
    BOOL dark = window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    CGFloat dt = MIN(1.0 / 30.0, MAX(1.0 / 240.0, link.targetTimestamp - link.timestamp));
    CFTimeInterval now = CACurrentMediaTime();
    self.clock += dt;

    CGFloat target = [self barShown];
    if (!still && target > 0.9 && now > self.nextPeek) {
        // Duck in for a moment, then come back out.
        self.peekUntil = now + 0.6;
        self.nextPeek = now + 30 + arc4random_uniform(30);
        self.thumped = NO;
    }
    if (now < self.peekUntil) {
        target = 0;
    }
    if (!still && _pointsReady && now > self.nextTwitch && self.out > 0.9) {
        // An ear twitch: a small flick at the head that ripples back up.
        CGFloat side = arc4random_uniform(2) ? 1 : -1;
        _previous[kSlimeBones].x -= side * 2.2;
        _previous[kSlimeBones - 1].x += side * 1.0;
        self.nextTwitch = now + 5 + arc4random_uniform(7);
    }

    if (still) {
        self.out = target;
        self.velocity = 0;
    } else {
        // How far out rides a spring: coming out a little underdamped (a soft boing, not a
        // big stretch), going in steadier (a slurp, the head dragged in last). The rig adds
        // the follow-through on top. Both run 1.3x the first version's speed.
        BOOL comingOut = target > self.out;
        CGFloat stiffness = comingOut ? 220 : 51, damping = comingOut ? 17 : 13;
        CGFloat before = self.velocity;
        self.velocity += (stiffness * (target - self.out) - damping * self.velocity) * dt;
        self.out = MAX(0, self.out + self.velocity * dt);
        if (!self.thumped && before > 0 && self.velocity <= 0 && self.out > 0.9) {
            self.thumped = YES;
            if ([BHTSettings boolForKey:@"kemo_haptics"] && !NSProcessInfo.processInfo.isLowPowerModeEnabled) {
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft] impactOccurred];
            }
        }
    }
    // Going in, the root of the chain slides up into the island and the rest follows it
    // (so the head is dragged in last); past full length the bones stretch instead, so
    // it never comes loose from the island.
    CGFloat depth = MAX(0, 1 - self.out);
    CGFloat breathe = still ? 0 : sin(self.clock * 2.0) * 0.03; // breathing, slow and visible
    CGFloat length = MAX(1, self.out) * (1 + breathe);
    CGPoint anchor = CGPointMake(CGRectGetMidX(window.bounds),
                                 IslandBottom(window) - kSlimeTuck - depth * (self.slimeSize.height + 4));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self simulate:dt anchor:anchor length:length still:still];
    [self render:depth];
    // Thicker while it is pulled in or stretched, settling to a slim join at rest.
    CGFloat energy = MIN(1, depth * 1.4 + MAX(0, -self.velocity) * 0.15 + MAX(0, self.out - 1) * 2);
    CGPathRef junction = [self newJunctionAt:IslandBottom(window) energy:energy];
    self.junction.path = junction;
    CGPathRelease(junction);
    self.container.frame = window.bounds;
    self.container.hidden = depth > 0.98;
    // Whatever is pulled up past the island would show above it, in the status bar:
    // only draw from a little above the island's bottom edge (the island hides the rest).
    if (!self.container.mask) {
        self.container.mask = [CALayer layer];
        self.container.mask.backgroundColor = [UIColor blackColor].CGColor;
    }
    CGFloat clipTop = IslandBottom(window) - 30;
    self.container.mask.frame = CGRectMake(0, clipTop, CGRectGetWidth(window.bounds),
                                           CGRectGetHeight(window.bounds) - clipTop);
    // Black on a black bar would vanish: a faint light edge keeps it readable in dark mode.
    self.container.shadowColor = [UIColor whiteColor].CGColor;
    self.container.shadowOffset = CGSizeZero;
    self.container.shadowRadius = 1.5;
    self.container.shadowOpacity = dark ? 0.55 : 0;
    [CATransaction commit];

    CGPoint tip = _points[kSlimeBones];
    self.debug = [NSString stringWithFormat:@"islandBottom=%.1f bar=%.2f out=%.2f v=%.2f tip=(%.1f, %.1f) dark=%d",
                                            IslandBottom(window), target, self.out, self.velocity,
                                            tip.x - anchor.x, tip.y - anchor.y, dark];
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
