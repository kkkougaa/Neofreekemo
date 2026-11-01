//
//  JellyPaw.x
//  NeoFreeBird
//
//  A rubber paw drawn over X's pull-to-refresh control. The control itself still
//  starts the refresh; if it is not the timeline's control, the paw stays off.

#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import "HookHelpers.h"

static const void* kPawKey = &kPawKey;
static const void* kStampedKey = &kStampedKey;

static BOOL PawOn(void) {
    return [BHTSettings boolForKey:@"kemo_jelly_paw"];
}

static BOOL IsTimelineScroller(UIScrollView* scroll) {
    if (![scroll isKindOfClass:[UIScrollView class]] || scroll.bounds.size.height < 200) {
        return NO;
    }
    UIResponder* responder = scroll;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            NSString* name = NSStringFromClass(responder.class);
            if ([name containsString:@"Timeline"] || [name containsString:@"Home"] ||
                [name containsString:@"URT"] || [name containsString:@"ItemsData"]) {
                return YES;
            }
        }
        responder = responder.nextResponder;
    }
    return NO;
}

static id PawValue(id object, NSString* selectorName) {
    if (!object) {
        return nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* returnType = signature.methodReturnType;
    if (!returnType || strcmp(returnType, @encode(id)) != 0) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGFloat PawFloat(id object, NSString* selectorName) {
    if (!object) {
        return 0;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return 0;
    }
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* returnType = signature.methodReturnType;
    if (!returnType) {
        return 0;
    }
    if (strcmp(returnType, @encode(double)) == 0 || strcmp(returnType, "d") == 0) {
        return (CGFloat)((double (*)(id, SEL))objc_msgSend)(object, selector);
    }
    if (strcmp(returnType, @encode(float)) == 0 || strcmp(returnType, "f") == 0) {
        return ((float (*)(id, SEL))objc_msgSend)(object, selector);
    }
    return 0;
}

static UIBezierPath* PawPath(CGRect bounds) {
    UIBezierPath* path = [UIBezierPath bezierPath];
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(width * 0.22, height * 0.40,
                                                                       width * 0.56, height * 0.50)]];
    CGFloat toeW = width * 0.22;
    CGFloat toeH = height * 0.24;
    CGFloat xs[4] = {0.06, 0.28, 0.50, 0.70};
    CGFloat ys[4] = {0.26, 0.06, 0.04, 0.24};
    for (NSInteger i = 0; i < 4; i++) {
        [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(width * xs[i], height * ys[i],
                                                                           toeW, toeH)]];
    }
    return path;
}

static CAShapeLayer* PawLayer(UIView* control) {
    CAShapeLayer* paw = objc_getAssociatedObject(control, kPawKey);
    if (paw) {
        return paw;
    }
    paw = [CAShapeLayer layer];
    paw.path = PawPath(CGRectMake(0, 0, 36, 36)).CGPath;
    paw.bounds = CGRectMake(0, 0, 36, 36);
    paw.fillColor = [UIColor colorWithRed:0.96 green:0.45 blue:0.55 alpha:1].CGColor;
    paw.contentsScale = UIScreen.mainScreen.scale;
    [control.layer addSublayer:paw];
    objc_setAssociatedObject(control, kPawKey, paw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return paw;
}

static void PawHideStockArrow(UIView* control, BOOL hide) {
    UIView* arrow = PawValue(control, @"arrowView");
    if ([arrow isKindOfClass:[UIView class]]) {
        arrow.alpha = hide ? 0 : 1;
    }
}

static void PawUpdate(UIView* control) {
    CAShapeLayer* paw = objc_getAssociatedObject(control, kPawKey);
    if (!PawOn()) {
        paw.hidden = YES;
        PawHideStockArrow(control, NO);
        return;
    }
    UIScrollView* scroll = PawValue(control, @"savedScrollView");
    if (![scroll isKindOfClass:[UIScrollView class]] || !IsTimelineScroller(scroll)) {
        paw.hidden = YES;
        PawHideStockArrow(control, NO);
        return;
    }
    CGFloat pulled = (-scroll.adjustedContentInset.top) - scroll.contentOffset.y;
    if (pulled < 0) {
        pulled = 0;
    }
    CGFloat threshold = fabs(PawFloat(control, @"thresholdOffsetY"));
    if (threshold < 20 || threshold > 400) {
        threshold = 72;
    }
    CGFloat fraction = MIN(1.35, pulled / threshold);
    if (fraction < 0.04) {
        if (paw) {
            paw.hidden = YES;
        }
        PawHideStockArrow(control, NO);
        objc_setAssociatedObject(control, kStampedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    paw = PawLayer(control);
    paw.hidden = NO;
    PawHideStockArrow(control, YES);
    paw.position = CGPointMake(CGRectGetMidX(control.bounds), CGRectGetMidY(control.bounds));
    CGFloat squash = 1.0 - MIN(fraction, 1.0) * 0.18;
    CGFloat stretch = 1.0 + MIN(fraction, 1.0) * 0.55;
    // layoutSubviews keeps running during the stamp, so leave that animation alone.
    if ([paw animationForKey:@"stamp"] == nil) {
        paw.transform = CATransform3DMakeScale(squash, stretch, 1);
    }
    if (fraction >= 1.0 && objc_getAssociatedObject(control, kStampedKey) == nil) {
        objc_setAssociatedObject(control, kStampedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
            UIImpactFeedbackGenerator* tap =
                [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [tap impactOccurred];
        }
        CAKeyframeAnimation* stamp = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        stamp.values = @[ @1.0, @1.28, @0.86, @1.0 ];
        stamp.keyTimes = @[ @0, @0.35, @0.7, @1 ];
        stamp.duration = 0.28;
        [paw addAnimation:stamp forKey:@"stamp"];
    }
}

%hook TFNPullToRefreshControl

- (void)layoutSubviews {
    %orig;
    PawUpdate((UIView*)self);
}

- (void)setLoading:(BOOL)loading {
    %orig;
    if (!loading) {
        PawUpdate((UIView*)self);
    }
}

%end
