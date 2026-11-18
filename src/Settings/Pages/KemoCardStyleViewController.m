//
//  KemoCardStyleViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoCardStyleViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"
#import "Core/NFBCardStyle.h"

extern UIColor* CurrentAccentColor(void);

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

// MARK: - Preview
// A piece of the timeline, laid out the way the timeline lays its rows out
// now (X's own row layout inside the card margin, nothing drawn smaller): the
// tweets that were on screen in the home timeline when the page opened, with
// their own names, text, pictures and threads. Until 7.3.96 this was three
// made-up rows drawn smaller into their cards, which is not how the timeline
// looks. Where the timeline has nothing to show (cards off, or the app was
// opened straight into settings), a made-up tweet and thread stand in.

// Readability.x: the tweets on screen in the home timeline. Each is a
// dictionary: name, handle, time, body, context (strings), avatar, media
// (UIImage), connector (X's thread connector: 1 = up, 2 = down).
extern NSArray<NSDictionary*>* NFBTimelineSamples(void);

static const CGFloat kPreviewSide = 8;    // page colour beside a card (kCardSide in Readability.x)
static const CGFloat kPreviewPad = 9;     // X's own margin inside a row
static const CGFloat kPreviewAvatar = 38; // X's avatar
static const CGFloat kPreviewColumnGap = 8;
static NSString* const kPreviewThumbKey = @"kemo_thumb_side"; // the small photo's side (CompactMedia.x)

static CGFloat PreviewThumb(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kPreviewThumbKey];
    CGFloat side = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 56;
    return MAX(40, MIN(92, side));
}

@interface NFBPreviewRow : UIView
@property (nonatomic, copy) NSDictionary* sample;
@property (nonatomic, assign) NFBCardStyle style;
@property (nonatomic, assign) BOOL up;      // joined to the row above: a reply in a thread card
@property (nonatomic, assign) BOOL down;    // joined to the row below
@property (nonatomic, assign) BOOL nestUp;  // the row above is a reply too
@property (nonatomic, assign) BOOL compact; // small media
@property (nonatomic, assign) BOOL corner;  // one small photo sits beside the text
@property (nonatomic, assign) BOOL dim;     // faded action row
- (CGFloat)layoutForWidth:(CGFloat)width;
@end

@implementation NFBPreviewRow {
    NFBCardView* _card;
    NFBCardView* _nest;
    CAShapeLayer* _line;
    UIImageView* _contextIcon;
    UILabel* _contextLabel;
    UIImageView* _avatar;
    UILabel* _avatarLetter;
    UILabel* _name;
    UILabel* _handle;
    UILabel* _time;
    UIImageView* _more;
    UILabel* _body;
    UIImageView* _media;
    NSArray<UIImageView*>* _actionIcons;
    NSArray<UILabel*>* _actionCounts;
}

- (UIImageView*)symbol:(NSString*)name size:(CGFloat)size {
    UIImageSymbolConfiguration* config = [UIImageSymbolConfiguration configurationWithPointSize:size
                                                                                         weight:UIImageSymbolWeightRegular];
    UIImageView* view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name withConfiguration:config]];
    view.contentMode = UIViewContentModeCenter;
    view.tintColor = [UIColor secondaryLabelColor];
    return view;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _card = [NFBCardView new];
        _nest = [NFBCardView new];
        _nest.plain = YES;
        [self addSubview:_card];
        [self addSubview:_nest];
        _line = [CAShapeLayer layer];
        _line.fillColor = nil;
        _line.lineWidth = 2;
        _line.lineCap = kCALineCapRound;
        _line.actions = @{@"path" : [NSNull null], @"strokeColor" : [NSNull null]};
        [self.layer addSublayer:_line];

        _contextIcon = [self symbol:@"arrow.2.squarepath" size:11];
        _contextLabel = [UILabel new];
        _contextLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _contextLabel.textColor = [UIColor secondaryLabelColor];
        _avatar = [UIImageView new];
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        _avatar.clipsToBounds = YES;
        _avatarLetter = [UILabel new];
        _avatarLetter.textAlignment = NSTextAlignmentCenter;
        _avatarLetter.textColor = [UIColor whiteColor];
        [_avatar addSubview:_avatarLetter];
        _name = [UILabel new];
        _name.textColor = [UIColor labelColor];
        _handle = [UILabel new];
        _handle.textColor = [UIColor secondaryLabelColor];
        _handle.lineBreakMode = NSLineBreakByTruncatingTail;
        _time = [UILabel new];
        _time.textColor = [UIColor secondaryLabelColor];
        _more = [self symbol:@"ellipsis" size:13];
        _body = [UILabel new];
        _body.numberOfLines = 0;
        _body.textColor = [UIColor labelColor];
        _media = [UIImageView new];
        _media.contentMode = UIViewContentModeScaleAspectFill;
        _media.clipsToBounds = YES;
        _media.layer.cornerCurve = kCACornerCurveContinuous;
        for (UIView* view in @[ _contextIcon, _contextLabel, _avatar, _name, _handle, _time, _more, _body, _media ]) {
            [self addSubview:view];
        }
        NSMutableArray<UIImageView*>* icons = [NSMutableArray array];
        NSMutableArray<UILabel*>* counts = [NSMutableArray array];
        NSArray<NSString*>* names = @[ @"bubble.left", @"arrow.2.squarepath", @"heart", @"chart.bar" ];
        NSArray<NSString*>* numbers = @[ @"3", @"12", @"48", @"1,204" ];
        for (NSUInteger i = 0; i < names.count; i++) {
            UIImageView* icon = [self symbol:names[i] size:13];
            UILabel* count = [UILabel new];
            count.text = numbers[i];
            count.font = [UIFont systemFontOfSize:12];
            count.textColor = [UIColor secondaryLabelColor];
            [self addSubview:icon];
            [self addSubview:count];
            [icons addObject:icon];
            [counts addObject:count];
        }
        _actionIcons = icons;
        _actionCounts = counts;
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection*)previous {
    [super traitCollectionDidChange:previous];
    [self.superview.superview setNeedsLayout];
}

- (CGFloat)layoutForWidth:(CGFloat)width {
    NFBCardStyle style = self.style;
    NSDictionary* sample = self.sample;
    CGFloat margin = kPreviewSide + style.inner;
    CGFloat drawnAvatar = kPreviewAvatar * style.avatarScale;
    // The thread line runs under a first tweet's reply icon; a reply sits
    // further in, with its avatar on that line.
    CGFloat lineX = margin + kPreviewPad + kPreviewAvatar + kPreviewColumnGap + 10;
    CGFloat indent = self.up ? lineX - (margin + kPreviewPad + kPreviewAvatar - drawnAvatar / 2) : 0;
    CGFloat left = margin + indent, right = width - margin;
    CGFloat avatarRight = left + kPreviewPad + kPreviewAvatar;
    CGFloat columnX = avatarRight + kPreviewColumnGap, columnRight = right - kPreviewPad;
    // One small photo sits at the top right; the tweet's column ends before it.
    UIImage* picture = [sample[@"media"] isKindOfClass:[UIImage class]] ? sample[@"media"] : nil;
    CGFloat thumb = PreviewThumb();
    BOOL beside = picture && self.compact && self.corner;
    if (beside) {
        columnRight -= thumb + 8;
    }
    CGFloat columnWidth = MAX(40, columnRight - columnX);
    // Half the gap and the inner room above the content, unless the row is
    // joined to the one above (and the same below), as in the timeline.
    CGFloat roomAtEnd = style.gap / 2 + style.inner;
    CGFloat y = 12 + (self.up ? 0 : roomAtEnd);

    // "... reposted" above the tweet.
    NSString* context = [sample[@"context"] isKindOfClass:[NSString class]] ? sample[@"context"] : nil;
    BOOL hasContext = context.length > 0;
    _contextIcon.hidden = !hasContext;
    _contextLabel.hidden = !hasContext;
    if (hasContext) {
        _contextLabel.text = context;
        _contextIcon.frame = CGRectMake(columnX - 20, y, 14, 14);
        _contextLabel.frame = CGRectMake(columnX, y - 1, columnWidth, 16);
        y += 19;
    }

    // The avatar grows from its top right corner, as in the timeline.
    _avatar.frame = CGRectMake(avatarRight - drawnAvatar, y, drawnAvatar, drawnAvatar);
    _avatar.layer.cornerRadius = drawnAvatar / 2;
    UIImage* face = [sample[@"avatar"] isKindOfClass:[UIImage class]] ? sample[@"avatar"] : nil;
    NSString* nameText = [sample[@"name"] isKindOfClass:[NSString class]] ? sample[@"name"] : @"";
    _avatar.image = face;
    _avatarLetter.hidden = face != nil;
    if (!face) {
        NSUInteger hue = nameText.hash % 12;
        _avatar.backgroundColor = [UIColor colorWithHue:hue / 12.0 saturation:0.35 brightness:0.72 alpha:1];
        _avatarLetter.text = nameText.length > 0
                                 ? [nameText substringWithRange:[nameText rangeOfComposedCharacterSequenceAtIndex:0]]
                                 : @"";
        _avatarLetter.font = [UIFont systemFontOfSize:drawnAvatar * 0.42 weight:UIFontWeightSemibold];
        _avatarLetter.frame = CGRectMake(0, 0, drawnAvatar, drawnAvatar);
    }

    // The name line: name and handle larger by the chosen size, the time a
    // little smaller at the right end just left of "...", all on one
    // baseline, moved up by the chosen gap. A reply leaves its time out.
    const CGFloat lineBox = 16;
    _name.font = [UIFont systemFontOfSize:14 * style.nameScale weight:UIFontWeightSemibold];
    _handle.font = [UIFont systemFontOfSize:14 * style.nameScale];
    _time.font = [UIFont systemFontOfSize:14 * 0.9];
    _name.text = nameText;
    _handle.text = [sample[@"handle"] isKindOfClass:[NSString class]] ? sample[@"handle"] : @"";
    _time.text = [sample[@"time"] isKindOfClass:[NSString class]] ? sample[@"time"] : @"";
    _more.frame = CGRectMake(columnRight - 18, y - 1, 18, 18);
    CGFloat pixel = 1.0 / MAX(1.0, UIScreen.mainScreen.scale);
    CGFloat nameHeight = ceil(_name.font.lineHeight);
    CGFloat nameTop = y + round((lineBox - nameHeight) / 2) - style.nameGap;
    CGFloat baseline = nameTop + (nameHeight - _name.font.lineHeight) / 2 + _name.font.ascender;
    CGFloat (^topOf)(UILabel*) = ^CGFloat(UILabel* label) {
        CGFloat labelHeight = ceil(label.font.lineHeight);
        CGFloat labelTop = baseline - label.font.ascender - (labelHeight - label.font.lineHeight) / 2;
        return round(labelTop / pixel) * pixel;
    };
    CGFloat (^fit)(UILabel*) = ^CGFloat(UILabel* label) {
        return ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, lineBox)].width);
    };
    CGFloat limit = CGRectGetMinX(_more.frame);
    CGFloat end = limit - 6;
    _time.hidden = self.up || _time.text.length == 0;
    if (!_time.hidden) {
        CGFloat timeWidth = fit(_time);
        _time.frame = CGRectMake(limit - 6 - timeWidth, topOf(_time), timeWidth, ceil(_time.font.lineHeight));
        end = CGRectGetMinX(_time.frame) - 8;
    }
    CGFloat nameWidth = fit(_name), handleWidth = _handle.text.length > 0 ? fit(_handle) : 0;
    CGFloat room = end - columnX - 4 - handleWidth;
    if (room < nameWidth && handleWidth > 44) {
        handleWidth = MAX(44, handleWidth - (nameWidth - room));
        room = end - columnX - 4 - handleWidth;
    }
    if (room < MIN(nameWidth, 36)) {
        handleWidth = MAX(0, handleWidth - (MIN(nameWidth, 36) - room));
        room = end - columnX - 4 - handleWidth;
    }
    CGFloat shownName = MAX(0, MIN(nameWidth, room));
    _name.lineBreakMode = shownName < nameWidth - 0.5 ? NSLineBreakByClipping : NSLineBreakByTruncatingTail;
    _name.frame = CGRectMake(columnX, nameTop, shownName, nameHeight);
    _handle.frame = CGRectMake(CGRectGetMaxX(_name.frame) + 4, topOf(_handle), handleWidth, ceil(_handle.font.lineHeight));
    _handle.hidden = handleWidth < 8;
    y += lineBox + 3;

    // The tweet's text.
    _body.font = [UIFont systemFontOfSize:15 + style.bodyStep];
    NSString* bodyText = [sample[@"body"] isKindOfClass:[NSString class]] ? sample[@"body"] : @"";
    _body.text = bodyText;
    _body.hidden = bodyText.length == 0;
    if (!_body.hidden) {
        CGFloat bodyHeight = ceil([_body sizeThatFits:CGSizeMake(columnWidth, CGFLOAT_MAX)].height);
        _body.frame = CGRectMake(columnX, y, columnWidth, bodyHeight);
        y += bodyHeight;
    }

    // Its picture: a small square at the right end of the text column with
    // small media on, else as wide as the column.
    _media.hidden = picture == nil;
    if (beside) {
        _media.image = picture;
        _media.frame = CGRectMake(columnRight + 8, nameTop, thumb, thumb);
        _media.layer.cornerRadius = 12;
    } else if (picture) {
        y += 8;
        _media.image = picture;
        if (self.compact) {
            CGFloat side = MIN(thumb, columnWidth);
            _media.frame = CGRectMake(columnRight - side, y, side, side);
            _media.layer.cornerRadius = 12;
            y += side;
        } else {
            CGFloat ratio = picture.size.width > 0 ? picture.size.height / picture.size.width : 0.5625;
            CGFloat mediaHeight = round(columnWidth * MAX(0.4, MIN(1.25, ratio)));
            _media.frame = CGRectMake(columnX, y, columnWidth, mediaHeight);
            _media.layer.cornerRadius = 14;
            y += mediaHeight;
        }
    }

    // Reply, repost, like, views.
    y += 10;
    CGFloat step = columnWidth / _actionIcons.count;
    for (NSUInteger i = 0; i < _actionIcons.count; i++) {
        UIImageView* icon = _actionIcons[i];
        UILabel* count = _actionCounts[i];
        icon.frame = CGRectMake(columnX + step * i, y, 20, 18);
        CGFloat countWidth = ceil([count sizeThatFits:CGSizeMake(CGFLOAT_MAX, 18)].width);
        count.frame = CGRectMake(CGRectGetMaxX(icon.frame) + 3, y, MIN(countWidth, step - 26), 18);
        icon.alpha = self.dim ? 0.45 : 1;
        count.alpha = self.dim ? 0.45 : 1;
    }
    CGRect replyIcon = _actionIcons.firstObject.frame;
    y += 18 + 10;
    CGFloat height = MAX(y, CGRectGetMaxY(_avatar.frame) + 10);
    if (beside) {
        height = MAX(height, CGRectGetMaxY(_media.frame) + 10);
    }
    height += self.down ? 0 : roomAtEnd;

    // The card (Readability.x's NFBCardBackground): as wide as the row, with
    // half the gap above and below unless joined to the next row.
    CGFloat half = style.gap / 2;
    CGFloat cardTop = self.up ? 0 : half;
    CGFloat cardBottom = self.down ? height : height - half;
    UIColor* paper = NFBCardPaperColor(style, [UIColor systemBackgroundColor], CurrentAccentColor());
    UIColor* page = NFBCardPageColor(paper);
    _card.style = style;
    _card.backgroundColor = paper;
    _card.openTop = self.up;
    _card.openBottom = self.down;
    _card.frame = CGRectMake(kPreviewSide, cardTop, width - kPreviewSide * 2, MAX(0, cardBottom - cardTop));
    _nest.hidden = !self.up;
    if (self.up) {
        CGFloat nestLeft = lineX - drawnAvatar / 2 - 8;
        CGFloat nestRight = width - kPreviewSide - 8;
        CGFloat nestTop = self.nestUp ? 0 : cardTop + 2;
        CGFloat nestBottom = self.down ? height : cardBottom - 8;
        _nest.style = style;
        _nest.backgroundColor = NFBCardBlend(paper, page, 0.55);
        _nest.radiusOverride = MAX(4, MIN(14, style.radius * 0.75));
        _nest.openTop = self.nestUp;
        _nest.openBottom = self.down;
        _nest.frame = CGRectMake(nestLeft, nestTop, MAX(0, nestRight - nestLeft), MAX(0, nestBottom - nestTop));
    }

    // The reply line.
    UIBezierPath* path = [UIBezierPath bezierPath];
    if (self.up) {
        [path moveToPoint:CGPointMake(lineX, 0)];
        [path addLineToPoint:CGPointMake(lineX, MAX(0, CGRectGetMinY(_avatar.frame) - 3))];
        if (self.down) {
            [path moveToPoint:CGPointMake(lineX, CGRectGetMaxY(_avatar.frame) + 3)];
            [path addLineToPoint:CGPointMake(lineX, height)];
        }
    } else if (self.down) {
        [path moveToPoint:CGPointMake(lineX, CGRectGetMaxY(replyIcon) + 3)];
        [path addLineToPoint:CGPointMake(lineX, height)];
    }
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    _line.frame = CGRectMake(0, 0, width, height);
    _line.strokeColor = (dark ? [UIColor colorWithRed:0.20 green:0.21 blue:0.22 alpha:1]
                              : [UIColor colorWithRed:0.81 green:0.85 blue:0.87 alpha:1]).CGColor;
    _line.path = (self.up || self.down) ? path.CGPath : nil;
    return height;
}

@end

@interface NFBCardPreview : UIView
@property (nonatomic, assign) NFBCardStyle style;
@end

@implementation NFBCardPreview {
    UIScrollView* _scroll;
    NSMutableArray<NFBPreviewRow*>* _rows;
}

// Stand-ins for when the timeline has nothing on screen.
+ (NSArray<NSDictionary*>*)madeUpSamples {
    return @[
        @{
            @"name" : @"フェムト",
            @"handle" : @"@femt_1240",
            @"time" : @"8분",
            @"body" : L(@"KEMO_CARD_PREVIEW_BODY1"),
            @"connector" : @0
        },
        @{
            @"name" : @"きたしろ",
            @"handle" : @"@NW_1838",
            @"time" : @"19시",
            @"body" : L(@"KEMO_CARD_PREVIEW_BODY2"),
            @"connector" : @2
        },
        @{
            @"name" : @"ねこ",
            @"handle" : @"@neko",
            @"time" : @"18시",
            @"body" : L(@"KEMO_CARD_PREVIEW_BODY3"),
            @"connector" : @1
        },
    ];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        _scroll = [UIScrollView new];
        _scroll.alwaysBounceVertical = YES;
        _scroll.showsVerticalScrollIndicator = NO;
        [self addSubview:_scroll];
        _rows = [NSMutableArray array];

        NSMutableArray<NSDictionary*>* samples = [NSMutableArray array];
        BOOL hasThread = NO;
        for (NSDictionary* sample in NFBTimelineSamples()) {
            if (![sample isKindOfClass:[NSDictionary class]] || samples.count >= 6) {
                continue;
            }
            [samples addObject:sample];
        }
        // A thread only counts when both ends of it were on screen.
        for (NSUInteger i = 0; i + 1 < samples.count; i++) {
            if (([samples[i][@"connector"] unsignedIntegerValue] & 2) &&
                ([samples[i + 1][@"connector"] unsignedIntegerValue] & 1)) {
                hasThread = YES;
            }
        }
        NSArray<NSDictionary*>* madeUp = [NFBCardPreview madeUpSamples];
        if (samples.count == 0) {
            [samples addObjectsFromArray:madeUp];
        } else if (!hasThread) {
            // Always show what a thread looks like.
            [samples addObject:madeUp[1]];
            [samples addObject:madeUp[2]];
        }
        for (NSUInteger i = 0; i < samples.count; i++) {
            NFBPreviewRow* row = [NFBPreviewRow new];
            row.sample = samples[i];
            NSUInteger connector = [samples[i][@"connector"] unsignedIntegerValue];
            NSUInteger before = i > 0 ? [samples[i - 1][@"connector"] unsignedIntegerValue] : 0;
            NSUInteger after = i + 1 < samples.count ? [samples[i + 1][@"connector"] unsignedIntegerValue] : 0;
            // Joined only when the neighbour agrees, as in the timeline.
            row.up = (connector & 1) && (before & 2);
            row.down = (connector & 2) && (after & 1);
            row.nestUp = row.up && (before & 1) && i > 1 && ([samples[i - 2][@"connector"] unsignedIntegerValue] & 2);
            [_scroll addSubview:row];
            [_rows addObject:row];
        }
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

- (void)layoutSubviews {
    [super layoutSubviews];
    NFBCardStyle style = self.style;
    UIColor* paper = NFBCardPaperColor(style, [UIColor systemBackgroundColor], CurrentAccentColor());
    self.backgroundColor = NFBCardPageColor(paper);
    _scroll.frame = self.bounds;
    CGFloat width = CGRectGetWidth(self.bounds);
    BOOL compact = [BHTSettings boolForKey:@"kemo_compact_media"] &&
                   ![BHTSettings boolForKey:@"disable_sensitive_tweet_warnings"];
    BOOL dim = [BHTSettings boolForKey:@"kemo_dim_actions"];
    CGFloat y = 6;
    for (NFBPreviewRow* row in _rows) {
        row.style = style;
        row.compact = compact;
        row.corner = [BHTSettings boolForKey:@"kemo_corner_media"];
        row.dim = dim;
        CGFloat height = [row layoutForWidth:width];
        row.frame = CGRectMake(0, y, width, height);
        y += height;
    }
    _scroll.contentSize = CGSizeMake(width, y + 6);
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
    [self addSlider:kPreviewThumbKey title:L(@"KEMO_THUMB_SIDE") min:40 max:92 unit:@"pt" divisor:1];
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
        kPreviewThumbKey : @(PreviewThumb()),
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
        [self.preview setNeedsLayout];
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
