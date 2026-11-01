#import "Mood/NFBMoodFaceView.h"

static UIColor *NFBMoodColor(NSInteger level) {
    switch (level) {
        case 1:
            return [UIColor colorWithRed:0x2D / 255.0 green:0xD4 / 255.0 blue:0xBF / 255.0 alpha:1];
        case 2:
            return [UIColor colorWithRed:0x3B / 255.0 green:0x82 / 255.0 blue:0xF6 / 255.0 alpha:1];
        case 3:
            return [UIColor colorWithRed:0xF5 / 255.0 green:0xC5 / 255.0 blue:0x42 / 255.0 alpha:1];
        case 4:
            return [UIColor colorWithRed:0xF9 / 255.0 green:0x73 / 255.0 blue:0x16 / 255.0 alpha:1];
        case 5:
            return [UIColor colorWithRed:0xEF / 255.0 green:0x44 / 255.0 blue:0x44 / 255.0 alpha:1];
        default:
            return [UIColor colorWithRed:0xA2 / 255.0 green:0x1C / 255.0 blue:0xAF / 255.0 alpha:1];
    }
}

@implementation NFBMoodFaceView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.isAccessibilityElement = NO;
    }
    return self;
}

- (void)setLevel:(NSInteger)level {
    if (_level == level) {
        return;
    }
    _level = level;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (self.level < 1 || self.level > 6) {
        return;
    }
    CGFloat side = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect));
    if (side < 2) {
        return;
    }
    CGRect box = CGRectMake((CGRectGetWidth(rect) - side) / 2.0,
                            (CGRectGetHeight(rect) - side) / 2.0, side, side);
    CGFloat inset = side * 0.04;
    CGRect circle = CGRectInset(box, inset, inset);
    [NFBMoodColor(self.level) setFill];
    [[UIBezierPath bezierPathWithOvalInRect:circle] fill];

    CGPoint center = CGPointMake(CGRectGetMidX(circle), CGRectGetMidY(circle));
    CGFloat radius = CGRectGetWidth(circle) / 2.0;
    CGFloat line = MAX(1.15, side * 0.078);
    [[UIColor whiteColor] setStroke];
    [[UIColor whiteColor] setFill];

    CGFloat eyeRadius = side * (self.level >= 5 ? 0.055 : 0.062);
    CGFloat eyeY = center.y - radius * 0.16;
    CGFloat eyeDX = radius * 0.38;
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(center.x - eyeDX - eyeRadius, eyeY - eyeRadius,
                                                       eyeRadius * 2, eyeRadius * 2)] fill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(center.x + eyeDX - eyeRadius, eyeY - eyeRadius,
                                                       eyeRadius * 2, eyeRadius * 2)] fill];

    if (self.level >= 4) {
        UIBezierPath *brows = [UIBezierPath bezierPath];
        brows.lineWidth = line;
        brows.lineCapStyle = kCGLineCapRound;
        CGFloat browY = eyeY - radius * 0.32;
        CGFloat drop = self.level == 4 ? radius * 0.12 : (self.level == 5 ? radius * 0.24 : radius * 0.34);
        CGFloat outer = radius * 0.22;
        CGFloat inner = radius * 0.16;
        [brows moveToPoint:CGPointMake(center.x - eyeDX - outer, browY)];
        [brows addLineToPoint:CGPointMake(center.x - eyeDX + inner, browY + drop)];
        [brows moveToPoint:CGPointMake(center.x + eyeDX + outer, browY)];
        [brows addLineToPoint:CGPointMake(center.x + eyeDX - inner, browY + drop)];
        [brows stroke];
    }

    CGFloat mouthY = center.y + radius * 0.42;
    CGFloat mouthW = radius * 0.62;
    UIBezierPath *mouth = [UIBezierPath bezierPath];
    mouth.lineWidth = line;
    mouth.lineCapStyle = kCGLineCapRound;
    mouth.lineJoinStyle = self.level == 6 ? kCGLineJoinMiter : kCGLineJoinRound;
    BOOL strokeMouth = YES;
    switch (self.level) {
        case 1:
            [mouth moveToPoint:CGPointMake(center.x - mouthW, mouthY - radius * 0.02)];
            [mouth addQuadCurveToPoint:CGPointMake(center.x + mouthW, mouthY - radius * 0.02)
                          controlPoint:CGPointMake(center.x, mouthY + radius * 0.42)];
            break;
        case 2:
            [mouth moveToPoint:CGPointMake(center.x - mouthW * 0.85, mouthY)];
            [mouth addLineToPoint:CGPointMake(center.x + mouthW * 0.85, mouthY)];
            break;
        case 3: {
            CGFloat amp = radius * 0.16;
            [mouth moveToPoint:CGPointMake(center.x - mouthW, mouthY)];
            [mouth addCurveToPoint:CGPointMake(center.x, mouthY)
                     controlPoint1:CGPointMake(center.x - mouthW * 0.55, mouthY - amp)
                     controlPoint2:CGPointMake(center.x - mouthW * 0.28, mouthY + amp)];
            [mouth addCurveToPoint:CGPointMake(center.x + mouthW, mouthY)
                     controlPoint1:CGPointMake(center.x + mouthW * 0.28, mouthY - amp)
                     controlPoint2:CGPointMake(center.x + mouthW * 0.55, mouthY + amp)];
            break;
        }
        case 4:
            [mouth moveToPoint:CGPointMake(center.x - mouthW, mouthY + radius * 0.16)];
            [mouth addQuadCurveToPoint:CGPointMake(center.x + mouthW, mouthY + radius * 0.16)
                          controlPoint:CGPointMake(center.x, mouthY - radius * 0.28)];
            break;
        case 5: {
            strokeMouth = NO;
            CGRect open = CGRectMake(center.x - mouthW * 0.48, mouthY - radius * 0.18, mouthW * 0.96,
                                     radius * 0.50);
            UIBezierPath *oval = [UIBezierPath bezierPathWithOvalInRect:open];
            oval.lineWidth = line;
            [oval stroke];
            break;
        }
        default: {
            CGFloat left = center.x - mouthW;
            CGFloat right = center.x + mouthW;
            CGFloat top = mouthY - radius * 0.20;
            CGFloat bottom = mouthY + radius * 0.22;
            [mouth moveToPoint:CGPointMake(left, top)];
            [mouth addLineToPoint:CGPointMake(center.x - mouthW * 0.28, bottom)];
            [mouth addLineToPoint:CGPointMake(center.x + mouthW * 0.12, top)];
            [mouth addLineToPoint:CGPointMake(right, bottom)];
            break;
        }
    }
    if (strokeMouth) {
        [mouth stroke];
    }
}

@end
