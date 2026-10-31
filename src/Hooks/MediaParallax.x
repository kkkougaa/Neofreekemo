//
//  MediaParallax.x
//  NeoFreeBird
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"

// MARK: - Timeline photo parallax

// A photo shifts by at most a few points as its row moves through the viewport.
// The shift is a contentsRect window inside the image, so the view's frame never
// changes and no edge is uncovered. Low Power Mode and Reduce Motion turn it off.
// The crop is constant while a row is on screen; only the window moves.

static const CGFloat kMaxParallax = 3.5;
static const void* kStateKey = &kStateKey;
static const void* kPhotosKey = &kPhotosKey;
static const void* kDirtyKey = &kDirtyKey;
static const void* kCellShiftKey = &kCellShiftKey;
static const void* kListKey = &kListKey;
static const void* kAppliedKey = &kAppliedKey;

static BOOL gParallaxOn = NO;
static CFTimeInterval gParallaxCheck = 0;

@interface NFBParallaxState : NSObject
@property (nonatomic, assign) CGFloat shift;
@property (nonatomic, assign) BOOL active;
@end

@implementation NFBParallaxState
@end

static BOOL ParallaxOn(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now >= gParallaxCheck) {
        gParallaxCheck = now + 0.35;
        gParallaxOn = [BHTSettings boolForKey:@"kemo_media_parallax"] &&
                      !UIAccessibilityIsReduceMotionEnabled() &&
                      ![[NSProcessInfo processInfo] isLowPowerModeEnabled];
    }
    return gParallaxOn;
}

static void InvalidateParallaxCache(void) {
    gParallaxCheck = 0;
}

static Class PhotoImageClass(void) {
    static Class cls;
    if (!cls) {
        cls = objc_getClass("_TtC21TweetMediaAttachments23MultiMediaViewImageView");
    }
    return cls;
}

static UIView* EnclosingMediaCell(UIView* view) {
    for (UIView* step = view; step; step = step.superview) {
        if ([step isKindOfClass:[UITableViewCell class]] ||
            [step isKindOfClass:[UICollectionViewCell class]]) {
            return step;
        }
    }
    return nil;
}

static void CollectPhotos(UIView* view, Class photoClass, NSHashTable* out, int depth) {
    if (!view || depth > 9) {
        return;
    }
    if (photoClass && [view isKindOfClass:photoClass]) {
        [out addObject:view];
        return;
    }
    for (UIView* sub in view.subviews) {
        CollectPhotos(sub, photoClass, out, depth + 1);
    }
}

static NSHashTable* PhotosForCell(UIView* cell, BOOL rebuild) {
    NSHashTable* photos = objc_getAssociatedObject(cell, kPhotosKey);
    BOOL dirty = [objc_getAssociatedObject(cell, kDirtyKey) boolValue];
    if (photos && !dirty && !rebuild) {
        return photos;
    }
    Class photoClass = PhotoImageClass();
    photos = [NSHashTable weakObjectsHashTable];
    if (photoClass) {
        CollectPhotos(cell, photoClass, photos, 0);
    }
    objc_setAssociatedObject(cell, kPhotosKey, photos, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kDirtyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return photos;
}

static CGRect RectForShift(UIImageView* image, CGFloat shift) {
    CGFloat height = CGRectGetHeight(image.bounds);
    CGFloat margin = (kMaxParallax * 2.0) / MAX(height, 1);
    if (margin > 0.045) {
        margin = 0.045;
    }
    if (margin < 0.004) {
        margin = 0.004;
    }
    CGFloat span = 1.0 - margin;
    CGFloat travel = (margin * 0.5 / span) * height;
    CGFloat clamped = shift;
    if (clamped > travel) {
        clamped = travel;
    }
    if (clamped < -travel) {
        clamped = -travel;
    }
    if (clamped > kMaxParallax) {
        clamped = kMaxParallax;
    }
    if (clamped < -kMaxParallax) {
        clamped = -kMaxParallax;
    }
    CGFloat y = margin * 0.5 + (clamped / height) * span;
    if (y < 0) {
        y = 0;
    }
    if (y > margin) {
        y = margin;
    }
    return CGRectMake(margin * 0.5, y, span, span);
}

static void ResetImage(UIImageView* image) {
    NFBParallaxState* state = objc_getAssociatedObject(image, kStateKey);
    if (!state || !state.active) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    image.layer.contentsRect = CGRectMake(0, 0, 1, 1);
    [CATransaction commit];
    state.active = NO;
    state.shift = 0;
}

static void CommitShift(UIImageView* image, CGFloat shift) {
    CGFloat height = CGRectGetHeight(image.bounds);
    CGFloat width = CGRectGetWidth(image.bounds);
    if (height < 48 || width < 48 || !image.image) {
        ResetImage(image);
        return;
    }
    CGFloat quantum = round(shift * 10.0) / 10.0;
    CGRect desired = RectForShift(image, quantum);
    NFBParallaxState* state = objc_getAssociatedObject(image, kStateKey);
    if (!state) {
        state = [NFBParallaxState new];
        objc_setAssociatedObject(image, kStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (state.active && fabs(state.shift - quantum) < 0.05 &&
        CGRectEqualToRect(image.layer.contentsRect, desired)) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    image.layer.contentsRect = desired;
    [CATransaction commit];
    state.shift = quantum;
    state.active = YES;
}

static void ReapplyImage(UIImageView* image) {
    NFBParallaxState* state = objc_getAssociatedObject(image, kStateKey);
    if (!state || !state.active) {
        return;
    }
    if (!ParallaxOn()) {
        ResetImage(image);
        return;
    }
    CommitShift(image, state.shift);
}

static CGFloat ShiftForCell(UIView* cell, UIScrollView* scroll) {
    CGRect rect = [cell convertRect:cell.bounds toView:scroll];
    CGFloat mid = CGRectGetMidY(rect);
    CGFloat viewMid = scroll.contentOffset.y + CGRectGetHeight(scroll.bounds) * 0.5;
    CGFloat relative = (mid - viewMid) / MAX(CGRectGetHeight(scroll.bounds), 1);
    if (relative > 0.5) {
        relative = 0.5;
    }
    if (relative < -0.5) {
        relative = -0.5;
    }
    // Lag the row: a cell below the middle eases its photo the other way.
    return -relative * (kMaxParallax * 2.0);
}

static void ResetCell(UIView* cell) {
    NSHashTable* photos = objc_getAssociatedObject(cell, kPhotosKey);
    if (!photos && !objc_getAssociatedObject(cell, kCellShiftKey)) {
        return;
    }
    // The cell retains its image views, so the weak cache still holds any photo
    // we shifted. A cold row has neither key and is left alone.
    for (UIImageView* image in photos.allObjects) {
        ResetImage(image);
    }
    objc_setAssociatedObject(cell, kPhotosKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kDirtyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kCellShiftKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApplyCell(UIView* cell, UIScrollView* scroll) {
    BOOL dirty = [objc_getAssociatedObject(cell, kDirtyKey) boolValue];
    CGFloat shift = ShiftForCell(cell, scroll);
    CGFloat quantum = round(shift * 10.0) / 10.0;
    NSNumber* previous = objc_getAssociatedObject(cell, kCellShiftKey);
    NSHashTable* photos = PhotosForCell(cell, dirty);
    if (!dirty && previous && fabs(previous.doubleValue - quantum) < 0.05) {
        return photos.count > 0;
    }
    objc_setAssociatedObject(cell, kCellShiftKey, @(quantum), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL any = NO;
    for (UIImageView* image in photos.allObjects) {
        CommitShift(image, quantum);
        NFBParallaxState* state = objc_getAssociatedObject(image, kStateKey);
        if (state.active) {
            any = YES;
        }
    }
    return any;
}

static BOOL IsTweetList(UIScrollView* scroll) {
    NSNumber* flag = objc_getAssociatedObject(scroll, kListKey);
    if (flag) {
        return flag.boolValue;
    }
    UIResponder* responder = scroll.nextResponder;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) {
        responder = responder.nextResponder;
    }
    if (!responder) {
        return NO;
    }
    NSString* name = NSStringFromClass(responder.class);
    BOOL yes = [name containsString:@"Timeline"] || [name containsString:@"Status"] ||
               [name containsString:@"Conversation"] || [name containsString:@"Profile"];
    objc_setAssociatedObject(scroll, kListKey, @(yes), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return yes;
}

static NSArray<UIView*>* VisibleCells(UIScrollView* scroll) {
    if ([scroll isKindOfClass:[UITableView class]]) {
        return ((UITableView*)scroll).visibleCells;
    }
    if ([scroll isKindOfClass:[UICollectionView class]]) {
        return ((UICollectionView*)scroll).visibleCells;
    }
    return nil;
}

static BOOL gUpdatingList = NO;

static void UpdateList(UIScrollView* scroll) {
    if (gUpdatingList) {
        return;
    }
    if (![scroll isKindOfClass:[UITableView class]] && ![scroll isKindOfClass:[UICollectionView class]]) {
        return;
    }
    BOOL on = ParallaxOn();
    if (!on && ![objc_getAssociatedObject(scroll, kAppliedKey) boolValue]) {
        return;
    }
    if (!scroll.window || !IsTweetList(scroll)) {
        return;
    }
    gUpdatingList = YES;
    @try {
        BOOL any = NO;
        for (UIView* cell in VisibleCells(scroll)) {
            if (on) {
                if (ApplyCell(cell, scroll)) {
                    any = YES;
                }
            } else {
                ResetCell(cell);
            }
        }
        objc_setAssociatedObject(scroll, kAppliedKey, any ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @finally {
        gUpdatingList = NO;
    }
}

static void ResetAppliedLists(UIView* view, int depth) {
    if (!view || depth > 16) {
        return;
    }
    if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) {
        UIScrollView* scroll = (UIScrollView*)view;
        if ([objc_getAssociatedObject(scroll, kAppliedKey) boolValue]) {
            for (UIView* cell in VisibleCells(scroll)) {
                ResetCell(cell);
            }
            objc_setAssociatedObject(scroll, kAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    for (UIView* sub in view.subviews) {
        ResetAppliedLists(sub, depth + 1);
    }
}

static void ResetEverything(void) {
    InvalidateParallaxCache();
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            ResetAppliedLists(window, 0);
        }
    }
}

static void NotePhotoImage(UIImageView* image) {
    if (!ParallaxOn()) {
        ResetImage(image);
        return;
    }
    UIView* cell = EnclosingMediaCell(image);
    if (!cell) {
        return;
    }
    objc_setAssociatedObject(cell, kDirtyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIScrollView* scroll = nil;
    for (UIView* step = cell.superview; step; step = step.superview) {
        if ([step isKindOfClass:[UITableView class]] || [step isKindOfClass:[UICollectionView class]]) {
            scroll = (UIScrollView*)step;
            break;
        }
    }
    if (scroll && IsTweetList(scroll)) {
        if (ApplyCell(cell, scroll)) {
            objc_setAssociatedObject(scroll, kAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

%hook _TtC21TweetMediaAttachments23MultiMediaViewImageView

- (void)layoutSubviews {
    %orig;
    ReapplyImage((UIImageView*)self);
}

- (void)setImage:(UIImage*)image {
    %orig;
    NotePhotoImage((UIImageView*)self);
}

%end

%hook UITableViewCell

- (void)prepareForReuse {
    ResetCell((UIView*)self);
    %orig;
}

%end

%hook UICollectionViewCell

- (void)prepareForReuse {
    ResetCell((UIView*)self);
    %orig;
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    UpdateList(self);
}

%end

%ctor {
    // A custom constructor replaces Logos's, which is the only thing that installs the hooks above.
    %init;

    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    void (^reset)(NSNotification*) = ^(NSNotification* note) {
        (void)note;
        ResetEverything();
    };
    [center addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:reset];
    [center addObserverForName:UIAccessibilityReduceMotionStatusDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:reset];
}
