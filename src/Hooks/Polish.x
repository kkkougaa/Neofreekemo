//
//  Polish.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Paw print loading spinner

// Standard spinners are drawn as four paw prints that appear one after another. The
// spinner's own spokes are made see-through while the paws run.

static const NSInteger kPawTag = 0x4E465057;
static const void* kPawColorKey = &kPawColorKey;

static UIBezierPath* PawPath(CGFloat size) {
    CGFloat unit = size / 24.0;
    UIBezierPath* path = [UIBezierPath bezierPath];
    NSArray<NSValue*>* ovals = @[
        [NSValue valueWithCGRect:CGRectMake(6.5, 11.5, 11, 9)],
        [NSValue valueWithCGRect:CGRectMake(2.8, 7.2, 4.4, 5.6)],
        [NSValue valueWithCGRect:CGRectMake(7.3, 2.7, 4.4, 5.6)],
        [NSValue valueWithCGRect:CGRectMake(12.3, 2.7, 4.4, 5.6)],
        [NSValue valueWithCGRect:CGRectMake(16.8, 7.2, 4.4, 5.6)],
    ];
    for (NSValue* value in ovals) {
        CGRect rect = value.CGRectValue;
        [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(
                                           rect.origin.x * unit, rect.origin.y * unit,
                                           rect.size.width * unit, rect.size.height * unit)]];
    }
    return path;
}

static void PawStop(UIActivityIndicatorView* spinner) {
    UIView* paws = [spinner viewWithTag:kPawTag];
    if (!paws) {
        return;
    }
    [paws removeFromSuperview];
    UIColor* original = objc_getAssociatedObject(spinner, kPawColorKey);
    if (original) {
        spinner.color = [original isKindOfClass:[UIColor class]] ? original : nil;
    }
    objc_setAssociatedObject(spinner, kPawColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL PawRefreshOnHome(UIActivityIndicatorView* spinner) {
    BOOL refresh = NO;
    for (UIView* view = spinner; view; view = view.superview) {
        NSString* name = NSStringFromClass(view.class);
        if ([name containsString:@"PullToRefresh"] || [name containsString:@"RefreshControl"]) {
            refresh = YES;
            break;
        }
    }
    if (!refresh) {
        return NO;
    }
    for (UIResponder* responder = spinner; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:[UIViewController class]]) {
            continue;
        }
        if ([NSStringFromClass([(UIViewController*)responder class]) containsString:@"HomeTimeline"]) {
            return YES;
        }
    }
    return NO;
}

static void PawStart(UIActivityIndicatorView* spinner) {
    if (![BHTSettings boolForKey:@"kemo_paw_loading"] || [spinner viewWithTag:kPawTag] ||
        !PawRefreshOnHome(spinner)) {
        return;
    }
    objc_setAssociatedObject(spinner, kPawColorKey, spinner.color ?: (id)[NSNull null],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    spinner.color = [UIColor clearColor];

    static const CGFloat kPaw = 16.5;
    static const CGFloat kStep = 21.0;
    UIView* paws = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kStep * 4, 36)];
    paws.tag = kPawTag;
    paws.userInteractionEnabled = NO;
    paws.center = CGPointMake(CGRectGetMidX(spinner.bounds), CGRectGetMidY(spinner.bounds));
    CFTimeInterval now = CACurrentMediaTime();
    for (int i = 0; i < 4; i++) {
        CAShapeLayer* paw = [CAShapeLayer layer];
        paw.path = PawPath(kPaw).CGPath;
        paw.fillColor = CurrentAccentColor().CGColor;
        paw.frame = CGRectMake(1.5 + i * kStep, i % 2 ? 18 : 1.5, kPaw, kPaw);
        paw.opacity = 0;

        CAKeyframeAnimation* fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[ @0, @1, @1, @0, @0 ];
        fade.keyTimes = @[ @0, @0.15, @0.55, @0.8, @1 ];
        CAKeyframeAnimation* grow = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        grow.values = @[ @0.6, @1, @1, @1, @1 ];
        grow.keyTimes = @[ @0, @0.15, @0.55, @0.8, @1 ];
        CAAnimationGroup* group = [CAAnimationGroup animation];
        group.animations = @[ fade, grow ];
        group.duration = 1.6;
        group.repeatCount = HUGE_VALF;
        group.beginTime = now + i * 0.3;
        group.fillMode = kCAFillModeBackwards;
        [paw addAnimation:group forKey:@"walk"];
        [paws.layer addSublayer:paw];
    }
    [spinner addSubview:paws];
}

%hook UIActivityIndicatorView

- (void)startAnimating {
    %orig;
    PawStart(self);
}

- (void)stopAnimating {
    PawStop(self);
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window) {
        PawStop(self);
    }
}

%end

// MARK: - Bookmark icon wiggle

// The bookmark button's icon wiggles like a ribbon when the tweet gets bookmarked.

static void WiggleIcon(UIView* icon) {
    CAKeyframeAnimation* turn = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
    turn.values = @[ @0, @(-0.3), @0.22, @(-0.12), @0.05, @0 ];
    CAKeyframeAnimation* hop = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
    hop.values = @[ @0, @(-3), @0.5, @0, @0, @0 ];
    CAAnimationGroup* group = [CAAnimationGroup animation];
    group.animations = @[ turn, hop ];
    group.duration = 0.55;
    [icon.layer addAnimation:group forKey:@"wiggle"];
    if ([BHTSettings boolForKey:@"kemo_haptics"]) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
}

%hook TFNAnimatableButton

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent*)event {
    UIButton* button = (UIButton*)self;
    BOOL isBookmark = [BHTSettings boolForKey:@"kemo_bookmark_wiggle"] &&
                      [NSStringFromClass(button.superview.class) isEqualToString:@"TTAStatusInlineBookmarkButton"];
    BOOL before = button.isSelected;
    UIImage* imageBefore = button.imageView.image;
    %orig;
    if (!isBookmark) {
        return;
    }
    __weak UIButton* weakButton = button;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIButton* current = weakButton;
                       if (!current.window) {
                           return;
                       }
                       // Wiggle when it became selected; if the app does not use the selected
                       // state, an icon that changed at all counts as bookmarked.
                       BOOL nowSelected = current.isSelected;
                       if (nowSelected != before ? nowSelected : current.imageView.image != imageBefore) {
                           WiggleIcon(current.imageView);
                       }
                   });
}

%end

// MARK: - Images reveal from a blur

// An image that arrives after a visible wait fades in out of a blur instead of popping in.
// Images that are set right away (reused cells, cached pictures) are left alone.

static const void* kEmptySinceKey = &kEmptySinceKey;
static const NSInteger kRevealTag = 0x4E465256;

%hook _TtC21TweetMediaAttachments23MultiMediaViewImageView

- (void)setImage:(UIImage*)image {
    UIImageView* view = (UIImageView*)self;
    UIImage* previous = view.image;
    %orig;
    if (![BHTSettings boolForKey:@"kemo_image_reveal"]) {
        return;
    }
    if (!image) {
        objc_setAssociatedObject(view, kEmptySinceKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSDate* since = objc_getAssociatedObject(view, kEmptySinceKey);
    if (previous || !since || -[since timeIntervalSinceNow] < 0.15 || !view.window ||
        [view viewWithTag:kRevealTag]) {
        return;
    }
    objc_setAssociatedObject(view, kEmptySinceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIVisualEffectView* blur =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular]];
    blur.tag = kRevealTag;
    blur.frame = view.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [view addSubview:blur];
    [UIView animateWithDuration:0.6
        delay:0.05
        options:UIViewAnimationOptionCurveEaseOut
        animations:^{
            blur.alpha = 0;
        }
        completion:^(BOOL finished) {
            [blur removeFromSuperview];
        }];
}

%end
