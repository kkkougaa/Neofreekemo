//
//  NFBCardStyle.m
//  NeoFreeBird
//

#import "Core/NFBCardStyle.h"
#import <QuartzCore/QuartzCore.h>

NSString* const NFBCardLookKey = @"kemo_card_look";
NSString* const NFBCardRadiusKey = @"kemo_card_radius";
NSString* const NFBCardGapKey = @"kemo_card_gap";
NSString* const NFBCardInnerKey = @"kemo_card_inner";
NSString* const NFBCardBodyKey = @"kemo_card_body";
NSString* const NFBCardNameKey = @"kemo_card_name";
NSString* const NFBCardAvatarKey = @"kemo_card_avatar";
NSString* const NFBCardNameGapKey = @"kemo_card_name_gap";
NSString* const NFBCardPaperKey = @"kemo_card_paper";
NSString* const NFBCardPaperRGBKey = @"kemo_card_paper_rgb";

static CGFloat Number(NSUserDefaults* defaults, NSString* key, CGFloat fallback, CGFloat low, CGFloat high) {
    id value = [defaults objectForKey:key];
    CGFloat number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
    return MAX(low, MIN(high, number));
}

NFBCardStyle NFBCardStyleCurrent(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    // Before 7.3.90 "bigger text" was one switch; it still sets the defaults
    // for the text and avatar sizes until they are chosen on the new page.
    BOOL bigger = [defaults boolForKey:@"kemo_bigger_text"];
    NFBCardStyle style;
    style.look = (NFBCardLook)Number(defaults, NFBCardLookKey, NFBCardLookOutlined, 0, 1);
    style.radius = Number(defaults, NFBCardRadiusKey, 16, 0, 30);
    style.gap = Number(defaults, NFBCardGapKey, 10, 0, 24);
    style.inner = Number(defaults, NFBCardInnerKey, 6, 0, 18);
    style.bodyStep = Number(defaults, NFBCardBodyKey, bigger ? 15 : 0, -10, 40) / 10.0;
    style.nameScale = Number(defaults, NFBCardNameKey, bigger ? 108 : 100, 90, 130) / 100.0;
    style.avatarScale = Number(defaults, NFBCardAvatarKey, bigger ? 112 : 100, 90, 130) / 100.0;
    style.paper = (NSInteger)Number(defaults, NFBCardPaperKey, NFBCardPaperDefault, 0, 4);
    style.nameGap = Number(defaults, NFBCardNameGapKey, 0, 0, 8);
    return style;
}

void NFBCardStyleReset(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    for (NSString* key in @[ NFBCardLookKey, NFBCardRadiusKey, NFBCardGapKey, NFBCardInnerKey, NFBCardBodyKey,
                             NFBCardNameKey, NFBCardAvatarKey, NFBCardPaperKey, NFBCardPaperRGBKey, NFBCardNameGapKey ]) {
        [defaults removeObjectForKey:key];
    }
    [defaults setBool:NO forKey:@"kemo_bigger_text"];
}

UIColor* NFBCardBlend(UIColor* from, UIColor* to, CGFloat amount) {
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        CGFloat r1 = 0, g1 = 0, b1 = 0, a1 = 0, r2 = 0, g2 = 0, b2 = 0, a2 = 0;
        [[from resolvedColorWithTraitCollection:traits] getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
        [[to resolvedColorWithTraitCollection:traits] getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
        return [UIColor colorWithRed:r1 + (r2 - r1) * amount
                               green:g1 + (g2 - g1) * amount
                                blue:b1 + (b2 - b1) * amount
                               alpha:1];
    }];
}

static UIColor* Pair(CGFloat light, CGFloat lightG, CGFloat lightB, CGFloat dark, CGFloat darkG, CGFloat darkB) {
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? [UIColor colorWithRed:dark green:darkG blue:darkB alpha:1]
                   : [UIColor colorWithRed:light green:lightG blue:lightB alpha:1];
    }];
}

UIColor* NFBCardPaperColor(NFBCardStyle style, UIColor* xPaper, UIColor* accent) {
    UIColor* base = xPaper ?: [UIColor systemBackgroundColor];
    switch (style.paper) {
        case NFBCardPaperGray:
            return Pair(0.973, 0.976, 0.980, 0.086, 0.094, 0.110);
        case NFBCardPaperWarm:
            return Pair(0.992, 0.980, 0.961, 0.110, 0.102, 0.090);
        case NFBCardPaperTint: {
            UIColor* hint = accent ?: [UIColor systemBlueColor];
            return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
                BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
                return [NFBCardBlend(base, hint, dark ? 0.12 : 0.06) resolvedColorWithTraitCollection:traits];
            }];
        }
        case NFBCardPaperCustom: {
            NSArray* rgb = [[NSUserDefaults standardUserDefaults] arrayForKey:NFBCardPaperRGBKey];
            if (rgb.count >= 3) {
                return [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue] blue:[rgb[2] doubleValue] alpha:1];
            }
            return base;
        }
        default:
            return base;
    }
}

UIColor* NFBCardPageColor(UIColor* paper) {
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [[paper resolvedColorWithTraitCollection:traits] getRed:&r green:&g blue:&b alpha:&a];
        CGFloat light = 0.299 * r + 0.587 * g + 0.114 * b;
        if (light > 0.5) {
            // A touch darker, leaning slightly blue-grey.
            return [UIColor colorWithRed:r + (0.12 - r) * 0.07 green:g + (0.20 - g) * 0.07 blue:b + (0.28 - b) * 0.07 alpha:1];
        }
        return [UIColor colorWithRed:MIN(1, r + 0.07) green:MIN(1, g + 0.07) blue:MIN(1, b + 0.08) alpha:1];
    }];
}

// The card draws its own fill as a shape, with the shadow on that shape, both
// inside a box that is cut off exactly at an open edge: two joined cards then
// meet with no shadow or outline between them (7.3.90 showed a dark seam).
@implementation NFBCardView {
    CALayer* _shadowBox;
    CAShapeLayer* _fill;
    CALayer* _outlineBox;
    CAShapeLayer* _outline;
    UIColor* _fillColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        [super setBackgroundColor:[UIColor clearColor]];
        _shadowBox = [CALayer layer];
        _shadowBox.masksToBounds = YES;
        _fill = [CAShapeLayer layer];
        [_shadowBox addSublayer:_fill];
        [self.layer addSublayer:_shadowBox];
        _outlineBox = [CALayer layer];
        _outlineBox.masksToBounds = YES;
        _outline = [CAShapeLayer layer];
        _outline.fillColor = nil;
        [_outlineBox addSublayer:_outline];
        [self.layer addSublayer:_outlineBox];
        _style = NFBCardStyleCurrent();
    }
    return self;
}

- (void)setBackgroundColor:(UIColor*)color {
    _fillColor = color;
    [self setNeedsLayout];
}

- (UIColor*)backgroundColor {
    return _fillColor;
}

- (void)setStyle:(NFBCardStyle)style {
    _style = style;
    [self setNeedsLayout];
}

- (void)setOpenTop:(BOOL)openTop {
    if (_openTop != openTop) {
        _openTop = openTop;
        [self setNeedsLayout];
    }
}

- (void)setOpenBottom:(BOOL)openBottom {
    if (_openBottom != openBottom) {
        _openBottom = openBottom;
        [self setNeedsLayout];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection*)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat radius = MIN(self.radiusOverride > 0 ? self.radiusOverride : self.style.radius,
                         MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds)) / 2);
    UIRectCorner rounded = 0;
    if (!self.openTop) {
        rounded |= UIRectCornerTopLeft | UIRectCornerTopRight;
    }
    if (!self.openBottom) {
        rounded |= UIRectCornerBottomLeft | UIRectCornerBottomRight;
    }
    // Open edges reach past the bounds, where the boxes cut them off.
    CGFloat reach = 40;
    CGRect shape = bounds;
    if (self.openTop) {
        shape.origin.y -= reach;
        shape.size.height += reach;
    }
    if (self.openBottom) {
        shape.size.height += reach;
    }
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    BOOL shadow = !self.plain && self.style.look == NFBCardLookFloating && !dark;
    BOOL line = !self.plain && !shadow;
    CGFloat hair = 1.0 / MAX(1.0, UIScreen.mainScreen.scale);
    CGPathRef outlinePath = [UIBezierPath bezierPathWithRoundedRect:shape
                                                  byRoundingCorners:rounded
                                                        cornerRadii:CGSizeMake(radius, radius)]
                                .CGPath;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // The shadow box: room for the shadow on closed edges, none on open ones.
    CGFloat room = shadow ? 24 : 0;
    CGRect box = CGRectInset(bounds, -room, 0);
    if (!self.openTop) {
        box.origin.y -= room;
        box.size.height += room;
    }
    if (!self.openBottom) {
        box.size.height += room;
    }
    _shadowBox.frame = box;
    _fill.frame = CGRectMake(-box.origin.x, -box.origin.y, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    _fill.path = outlinePath;
    _fill.fillColor = [_fillColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    if (shadow) {
        _fill.shadowColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.10 alpha:1].CGColor;
        _fill.shadowOpacity = 0.07;
        _fill.shadowRadius = 7;
        _fill.shadowOffset = CGSizeMake(0, 2);
        _fill.shadowPath = outlinePath;
    } else {
        _fill.shadowOpacity = 0;
        _fill.shadowPath = nil;
    }
    _outlineBox.frame = bounds;
    _outline.hidden = !line;
    if (line) {
        CGFloat alpha = dark ? (self.style.look == NFBCardLookFloating ? 0.08 : 0.10) : 0.07;
        _outline.strokeColor = [UIColor colorWithWhite:dark ? 1 : 0 alpha:alpha].CGColor;
        _outline.lineWidth = hair;
        _outline.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(shape, hair / 2, hair / 2)
                                              byRoundingCorners:rounded
                                                    cornerRadii:CGSizeMake(radius, radius)]
                            .CGPath;
    }
    [CATransaction commit];
}

@end
