//
//  DropRefresh.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Drop pull-to-refresh

// The X spinner is swapped for a drop in the accent color. Pulling a list down
// stretches the drop out of a small handle, past the threshold it pops and snaps
// off, and while the refresh runs it turns into a spinner. When the refresh ends
// it shrinks back into the handle.
//
// Port of the "Pull to refresh" motion study. The springs are the same
// stiffness / damping pairs and are stepped the same way (semi-implicit Euler,
// four substeps a frame, frames capped at 1/30 s), so it moves the same.
// The list itself is still moved by UIKit and X; only the drop is ours.

@interface TFNPullToRefreshControl : UIView
- (BOOL)loading;
@end

// Spring tokens from the study ("stiffness damping").
static const CGFloat kPullThreshold = 88;  // --pull-threshold
static const CGFloat kHold = 64;           // list offset while loading
static const CGFloat kRestY = 5;           // drop center at rest, inside the handle
static const CGFloat kRestScale = 0.25;    // drop scale at rest
static const CGFloat kDropRadius = 16;
static const CGFloat kHandleWidth = 44;
static const CGFloat kHandleHeight = 6;
static const CGFloat kHandleTop = 2;
static const CGFloat kNeckReach = 22;  // how far the neck holds on before it snaps

typedef struct {
    CGFloat x, v, t, k, c;
} NFBSpring;

static NFBSpring SpringMake(CGFloat x, CGFloat k, CGFloat c) {
    NFBSpring s = {x, 0, x, k, c};
    // Reduce Motion: critically damped, so nothing overshoots.
    if (UIAccessibilityIsReduceMotionEnabled()) {
        s.c = 2 * sqrt(k);
    }
    return s;
}

static void SpringStep(NFBSpring* s, CGFloat dt) {
    CGFloat a = -s->k * (s->x - s->t) - s->c * s->v;
    s->v += a * dt;
    s->x += s->v * dt;
}

static CGFloat Clamp(CGFloat v, CGFloat a, CGFloat b) {
    return MAX(a, MIN(b, v));
}

static BOOL DropRefreshEnabled(void) {
    return [BHTSettings boolForKey:@"kemo_drop_refresh"];
}

// MARK: Display link trampoline

@interface NFBDropRefreshTicker : NSObject
@property (nonatomic, copy) void (^block)(CADisplayLink* link);
- (instancetype)initWithBlock:(void (^)(CADisplayLink* link))block;
@end

@implementation NFBDropRefreshTicker
- (instancetype)initWithBlock:(void (^)(CADisplayLink* link))block {
    if ((self = [super init])) {
        _block = [block copy];
    }
    return self;
}
- (void)fire:(CADisplayLink*)link {
    if (self.block) {
        self.block(link);
    }
}
@end

@interface NFBDropRefresh : NSObject
@property (nonatomic, weak) TFNPullToRefreshControl* control;
@property (nonatomic, weak) UIScrollView* scrollView;
@property (nonatomic, strong) UIView* overlay;
@property (nonatomic, strong) CAShapeLayer* goo;
@property (nonatomic, strong) CALayer* spinner;
@property (nonatomic, strong) CAShapeLayer* arc;
@property (nonatomic, strong) CADisplayLink* link;
@property (nonatomic, assign) CFTimeInterval lastTime;
@property (nonatomic, assign) CGFloat baseInset;
@property (nonatomic, assign) BOOL armed;
@property (nonatomic, assign) BOOL observing;
@end

@implementation NFBDropRefresh {
    NFBSpring _drop;       // drop center y
    NFBSpring _scale;      // drop scale
    NFBSpring _spin;       // spinner opacity / scale
}

- (instancetype)initWithControl:(TFNPullToRefreshControl*)control scrollView:(UIScrollView*)scrollView {
    if ((self = [super init])) {
        _control = control;
        _scrollView = scrollView;
        _drop = SpringMake(kRestY, 380, 20);
        _scale = SpringMake(kRestScale, 420, 18);
        _spin = SpringMake(0, 400, 26);
        _baseInset = scrollView.adjustedContentInset.top;
        [self buildViews];
    }
    return self;
}

- (void)buildViews {
    UIColor* accent = CurrentAccentColor();

    self.overlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.overlay.userInteractionEnabled = NO;
    self.overlay.clipsToBounds = NO;
    self.overlay.alpha = 0;
    self.overlay.isAccessibilityElement = NO;

    self.goo = [CAShapeLayer layer];
    self.goo.fillColor = accent.CGColor;
    [self.overlay.layer addSublayer:self.goo];

    CGFloat size = kDropRadius * 2;
    self.spinner = [CALayer layer];
    self.spinner.bounds = CGRectMake(0, 0, size, size);
    self.spinner.cornerRadius = kDropRadius;
    self.spinner.backgroundColor = accent.CGColor;
    self.spinner.opacity = 0;
    [self.overlay.layer addSublayer:self.spinner];

    // A quarter arc, like the study's "M12 4a8 8 0 0 1 8 8" inside 6 px of padding.
    CGFloat unit = (size - 12) / 24.0;
    self.arc = [CAShapeLayer layer];
    self.arc.frame = self.spinner.bounds;
    self.arc.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(kDropRadius, kDropRadius)
                                                   radius:8 * unit
                                               startAngle:-M_PI_2
                                                 endAngle:0
                                                clockwise:YES]
                        .CGPath;
    self.arc.fillColor = UIColor.clearColor.CGColor;
    self.arc.strokeColor = UIColor.whiteColor.CGColor;
    self.arc.lineWidth = 3 * unit;
    self.arc.lineCap = kCALineCapRound;
    [self.spinner addSublayer:self.arc];

    CABasicAnimation* turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    turn.fromValue = @0;
    turn.toValue = @(2 * M_PI);
    turn.duration = 0.8;
    turn.repeatCount = HUGE_VALF;
    turn.removedOnCompletion = NO;
    [self.arc addAnimation:turn forKey:@"spin"];
}

- (void)attach {
    UIScrollView* scrollView = self.scrollView;
    if (!scrollView) {
        return;
    }
    if (self.overlay.superview != scrollView) {
        // Behind the cells: at rest the handle hides under the first row, like the study.
        [scrollView insertSubview:self.overlay atIndex:0];
    }
    if (!self.observing) {
        [scrollView addObserver:self forKeyPath:@"contentOffset" options:0 context:NULL];
        self.observing = YES;
    }
    [self wake];
}

- (void)detach {
    [self.link invalidate];
    self.link = nil;
    if (self.observing) {
        [self.scrollView removeObserver:self forKeyPath:@"contentOffset"];
        self.observing = NO;
    }
    [self.overlay removeFromSuperview];
}

- (void)dealloc {
    [self detach];
}

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
    [self wake];
}

- (void)wake {
    if (!self.link) {
        // The display link holds its target; a weak trampoline keeps us from leaking.
        __weak NFBDropRefresh* weakSelf = self;
        id target = [[NFBDropRefreshTicker alloc] initWithBlock:^(CADisplayLink* link) {
            [weakSelf tick:link];
        }];
        self.link = [CADisplayLink displayLinkWithTarget:target selector:@selector(fire:)];
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self.lastTime = 0;
    }
    self.link.paused = NO;
}

- (CGFloat)pull {
    UIScrollView* scrollView = self.scrollView;
    return -(scrollView.contentOffset.y + self.baseInset);
}

- (void)tick:(CADisplayLink*)link {
    UIScrollView* scrollView = self.scrollView;
    TFNPullToRefreshControl* control = self.control;
    if (!scrollView || !control || !control.window) {
        link.paused = YES;
        return;
    }
    if (!DropRefreshEnabled()) {
        self.overlay.alpha = 0;
        NSNumber* wanted = objc_getAssociatedObject(control, @selector(setAlpha:));
        control.alpha = wanted ? wanted.doubleValue : 1;
        link.paused = YES;
        return;
    }

    if (control.alpha > 0) {
        control.alpha = control.alpha;  // the setting was turned back on: hide the X spinner again
    }

    BOOL loading = [control loading];
    // X adds its own inset while it holds the list open, so only learn the resting
    // inset while it is not loading.
    if (!loading) {
        self.baseInset = scrollView.adjustedContentInset.top;
    }
    CGFloat pull = MAX(0, [self pull]);

    CFTimeInterval now = link.timestamp;
    CGFloat dt = self.lastTime > 0 ? MIN(now - self.lastTime, 1.0 / 30) : 1.0 / 60;
    self.lastTime = now;

    if (loading) {
        _drop.t = kHold / 2;
        _scale.t = 1;
        _spin.t = 1;
        self.armed = NO;
    } else if (scrollView.isTracking) {
        CGFloat p = Clamp(pull / kPullThreshold, 0, 1);
        _drop.t = MAX(kRestY, pull * 0.5);
        _scale.t = kRestScale + (1 - kRestScale) * p;
        _spin.t = 0;
        BOOL over = pull >= kPullThreshold;
        if (over && !self.armed) {
            self.armed = YES;
            _scale.v += 4;  // the pop at the threshold
        } else if (!over) {
            self.armed = NO;
        }
    } else {
        _drop.t = kRestY;
        _scale.t = kRestScale;
        _spin.t = 0;
        self.armed = NO;
    }

    const int substeps = 4;
    for (int i = 0; i < substeps; i++) {
        SpringStep(&_drop, dt / substeps);
        SpringStep(&_scale, dt / substeps);
        SpringStep(&_spin, dt / substeps);
    }

    [self renderWithPull:pull loading:loading];

    BOOL settled = fabs(_drop.x - _drop.t) < 0.05 && fabs(_drop.v) < 0.5 && fabs(_scale.x - _scale.t) < 0.002 &&
                   fabs(_scale.v) < 0.01 && fabs(_spin.x - _spin.t) < 0.002 && fabs(_spin.v) < 0.01;
    if (settled && !loading && pull <= 0 && !scrollView.isTracking) {
        link.paused = YES;
        self.lastTime = 0;
    }
}

- (void)renderWithPull:(CGFloat)pull loading:(BOOL)loading {
    UIScrollView* scrollView = self.scrollView;
    CGFloat width = CGRectGetWidth(scrollView.bounds);
    CGFloat top = scrollView.contentOffset.y + self.baseInset;  // top edge of the visible list

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    self.overlay.frame = CGRectMake(0, top, width, 120);
    // Fade in with the first few points of pull, so it never shows over a see-through row.
    self.overlay.alpha = loading ? 1 : Clamp(MAX(pull, _drop.x - kRestY) / 12, 0, 1);

    CGFloat cx = width / 2;
    CGFloat spin = Clamp(_spin.x, 0, 1);

    // The drop stretches vertically while it moves fast.
    CGFloat stretch = 1 + Clamp(fabs(_drop.v) / 1600, 0, 0.35);
    CGFloat scale = MAX(0, _scale.x);
    CGFloat rx = kDropRadius * scale / stretch;
    CGFloat ry = kDropRadius * scale * stretch;
    CGFloat dy = _drop.x;

    UIBezierPath* path = [UIBezierPath
        bezierPathWithRoundedRect:CGRectMake(cx - kHandleWidth / 2, kHandleTop, kHandleWidth, kHandleHeight)
                     cornerRadius:kHandleHeight / 2];
    [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - rx, dy - ry, rx * 2, ry * 2)]];

    // The neck between handle and drop: thick while they touch, thin as they part,
    // gone once the drop has snapped off. Stands in for the study's goo filter.
    CGFloat handleBottom = kHandleTop + kHandleHeight;
    CGFloat gap = (dy - ry) - handleBottom;
    if (gap < kNeckReach && dy > handleBottom && rx > 1) {
        CGFloat t = 1 - Clamp(gap / kNeckReach, 0, 1);
        CGFloat topHalf = MIN(kHandleWidth / 2, 6 + 8 * t);
        CGFloat pinch = MAX(1.5, rx * 0.4 * t);
        CGFloat attachY = dy - ry * 0.7;
        CGFloat attachX = rx * 0.71;
        CGFloat midY = (handleBottom + attachY) / 2;
        UIBezierPath* neck = [UIBezierPath bezierPath];
        [neck moveToPoint:CGPointMake(cx - topHalf, handleBottom - 1)];
        [neck addQuadCurveToPoint:CGPointMake(cx - attachX, attachY) controlPoint:CGPointMake(cx - pinch, midY)];
        [neck addLineToPoint:CGPointMake(cx + attachX, attachY)];
        [neck addQuadCurveToPoint:CGPointMake(cx + topHalf, handleBottom - 1)
                     controlPoint:CGPointMake(cx + pinch, midY)];
        [neck closePath];
        [path appendPath:neck];
    }
    self.goo.path = path.CGPath;
    self.goo.opacity = 1 - spin;

    // While it spins, a clean circle sits on top and the drop fades out under it.
    CGFloat spinScale = 0.6 + 0.4 * _spin.x;
    self.spinner.position = CGPointMake(cx, dy);
    self.spinner.transform = CATransform3DMakeScale(spinScale, spinScale, 1);
    self.spinner.opacity = spin;

    [CATransaction commit];
}

- (void)refreshColors {
    UIColor* accent = CurrentAccentColor();
    self.goo.fillColor = accent.CGColor;
    self.spinner.backgroundColor = accent.CGColor;
}

@end

// MARK: Hooks

static char kDropRefreshKey;

static UIScrollView* EnclosingScrollView(UIView* view) {
    UIView* current = view.superview;
    while (current && ![current isKindOfClass:[UIScrollView class]]) {
        current = current.superview;
    }
    return (UIScrollView*)current;
}

%hook TFNPullToRefreshControl

- (void)didMoveToWindow {
    %orig;
    NFBDropRefresh* drop = objc_getAssociatedObject(self, &kDropRefreshKey);
    if (!self.window) {
        [drop detach];
        return;
    }
    if (!DropRefreshEnabled()) {
        return;
    }
    UIScrollView* scrollView = EnclosingScrollView(self);
    if (!scrollView) {
        return;  // not inside a list we know how to read; keep the X spinner
    }
    if (!drop || drop.scrollView != scrollView) {
        [drop detach];
        drop = [[NFBDropRefresh alloc] initWithControl:self scrollView:scrollView];
        objc_setAssociatedObject(self, &kDropRefreshKey, drop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [drop refreshColors];
    [drop attach];
    // Hide the X spinner; it keeps running underneath, so refreshing works as before.
    self.alpha = self.alpha;
}

- (void)setAlpha:(CGFloat)alpha {
    // Remember what X asked for, so turning the setting off puts it back.
    objc_setAssociatedObject(self, @selector(setAlpha:), @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL ours = objc_getAssociatedObject(self, &kDropRefreshKey) != nil && DropRefreshEnabled();
    %orig(ours ? 0 : alpha);
}

%end
