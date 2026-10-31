//
//  LikeHearts.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Like heart particles

// A like (never an unlike) lifts a few small hearts off the button. They live on the
// window, not in the cell, so a reused row cannot keep them, and the host refuses
// hits so the button underneath still receives the touch.

static const void* kArmedAtKey = &kArmedAtKey;
static const void* kBurstAtKey = &kBurstAtKey;
static const void* kArmedHostKey = &kArmedHostKey;
static const NSTimeInterval kArmLifetime = 12.0;

static BOOL HeartsOn(void) {
    return [BHTSettings boolForKey:@"kemo_like_hearts"];
}

static BOOL IsFavoriteView(UIView* view) {
    if (!view) {
        return NO;
    }
    static Class favorite;
    if (!favorite) {
        favorite = objc_getClass("TTAStatusInlineFavoriteButton");
    }
    if (favorite) {
        return [view isKindOfClass:favorite];
    }
    return [NSStringFromClass(view.class) isEqualToString:@"TTAStatusInlineFavoriteButton"];
}

static UIView* FavoriteHost(UIView* view) {
    for (UIView* step = view; step; step = step.superview) {
        if (IsFavoriteView(step)) {
            return step;
        }
        if ([step isKindOfClass:[UITableViewCell class]] ||
            [step isKindOfClass:[UICollectionViewCell class]]) {
            break;
        }
    }
    return nil;
}

static UIView* EnclosingCell(UIView* view) {
    for (UIView* step = view; step; step = step.superview) {
        if ([step isKindOfClass:[UITableViewCell class]] ||
            [step isKindOfClass:[UICollectionViewCell class]]) {
            return step;
        }
    }
    return nil;
}

static void ArmHost(UIView* host) {
    if (!host) {
        return;
    }
    objc_setAssociatedObject(host, kArmedAtKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView* cell = EnclosingCell(host);
    if (cell) {
        objc_setAssociatedObject(cell, kArmedHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void DisarmHost(UIView* host) {
    if (!host) {
        return;
    }
    objc_setAssociatedObject(host, kArmedAtKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ArmIsLive(UIView* host) {
    NSDate* armed = objc_getAssociatedObject(host, kArmedAtKey);
    return armed && -[armed timeIntervalSinceNow] < kArmLifetime;
}

@interface NFBHeartHost : UIView
@end

@implementation NFBHeartHost

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    (void)point;
    (void)event;
    return NO;
}

@end

static UIImage* HeartGlyph(void) {
    static UIImage* glyph;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImageSymbolConfiguration* config =
            [UIImageSymbolConfiguration configurationWithPointSize:13
                                                            weight:UIImageSymbolWeightRegular];
        glyph = [[UIImage systemImageNamed:@"heart.fill" withConfiguration:config]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return glyph;
}

// The painted heart once it is liked. A near-black or near-white tint is the
// unliked outline, so those fall back to the usual like pink.
static UIColor* LikeTint(UIView* source) {
    UIColor* tint = nil;
    if ([source isKindOfClass:[UIButton class]]) {
        UIButton* button = (UIButton*)source;
        tint = button.imageView.tintColor ?: button.tintColor;
    }
    if (!tint) {
        for (UIView* sub in source.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] && sub.tintColor) {
                tint = sub.tintColor;
                break;
            }
            if ([sub isKindOfClass:[UIButton class]]) {
                tint = ((UIButton*)sub).tintColor;
                break;
            }
        }
    }
    if (tint) {
        tint = [tint resolvedColorWithTraitCollection:source.traitCollection];
    }
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (tint && [tint getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat maxc = MAX(r, MAX(g, b));
        CGFloat minc = MIN(r, MIN(g, b));
        if (a > 0.4 && maxc > 0.25 && maxc < 0.97 && (maxc - minc) > 0.12) {
            return tint;
        }
    }
    return [UIColor colorWithRed:0.973 green:0.114 blue:0.498 alpha:1];
}

static BOOL ControlIsSelected(UIView* view) {
    if ([view isKindOfClass:[UIControl class]]) {
        return ((UIControl*)view).isSelected;
    }
    for (UIView* sub in view.subviews) {
        if ([sub isKindOfClass:[UIControl class]] && ((UIControl*)sub).isSelected) {
            return YES;
        }
    }
    return NO;
}

static void SpawnHeartsAt(CGPoint center, UIWindow* window, UIColor* color) {
    if (!window || !HeartsOn()) {
        return;
    }
    UIImage* glyph = HeartGlyph();
    if (!glyph) {
        return;
    }
    NFBHeartHost* host = [[NFBHeartHost alloc] initWithFrame:window.bounds];
    host.userInteractionEnabled = NO;
    host.backgroundColor = [UIColor clearColor];
    host.opaque = NO;
    host.isAccessibilityElement = NO;
    host.accessibilityElementsHidden = YES;
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:host];

    static const NSInteger kCount = 6;
    for (NSInteger i = 0; i < kCount; i++) {
        CGFloat side = 7 + (i % 3) * 2;
        UIImageView* heart = [[UIImageView alloc] initWithImage:glyph];
        heart.userInteractionEnabled = NO;
        heart.isAccessibilityElement = NO;
        heart.tintColor = color;
        heart.contentMode = UIViewContentModeScaleAspectFit;
        heart.bounds = CGRectMake(0, 0, side, side);
        CGFloat spread = ((i / (CGFloat)(kCount - 1)) - 0.5) * 22.0;
        heart.center = CGPointMake(center.x + spread * 0.25, center.y + 1);
        heart.alpha = 0.95;
        heart.transform = CGAffineTransformMakeScale(0.45, 0.45);
        [host addSubview:heart];

        CGFloat rise = 26.0 + (i % 3) * 7.0;
        NSTimeInterval duration = 0.62 + (i % 4) * 0.07;
        NSTimeInterval delay = i * 0.025;
        CGPoint end = CGPointMake(center.x + spread, center.y - rise);
        [UIView animateWithDuration:duration
                              delay:delay
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             heart.center = end;
                             heart.alpha = 0;
                             heart.transform = CGAffineTransformMakeScale(0.85, 0.85);
                         }
                         completion:^(BOOL finished) {
                             [heart removeFromSuperview];
                         }];
    }

    if ([BHTSettings boolForKey:@"kemo_haptics"]) {
        UIImpactFeedbackGenerator* haptic =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
        [haptic impactOccurred];
    }

    __weak UIView* weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakHost removeFromSuperview];
                   });
}

static void SpawnFromView(UIView* source) {
    if (!source.window || !ArmIsLive(source)) {
        return;
    }
    NSDate* last = objc_getAssociatedObject(source, kBurstAtKey);
    if (last && -[last timeIntervalSinceNow] < 0.4) {
        DisarmHost(source);
        return;
    }
    DisarmHost(source);
    objc_setAssociatedObject(source, kBurstAtKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGPoint center = [source convertPoint:CGPointMake(CGRectGetMidX(source.bounds),
                                                      CGRectGetMidY(source.bounds))
                                 toView:source.window];
    SpawnHeartsAt(center, source.window, LikeTint(source));
}

static void NoteFavoriteTap(UIView* button, BOOL selectedBefore, UIImage* imageBefore) {
    UIView* host = FavoriteHost(button) ?: button;
    if (!IsFavoriteView(host) && !IsFavoriteView(button)) {
        return;
    }
    if (!HeartsOn()) {
        DisarmHost(host);
        return;
    }
    if (selectedBefore) {
        DisarmHost(host);
        return;
    }
    ArmHost(host);
    BOOL selectedNow = ControlIsSelected(button) || ControlIsSelected(host);
    BOOL imageChanged = [button isKindOfClass:[UIButton class]] &&
                        ((UIButton*)button).imageView.image != imageBefore;
    if (selectedNow || imageChanged) {
        SpawnFromView(host);
    }
}

%hook TFNAnimatableButton

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent*)event {
    UIButton* button = (UIButton*)self;
    UIView* host = FavoriteHost(button);
    BOOL watch = host && HeartsOn();
    BOOL selectedBefore = watch && button.isSelected;
    UIImage* imageBefore = watch ? button.imageView.image : nil;
    if (watch && !selectedBefore) {
        ArmHost(host);
    } else if (watch && selectedBefore) {
        DisarmHost(host);
    }
    %orig;
    if (watch && !selectedBefore) {
        NoteFavoriteTap(button, NO, imageBefore);
    }
}

- (void)setSelected:(BOOL)selected {
    UIView* host = FavoriteHost((UIView*)self);
    %orig;
    if (selected && host && ArmIsLive(host)) {
        SpawnFromView(host);
    }
}

%end

%hook TTAStatusInlineActionsView

- (void)didTapInlineActionButton:(UIView*)button {
    BOOL favorite = IsFavoriteView(button);
    BOOL selectedBefore = favorite && ControlIsSelected(button);
    if (favorite && !selectedBefore && HeartsOn()) {
        ArmHost(button);
    } else if (favorite && selectedBefore) {
        DisarmHost(button);
    }
    %orig;
    if (favorite && !selectedBefore && ControlIsSelected(button)) {
        SpawnFromView(button);
    }
}

%end

%hook T1SlideshowStatusView

- (void)_favoriteAction:(id)sender {
    UIView* view = [sender isKindOfClass:[UIView class]] ? sender : nil;
    BOOL selectedBefore = [view isKindOfClass:[UIControl class]] && ((UIControl*)view).isSelected;
    if (view && !selectedBefore && HeartsOn()) {
        ArmHost(view);
    }
    %orig;
    if (view && !selectedBefore && [view isKindOfClass:[UIControl class]] &&
        ((UIControl*)view).isSelected) {
        SpawnFromView(view);
    }
}

%end

// This gesture only likes, but the confirm alert can still cancel it.
%hook _TtC14T1TwitterSwift32ImmersiveDoubleTapLikePluginView

- (void)handleDoubleTap:(id)gesture {
    %orig;
    if (!HeartsOn() || [BHTSettings boolForKey:@"like_confirm"]) {
        return;
    }
    UIView* view = nil;
    CGPoint point = CGPointZero;
    if ([gesture isKindOfClass:[UIGestureRecognizer class]]) {
        UIGestureRecognizer* recognizer = gesture;
        view = recognizer.view;
        if (view.window) {
            point = [recognizer locationInView:view.window];
        }
    } else {
        // Logos only forward-declares this Swift class, so self cannot be messaged.
        id receiver = (id)self;
        if ([receiver isKindOfClass:[UIView class]]) {
            view = receiver;
            point = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                               toView:view.window];
        }
    }
    if (!view.window) {
        return;
    }
    SpawnHeartsAt(point, view.window, [UIColor colorWithRed:0.973 green:0.114 blue:0.498 alpha:1]);
}

%end

%hook UITableViewCell

- (void)prepareForReuse {
    UIView* host = objc_getAssociatedObject(self, kArmedHostKey);
    DisarmHost(host);
    objc_setAssociatedObject(self, kArmedHostKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}

%end

%hook UICollectionViewCell

- (void)prepareForReuse {
    UIView* host = objc_getAssociatedObject(self, kArmedHostKey);
    DisarmHost(host);
    objc_setAssociatedObject(self, kArmedHostKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}

%end
