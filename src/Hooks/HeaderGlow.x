//
//  HeaderGlow.x
//  NeoFreeBird
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"

// MARK: - Dark header glow

// A soft blue-purple halo behind the home logo. One opacity animation (about six
// seconds for a full breath) does the work, so it costs a compositor fade and
// nothing on the CPU. It is only added in a dark or dim palette, it does not
// take touches, and it pauses while the app is in the background.

static const void* kHaloKey = &kHaloKey;
static BOOL gGlowBackgrounded = NO;
static BOOL gUpdatingGlow = NO;

static NSHashTable<CAGradientLayer*>* LiveHalos(void) {
    static NSHashTable* halos;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        halos = [NSHashTable weakObjectsHashTable];
    });
    return halos;
}

static BOOL GlowOn(void) {
    return [BHTSettings boolForKey:@"kemo_header_glow"];
}

static BOOL AppearanceIsDark(UIView* view) {
    if (view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        return YES;
    }
    Class settingsClass = objc_getClass("TAEColorSettings");
    if (!settingsClass) {
        return NO;
    }
    TAEColorSettings* settings = [settingsClass sharedSettings];
    return settings.currentColorPalette.isDark;
}

static UIColor* HaloColor(void) {
    UIColor* accent = CurrentAccentColor() ?: [UIColor colorWithRed:0.36 green:0.52 blue:0.98 alpha:1];
    UIColor* resolved = [accent resolvedColorWithTraitCollection:[UITraitCollection currentTraitCollection]];
    CGFloat r = 0.36, g = 0.52, b = 0.98, a = 1;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0;
        if ([resolved getWhite:&white alpha:&a]) {
            r = g = b = white;
        }
    }
    // Keep the halo in the blue-purple range even when the accent is a warm colour.
    return [UIColor colorWithRed:r * 0.62 + 0.42 * 0.38
                           green:g * 0.62 + 0.40 * 0.38
                            blue:b * 0.62 + 0.96 * 0.38
                           alpha:1];
}

static UIImageView* LogoInControl(UIView* control) {
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:control];
    NSUInteger index = 0;
    while (index < queue.count && index < 40) {
        UIView* view = queue[index++];
        if ([view isKindOfClass:[UIImageView class]] && !view.hidden && view.alpha > 0.01) {
            CGFloat width = CGRectGetWidth(view.bounds);
            if (width >= 24 && width <= 80) {
                return (UIImageView*)view;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static void TintHalo(CAGradientLayer* halo, UIColor* color) {
    halo.colors = @[
        (id)[color colorWithAlphaComponent:0.50].CGColor,
        (id)[color colorWithAlphaComponent:0.18].CGColor,
        (id)[color colorWithAlphaComponent:0.0].CGColor
    ];
}

static CAGradientLayer* MakeHalo(void) {
    CAGradientLayer* halo = [CAGradientLayer layer];
    halo.type = kCAGradientLayerRadial;
    halo.startPoint = CGPointMake(0.5, 0.5);
    halo.endPoint = CGPointMake(1, 1);
    // The outer stop is clear, so the visible light stays inside the logo's neighbourhood.
    halo.locations = @[ @0.0, @0.32, @0.62 ];
    halo.contentsScale = UIScreen.mainScreen.scale;
    return halo;
}

static void PauseHalo(CALayer* layer) {
    if (layer.speed == 0) {
        return;
    }
    CFTimeInterval frozen = [layer convertTime:CACurrentMediaTime() fromLayer:nil];
    layer.speed = 0;
    layer.timeOffset = frozen;
}

static void ResumeHalo(CALayer* layer) {
    if (layer.speed != 0) {
        return;
    }
    CFTimeInterval frozen = layer.timeOffset;
    layer.speed = 1;
    layer.timeOffset = 0;
    layer.beginTime = 0;
    CFTimeInterval since = [layer convertTime:CACurrentMediaTime() fromLayer:nil] - frozen;
    layer.beginTime = since;
}

static void EnsureBreath(CAGradientLayer* halo) {
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    if (reduce) {
        [halo removeAnimationForKey:@"breathe"];
        halo.speed = 1;
        halo.timeOffset = 0;
        halo.beginTime = 0;
        halo.opacity = 0.45;
        return;
    }
    if (![halo animationForKey:@"breathe"]) {
        halo.opacity = 0.55;
        CABasicAnimation* breath = [CABasicAnimation animationWithKeyPath:@"opacity"];
        breath.fromValue = @0.32;
        breath.toValue = @0.78;
        breath.duration = 3.0;
        breath.autoreverses = YES;
        breath.repeatCount = HUGE_VALF;
        breath.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [halo addAnimation:breath forKey:@"breathe"];
    }
    if (gGlowBackgrounded) {
        PauseHalo(halo);
    } else {
        ResumeHalo(halo);
    }
}

// The logo's layout position in the title control, before the control's
// sublayerTransform scales every child the same way. The halo is a sibling
// layer of that transform, so it stays behind the bird and scales with it.
static void PlaceHalo(CALayer* halo, UIImageView* logo, UIView* control) {
    CGPoint center = [control convertPoint:CGPointMake(CGRectGetMidX(logo.bounds), CGRectGetMidY(logo.bounds))
                                   fromView:logo];
    CGFloat side = MAX(CGRectGetWidth(logo.bounds), CGRectGetHeight(logo.bounds));
    side = MAX(side, 24) * 2.8;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    halo.bounds = CGRectMake(0, 0, side, side);
    halo.position = center;
    [CATransaction commit];
}

static void RemoveHalo(UIView* control) {
    CAGradientLayer* halo = objc_getAssociatedObject(control, kHaloKey);
    if (!halo) {
        return;
    }
    [halo removeAllAnimations];
    [halo removeFromSuperlayer];
    [LiveHalos() removeObject:halo];
    objc_setAssociatedObject(control, kHaloKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void UpdateHeaderGlow(UIView* control) {
    if (gUpdatingGlow || ![control isKindOfClass:[UIView class]]) {
        return;
    }
    gUpdatingGlow = YES;
    UIImageView* logo = LogoInControl(control);
    if (!GlowOn() || !logo || !logo.window || !AppearanceIsDark(control)) {
        RemoveHalo(control);
        gUpdatingGlow = NO;
        return;
    }

    CAGradientLayer* halo = objc_getAssociatedObject(control, kHaloKey);
    if (![halo isKindOfClass:[CAGradientLayer class]]) {
        halo = MakeHalo();
        objc_setAssociatedObject(control, kHaloKey, halo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [LiveHalos() addObject:halo];
    }
    TintHalo(halo, HaloColor());
    PlaceHalo(halo, logo, control);
    if (halo.superlayer != control.layer) {
        [control.layer insertSublayer:halo atIndex:0];
    }
    EnsureBreath(halo);
    gUpdatingGlow = NO;
}

static void SetHalosPaused(BOOL paused) {
    gGlowBackgrounded = paused;
    for (CAGradientLayer* halo in LiveHalos().allObjects) {
        if (![halo animationForKey:@"breathe"]) {
            continue;
        }
        if (paused) {
            PauseHalo(halo);
        } else {
            ResumeHalo(halo);
        }
    }
}

%hook _UINavigationBarTitleControl

- (void)layoutSubviews {
    %orig;
    UpdateHeaderGlow((UIView*)self);
}

- (void)didMoveToWindow {
    %orig;
    UpdateHeaderGlow((UIView*)self);
}

- (void)traitCollectionDidChange:(UITraitCollection*)previous {
    %orig;
    UpdateHeaderGlow((UIView*)self);
}

%end

%ctor {
    // A custom constructor replaces Logos's, which is the only thing that installs the hooks above.
    %init;

    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) {
                        (void)note;
                        SetHalosPaused(YES);
                    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) {
                        (void)note;
                        SetHalosPaused(NO);
                    }];
    [center addObserverForName:UIAccessibilityReduceMotionStatusDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) {
                        (void)note;
                        for (CAGradientLayer* halo in LiveHalos().allObjects) {
                            EnsureBreath(halo);
                        }
                    }];
}
