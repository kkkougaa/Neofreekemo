//
//  HeaderLogoLoading.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Header logo loading dots

// While the timeline refreshes, the bird inside the logo's speech bubble is swapped for
// dots that count . .. ...; when the refresh ends the bird comes back and the logo pops.
// Refresh start/end comes from the pull-to-refresh control.

@interface TFNPullToRefreshControl : UIView
- (BOOL)loading;
@end

extern void NFBNoteRefreshStarted(void);
extern void NFBKeepPositionBegin(UIView* control);
extern void NFBKeepPositionEnd(void);

static const NSInteger kLogoDotsTag = 0x4E464C44;
static const CGFloat kLogoViewBox = 1024.0;
// Middle of the bubble hole (x 53-445, y 66-401 in the 1024 logo units).
static const CGPoint kBubbleCenter = {249.0, 232.0};

UIImageView* HeaderLogoInWindow(UIWindow* window) {
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
    while (queue.count > 0) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:[UIImageView class]] && !view.hidden && view.alpha > 0.01 &&
            CGRectGetWidth(view.bounds) <= 80 && CGRectGetWidth(view.bounds) >= 24 &&
            [NSStringFromClass([view.superview.superview class]) containsString:@"NavigationBarTitleControl"]) {
            return (UIImageView*)view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

UIWindow* NFBKeyWindow(void) {
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

// The logo without its bird: the bundled SVG is plain polygons (M x y x y ... Z, even-odd).
UIImage* NFBRenderLogoSVG(NSString* fileName, CGSize size, UIColor* color) {
    NSURL* url = [[BHTBundle sharedBundle] pathForFile:fileName];
    NSString* svg = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] : nil;
    NSRange start = [svg rangeOfString:@" d=\""];
    if (start.location == NSNotFound) {
        return nil;
    }
    NSString* rest = [svg substringFromIndex:NSMaxRange(start)];
    NSRange end = [rest rangeOfString:@"\""];
    if (end.location == NSNotFound) {
        return nil;
    }
    NSString* data = [rest substringToIndex:end.location];

    UIBezierPath* path = [UIBezierPath bezierPath];
    path.usesEvenOddFillRule = YES;
    NSScanner* scanner = [NSScanner scannerWithString:data];
    BOOL open = NO;
    while (!scanner.isAtEnd) {
        if ([scanner scanString:@"M" intoString:nil]) {
            double x = 0, y = 0;
            if ([scanner scanDouble:&x] && [scanner scanDouble:&y]) {
                [path moveToPoint:CGPointMake(x, y)];
                open = YES;
            }
        } else if ([scanner scanString:@"Z" intoString:nil]) {
            [path closePath];
            open = NO;
        } else {
            double x = 0, y = 0;
            if ([scanner scanDouble:&x] && [scanner scanDouble:&y]) {
                if (open) {
                    [path addLineToPoint:CGPointMake(x, y)];
                }
            } else {
                scanner.scanLocation += 1;
            }
        }
    }

    CGFloat scale = size.width / kLogoViewBox;
    UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        CGContextScaleCTM(context.CGContext, scale, scale);
        [color setFill];
        [path fill];
    }];
}

@interface NFBLogoDots : UIView
@property (nonatomic, strong) NSTimer* timer;
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, strong) UIImage* originalImage;
@property (nonatomic, strong) NSArray<UIView*>* dots;
@end

@implementation NFBLogoDots

- (void)tick {
    NSInteger previous = self.count;
    self.count = self.count % 3 + 1;
    for (NSUInteger i = 0; i < self.dots.count; i++) {
        BOOL visible = (NSInteger)i < self.count;
        UIView* dot = self.dots[i];
        if (visible && dot.alpha < 0.5 && previous != 0) {
            // The dot that just appeared pops in a little, and that is all.
            dot.alpha = 1;
            dot.transform = CGAffineTransformMakeScale(0.5, 0.5);
            [UIView animateWithDuration:0.22
                                  delay:0
                 usingSpringWithDamping:0.6
                  initialSpringVelocity:0
                                options:0
                             animations:^{
                                 dot.transform = CGAffineTransformIdentity;
                             }
                             completion:nil];
        } else {
            dot.alpha = visible ? 1.0 : 0.0;
        }
    }
}

- (void)start {
    [self.timer invalidate];
    self.count = 0;
    [self tick];
    __weak NFBLogoDots* weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                 repeats:YES
                                                   block:^(NSTimer* timer) {
                                                       [weakSelf tick];
                                                   }];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [self removeFromSuperview];
}

@end

static void StartLogoLoading(void) {
    if (![BHTSettings boolForKey:@"kemo_logo_loading"]) {
        return;
    }
    UIWindow* window = NFBKeyWindow();
    UIImageView* logo = window ? HeaderLogoInWindow(window) : nil;
    if (!logo || !logo.image || [logo viewWithTag:kLogoDotsTag]) {
        return;
    }

    UIColor* color = logo.tintColor ?: CurrentAccentColor();
    UIImage* empty = NFBRenderLogoSVG(@"logo_loading.svg", logo.bounds.size, color);
    if (!empty) {
        return;
    }

    CGFloat width = CGRectGetWidth(logo.bounds);
    CGFloat unit = width / kLogoViewBox;
    // The bubble hole is about 392 of the 1024 logo units wide; the dots take about two thirds of it.
    CGFloat bubbleWidth = 392.0 * unit;
    CGFloat diameter = bubbleWidth * 0.16;
    CGFloat gap = bubbleWidth * 0.26;
    CGPoint center = CGPointMake(kBubbleCenter.x * unit, kBubbleCenter.y * unit);

    NFBLogoDots* holder = [[NFBLogoDots alloc] initWithFrame:logo.bounds];
    holder.tag = kLogoDotsTag;
    holder.userInteractionEnabled = NO;
    holder.originalImage = logo.image;
    NSMutableArray<UIView*>* dots = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        UIView* dot = [[UIView alloc]
            initWithFrame:CGRectMake(center.x + (i - 1) * gap - diameter / 2, center.y - diameter / 2,
                                     diameter, diameter)];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = diameter / 2;
        [holder addSubview:dot];
        [dots addObject:dot];
    }
    holder.dots = dots;

    logo.image = empty;
    [logo addSubview:holder];
    [holder start];
}

static void StopLogoLoading(void) {
    UIWindow* window = NFBKeyWindow();
    UIImageView* logo = window ? HeaderLogoInWindow(window) : nil;
    NFBLogoDots* holder = (NFBLogoDots*)[logo viewWithTag:kLogoDotsTag];
    if (![holder isKindOfClass:[NFBLogoDots class]]) {
        return;
    }
    logo.image = holder.originalImage;
    [holder stop];

    // A small, soft swell as a layer animation only: nothing changes on the view itself, so
    // UIKit has nothing to react to (a transform on the logo made it re-measure the title).
    CABasicAnimation* swell = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    swell.fromValue = @1.0;
    swell.toValue = @1.07;
    swell.duration = 0.28;
    swell.autoreverses = YES;
    swell.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [logo.layer addAnimation:swell forKey:@"nfbSwell"];
}

%hook TFNPullToRefreshControl

- (void)_setStatus:(unsigned long long)status fromScrolling:(BOOL)fromScrolling {
    BOOL wasActive = [self loading];

    %orig;

    if (status == 1 && !wasActive) {
        NFBNoteRefreshStarted();
        NFBKeepPositionBegin(self);
        StartLogoLoading();
    } else if (status == 0 && wasActive) {
        NFBKeepPositionEnd();
        StopLogoLoading();
    }
}

%end
