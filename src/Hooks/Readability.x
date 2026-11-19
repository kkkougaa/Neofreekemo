//
//  Readability.x
//  NeoFreeBird
//

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "HookHelpers.h"

// MARK: - Easier reading in the timeline and notifications
// Switches:
//
//  - kemo_notification_swipe_reply: replies and mentions in the notifications
//    list can be pulled from right to left to answer them.
//  - kemo_dim_actions: the reply / repost / like / views row is faded, so the
//    numbers no longer pull the eye away from the text.
//
// 7.3.86-7.3.105 also drew every row of the home timeline and the
// notifications on a rounded card (kemo_timeline_cards, kemo_notification_cards)
// with a settings page for the card's look and for the sizes of the text, the
// name line and the avatar. All of that was taken out in 7.3.106 at the user's
// wish: rows are X's own again, and nothing here touches X's layout metrics,
// row heights, backgrounds, dividers, thread lines, fonts or the name line.
//
// The swipe only exists in the notifications list. On the home timeline a
// sideways drag stays X's (it changes tabs).

static NSString* const kDimKey = @"kemo_dim_actions";
static NSString* const kNoteSwipeKey = @"kemo_notification_swipe_reply";

static const CGFloat kDimAlpha = 0.6;   // 0.45 until 7.3.98: the counts were hard to read
static const CGFloat kReplyPull = 80.0; // pull this far to answer
static const CGFloat kMarkInset = 8.0;  // the reply mark's distance from the row's right edge

// The switches, read once and refreshed when settings change (the hooks run a lot).
static BOOL gDimOn, gNoteSwipeOn;

static void RefreshOnScreen(void);

static void ReadSwitches(void) {
    static BOOL read = NO;
    BOOL dim = [BHTSettings boolForKey:kDimKey];
    BOOL changed = read && dim != gDimOn;
    gDimOn = dim;
    gNoteSwipeOn = [BHTSettings boolForKey:kNoteSwipeKey];
    read = YES;
    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RefreshOnScreen();
        });
    }
}

// For the shake dump.
static NSInteger gSwipeBegins = 0;
static NSString* gSwipeLog = @"(no swipe yet)";
static NSString* gPullLog = @"(no pull yet)";

NSString* NFBReadabilityDebugText(void) {
    return [NSString stringWithFormat:@"dim=%d noteSwipe=%d swipes=%ld last=%@\npull: %@", gDimOn, gNoteSwipeOn,
                                      (long)gSwipeBegins, gSwipeLog, gPullLog];
}

// MARK: Which list a cell is in

typedef NS_ENUM(NSInteger, NFBListKind) {
    NFBListOther = 0,
    NFBListHome = 1,
    NFBListNotifications = 2,
};

static const void* kListKindKey = &kListKindKey;

static UITableView* TableOf(UIView* cell) {
    for (UIView* view = cell.superview; view; view = view.superview) {
        if ([view isKindOfClass:[UITableView class]]) {
            return (UITableView*)view;
        }
    }
    return nil;
}

static NFBListKind ListKind(UITableView* table) {
    if (!table) {
        return NFBListOther;
    }
    NSNumber* known = objc_getAssociatedObject(table, kListKindKey);
    if (known) {
        return (NFBListKind)known.integerValue;
    }
    // Only decide once the list is on screen, inside its controllers.
    if (!table.window) {
        return NFBListOther;
    }
    NFBListKind kind = NFBListOther;
    for (UIResponder* responder = table; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:[UIViewController class]]) {
            continue;
        }
        NSString* name = NSStringFromClass(responder.class);
        if ([name containsString:@"HomeTimeline"]) {
            kind = NFBListHome;
            break;
        }
        if ([name containsString:@"NotificationsViewController"]) {
            kind = NFBListNotifications;
            break;
        }
    }
    objc_setAssociatedObject(table, kListKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return kind;
}

// MARK: Finding things in a row

static UIView* FindView(UIView* view, NSString* part, int depth) {
    if (depth > 14 || view.hidden) {
        return nil;
    }
    if ([NSStringFromClass(view.class) containsString:part]) {
        return view;
    }
    for (UIView* sub in view.subviews) {
        UIView* found = FindView(sub, part, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

// After the fade switch changed: every tweet on screen is laid out again.
static void RefreshViews(UIView* view, int depth) {
    if (depth > 40) {
        return;
    }
    if ([NSStringFromClass(view.class) isEqualToString:@"T1StandardStatusView"]) {
        [view setNeedsLayout];
    }
    for (UIView* sub in view.subviews) {
        RefreshViews(sub, depth + 1);
    }
}

static void RefreshOnScreen(void) {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            RefreshViews(window, 0);
        }
    }
}

// MARK: Pull a notification to answer it
//
// 7.3.86 moved the row only once the pan gesture began, and on device it
// began only when the finger lifted (another gesture kept it waiting), so the
// row sat still and the reply mark just flashed. The pull is now followed
// straight from the touches: the row moves with the finger from the first
// sideways move, whatever the gesture machinery decides. The gesture itself
// only keeps the tab pager from turning the page meanwhile.

// The row's own reply button, if it has one (replies and mentions do).
static UIView* ReplyButton(UITableViewCell* cell) {
    return FindView(cell.contentView, @"InlineReplyButton", 0);
}

static BOOL PressReply(UIView* button) {
    if (!button) {
        return NO;
    }
    if ([button isKindOfClass:[UIControl class]]) {
        [(UIControl*)button sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:button];
    while (queue.count > 0) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view != button && [view isKindOfClass:[UIControl class]]) {
            [(UIControl*)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return NO;
}

// Sets a layer's sublayer transform, at once or with an animation of its own.
// The pull used to set the content view's transform; in 7.3.97 the reply mark
// showed and nothing moved: X lays the row out again while it is touched and
// puts the view back. A sublayer transform is not part of that layout.
static void MoveSublayers(CALayer* layer, CATransform3D to, CFTimeInterval duration, BOOL spring) {
    if (!layer) {
        return;
    }
    CALayer* shown = layer.presentationLayer;
    CATransform3D from = ([layer animationForKey:@"nfbSwipe"] && shown) ? shown.sublayerTransform : layer.sublayerTransform;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.sublayerTransform = to;
    [CATransaction commit];
    [layer removeAnimationForKey:@"nfbSwipe"];
    if (duration <= 0 || CATransform3DEqualToTransform(from, to)) {
        return;
    }
    CABasicAnimation* animation = nil;
    if (spring) {
        CASpringAnimation* bounce = [CASpringAnimation animationWithKeyPath:@"sublayerTransform"];
        bounce.mass = 1;
        bounce.stiffness = 300;
        bounce.damping = 26;
        bounce.duration = bounce.settlingDuration;
        animation = bounce;
    } else {
        animation = [CABasicAnimation animationWithKeyPath:@"sublayerTransform"];
        animation.duration = duration;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    }
    animation.fromValue = [NSValue valueWithCATransform3D:from];
    animation.toValue = [NSValue valueWithCATransform3D:to];
    [layer addAnimation:animation forKey:@"nfbSwipe"];
}

@interface NFBReplySwipe : UIPanGestureRecognizer
@property (nonatomic, weak) UITableViewCell* cell;
@property (nonatomic, strong) UIView* mark;
@property (nonatomic, assign) CGPoint start;
@property (nonatomic, assign) BOOL decided;  // the first move told sideways from up/down
@property (nonatomic, assign) BOOL tracking; // the row is following the finger
@property (nonatomic, assign) BOOL armed;    // pulled far enough to answer on release
@property (nonatomic, assign) NSInteger moves;
@end

@implementation NFBReplySwipe

- (void)showMark:(CGFloat)offset {
    UIView* mark = self.mark;
    CGFloat progress = MIN(1.0, -offset / kReplyPull);
    mark.alpha = progress;
    CGFloat scale = self.armed ? 1.15 : 0.5 + 0.5 * progress;
    // The mark rides a little behind the row's edge until it is fully shown.
    mark.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale),
                                             CGAffineTransformMakeTranslation((1 - progress) * 24, 0));
}

- (void)setOffset:(CGFloat)offset duration:(CFTimeInterval)duration spring:(BOOL)spring {
    UITableViewCell* cell = self.cell;
    MoveSublayers(cell.contentView.layer, CATransform3DMakeTranslation(offset, 0, 0), duration, spring);
    if (duration > 0) {
        [UIView animateWithDuration:MIN(duration, 0.25)
                         animations:^{
                             [self showMark:offset];
                         }];
    } else {
        [self showMark:offset];
    }
}

- (void)beginTracking {
    UITableViewCell* cell = self.cell;
    self.tracking = YES;
    self.armed = NO;
    self.moves = 0;
    gSwipeBegins++;
    if (!self.mark) {
        UIImageSymbolConfiguration* config =
            [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold];
        UIImageView* mark = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:@"arrowshape.turn.up.left.fill" withConfiguration:config]];
        mark.contentMode = UIViewContentModeCenter;
        mark.tintColor = [UIColor whiteColor];
        mark.bounds = CGRectMake(0, 0, 40, 40);
        mark.layer.cornerRadius = 20;
        mark.userInteractionEnabled = NO;
        self.mark = mark;
    }
    [self.mark.layer removeAllAnimations];
    self.mark.backgroundColor = CurrentAccentColor();
    self.mark.center = CGPointMake(CGRectGetWidth(cell.bounds) - kMarkInset - kReplyPull / 2,
                                   CGRectGetMidY(cell.bounds));
    self.mark.alpha = 0;
    // The row's content has a colour of its own that stays where it is, so
    // the mark goes over it, where the pulled content has made room.
    [cell insertSubview:self.mark aboveSubview:cell.contentView];
    // Stop the list scrolling up and down while the row is pulled.
    UITableView* table = TableOf(cell);
    if (table.panGestureRecognizer.enabled) {
        table.panGestureRecognizer.enabled = NO;
        table.panGestureRecognizer.enabled = YES;
    }
}

- (void)followTo:(CGFloat)dx {
    dx = MIN(0, dx);
    self.moves++;
    // Past the answer point the row still follows, but stiffer.
    CGFloat shown = dx < -kReplyPull ? -kReplyPull + (dx + kReplyPull) * 0.3 : dx;
    BOOL armed = dx <= -kReplyPull;
    if (armed != self.armed) {
        self.armed = armed;
        if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:armed ? UIImpactFeedbackStyleRigid
                                                                    : UIImpactFeedbackStyleLight]
                impactOccurredWithIntensity:armed ? 0.8 : 0.4];
        }
        [self setOffset:shown duration:0.18 spring:NO];
        return;
    }
    [self setOffset:shown duration:0 spring:NO];
}

- (void)endTracking:(BOOL)lifted {
    if (!self.tracking) {
        return;
    }
    self.tracking = NO;
    BOOL answer = lifted && self.armed;
    self.armed = NO;
    UIView* mark = self.mark;
    UITableViewCell* cell = self.cell;
    [self setOffset:0 duration:0.42 spring:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.tracking) {
            [mark removeFromSuperview];
        }
    });
    if (answer && cell) {
        UIView* button = ReplyButton(cell);
        BOOL pressed = PressReply(button);
        gSwipeLog = [NSString stringWithFormat:@"reply %@ via %@ after %ld moves", pressed ? @"opened" : @"NOT opened",
                                               button ? NSStringFromClass(button.class) : @"(no button)",
                                               (long)self.moves];
    } else {
        gSwipeLog = [NSString stringWithFormat:@"let go early after %ld moves", (long)self.moves];
    }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesBegan:touches withEvent:event];
    UITableViewCell* cell = self.cell;
    self.start = cell ? [touches.anyObject locationInView:cell] : CGPointZero;
    self.decided = NO;
}

// 7.3.89 called super first: when one move crossed both the pan's own start
// distance and ours, the pan asked to begin before this pull had decided, was
// refused, and failed, so no more touches came and the row stayed put. Decide
// first, then let the pan see the move.
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self followTouches:touches];
    [super touchesMoved:touches withEvent:event];
}

- (void)followTouches:(NSSet<UITouch*>*)touches {
    UITableViewCell* cell = self.cell;
    if (!cell) {
        return;
    }
    CGPoint point = [touches.anyObject locationInView:cell];
    CGFloat dx = point.x - self.start.x, dy = point.y - self.start.y;
    if (!self.decided) {
        if (hypot(dx, dy) < 8) {
            return;
        }
        self.decided = YES;
        BOOL sideways = dx < 0 && fabs(dx) > fabs(dy) * 1.3;
        if (sideways && gNoteSwipeOn && ListKind(TableOf(cell)) == NFBListNotifications && ReplyButton(cell)) {
            [self beginTracking];
        } else {
            if (self.state == UIGestureRecognizerStatePossible) {
                self.state = UIGestureRecognizerStateFailed;
            }
            return;
        }
    }
    if (self.tracking) {
        [self followTo:dx];
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesEnded:touches withEvent:event];
    [self endTracking:YES];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesCancelled:touches withEvent:event];
    [self endTracking:NO];
}

- (void)reset {
    [super reset];
    // Another gesture (the list scrolling) took over: put the row back.
    if (self.tracking) {
        NSInteger moves = self.moves;
        [self endTracking:NO];
        gSwipeLog = [NSString stringWithFormat:@"taken over after %ld moves", (long)moves];
    }
    self.decided = NO;
}

@end

@interface NFBReplySwipeHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

@implementation NFBReplySwipeHandler

+ (instancetype)shared {
    static NFBReplySwipeHandler* handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handler = [NFBReplySwipeHandler new];
    });
    return handler;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    return [gesture isKindOfClass:[NFBReplySwipe class]] && ((NFBReplySwipe*)gesture).tracking;
}

// The tab pager (a sideways scroll view) waits for this pull to fail first.
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer*)other {
    UIView* view = other.view;
    if ([view isKindOfClass:[UIScrollView class]] && ![view isKindOfClass:[UITableView class]]) {
        UIScrollView* scroll = (UIScrollView*)view;
        return scroll.contentSize.width > CGRectGetWidth(scroll.bounds) + 1;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer*)other {
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    // The list's own scrolling must not make this pull fail before it has
    // decided; once the row follows the finger the list is stopped anyway.
    return [other.view isKindOfClass:[UITableView class]];
}

// The row is moved from the touches themselves; nothing to do here.
- (void)swiped:(NFBReplySwipe*)swipe {
}

@end

static const void* kReplySwipeKey = &kReplySwipeKey;
static void AttachReplySwipe(UITableViewCell* cell) {
    if (objc_getAssociatedObject(cell, kReplySwipeKey)) {
        return;
    }
    NFBReplySwipe* swipe = [[NFBReplySwipe alloc] initWithTarget:[NFBReplySwipeHandler shared]
                                                          action:@selector(swiped:)];
    swipe.cell = cell;
    swipe.maximumNumberOfTouches = 1;
    // Taps on the row (opening it, the buttons) must not wait for this pull.
    swipe.delaysTouchesEnded = NO;
    swipe.delegate = [NFBReplySwipeHandler shared];
    [cell addGestureRecognizer:swipe];
    objc_setAssociatedObject(cell, kReplySwipeKey, swipe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: Hooks

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    UITableViewCell* cell = (UITableViewCell*)self;
    if (gNoteSwipeOn && !objc_getAssociatedObject(cell, kReplySwipeKey) &&
        ListKind(TableOf(cell)) == NFBListNotifications) {
        AttachReplySwipe(cell);
    }
}

%end

static const void* kDimmedKey = &kDimmedKey;

// MARK: The faded action row
// The row is faded button by button, and a like or a repost the reader has
// made keeps its full colour (X paints it pink or green), so it still shows.
// A tap on the row looks again shortly after, once X has recoloured it.

// The theme colour, which untouched icons could inherit; never taken as "done".
static CGFloat gAccentHue = -1;

static BOOL IsDoneColor(UIColor* color, UITraitCollection* traits) {
    if (!color) {
        return NO;
    }
    CGFloat h = 0, sat = 0, b = 0, a = 0;
    UIColor* resolved = traits ? [color resolvedColorWithTraitCollection:traits] : color;
    if (![resolved getHue:&h saturation:&sat brightness:&b alpha:&a]) {
        return NO;
    }
    if (sat < 0.4 || b < 0.3 || a < 0.3) {
        return NO;
    }
    if (gAccentHue >= 0 && fabs(h - gAccentHue) < 0.015) {
        return NO;
    }
    BOOL pink = h > 0.85 || h < 0.02;   // like
    BOOL green = h > 0.30 && h < 0.48;  // repost
    return pink || green;
}

static BOOL LayerIsDone(CALayer* layer, int depth) {
    if (depth > 6) {
        return NO;
    }
    if ([layer isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer* shape = (CAShapeLayer*)layer;
        for (id cg in @[ (__bridge id)shape.fillColor ?: [NSNull null], (__bridge id)shape.strokeColor ?: [NSNull null] ]) {
            if (cg != [NSNull null] && IsDoneColor([UIColor colorWithCGColor:(__bridge CGColorRef)cg], nil)) {
                return YES;
            }
        }
    }
    for (CALayer* sub in layer.sublayers) {
        if (LayerIsDone(sub, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static BOOL ActionIsDone(UIView* view, int depth) {
    if (depth > 6 || view.hidden) {
        return NO;
    }
    UITraitCollection* traits = view.traitCollection;
    if ([view isKindOfClass:[UILabel class]] && IsDoneColor(((UILabel*)view).textColor, traits)) {
        return YES;
    }
    if ([view isKindOfClass:[UIImageView class]] && ((UIImageView*)view).image &&
        IsDoneColor(view.tintColor, traits) &&
        ((UIImageView*)view).image.renderingMode != UIImageRenderingModeAlwaysOriginal) {
        return YES;
    }
    if ([view isKindOfClass:[UIButton class]] && IsDoneColor([(UIButton*)view titleColorForState:UIControlStateNormal], traits)) {
        return YES;
    }
    // Lottie and other drawn icons.
    if (view.subviews.count == 0 && LayerIsDone(view.layer, 0)) {
        return YES;
    }
    for (UIView* sub in view.subviews) {
        if (ActionIsDone(sub, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static void DimActions(UIView* actions);

@interface NFBActionTapWatcher : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

@implementation NFBActionTapWatcher

+ (instancetype)shared {
    static NFBActionTapWatcher* watcher;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        watcher = [NFBActionTapWatcher new];
    });
    return watcher;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return YES;
}

- (void)tapped:(UITapGestureRecognizer*)tap {
    __weak UIView* actions = tap.view;
    for (NSNumber* delay in @[ @0.15, @0.6, @1.2 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (actions) {
                               DimActions(actions);
                           }
                       });
    }
}

@end

static const void* kTapWatcherKey = &kTapWatcherKey;

static void DimActions(UIView* actions) {
    // The buttons: below any single-child wrappers, the views side by side.
    UIView* row = actions;
    for (int i = 0; i < 4 && row.subviews.count == 1; i++) {
        row = row.subviews.firstObject;
    }
    if (gDimOn) {
        CGFloat h = 0, sat = 0, b = 0, a = 0;
        gAccentHue = [CurrentAccentColor() getHue:&h saturation:&sat brightness:&b alpha:&a] ? h : -1;
        if (actions.alpha < 1) {
            actions.alpha = 1.0; // 7.3.86-7.3.91 faded the whole row
        }
        for (UIView* button in row.subviews) {
            CGFloat alpha = ActionIsDone(button, 0) ? 1.0 : kDimAlpha;
            if (button.alpha != alpha) {
                button.alpha = alpha;
            }
        }
        objc_setAssociatedObject(actions, kDimmedKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!objc_getAssociatedObject(actions, kTapWatcherKey)) {
            UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:[NFBActionTapWatcher shared]
                                                                                  action:@selector(tapped:)];
            tap.cancelsTouchesInView = NO;
            tap.delaysTouchesEnded = NO;
            tap.delegate = [NFBActionTapWatcher shared];
            [actions addGestureRecognizer:tap];
            objc_setAssociatedObject(actions, kTapWatcherKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else {
        UIView* dimmed = objc_getAssociatedObject(actions, kDimmedKey);
        if (dimmed) {
            for (UIView* button in dimmed.subviews) {
                button.alpha = 1.0;
            }
            actions.alpha = 1.0;
            objc_setAssociatedObject(actions, kDimmedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

%hook T1StandardStatusView

- (void)layoutSubviews {
    %orig;
    UIView* actions = [self respondsToSelector:@selector(visibleInlineActionsView)]
                          ? [(T1StandardStatusView*)self visibleInlineActionsView]
                          : nil;
    if (actions) {
        DimActions(actions);
    }
}

%end

// MARK: Pull to refresh
// Nothing here adds to, moves or hooks the refresh control (the pill behind
// X's spinner of 7.3.90-7.3.96 is gone). What a pull looked like the moment
// the refresh started is noted for the dump (read only, called from
// HeaderLogoLoading.x's hook), in case the top bar or the spinner is wrong.

static UIView* FindSpinner(UIView* view, int depth) {
    if (depth > 8) {
        return nil;
    }
    for (UIView* sub in view.subviews) {
        NSString* name = NSStringFromClass(sub.class);
        if ([sub isKindOfClass:[UIActivityIndicatorView class]] || [name containsString:@"Spinner"] ||
            [name containsString:@"ActivityIndicator"] || [name containsString:@"Loading"]) {
            return sub;
        }
        UIView* found = FindSpinner(sub, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

void NFBNotePullStatus(UIView* control, unsigned long long status) {
    if (status != 1 || !control.window) {
        return;
    }
    UIWindow* window = control.window;
    NSMutableString* chain = [NSMutableString string];
    int depth = 0;
    for (UIView* up = control.superview; up && depth < 6; up = up.superview, depth++) {
        [chain appendFormat:@" < %@%@", NSStringFromClass(up.class), depth == 0 ? NSStringFromCGRect(up.frame) : @""];
    }
    NSArray<UIView*>* siblings = control.superview.subviews;
    NSMutableString* above = [NSMutableString string];
    NSUInteger index = [siblings indexOfObject:control];
    for (NSUInteger i = index == NSNotFound ? siblings.count : index + 1; i < siblings.count && i < index + 5; i++) {
        UIView* view = siblings[i];
        [above appendFormat:@" %@%@a=%.1f%@", NSStringFromClass(view.class), NSStringFromCGRect(view.frame), view.alpha,
                            view.hidden ? @"(hidden)" : @""];
    }
    SEL savedSelector = NSSelectorFromString(@"savedScrollView");
    NSMethodSignature* savedSignature =
        [control respondsToSelector:savedSelector] ? [control methodSignatureForSelector:savedSelector] : nil;
    UIScrollView* scroll = (savedSignature && savedSignature.methodReturnType[0] == '@')
                               ? ((id (*)(id, SEL))objc_msgSend)(control, savedSelector)
                               : nil;
    if (![scroll isKindOfClass:[UIScrollView class]]) {
        scroll = nil;
    }
    UIView* spinner = FindSpinner(control, 0);
    // The top bar, to see whether it moved with the pull.
    UIView* bar = nil;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
    NSUInteger budget = 600;
    while (queue.count > 0 && budget-- > 0 && !bar) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString* name = NSStringFromClass(view.class);
        if ([name containsString:@"XNavigation"] && [name hasSuffix:@"Bar"]) {
            bar = view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    gPullLog = [NSString
        stringWithFormat:@"control %@ inWindow=%@ a=%.2f hidden=%d index=%lu/%lu%@ | above:%@ | scroll=%@ offset=%.0f inset=%@ bg=%d | "
                         @"spinner=%@ %@ a=%.2f hidden=%d | bar=%@ inWindow=%@",
                         NSStringFromCGRect(control.frame),
                         NSStringFromCGRect([control convertRect:control.bounds toView:window]), control.alpha,
                         control.hidden, (unsigned long)index, (unsigned long)siblings.count, chain, above,
                         scroll ? NSStringFromClass(scroll.class) : @"-", scroll.contentOffset.y,
                         NSStringFromUIEdgeInsets(scroll.adjustedContentInset), scroll.backgroundColor != nil,
                         spinner ? NSStringFromClass(spinner.class) : @"-",
                         spinner ? NSStringFromCGRect([spinner convertRect:spinner.bounds toView:window]) : @"",
                         spinner.alpha, spinner.hidden, bar ? NSStringFromClass(bar.class) : @"-",
                         bar ? NSStringFromCGRect([bar convertRect:bar.bounds toView:window]) : @""];
}

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        ReadSwitches();
    });
    // Never the main queue here (7.3.86 hung on the splash screen, as 7.3.79 did):
    // X changes defaults from background threads during launch while the main
    // thread waits on them, and a main-queue observer makes that thread wait for
    // the main thread in turn. Reading the switches is safe on any thread; a
    // change hops to the main thread on its own.
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification* note) {
                                                      ReadSwitches();
                                                  }];
    %init;
}
