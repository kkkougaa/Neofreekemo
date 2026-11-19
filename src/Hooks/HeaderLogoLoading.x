//
//  HeaderLogoLoading.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - The header logo

// Finding the logo in the top bar and drawing it from the bundled SVGs, for
// the header bubble and the logo menu. (Until 7.3.105 the bird inside the logo
// was swapped for counting dots while the timeline refreshed.)

@interface TFNPullToRefreshControl : UIView
- (BOOL)loading;
@end

// Readability.x: notes what the pull looked like, for the shake dump.
extern void NFBNotePullStatus(UIView* control, unsigned long long status);

static const CGFloat kLogoViewBox = 1024.0;

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

%hook TFNPullToRefreshControl

- (void)_setStatus:(unsigned long long)status fromScrolling:(BOOL)fromScrolling {
    %orig;
    NFBNotePullStatus(self, status);
}

%end
