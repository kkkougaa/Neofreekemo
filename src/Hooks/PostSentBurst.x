//
//  PostSentBurst.x
//  NeoFreeBird
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"

// MARK: - Burst when a tweet is sent

// The compose screen already treats the send button (after the confirm alert, if
// that is on) as "this tweet is on its way". That path calls NFBNoteTweetPosted.
// The home logo then blinks once, swells, and throws a short ring of accent dots.
// Reduce Motion keeps a fade in place and skips the moving parts.

extern UIImageView* HeaderLogoInWindow(UIWindow* window);
extern UIWindow* NFBKeyWindow(void);
extern UIImage* NFBRenderLogoSVG(NSString* fileName, CGSize size, UIColor* color);

static const NSInteger kLogoDotsTag = 0x4E464C44;
static NSTimeInterval gLastPostNote = 0;

static UIView* TitleControlForLogo(UIView* logo) {
    for (UIView* view = logo; view; view = view.superview) {
        if ([NSStringFromClass(view.class) containsString:@"NavigationBarTitleControl"]) {
            return view;
        }
    }
    return nil;
}

static CAGradientLayer* FlashLayer(UIColor* color) {
    CAGradientLayer* flash = [CAGradientLayer layer];
    flash.type = kCAGradientLayerRadial;
    flash.startPoint = CGPointMake(0.5, 0.5);
    flash.endPoint = CGPointMake(1, 1);
    flash.locations = @[ @0.0, @0.4, @0.75 ];
    flash.colors = @[
        (id)[color colorWithAlphaComponent:0.55].CGColor,
        (id)[color colorWithAlphaComponent:0.16].CGColor,
        (id)[color colorWithAlphaComponent:0.0].CGColor
    ];
    flash.opacity = 0;
    flash.contentsScale = UIScreen.mainScreen.scale;
    return flash;
}

static void PlaceFlash(CALayer* flash, UIImageView* logo, UIView* control) {
    CGPoint center = [control convertPoint:CGPointMake(CGRectGetMidX(logo.bounds), CGRectGetMidY(logo.bounds))
                                   fromView:logo];
    CGFloat side = MAX(MAX(CGRectGetWidth(logo.bounds), CGRectGetHeight(logo.bounds)), 24) * 3.0;
    flash.bounds = CGRectMake(0, 0, side, side);
    flash.position = center;
}

static void BlinkOnce(UIImageView* logo) {
    if (!logo.image || CGRectGetWidth(logo.bounds) < 1 || [logo viewWithTag:kLogoDotsTag]) {
        return;
    }
    UIColor* color = logo.tintColor ?: CurrentAccentColor();
    UIImage* closed = NFBRenderLogoSVG(@"logo_blink.svg", logo.bounds.size, color);
    if (!closed) {
        return;
    }
    UIImage* open = logo.image;
    logo.image = closed;
    __weak UIImageView* weakLogo = logo;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIImageView* current = weakLogo;
                       if (current.image == closed) {
                           current.image = open;
                       }
                   });
}

static void SwellOnce(UIImageView* logo) {
    CABasicAnimation* swell = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    swell.fromValue = @1.0;
    swell.toValue = @1.06;
    swell.duration = 0.26;
    swell.autoreverses = YES;
    swell.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [logo.layer addAnimation:swell forKey:@"nfbPostSwell"];
}

static void BurstDots(UIImageView* logo) {
    UIWindow* window = logo.window;
    if (!window) {
        return;
    }
    CGPoint mid = CGPointMake(CGRectGetMidX(logo.bounds), CGRectGetMidY(logo.bounds));
    CGPoint at = [logo.layer convertPoint:mid toLayer:window.layer];
    UIColor* color = CurrentAccentColor();
    static const NSInteger kCount = 12;
    for (NSInteger i = 0; i < kCount; i++) {
        CGFloat angle = (M_PI * 2 / kCount) * i + 0.35;
        CGFloat size = (i % 2) ? 6.0 : 8.0;
        UIView* dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
        dot.userInteractionEnabled = NO;
        dot.backgroundColor = color;
        dot.layer.cornerRadius = size / 2;
        dot.center = at;
        dot.alpha = 0.9;
        [window addSubview:dot];
        CGFloat distance = 22 + (i % 4) * 8;
        [UIView animateWithDuration:0.8
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             dot.center = CGPointMake(at.x + cos(angle) * distance,
                                                      at.y + sin(angle) * distance);
                             dot.alpha = 0;
                             dot.transform = CGAffineTransformMakeScale(0.25, 0.25);
                         }
                         completion:^(BOOL finished) {
                             [dot removeFromSuperview];
                         }];
        __weak UIView* weakDot = dot;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakDot removeFromSuperview];
                       });
    }
}

static void PlayBurst(UIImageView* logo) {
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    UIView* control = TitleControlForLogo(logo);
    if (control) {
        CAGradientLayer* flash = FlashLayer(CurrentAccentColor());
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        PlaceFlash(flash, logo, control);
        [CATransaction commit];
        [control.layer insertSublayer:flash atIndex:0];
        CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0;
        fade.toValue = reduce ? @0.45 : @0.9;
        fade.duration = 0.22;
        fade.autoreverses = YES;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [flash addAnimation:fade forKey:@"flash"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [flash removeFromSuperlayer];
                       });
    }
    if (reduce) {
        return;
    }
    BlinkOnce(logo);
    SwellOnce(logo);
    BurstDots(logo);
}

static void PlayWhenReady(NSInteger attempt) {
    if (![BHTSettings boolForKey:@"kemo_post_burst"]) {
        return;
    }
    UIWindow* window = NFBKeyWindow();
    UIImageView* logo = window ? HeaderLogoInWindow(window) : nil;
    if (!logo) {
        if (attempt < 4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               PlayWhenReady(attempt + 1);
                           });
        }
        return;
    }
    PlayBurst(logo);
}

// Called from the real send path in Confirmations.x, including after the
// confirm alert. A second call inside the same second is the same send.
void NFBNoteTweetPosted(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NFBNoteTweetPosted();
        });
        return;
    }
    if (![BHTSettings boolForKey:@"kemo_post_burst"]) {
        return;
    }
    NSTimeInterval now = CACurrentMediaTime();
    if (now - gLastPostNote < 1.0) {
        return;
    }
    gLastPostNote = now;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       PlayWhenReady(0);
                   });
}

// 12.38.1 still has _t1_didTapSendButton: on T1TweetComposeViewController (Confirmations
// calls NFBNoteTweetPosted from there) and on T1ComposeViewController. The redesigned
// toolbar calls composerToolbarDidTapPost:, and the compositions actually leave through
// _t1_sendCompositions:. Inline compose reports success with didSendComposition:.
// The one-second guard in NFBNoteTweetPosted collapses these into a single burst.

%hook T1TweetComposeViewController

- (void)composerToolbarDidTapPost:(id)sender {
    %orig;
    NFBNoteTweetPosted();
}

- (void)_t1_sendCompositions:(id)compositions {
    %orig;
    NFBNoteTweetPosted();
}

%end

%hook T1ComposeViewController

- (void)_t1_didTapSendButton:(id)sender {
    %orig;
    NFBNoteTweetPosted();
}

%end

%hook T1MediaInlineComposeController

- (void)composeBarViewController:(id)controller didSendComposition:(id)composition {
    %orig;
    NFBNoteTweetPosted();
}

- (void)_t1_didSendInlineCompose:(id)note {
    %orig;
    NFBNoteTweetPosted();
}

%end
