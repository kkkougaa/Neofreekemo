//
//  DoubleTapLike.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Double tap a tweet's photo or video to like it
// With "kemo_double_tap_like" on, two quick taps on a timeline tweet's media burst a
// heart over it and like the tweet. It never unlikes: on a tweet that is already liked
// only the heart plays. The like goes through the row's own heart button
// (-[TTAStatusInlineActionsView didTapInlineActionButton:]), so the like confirmation
// setting and X's own button animation still apply.
//
// X opens the viewer on the first tap. While this is on, that single-tap action waits
// a moment and is dropped when a second tap follows.

@interface T1StatusPhotoVideoForwardView : UIView
@end

@interface TTAStatusInlineActionsView (NFBDoubleTapLike)
- (void)didTapInlineActionButton:(UIView*)button;
@end

static NSString* const kDoubleTapKey = @"kemo_double_tap_like";
static const NSTimeInterval kSingleTapDelay = 0.26;

static const void* kRecognizerKey = &kRecognizerKey;
static const void* kPendingKey = &kPendingKey;
static const void* kSuppressUntilKey = &kSuppressUntilKey;

static BOOL NFBDoubleTapEnabled(void) {
    return [BHTSettings boolForKey:kDoubleTapKey];
}

// MARK: Like

static UIView* NFBStatusViewFor(UIView* media) {
    Class statusClass = NSClassFromString(@"T1StandardStatusView");
    Class cellClass = [UITableViewCell class];
    Class collectionCellClass = [UICollectionViewCell class];
    UIView* fallback = nil;
    for (UIView* view = media.superview; view; view = view.superview) {
        if (statusClass && [view isKindOfClass:statusClass]) {
            return view;
        }
        if ([view isKindOfClass:cellClass] || [view isKindOfClass:collectionCellClass]) {
            fallback = view;
            break;
        }
    }
    return fallback;
}

static void NFBLikeStatusOf(UIView* media) {
    UIView* status = NFBStatusViewFor(media);
    if (!status) {
        return;
    }
    Class actionsClass = NSClassFromString(@"TTAStatusInlineActionsView");
    Class favoriteClass = NSClassFromString(@"TTAStatusInlineFavoriteButton");
    if (!actionsClass || !favoriteClass) {
        return;
    }

    __block UIView* actions = nil;
    __block UIView* favorite = nil;
    EnumerateSubviewsRecursively(status, ^(UIView* view) {
        if (!actions && [view isKindOfClass:actionsClass]) {
            actions = view;
        }
        if (!favorite && [view isKindOfClass:favoriteClass]) {
            favorite = view;
        }
    });
    if (!actions || !favorite || ![actions respondsToSelector:@selector(didTapInlineActionButton:)]) {
        return;
    }
    if ([favorite respondsToSelector:@selector(isSelected)] && [(UIControl*)favorite isSelected]) {
        return; // already liked; a double tap never unlikes
    }
    [(TTAStatusInlineActionsView*)actions didTapInlineActionButton:favorite];
}

// MARK: Heart

static UIColor* NFBLikeColor(void) {
    return [UIColor colorWithRed:249 / 255.0 green:24 / 255.0 blue:128 / 255.0 alpha:1];
}

static UIImageView* NFBHeartView(CGFloat size, UIColor* color) {
    UIImageSymbolConfiguration* config =
        [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightBold];
    UIImage* image = [UIImage systemImageNamed:@"heart.fill" withConfiguration:config];
    UIImageView* view = [[UIImageView alloc]
        initWithImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    view.tintColor = color;
    view.userInteractionEnabled = NO;
    return view;
}

static void NFBBurstHeart(UIView* media, CGPoint point) {
    CGFloat side = MIN(CGRectGetWidth(media.bounds), CGRectGetHeight(media.bounds));
    CGFloat size = MAX(28, MIN(88, side * 0.42));

    UIImageView* heart = NFBHeartView(size, [UIColor whiteColor]);
    heart.layer.shadowColor = [UIColor blackColor].CGColor;
    heart.layer.shadowOpacity = 0.35;
    heart.layer.shadowRadius = 8;
    heart.layer.shadowOffset = CGSizeZero;
    heart.center = point;
    heart.transform = CGAffineTransformMakeScale(0.2, 0.2);
    heart.alpha = 0;
    [media addSubview:heart];

    UIImageView* fill = NFBHeartView(size * 0.78, NFBLikeColor());
    fill.center = CGPointMake(CGRectGetMidX(heart.bounds), CGRectGetMidY(heart.bounds) + size * 0.02);
    [heart addSubview:fill];

    [UIView animateWithDuration:0.42
        delay:0
        usingSpringWithDamping:0.45
        initialSpringVelocity:10
        options:UIViewAnimationOptionAllowUserInteraction
        animations:^{
            heart.alpha = 1;
            heart.transform = CGAffineTransformIdentity;
        }
        completion:^(BOOL finished) {
            [UIView animateWithDuration:0.35
                delay:0.25
                options:UIViewAnimationOptionCurveEaseIn
                animations:^{
                    heart.alpha = 0;
                    heart.transform = CGAffineTransformTranslate(
                        CGAffineTransformMakeScale(0.8, 0.8), 0, -size * 0.6);
                }
                completion:^(BOOL done) {
                    [heart removeFromSuperview];
                }];
        }];

    // A ring of small hearts flying outward.
    NSInteger count = side < 120 ? 5 : 8;
    CGFloat radius = size * 0.55;
    for (NSInteger i = 0; i < count; i++) {
        CGFloat angle = (CGFloat)i / count * 2 * M_PI - M_PI_2;
        UIImageView* small = NFBHeartView(MAX(9, size * 0.2), NFBLikeColor());
        small.center = point;
        small.alpha = 0;
        small.transform = CGAffineTransformMakeScale(0.3, 0.3);
        [media addSubview:small];
        [UIView animateWithDuration:0.55
            delay:0.06
            options:UIViewAnimationOptionCurveEaseOut
            animations:^{
                small.alpha = 1;
                small.transform = CGAffineTransformMakeRotation((i % 2 ? 1 : -1) * 0.35);
                small.center = CGPointMake(point.x + cos(angle) * (radius + size * 0.5),
                                           point.y + sin(angle) * (radius + size * 0.5));
            }
            completion:^(BOOL finished) {
                [UIView animateWithDuration:0.25
                    animations:^{
                        small.alpha = 0;
                    }
                    completion:^(BOOL done) {
                        [small removeFromSuperview];
                    }];
            }];
    }

    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
}

// MARK: Gesture

@interface NFBDoubleTapTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)doubleTapped:(UITapGestureRecognizer*)recognizer;
@end

@implementation NFBDoubleTapTarget

+ (instancetype)shared {
    static NFBDoubleTapTarget* target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        target = [NFBDoubleTapTarget new];
    });
    return target;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)recognizer {
    return NFBDoubleTapEnabled();
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return YES;
}

- (void)doubleTapped:(UITapGestureRecognizer*)recognizer {
    UIView* media = recognizer.view;
    if (recognizer.state != UIGestureRecognizerStateRecognized || !media.window) {
        return;
    }
    // Drop the single-tap action that the first tap queued, and the one the second
    // tap may still deliver.
    dispatch_block_t pending = objc_getAssociatedObject(media, kPendingKey);
    if (pending) {
        dispatch_block_cancel(pending);
        objc_setAssociatedObject(media, kPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(media, kSuppressUntilKey, @(CACurrentMediaTime() + 0.35),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NFBBurstHeart(media, [recognizer locationInView:media]);
    NFBLikeStatusOf(media);
}

@end

static void NFBInstallDoubleTap(UIView* media) {
    if (objc_getAssociatedObject(media, kRecognizerKey)) {
        return;
    }
    NFBDoubleTapTarget* target = [NFBDoubleTapTarget shared];
    UITapGestureRecognizer* recognizer =
        [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(doubleTapped:)];
    recognizer.numberOfTapsRequired = 2;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesEnded = NO;
    recognizer.delegate = target;
    [media addGestureRecognizer:recognizer];
    objc_setAssociatedObject(media, kRecognizerKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Runs a single-tap action now, later, or not at all (see the top of the file).
static void NFBDeferSingleTap(UIView* media, dispatch_block_t action) {
    if (!NFBDoubleTapEnabled() || !media) {
        action();
        return;
    }
    NSNumber* until = objc_getAssociatedObject(media, kSuppressUntilKey);
    if (until && CACurrentMediaTime() < until.doubleValue) {
        return;
    }
    dispatch_block_t previous = objc_getAssociatedObject(media, kPendingKey);
    if (previous) {
        dispatch_block_cancel(previous);
    }
    __weak UIView* weakMedia = media;
    dispatch_block_t block = dispatch_block_create(0, ^{
        UIView* strongMedia = weakMedia;
        if (strongMedia) {
            objc_setAssociatedObject(strongMedia, kPendingKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (strongMedia.window) {
            action();
        }
    });
    objc_setAssociatedObject(media, kPendingKey, block, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSingleTapDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

%hook T1StatusPhotoVideoForwardView

- (void)didMoveToWindow {
    %orig;
    if (((UIView*)self).window) {
        NFBInstallDoubleTap((UIView*)self);
    }
}

- (void)_t1_mediaTapActionAtIndex:(NSUInteger)index {
    NFBDeferSingleTap((UIView*)self, ^{
        %orig;
    });
}

- (void)_t1_imageTapAction {
    NFBDeferSingleTap((UIView*)self, ^{
        %orig;
    });
}

- (void)inlineMediaViewWasTapped:(id)view withEvent:(id)event {
    NFBDeferSingleTap((UIView*)self, ^{
        %orig;
    });
}

%end
