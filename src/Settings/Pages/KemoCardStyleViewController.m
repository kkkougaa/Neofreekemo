//
//  KemoCardStyleViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoCardStyleViewController.h"
#import "Core/BHTBundle.h"
#import "Core/NFBCardStyle.h"

extern UIColor* CurrentAccentColor(void);

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

// MARK: - Preview
// A few made-up rows drawn with the same card view and the same numbers as the
// timeline: a tweet, and a thread (first tweet, then a reply in the inner box).

@interface NFBCardPreviewRow : NSObject
@property (nonatomic, strong) UIView* avatar;
@property (nonatomic, strong) UILabel* name;
@property (nonatomic, strong) UILabel* body;
@property (nonatomic, strong) UILabel* actions;
@end

@implementation NFBCardPreviewRow
@end

@interface NFBCardPreview : UIView
@property (nonatomic, assign) NFBCardStyle style;
@end

@implementation NFBCardPreview {
    NFBCardView* _first;
    NFBCardView* _thread;
    UIView* _nest;
    CAShapeLayer* _line;
    NSArray<NFBCardPreviewRow*>* _rows;
}

- (NFBCardPreviewRow*)rowWithName:(NSString*)name handle:(NSString*)handle body:(NSString*)body color:(UIColor*)color {
    NFBCardPreviewRow* row = [NFBCardPreviewRow new];
    row.avatar = [UIView new];
    row.avatar.backgroundColor = color;
    row.name = [UILabel new];
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc] initWithString:name];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:handle]]];
    row.name.attributedText = text;
    row.name.lineBreakMode = NSLineBreakByTruncatingTail;
    row.body = [UILabel new];
    row.body.text = body;
    row.body.numberOfLines = 2;
    row.actions = [UILabel new];
    row.actions.text = @"💬 3      🔁 1      ♡ 12      📊 131";
    row.actions.textColor = [UIColor secondaryLabelColor];
    for (UIView* view in @[ row.avatar, row.name, row.body, row.actions ]) {
        [self addSubview:view];
    }
    return row;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        _first = [NFBCardView new];
        _thread = [NFBCardView new];
        _nest = [UIView new];
        _nest.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:_first];
        [self addSubview:_thread];
        [self addSubview:_nest];
        _line = [CAShapeLayer layer];
        _line.fillColor = nil;
        _line.lineWidth = 2;
        _line.lineCap = kCALineCapRound;
        _rows = @[
            [self rowWithName:@"フェムト" handle:@"@femt_1240 · 8분" body:L(@"KEMO_CARD_PREVIEW_BODY1")
                        color:[UIColor colorWithRed:0.48 green:0.56 blue:0.69 alpha:1]],
            [self rowWithName:@"きたしろ" handle:@"@NW_1838 · 19시" body:L(@"KEMO_CARD_PREVIEW_BODY2")
                        color:[UIColor colorWithRed:0.85 green:0.65 blue:0.42 alpha:1]],
            [self rowWithName:@"ねこ" handle:@"@neko · 18시" body:L(@"KEMO_CARD_PREVIEW_BODY3")
                        color:[UIColor colorWithRed:0.72 green:0.64 blue:0.79 alpha:1]],
        ];
    }
    return self;
}

- (void)setStyle:(NFBCardStyle)style {
    _style = style;
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection*)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsLayout];
}

// Lays one made-up row out in `box` (the row's full width, like X's row), then
// draws it scaled into `target`, the way the timeline does. Returns its height.
- (CGFloat)layoutRow:(NFBCardPreviewRow*)row at:(CGFloat)y width:(CGFloat)width target:(CGRect)target {
    NFBCardStyle style = self.style;
    CGFloat avatarSide = 40;
    UIFont* nameFont = [UIFont systemFontOfSize:15 * style.nameScale weight:UIFontWeightBold];
    UIFont* handleFont = [UIFont systemFontOfSize:15 * style.nameScale];
    NSMutableAttributedString* name = [row.name.attributedText mutableCopy];
    NSRange space = [name.string rangeOfString:@" "];
    [name addAttributes:@{NSFontAttributeName : nameFont, NSForegroundColorAttributeName : [UIColor labelColor]}
                  range:NSMakeRange(0, space.location)];
    [name addAttributes:@{NSFontAttributeName : handleFont, NSForegroundColorAttributeName : [UIColor secondaryLabelColor]}
                  range:NSMakeRange(space.location, name.length - space.location)];
    row.name.attributedText = name;
    row.body.font = [UIFont systemFontOfSize:15 + style.bodyStep];
    row.actions.font = [UIFont systemFontOfSize:12];

    // X's own row: 12 above, avatar at 16, text column from 68.
    CGFloat textX = 68, textW = width - textX - 16;
    CGFloat nameH = ceil(nameFont.lineHeight);
    CGSize bodySize = [row.body sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)];
    CGFloat height = 12 + nameH + 2 + bodySize.height + 8 + 18 + 10;

    CGFloat scale = CGRectGetWidth(target) / width;
    CGAffineTransform place = CGAffineTransformMakeTranslation(CGRectGetMinX(target), y + (1 - scale) * height / 2);
    place = CGAffineTransformScale(place, scale, scale);
    void (^put)(UIView*, CGRect) = ^(UIView* view, CGRect frame) {
        view.transform = CGAffineTransformIdentity;
        view.frame = frame;
        CGPoint center = CGPointApplyAffineTransform(CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)), place);
        view.center = center;
        view.transform = CGAffineTransformMakeScale(scale, scale);
    };
    CGFloat side = avatarSide * style.avatarScale;
    // The avatar grows from its top right corner, as in the timeline.
    put(row.avatar, CGRectMake(16 + avatarSide - side, 12, side, side));
    row.avatar.layer.cornerRadius = side / 2;
    put(row.name, CGRectMake(textX, 12 - style.nameGap, textW, nameH));
    put(row.body, CGRectMake(textX, 12 + nameH + 2, textW, bodySize.height));
    put(row.actions, CGRectMake(textX, 12 + nameH + 2 + bodySize.height + 8, textW, 18));
    row.actions.alpha = 0.6;
    return height * scale;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NFBCardStyle style = self.style;
    UIColor* xPaper = [UIColor systemBackgroundColor];
    UIColor* paper = NFBCardPaperColor(style, xPaper, CurrentAccentColor());
    UIColor* page = NFBCardPageColor(paper);
    self.backgroundColor = page;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat side = 8, half = style.gap / 2;

    // A plain tweet card.
    CGFloat top = 10 + half;
    CGFloat inner = (width - (side + style.inner) * 2);
    CGRect target = CGRectMake((width - inner) / 2, top, inner, 0);
    CGFloat h1 = [self layoutRow:_rows[0] at:top width:width target:target];
    CGFloat cardTop = top;
    CGFloat cardBottom = top + h1;
    // The card reaches as far as the row (the gap is outside it).
    _first.style = style;
    _first.backgroundColor = paper;
    _first.frame = CGRectMake(side, cardTop, width - side * 2, cardBottom - cardTop);

    // A thread: first tweet, then a reply in the inner box.
    CGFloat t2 = cardBottom + style.gap;
    CGFloat h2 = [self layoutRow:_rows[1] at:t2 width:width target:CGRectMake((width - inner) / 2, t2, inner, 0)];
    CGFloat nestLeft = side + 46, nestRight = width - side - 8;
    CGFloat t3 = t2 + h2;
    CGFloat nestW = nestRight - nestLeft;
    CGFloat h3 = [self layoutRow:_rows[2] at:t3 + 2 width:width target:CGRectMake(nestLeft + 2, t3 + 2, nestW - 4, 0)];
    _thread.style = style;
    _thread.backgroundColor = paper;
    _thread.frame = CGRectMake(side, t2, width - side * 2, h2 + h3 + 14);
    _nest.backgroundColor = NFBCardBlend(paper, page, 0.55);
    _nest.layer.cornerRadius = MAX(4, MIN(14, style.radius * 0.75));
    _nest.frame = CGRectMake(nestLeft, t3, nestW, h3 + 4);
    [self bringSubviewToFront:_nest];
    for (NFBCardPreviewRow* row in _rows) {
        for (UIView* view in @[ row.avatar, row.name, row.body, row.actions ]) {
            [self bringSubviewToFront:view];
        }
    }
    // The reply line: down from the first tweet's avatar, bending into the reply's.
    CGRect head = _rows[1].avatar.frame, reply = _rows[2].avatar.frame;
    CGFloat x = CGRectGetMidX(head), y = CGRectGetMidY(reply), bend = 10;
    UIBezierPath* path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(x, CGRectGetMaxY(head) + 4)];
    [path addLineToPoint:CGPointMake(x, y - bend)];
    [path addQuadCurveToPoint:CGPointMake(x + bend, y) controlPoint:CGPointMake(x, y)];
    [path addLineToPoint:CGPointMake(CGRectGetMinX(reply) - 4, y)];
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    _line.strokeColor = (dark ? [UIColor colorWithRed:0.20 green:0.21 blue:0.22 alpha:1]
                              : [UIColor colorWithRed:0.81 green:0.85 blue:0.87 alpha:1]).CGColor;
    _line.path = path.CGPath;
    [_line removeFromSuperlayer];
    [self.layer addSublayer:_line];
}

@end

// MARK: - The page

@interface KemoCardStyleViewController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, strong) NFBCardPreview* preview;
@property (nonatomic, strong) UIStackView* stack;
@property (nonatomic, strong) UISegmentedControl* lookControl;
@property (nonatomic, strong) NSMutableArray<UIButton*>* swatches;
@property (nonatomic, strong) NSMutableDictionary<NSString*, UISlider*>* sliders;
@property (nonatomic, strong) NSMutableDictionary<NSString*, UILabel*>* values;
@end

@implementation KemoCardStyleViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"KEMO_CARD_STYLE_TITLE");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.sliders = [NSMutableDictionary dictionary];
    self.values = [NSMutableDictionary dictionary];
    self.swatches = [NSMutableArray array];
    UIColor* accent = CurrentAccentColor();
    self.view.tintColor = accent;

    self.preview = [NFBCardPreview new];
    self.preview.translatesAutoresizingMaskIntoConstraints = NO;
    self.preview.layer.cornerRadius = 20;
    self.preview.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:self.preview];

    UIScrollView* scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 18;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];

    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.preview.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.preview.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.preview.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.preview.heightAnchor constraintEqualToConstant:320],
        [scroll.topAnchor constraintEqualToAnchor:self.preview.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
    ]];

    [self addHeading:L(@"KEMO_CARD_SECTION_CARD")];
    self.lookControl = [[UISegmentedControl alloc]
        initWithItems:@[ L(@"KEMO_CARD_LOOK_OUTLINED"), L(@"KEMO_CARD_LOOK_FLOATING") ]];
    [self.lookControl addTarget:self action:@selector(lookChanged:) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.lookControl];
    [self addSlider:NFBCardRadiusKey title:L(@"KEMO_CARD_RADIUS") min:0 max:30 unit:@"pt" divisor:1];
    [self addSlider:NFBCardGapKey title:L(@"KEMO_CARD_GAP") min:0 max:24 unit:@"pt" divisor:1];
    [self addSlider:NFBCardInnerKey title:L(@"KEMO_CARD_INNER") min:0 max:18 unit:@"pt" divisor:1];
    [self addPaperRow];

    [self addHeading:L(@"KEMO_CARD_SECTION_TEXT")];
    [self addSlider:NFBCardBodyKey title:L(@"KEMO_CARD_BODY") min:-10 max:40 unit:@"pt" divisor:10];
    [self addSlider:NFBCardNameKey title:L(@"KEMO_CARD_NAME") min:90 max:130 unit:@"%" divisor:1];
    [self addSlider:NFBCardNameGapKey title:L(@"KEMO_CARD_NAME_GAP") min:0 max:8 unit:@"pt" divisor:1];
    [self addSlider:NFBCardAvatarKey title:L(@"KEMO_CARD_AVATAR") min:90 max:130 unit:@"%" divisor:1];
    UILabel* note = [UILabel new];
    note.text = L(@"KEMO_CARD_BODY_NOTE");
    note.numberOfLines = 0;
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.textColor = [UIColor secondaryLabelColor];
    [self.stack addArrangedSubview:note];

    UIButton* reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:L(@"KEMO_CARD_RESET") forState:UIControlStateNormal];
    [reset setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:reset];

    [self reload];
}

- (void)addHeading:(NSString*)text {
    UILabel* label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    [self.stack addArrangedSubview:label];
}

- (void)addSlider:(NSString*)key title:(NSString*)title min:(float)min max:(float)max unit:(NSString*)unit divisor:(float)divisor {
    UILabel* name = [UILabel new];
    name.text = title;
    name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    UILabel* value = [UILabel new];
    value.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
    value.textColor = [UIColor secondaryLabelColor];
    value.textAlignment = NSTextAlignmentRight;
    value.accessibilityHint = [NSString stringWithFormat:@"%@|%g", unit, divisor];
    [value setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView* top = [[UIStackView alloc] initWithArrangedSubviews:@[ name, value ]];
    UISlider* slider = [UISlider new];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.accessibilityIdentifier = key;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[ top, slider ]];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 4;
    [self.stack addArrangedSubview:row];
    self.sliders[key] = slider;
    self.values[key] = value;
}

- (void)addPaperRow {
    UILabel* name = [UILabel new];
    name.text = L(@"KEMO_CARD_PAPER");
    name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    UIStackView* swatches = [UIStackView new];
    swatches.spacing = 10;
    swatches.distribution = UIStackViewDistributionFillEqually;
    NSArray* titles = @[ L(@"KEMO_CARD_PAPER_DEFAULT"), L(@"KEMO_CARD_PAPER_GRAY"), L(@"KEMO_CARD_PAPER_WARM"),
                         L(@"KEMO_CARD_PAPER_TINT"), L(@"KEMO_CARD_PAPER_CUSTOM") ];
    for (NSInteger i = 0; i < 5; i++) {
        UIButton* button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = i;
        button.layer.cornerRadius = 10;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.7;
        button.contentEdgeInsets = UIEdgeInsetsMake(0, 2, 0, 2);
        [button setTitle:titles[i] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [button.heightAnchor constraintEqualToConstant:52].active = YES;
        [button addTarget:self action:@selector(paperTapped:) forControlEvents:UIControlEventTouchUpInside];
        [swatches addArrangedSubview:button];
        [self.swatches addObject:button];
    }
    UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[ name, swatches ]];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 8;
    [self.stack addArrangedSubview:row];
}

- (void)reload {
    NFBCardStyle style = NFBCardStyleCurrent();
    self.lookControl.selectedSegmentIndex = style.look;
    NSDictionary* numbers = @{
        NFBCardRadiusKey : @(style.radius),
        NFBCardGapKey : @(style.gap),
        NFBCardInnerKey : @(style.inner),
        NFBCardBodyKey : @(round(style.bodyStep * 10)),
        NFBCardNameKey : @(round(style.nameScale * 100)),
        NFBCardAvatarKey : @(round(style.avatarScale * 100)),
        NFBCardNameGapKey : @(round(style.nameGap)),
    };
    for (NSString* key in numbers) {
        self.sliders[key].value = [numbers[key] floatValue];
        [self showValueFor:key];
    }
    UIColor* xPaper = [UIColor systemBackgroundColor];
    for (UIButton* button in self.swatches) {
        NFBCardStyle sample = style;
        sample.paper = button.tag;
        button.backgroundColor = NFBCardPaperColor(sample, xPaper, CurrentAccentColor());
        BOOL chosen = button.tag == style.paper;
        button.layer.borderWidth = chosen ? 2.5 : 1.0 / UIScreen.mainScreen.scale;
        button.layer.borderColor = chosen ? self.view.tintColor.CGColor : [UIColor separatorColor].CGColor;
    }
    self.preview.style = style;
}

- (void)showValueFor:(NSString*)key {
    UILabel* label = self.values[key];
    NSArray* parts = [label.accessibilityHint componentsSeparatedByString:@"|"];
    float divisor = [parts.lastObject floatValue];
    float value = self.sliders[key].value;
    if (divisor > 1) {
        label.text = [NSString stringWithFormat:@"%+.1f%@", value / divisor, parts.firstObject];
    } else {
        label.text = [NSString stringWithFormat:@"%.0f%@", value, parts.firstObject];
    }
}

- (void)sliderChanged:(UISlider*)slider {
    NSString* key = slider.accessibilityIdentifier;
    // Whole steps: points, percents, or half points for the text.
    float step = [key isEqualToString:NFBCardBodyKey] ? 5 : 1;
    float value = roundf(slider.value / step) * step;
    slider.value = value;
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults integerForKey:key] != (NSInteger)value || ![defaults objectForKey:key]) {
        [defaults setInteger:(NSInteger)value forKey:key];
        [self showValueFor:key];
        self.preview.style = NFBCardStyleCurrent();
    }
}

- (void)lookChanged:(UISegmentedControl*)control {
    [[NSUserDefaults standardUserDefaults] setInteger:control.selectedSegmentIndex forKey:NFBCardLookKey];
    [self reload];
}

- (void)paperTapped:(UIButton*)button {
    if (button.tag == NFBCardPaperCustom) {
        UIColorPickerViewController* picker = [UIColorPickerViewController new];
        picker.supportsAlpha = NO;
        NSArray* rgb = [[NSUserDefaults standardUserDefaults] arrayForKey:NFBCardPaperRGBKey];
        if (rgb.count >= 3) {
            picker.selectedColor = [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue]
                                                    blue:[rgb[2] doubleValue] alpha:1];
        }
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }
    [[NSUserDefaults standardUserDefaults] setInteger:button.tag forKey:NFBCardPaperKey];
    [self reload];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController*)picker {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [picker.selectedColor getRed:&r green:&g blue:&b alpha:&a];
    [[NSUserDefaults standardUserDefaults] setObject:@[ @(r), @(g), @(b) ] forKey:NFBCardPaperRGBKey];
    [[NSUserDefaults standardUserDefaults] setInteger:NFBCardPaperCustom forKey:NFBCardPaperKey];
    [self reload];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController*)picker {
    [self reload];
}

- (void)resetTapped {
    NFBCardStyleReset();
    [self reload];
}

@end
