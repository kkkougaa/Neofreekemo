//
//  Readability.x
//  NeoFreeBird
//

#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "HookHelpers.h"
#import "Core/NFBCardStyle.h"

// MARK: - Easier reading in the home timeline and notifications
// Switches:
//
//  - kemo_timeline_cards: every home timeline row sits on a rounded card with a
//    gap of page colour around it, so tweets read as separate pieces.
//  - kemo_notification_cards: the same for the notifications list. Replies
//    and mentions there can be pulled from right to left to answer them.
//  - kemo_dim_actions: the reply / repost / like / views row is faded, so the
//    numbers no longer pull the eye away from the text.
//
// How the cards look (outlined or floating, corner radius, gap, inner room,
// card colour) and the sizes of tweet text, the name line and the avatar are
// chosen on the "Cards and text" settings page (Core/NFBCardStyle). Changes
// show at once on the rows on screen, except the tweet text size, which X
// measures when it lays a row out.
//
// 7.3.90: a thread in the home timeline is drawn as one card: the first tweet
// on top, and the replies under it (with "show more replies") nested in an
// inner box. (The pill behind the refresh spinner of 7.3.90-7.3.96 is gone.)
//
// 7.3.93: X's white backing view behind each tweet is cleared while a row has
// a card (it showed as square corners over the round card); threads follow
// X's connector (1 up, 2 down); the reply line bends into each reply's avatar;
// floating cards meet without a seam.
//
// The cards never change X's layout (moving views after X has laid them out
// made 7.3.76's small media jump back and forth). The row's content is only
// drawn smaller inside its card (the content view's sublayer transform), and
// the card itself is the cell's background view.
//
// The swipe only exists in the notifications list. On the home timeline a
// sideways drag stays X's (it changes tabs).

static NSString* const kCardsKey = @"kemo_timeline_cards";
static NSString* const kNoteCardsKey = @"kemo_notification_cards";
static NSString* const kDimKey = @"kemo_dim_actions";

static const CGFloat kCardSide = 8.0;    // page colour left and right of a card
static const CGFloat kPileStep = 3.5;    // how far each card edge under a pile peeks out
static const CGFloat kNestIndent = 46.0; // where a thread's inner box starts, from the card's left edge
static const CGFloat kDimAlpha = 0.6; // 0.45 until 7.3.98: the counts were hard to read
static const CGFloat kReplyPull = 80.0;  // pull this far to answer

// Switches and the card style, read once and refreshed when settings change
// (the cell hook runs a lot). gStamp changes whenever the style does, so cells
// know to redo their colours.
static BOOL gCardsOn, gNoteCardsOn, gDimOn, gCompactOn, gPressOn;
static NFBCardStyle gStyle;
static NSInteger gStamp = 0;

static void RefreshOnScreen(void);

// CompactMedia.x: one small photo beside the text (see there).
extern CGFloat NFBCornerThumbFor(id viewModel);
extern CGFloat NFBCornerGap(void);
extern void NFBCornerAdjustLayout(id layout, CGFloat thumb);
extern void NFBPlaceCornerMedia(UIView* status);
static BOOL gSwitchesRead = NO;
static NSString* const kReplyIndentKey = @"kemo_thread_indent_measured";

// Set on an avatar while it carries our own scale (see ScaleFrom).
static const void* kScaledKey = &kScaledKey;

static BOOL SameStyle(NFBCardStyle a, NFBCardStyle b) {
    return a.look == b.look && a.radius == b.radius && a.gap == b.gap && a.inner == b.inner &&
           a.bodyStep == b.bodyStep && a.nameScale == b.nameScale && a.avatarScale == b.avatarScale &&
           a.paper == b.paper && a.nameGap == b.nameGap && a.innerV == b.innerV && a.page == b.page;
}

static void ReadSwitches(void) {
    BOOL cards = [BHTSettings boolForKey:kCardsKey];
    BOOL notes = [BHTSettings boolForKey:kNoteCardsKey];
    BOOL dim = [BHTSettings boolForKey:kDimKey];
    gPressOn = [BHTSettings boolForKey:@"kemo_card_press"];
    gCompactOn = [BHTSettings boolForKey:@"kemo_compact_media"] &&
                 ![BHTSettings boolForKey:@"disable_sensitive_tweet_warnings"];
    NFBCardStyle style = NFBCardStyleCurrent();
    static NSArray* lastRGB;
    NSArray* rgb = [[NSUserDefaults standardUserDefaults] arrayForKey:NFBCardPaperRGBKey];
    BOOL changed = cards != gCardsOn || notes != gNoteCardsOn || dim != gDimOn || !SameStyle(style, gStyle) ||
                   !((rgb == nil && lastRGB == nil) || [rgb isEqual:lastRGB]);
    // The small photo's size and place change each row's height too.
    static NSInteger lastMedia = -1;
    NSInteger media = [[NSUserDefaults standardUserDefaults] integerForKey:@"kemo_thumb_side"] * 2 +
                      ([BHTSettings boolForKey:@"kemo_corner_media"] ? 1 : 0);
    if (media != lastMedia) {
        changed = changed || lastMedia >= 0;
        lastMedia = media;
    }
    gCardsOn = cards;
    gNoteCardsOn = notes;
    gDimOn = dim;
    gStyle = style;
    lastRGB = rgb;
    gSwitchesRead = YES;
    if (changed) {
        gStamp++;
        dispatch_async(dispatch_get_main_queue(), ^{
            RefreshOnScreen();
        });
    }
}

// For the shake dump.
static NSInteger gHomeCards = 0, gNoteCards = 0, gPiles = 0, gThreadRows = 0, gFontCalls = 0, gSwipeBegins = 0;
static NSString* gSwipeLog = @"(no swipe yet)";
static NSInteger gAvatarShrinksKept = 0;
// 7.3.97: what X answered when asked to lay rows out inside the card margin,
// how the name line's labels were told apart, and what a pull looked like.
static NSString* gMetricsLog = @"(not asked yet)";
static NSInteger gMetricsCalls = 0, gMetricsMisses = 0, gIndentedRows = 0, gScaledRows = 0, gFitRows = 0;
static NSInteger gRoomRows = 0, gRoomInsets = 0;
static BOOL gIndentHooked = NO, gCellHooked = NO;
static NSString* gNameLineLog = @"(no name line yet)";
static NSString* gPullLog = @"(no pull yet)";
static CGFloat gReplyIndent = -1; // how far a reply is moved in a thread card, measured on a first tweet

NSString* NFBReadabilityDebugText(void) {
    return [NSString stringWithFormat:@"cards=%d noteCards=%d dim=%d look=%ld r=%.0f gap=%.0f inner=%.0f body=%+.1f "
                                      @"name=%.2f avatar=%.2f paper=%ld homeCards=%ld noteCards=%ld piles=%ld "
                                      @"threadRows=%ld contentFontCalls=%ld swipes=%ld avatarShrinksKept=%ld last=%@\n"
                                      @"metrics: calls=%ld misses=%ld fitRows=%ld scaledRows=%ld indentedRows=%ld roomRows=%ld roomInsets=%ld indent=%.1f "
                                      @"indentHook=%d cellHook=%d %@\nnameLine: %@\npull: %@",
                                      gCardsOn, gNoteCardsOn, gDimOn, (long)gStyle.look, gStyle.radius, gStyle.gap,
                                      gStyle.inner, gStyle.bodyStep, gStyle.nameScale, gStyle.avatarScale,
                                      (long)gStyle.paper, (long)gHomeCards, (long)gNoteCards, (long)gPiles,
                                      (long)gThreadRows, (long)gFontCalls, (long)gSwipeBegins, (long)gAvatarShrinksKept, gSwipeLog,
                                      (long)gMetricsCalls, (long)gMetricsMisses, (long)gFitRows, (long)gScaledRows,
                                      (long)gIndentedRows, (long)gRoomRows, (long)gRoomInsets, gReplyIndent, gIndentHooked, gCellHooked, gMetricsLog,
                                      gNameLineLog, gPullLog];
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

static BOOL CardsOnFor(NFBListKind kind) {
    return (kind == NFBListHome && gCardsOn) || (kind == NFBListNotifications && gNoteCardsOn);
}

// MARK: Finding things in a row

static NSUInteger CountViews(UIView* view, NSString* className, NSUInteger limit, int depth) {
    if (depth > 12) {
        return 0;
    }
    NSUInteger count = [NSStringFromClass(view.class) isEqualToString:className] ? 1 : 0;
    for (UIView* sub in view.subviews) {
        if (count >= limit) {
            break;
        }
        count += CountViews(sub, className, limit - count, depth + 1);
    }
    return count;
}

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

static BOOL IsDivider(UIView* view) {
    NSString* name = NSStringFromClass(view.class);
    return [name containsString:@"Separator"] || [name containsString:@"Divider"];
}

// MARK: The card

@interface NFBCardBackground : UIView
@property (nonatomic, strong) NFBCardView* edge2;
@property (nonatomic, strong) NFBCardView* edge1;
@property (nonatomic, strong) NFBCardView* card;
@property (nonatomic, strong) NFBCardView* nest; // the inner box of a thread's replies
@property (nonatomic, assign) BOOL pile;
@property (nonatomic, assign) BOOL openTop;     // joined to the row above (one thread)
@property (nonatomic, assign) BOOL openBottom;  // joined to the row below
@property (nonatomic, assign) BOOL nested;      // a reply inside a thread: draw the inner box
@property (nonatomic, assign) BOOL nestOpenTop; // the inner box goes on from the row above
@property (nonatomic, assign) CGFloat nestLeft;  // > 0: where the inner box starts, in row coordinates
@property (nonatomic, strong) UIColor* paper;
@property (nonatomic, strong) UIColor* page;
@property (nonatomic, strong) CAShapeLayer* threadLayer; // the reply line of a thread
@end

@implementation NFBCardBackground

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;
        self.backgroundColor = [UIColor clearColor];
        _edge2 = [NFBCardView new];
        _edge1 = [NFBCardView new];
        _card = [NFBCardView new];
        _nest = [NFBCardView new];
        _nest.plain = YES;
        for (UIView* view in @[ _edge2, _edge1, _card, _nest ]) {
            [self addSubview:view];
        }
        _threadLayer = [CAShapeLayer layer];
        _threadLayer.fillColor = nil;
        _threadLayer.lineWidth = 2;
        _threadLayer.lineCap = kCALineCapRound;
        _threadLayer.lineJoin = kCALineJoinRound;
        _threadLayer.actions = @{@"path" : [NSNull null], @"strokeColor" : [NSNull null]};
        [self.layer addSublayer:_threadLayer];
    }
    return self;
}

// The page itself is the list's background (see SetTablePage), so this view is
// clear outside the card: a pile's edges can then peek into the gap below the
// row without the next row's background covering them.
- (void)setPaper:(UIColor*)paper page:(UIColor*)page {
    self.paper = paper;
    self.page = page;
    self.card.backgroundColor = paper;
    // The cards underneath are solid, a step closer to the page each, so no
    // edge shows through another.
    self.edge1.backgroundColor = NFBCardBlend(paper, page, 0.35);
    self.edge2.backgroundColor = NFBCardBlend(paper, page, 0.65);
    self.nest.backgroundColor = NFBCardBlend(paper, page, 0.55);
    for (NFBCardView* view in @[ self.card, self.edge1, self.edge2, self.nest ]) {
        view.style = gStyle;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    self.threadLayer.frame = bounds;
    [self.threadLayer removeFromSuperlayer];
    [self.layer addSublayer:self.threadLayer];
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    self.threadLayer.strokeColor = (dark ? [UIColor colorWithRed:0.20 green:0.21 blue:0.22 alpha:1]
                                         : [UIColor colorWithRed:0.81 green:0.85 blue:0.87 alpha:1]).CGColor;
    CGFloat half = gStyle.gap / 2;
    CGFloat top = self.openTop ? 0 : half;
    CGFloat bottom = self.openBottom ? CGRectGetHeight(bounds) : CGRectGetHeight(bounds) - half;
    // Every card has the same frame rule, piles included, so the room around
    // the content is the same on every card.
    CGRect card = CGRectMake(kCardSide, top, CGRectGetWidth(bounds) - kCardSide * 2, MAX(0, bottom - top));
    self.card.frame = card;
    self.card.openTop = self.openTop;
    self.card.openBottom = self.openBottom;
    BOOL pile = self.pile && !self.openBottom;
    self.edge1.hidden = !pile;
    self.edge2.hidden = !pile;
    if (pile) {
        // Two narrower cards peek out under the bottom edge, into the gap.
        self.edge1.frame = CGRectOffset(CGRectInset(card, 12, 0), 0, kPileStep);
        self.edge2.frame = CGRectOffset(CGRectInset(card, 24, 0), 0, kPileStep * 2);
    }
    self.nest.hidden = !self.nested;
    if (self.nested) {
        CGFloat left = self.nestLeft > 0 ? self.nestLeft : CGRectGetMinX(card) + kNestIndent;
        CGFloat right = CGRectGetMaxX(card) - 8;
        CGFloat nestTop = self.nestOpenTop ? 0 : top + 2;
        CGFloat nestBottom = self.openBottom ? CGRectGetHeight(bounds) : bottom - 8;
        self.nest.frame = CGRectMake(left, nestTop, MAX(0, right - left), MAX(0, nestBottom - nestTop));
        self.nest.radiusOverride = MAX(4, MIN(14, gStyle.radius * 0.75));
        self.nest.openTop = self.nestOpenTop;
        self.nest.openBottom = self.openBottom;
    }
}

@end

// What a cell looked like before it got a card, to put back when switched off.
@interface NFBCardMemory : NSObject
@property (nonatomic, strong) NFBCardBackground* background;
@property (nonatomic, strong) UIView* oldBackgroundView;
@property (nonatomic, strong) UIColor* oldCellColor;
@property (nonatomic, strong) UIColor* oldContentColor;
@property (nonatomic, strong) UIColor* xPaper; // X's own colour for the row
@property (nonatomic, assign) NSInteger xPaperStyle; // light or dark when that colour was taken
@property (nonatomic, assign) CATransform3D baseTransform; // the content's transform without a swipe
@property (nonatomic, assign) CGFloat swipeOffset;         // how far the row is pulled sideways
@property (nonatomic, assign) NSInteger stamp;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) NSInteger thread; // last thread flags, to notice changes
@property (nonatomic, strong) NSHashTable<UIView*>* hiddenLines;
@property (nonatomic, strong) NSHashTable<UIView*>* keptLines; // told to stay hidden (see KeepsHidden)
@property (nonatomic, strong) NSMapTable<UIView*, UIColor*>* clearedBacking;
@property (nonatomic, strong) NFBCardBackground* highlight; // the card-shaped tap highlight
@property (nonatomic, strong) UIView* oldSelectedBackgroundView;
@end

@implementation NFBCardMemory
@end

static const void* kCardMemoryKey = &kCardMemoryKey;

// The list's own colour from before it showed cards.
static const void* kOldTableColorKey = &kOldTableColorKey;
static const void* kTablePageStampKey = &kTablePageStampKey;
static const void* kTablePageColorKey = &kTablePageColorKey; // the page colour we gave the list

static UIColor* XPaperColor(UITableViewCell* cell, UITableView* table) {
    UIColor* tableColor = objc_getAssociatedObject(table, kOldTableColorKey) ?: table.backgroundColor;
    for (UIColor* color in @[ cell.backgroundColor ?: [UIColor clearColor],
                              cell.contentView.backgroundColor ?: [UIColor clearColor],
                              tableColor ?: [UIColor clearColor] ]) {
        CGFloat r = 0, g = 0, b = 0, alpha = 0;
        [[color resolvedColorWithTraitCollection:cell.traitCollection] getRed:&r green:&g blue:&b alpha:&alpha];
        if (alpha > 0.5) {
            return color;
        }
    }
    return [UIColor systemBackgroundColor];
}

// X's row colour is a plain colour, not one that follows light and dark, and
// it was remembered once per row: after the phone went dark the cards stayed
// white under white text (7.3.96). The remembered colour is now only trusted
// in the mode it was taken in; in the other mode, until X paints the row again
// (see the setBackgroundColor: hooks, which take the new colour), a colour on
// the wrong side of grey gives way to plain white or black.
static UIColor* GuardedPaper(UIColor* xPaper, NSInteger takenInStyle) {
    if (!xPaper) {
        return [UIColor systemBackgroundColor];
    }
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        UIColor* resolved = [xPaper resolvedColorWithTraitCollection:traits];
        if ((NSInteger)traits.userInterfaceStyle == takenInStyle) {
            return resolved;
        }
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [resolved getRed:&r green:&g blue:&b alpha:&a];
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        BOOL lightColor = 0.299 * r + 0.587 * g + 0.114 * b >= 0.5;
        if (a > 0.5 && lightColor != dark) {
            return resolved;
        }
        return dark ? [UIColor blackColor] : [UIColor whiteColor];
    }];
}

static BOOL SameColor(UIColor* a, UIColor* b, UITraitCollection* traits) {
    if (!a || !b) {
        return a == b;
    }
    CGFloat r1 = 0, g1 = 0, b1 = 0, a1 = 0, r2 = 0, g2 = 0, b2 = 0, a2 = 0;
    [[a resolvedColorWithTraitCollection:traits] getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [[b resolvedColorWithTraitCollection:traits] getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    return fabs(r1 - r2) + fabs(g1 - g2) + fabs(b1 - b2) + fabs(a1 - a2) < 0.02;
}

// X painted a row that has a card: that is its colour for the row now (a
// change of theme). Not while the row is pressed, when the colour is X's
// highlight.
static void NoteXPaper(UITableViewCell* cell, NFBCardMemory* memory, UIColor* color) {
    if (cell.isHighlighted || cell.isSelected) {
        return;
    }
    NSInteger style = cell.traitCollection.userInterfaceStyle;
    if (memory.xPaperStyle == style && SameColor(color, memory.xPaper, cell.traitCollection)) {
        return;
    }
    memory.xPaper = color;
    memory.xPaperStyle = style;
    memory.stamp = -1;
    [cell setNeedsLayout];
}

// The faint line X draws between rows. It can be UIKit's separator on the
// cell, a divider view deeper inside the row, or the list's own separators, so
// all three are looked for: views named like a divider, and hairline views
// spanning most of the row's width at its top or bottom edge.
static const void* kOldSeparatorStyleKey = &kOldSeparatorStyleKey;

static void FindDividers(UIView* view, UITableViewCell* cell, int depth, NSMutableArray<UIView*>* found) {
    if (depth > 5) {
        return;
    }
    CGFloat width = CGRectGetWidth(cell.bounds), height = CGRectGetHeight(cell.bounds);
    for (UIView* sub in view.subviews) {
        if ([sub isKindOfClass:[NFBCardBackground class]] || sub == cell.backgroundView) {
            continue;
        }
        if (IsDivider(sub)) {
            [found addObject:sub];
            continue;
        }
        CGRect frame = [sub convertRect:sub.bounds toView:cell];
        BOOL hairline = CGRectGetHeight(frame) <= 1.01 && CGRectGetWidth(frame) > width * 0.4 &&
                        (CGRectGetMinY(frame) < 3 || CGRectGetMaxY(frame) > height - 3) && sub.subviews.count == 0;
        if (hairline) {
            [found addObject:sub];
            continue;
        }
        FindDividers(sub, cell, depth + 1, found);
    }
}

static const void* kHiddenDividersKey = &kHiddenDividersKey;

static void HideLineLayers(CALayer* layer, UITableViewCell* cell, int depth) {
    if (depth > 7) {
        return;
    }
    CGFloat width = CGRectGetWidth(cell.bounds), height = CGRectGetHeight(cell.bounds);
    for (CALayer* sub in layer.sublayers) {
        id owner = sub.delegate;
        if ([owner isKindOfClass:[NFBCardBackground class]] || [owner isKindOfClass:[NFBCardView class]]) {
            continue; // our own card
        }
        if (![owner isKindOfClass:[UIView class]] && !sub.hidden) {
            CGRect frame = [layer convertRect:sub.frame toLayer:cell.layer];
            if (CGRectGetHeight(frame) <= 1.01 && CGRectGetWidth(frame) > width * 0.4 &&
                (CGRectGetMinY(frame) < 3 || CGRectGetMaxY(frame) > height - 3)) {
                sub.hidden = YES;
                continue;
            }
        }
        HideLineLayers(sub, cell, depth + 1);
    }
}

static void SetDividersHidden(UITableViewCell* cell, BOOL hidden) {
    NSHashTable<UIView*>* done = objc_getAssociatedObject(cell, kHiddenDividersKey);
    if (hidden) {
        if (!done) {
            done = [NSHashTable weakObjectsHashTable];
            objc_setAssociatedObject(cell, kHiddenDividersKey, done, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSMutableArray<UIView*>* found = [NSMutableArray array];
        FindDividers(cell, cell, 0, found);
        for (UIView* view in found) {
            if (!view.hidden) {
                view.hidden = YES;
                [done addObject:view];
            }
        }
        // Lines drawn as bare layers (no view of their own), anywhere in the row:
        // the notifications list draws its line between rows that way, at the
        // row's top (7.3.95 dump: a CALayer 440 x 0.33 at y 0).
        // Without the fade a layer gets when it is hidden outside a view's
        // own animation (it showed as a line fading out).
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        HideLineLayers(cell.layer, cell, 0);
        [CATransaction commit];
    } else {
        for (UIView* view in done.allObjects) {
            view.hidden = NO;
        }
        [done removeAllObjects];
    }
}

// Behind the cards the list shows the page colour, so pulling to refresh opens
// onto the same colour as the gaps between cards instead of a white block.
static void SetTablePage(UITableView* table, UIColor* page) {
    if (!table) {
        return;
    }
    UIColor* old = objc_getAssociatedObject(table, kOldTableColorKey);
    if (page) {
        // The first time, or X painted the list again since (a change of
        // theme): what the list shows now is X's own colour.
        UIColor* ours = objc_getAssociatedObject(table, kTablePageColorKey);
        if (!old || (ours && !SameColor(table.backgroundColor, ours, table.traitCollection))) {
            objc_setAssociatedObject(table, kOldTableColorKey, table.backgroundColor ?: [UIColor clearColor],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        table.backgroundColor = page;
        objc_setAssociatedObject(table, kTablePageColorKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(table, kTablePageStampKey, @(gStamp), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (old) {
        NSNumber* separators = objc_getAssociatedObject(table, kOldSeparatorStyleKey);
        if (separators) {
            table.separatorStyle = (UITableViewCellSeparatorStyle)separators.integerValue;
            objc_setAssociatedObject(table, kOldSeparatorStyleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        table.backgroundColor = old;
        objc_setAssociatedObject(table, kOldTableColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(table, kTablePageColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(table, kTablePageStampKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// X's thread line between avatars: a thin coloured bar near the left edge.
// Inside a thread card the replies move into the inner box, so the line would
// point at nothing; it is hidden there and put back otherwise.
static void FindThreadLines(UIView* view, UIView* row, int depth, NSMutableArray<UIView*>* found) {
    if (depth > 6) {
        return;
    }
    for (UIView* sub in view.subviews) {
        CGRect frame = [sub convertRect:sub.bounds toView:row];
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [[sub.backgroundColor resolvedColorWithTraitCollection:sub.traitCollection] getRed:&r green:&g blue:&b alpha:&a];
        // X's line is a TFNRoundedCornerView about 2pt wide (7.3.90 dump).
        BOOL rounded = [NSStringFromClass(sub.class) isEqualToString:@"TFNRoundedCornerView"] &&
                       CGRectGetWidth(frame) <= 3;
        // The dots of "show more replies" too: anything that thin near the left,
        // coloured or an image.
        BOOL thin = CGRectGetWidth(frame) <= 3 && CGRectGetHeight(frame) >= 2 && CGRectGetMinX(frame) < 110 &&
                    sub.subviews.count == 0 && !IsDivider(sub) &&
                    (a > 0.3 || [sub isKindOfClass:[UIImageView class]] || sub.layer.sublayers.count > 0);
        if (rounded || thin) {
            [found addObject:sub];
            continue;
        }
        FindThreadLines(sub, row, depth + 1, found);
    }
}

// X's own lines by name: T1StandardStatusConversationConnectorsView holds a
// tweet's top, bottom and tweetstorm connector, and "show more replies" has a
// ConversationConnectorView of its own (from X's class list).
static void FindConnectors(UIView* view, int depth, NSMutableArray<UIView*>* found) {
    if (depth > 8) {
        return;
    }
    for (UIView* sub in view.subviews) {
        NSString* name = NSStringFromClass(sub.class);
        if ([name containsString:@"Quoted"]) {
            continue;
        }
        if ([name containsString:@"ConversationConnector"]) {
            [found addObject:sub];
            continue;
        }
        FindConnectors(sub, depth + 1, found);
    }
}

// X shows its lines again after we hide them: the connectors lay themselves
// out after the tweet does, which is after the row's card is set up (the line
// from the first tweet's avatar was still there in 7.3.97 and 7.3.98). A line
// hidden here is marked, and the hooks on X's two line classes keep a marked
// line hidden for as long as it sits in a row of a thread card.
static const void* kKeepHiddenKey = &kKeepHiddenKey;

static void SetThreadLinesHidden(UITableViewCell* cell, NFBCardMemory* memory, BOOL hidden) {
    if (hidden) {
        NSMutableArray<UIView*>* lines = [NSMutableArray array];
        FindConnectors(cell.contentView, 0, lines);
        FindThreadLines(cell.contentView, cell.contentView, 0, lines);
        if (!memory.hiddenLines) {
            memory.hiddenLines = [NSHashTable weakObjectsHashTable];
            memory.keptLines = [NSHashTable weakObjectsHashTable];
        }
        for (UIView* line in lines) {
            if (!objc_getAssociatedObject(line, kKeepHiddenKey)) {
                objc_setAssociatedObject(line, kKeepHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [memory.keptLines addObject:line];
            }
            if (!line.hidden) {
                line.hidden = YES;
                [memory.hiddenLines addObject:line];
            }
        }
    } else if (memory.hiddenLines.count > 0 || memory.keptLines.count > 0) {
        for (UIView* line in memory.keptLines.allObjects) {
            objc_setAssociatedObject(line, kKeepHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [memory.keptLines removeAllObjects];
        for (UIView* line in memory.hiddenLines.allObjects) {
            line.hidden = NO;
        }
        [memory.hiddenLines removeAllObjects];
    }
}

// Is this line of X's marked, and still in a row of a thread card? (X hands
// its views from row to row; elsewhere the mark is dropped and X decides.)
static BOOL KeepsHidden(UIView* view) {
    if (!objc_getAssociatedObject(view, kKeepHiddenKey)) {
        return NO;
    }
    for (UIView* up = view.superview; up; up = up.superview) {
        if ([up isKindOfClass:[UITableViewCell class]]) {
            NFBCardMemory* memory = objc_getAssociatedObject(up, kCardMemoryKey);
            if (memory.active && memory.thread) {
                return YES;
            }
            break;
        }
    }
    objc_setAssociatedObject(view, kKeepHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return NO;
}

// X puts a plain white view behind each tweet, as big as the row. Drawn
// smaller inside the card it is a white rectangle with square corners over
// the rounded card (the "square and round corners together" of 7.3.86-90).
// While the row has a card, such views are clear.
static void FindBacking(UIView* view, UITableViewCell* cell, int depth, NSMutableArray<UIView*>* found) {
    if (depth > 3) {
        return;
    }
    CGFloat width = CGRectGetWidth(cell.bounds), height = CGRectGetHeight(cell.bounds);
    for (UIView* sub in view.subviews) {
        NSString* name = NSStringFromClass(sub.class);
        if ([name containsString:@"Quoted"] || [name containsString:@"Media"] || [name containsString:@"Image"] ||
            [name containsString:@"Card"] || [name containsString:@"Avatar"]) {
            continue;
        }
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [[sub.backgroundColor resolvedColorWithTraitCollection:sub.traitCollection] getRed:&r green:&g blue:&b alpha:&a];
        if (a > 0.9 && CGRectGetWidth(sub.bounds) >= width * 0.6 && CGRectGetHeight(sub.bounds) >= height * 0.4) {
            [found addObject:sub];
        }
        FindBacking(sub, cell, depth + 1, found);
    }
}

static void SetBackingCleared(UITableViewCell* cell, NFBCardMemory* memory, BOOL cleared) {
    if (cleared) {
        if (!memory.clearedBacking) {
            memory.clearedBacking = [NSMapTable weakToStrongObjectsMapTable];
        }
        NSMutableArray<UIView*>* found = [NSMutableArray array];
        FindBacking(cell.contentView, cell, 0, found);
        for (UIView* view in found) {
            if (![memory.clearedBacking objectForKey:view]) {
                [memory.clearedBacking setObject:view.backgroundColor forKey:view];
            }
            view.backgroundColor = [UIColor clearColor];
        }
    } else {
        for (UIView* view in memory.clearedBacking.keyEnumerator.allObjects) {
            view.backgroundColor = [memory.clearedBacking objectForKey:view];
        }
        [memory.clearedBacking removeAllObjects];
    }
}

static void RemoveCard(UITableViewCell* cell, NFBCardMemory* memory) {
    if (!memory.active) {
        return;
    }
    memory.active = NO;
    cell.backgroundView = memory.oldBackgroundView;
    cell.backgroundColor = memory.oldCellColor;
    cell.contentView.backgroundColor = memory.oldContentColor;
    cell.contentView.layer.sublayerTransform = CATransform3DIdentity;
    SetDividersHidden(cell, NO);
    SetThreadLinesHidden(cell, memory, NO);
    SetBackingCleared(cell, memory, NO);
    memory.background.threadLayer.path = nil;
    if (cell.selectedBackgroundView == memory.highlight) {
        cell.selectedBackgroundView = memory.oldSelectedBackgroundView;
    }
}

// MARK: Threads
// A row belongs to a thread when X draws its conversation line (the status
// view's conversationConnectorType is set), and X's "show more replies" row (a
// short row without a tweet) belongs to the thread above it. Rows next to each
// other that both belong to one are drawn as one card. Only rows on screen can
// be asked, so a row that finds its neighbour changed asks that neighbour to
// lay out again.

typedef NS_OPTIONS(NSInteger, NFBThreadFlags) {
    NFBThreadUp = 1 << 0,       // joined to the row above
    NFBThreadDown = 1 << 1,     // joined to the row below
    NFBThreadNestUp = 1 << 2,   // the row above is itself a reply (inner box goes on)
};

static NSUInteger ConnectorOf(UITableViewCell* cell) {
    UIView* status = FindView(cell.contentView, @"T1StandardStatusView", 0);
    SEL selector = NSSelectorFromString(@"conversationConnectorType");
    if (!status || ![status respondsToSelector:selector]) {
        return 0;
    }
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(status, selector);
}

static BOOL IsShowMoreRow(UITableViewCell* cell) {
    return CGRectGetHeight(cell.bounds) <= 64 && !FindView(cell.contentView, @"StatusView", 0);
}

static UITableViewCell* Neighbour(UITableView* table, UITableViewCell* cell, NSInteger step) {
    NSIndexPath* path = [table indexPathForCell:cell];
    if (!path) {
        return nil;
    }
    NSInteger row = path.row + step;
    if (row < 0 || row >= [table numberOfRowsInSection:path.section]) {
        return nil;
    }
    return [table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:path.section]];
}

// X's connector (from the 7.3.90 dump): 1 = the line goes up to the row
// above, 2 = down to the row below, 3 = both. "Show this thread" between two
// tweets of a thread is a T1ConversationModuleGapCell with no tweet.
static const NSUInteger kConnectorUp = 1, kConnectorDown = 2;

static BOOL IsGapRow(UITableViewCell* cell) {
    return [NSStringFromClass(cell.class) containsString:@"ConversationModuleGap"] || IsShowMoreRow(cell);
}

static BOOL RowJoinsUp(UITableView* table, UITableViewCell* cell) {
    if (!cell) {
        return NO;
    }
    if (IsGapRow(cell)) {
        UITableViewCell* above = Neighbour(table, cell, -1);
        // Off screen: a gap row only ever sits inside a thread.
        return above ? (ConnectorOf(above) & kConnectorDown) != 0
                     : [NSStringFromClass(cell.class) containsString:@"ConversationModuleGap"];
    }
    return (ConnectorOf(cell) & kConnectorUp) != 0;
}

static BOOL RowJoinsDown(UITableView* table, UITableViewCell* cell) {
    if (IsGapRow(cell)) {
        UITableViewCell* below = Neighbour(table, cell, 1);
        return below ? (ConnectorOf(below) & kConnectorUp) != 0
                     : [NSStringFromClass(cell.class) containsString:@"ConversationModuleGap"];
    }
    return (ConnectorOf(cell) & kConnectorDown) != 0;
}

static NFBThreadFlags ThreadFlags(UITableView* table, UITableViewCell* cell) {
    if (!table) {
        return 0;
    }
    NFBThreadFlags flags = 0;
    if (RowJoinsUp(table, cell)) {
        flags |= NFBThreadUp;
        if (RowJoinsUp(table, Neighbour(table, cell, -1))) {
            flags |= NFBThreadNestUp;
        }
    }
    if (RowJoinsDown(table, cell)) {
        flags |= NFBThreadDown;
    }
    return flags;
}

// MARK: Where things are, without our transforms

// A view's rectangle in its row, as X laid it out: the view's own transform
// (the avatar's scale) and the content view's sublayer transform are both
// left out.
static CGRect PlainRectInCell(UIView* view, UITableViewCell* cell) {
    if (!view) {
        return CGRectNull;
    }
    CGSize size = view.bounds.size;
    CGRect rect = CGRectMake(view.center.x - size.width / 2, view.center.y - size.height / 2, size.width, size.height);
    for (UIView* parent = view.superview; parent && parent != cell; parent = parent.superview) {
        rect.origin.x += parent.center.x - CGRectGetWidth(parent.bounds) / 2 - parent.bounds.origin.x;
        rect.origin.y += parent.center.y - CGRectGetHeight(parent.bounds) / 2 - parent.bounds.origin.y;
    }
    return rect;
}

// The avatar as it is drawn inside X's layout: X's rectangle with our own
// scale (it grows from its top right corner, see ScaleFrom), worked out from
// numbers instead of asked of the views. 7.3.96 asked the views, and a row is
// laid out before the tweet inside it is: the avatar had not been scaled yet
// (or still sat where the row's last tweet had it), so the line missed it.
static CGRect AvatarDrawnRect(UIView* avatar, UITableViewCell* cell) {
    CGRect rect = PlainRectInCell(avatar, cell);
    if (CGRectIsNull(rect)) {
        return rect;
    }
    CGFloat scale = gStyle.avatarScale;
    if (objc_getAssociatedObject(avatar, kScaledKey) && fabs(scale - 1) > 0.005) {
        CGFloat width = CGRectGetWidth(rect), height = CGRectGetHeight(rect);
        rect = CGRectMake(CGRectGetMaxX(rect) - width * scale, CGRectGetMinY(rect), width * scale, height * scale);
    }
    return rect;
}

// A rectangle of X's layout as the row's content transform shows it.
static CGRect ThroughContentTransform(CGRect rect, UITableViewCell* cell) {
    CATransform3D transform = cell.contentView.layer.sublayerTransform;
    if (CGRectIsNull(rect) || CATransform3DIsIdentity(transform)) {
        return rect;
    }
    CGRect content = cell.contentView.frame;
    CGFloat cx = CGRectGetMidX(content), cy = CGRectGetMidY(content);
    return CGRectMake(cx + transform.m41 + transform.m11 * (CGRectGetMinX(rect) - cx),
                      cy + transform.m42 + transform.m22 * (CGRectGetMinY(rect) - cy),
                      CGRectGetWidth(rect) * transform.m11, CGRectGetHeight(rect) * transform.m22);
}

// MARK: The reply line
// 7.3.94 (from the 7.3.93 screenshots): the line of a thread card starts under
// the first tweet's reply button and runs straight down; the replies sit with
// their avatars on that line, and it stops just above and goes on just below
// each of them. "Show more replies" rows carry it straight through.
// X's own lines (and the dotted one of "show more") are hidden there.

static CGFloat gThreadX = -1; // the line, in row coordinates
static __weak UITableView* gHomeTable; // the home timeline's list, for the settings preview
static NSHashTable<UITableView*>* gCardTables; // lists that show cards, to lay out again when the look changes
static CGFloat gNestAvatarX = -1; // a reply's avatar centre as X lays it out (content view coordinates)

static UIView* AvatarOf(UITableViewCell* cell) {
    return FindView(cell.contentView, @"StatusFleetLineItemView", 0) ?: FindView(cell.contentView, @"AvatarHeaderView", 0);
}

// Until a first tweet has been measured: X's margin (9), avatar (38), the gap
// to the text column (8) and half a reply icon, inside the card margin.
static CGFloat ThreadX(void) {
    return gThreadX > 0 ? gThreadX : kCardSide + gStyle.inner + 65;
}

// How far right of a tweet's avatar the line runs, measured on a first tweet
// that X laid out itself. Replies are laid out by X that much further in (see
// "Replies laid out further in"); rows laid out for another value are laid
// out again.
static void NoteReplyIndent(CGFloat indent, UITableView* table) {
    if (indent < 15 || indent > 90 || fabs(indent - gReplyIndent) < 0.5) {
        return;
    }
    gReplyIndent = indent;
    [[NSUserDefaults standardUserDefaults] setDouble:indent forKey:kReplyIndentKey];
    // Rows laid out for the old value are laid out again; a few times at
    // most, should two kinds of row ever disagree about the value.
    static CFAbsoluteTime lastReload = 0;
    static NSInteger reloads = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!gIndentHooked || !table || now - lastReload < 3 || reloads >= 3) {
        return;
    }
    lastReload = now;
    reloads++;
    __weak UITableView* weakTable = table;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakTable reloadData];
    });
}

static void DrawThreadLine(UITableViewCell* cell, NFBCardBackground* background, NFBThreadFlags flags) {
    if (!flags) {
        background.threadLayer.path = nil;
        return;
    }
    CGFloat height = CGRectGetHeight(cell.bounds);
    UIView* avatar = AvatarOf(cell);
    BOOL plainLayout = CATransform3DIsIdentity(cell.contentView.layer.sublayerTransform);
    CGRect face = ThroughContentTransform(AvatarDrawnRect(avatar, cell), cell);
    UIBezierPath* path = [UIBezierPath bezierPath];
    BOOL up = (flags & NFBThreadUp) != 0, down = (flags & NFBThreadDown) != 0;
    if (!up) {
        // The first tweet: down from under its reply button.
        UIView* reply = FindView(cell.contentView, @"InlineReplyButton", 0);
        CGRect button = reply ? [reply convertRect:reply.bounds toView:cell] : CGRectNull;
        if (CGRectIsNull(button) && CGRectIsNull(face)) {
            background.threadLayer.path = nil;
            return;
        }
        CGRect from = CGRectIsNull(button) ? face : button;
        CGFloat x = CGRectGetMidX(from);
        // Only a real reply button, in a row X laid out itself, moves the
        // line. 7.3.97 also took the avatar of a row without a button and
        // rows drawn smaller: two rows that disagreed then laid each other
        // out again and again (replies on screen are placed for the line),
        // which is a list that never finishes laying out. The others are
        // also asked to lay out again a few times at most.
        if (!CGRectIsNull(button) && plainLayout && fabs(x - gThreadX) > 0.5) {
            gThreadX = x;
            static CFAbsoluteTime since = 0;
            static NSInteger asked = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - since > 2) {
                since = now;
                asked = 0;
            }
            if (asked++ < 4) {
                for (UITableViewCell* other in TableOf(cell).visibleCells) {
                    if (other != cell) {
                        [other setNeedsLayout];
                    }
                }
            }
        }
        CGFloat lineX = gThreadX > 0 ? gThreadX : x;
        // Measure how far in a reply has to sit, once the avatar has its final size.
        BOOL scaled = objc_getAssociatedObject(avatar, kScaledKey) != nil;
        BOOL wantsScale = fabs(gStyle.avatarScale - 1) > 0.005;
        if (plainLayout && !CGRectIsNull(button) && !CGRectIsNull(face) && scaled == wantsScale) {
            NoteReplyIndent(x - CGRectGetMidX(face), TableOf(cell));
        }
        if (down) {
            [path moveToPoint:CGPointMake(lineX, CGRectGetMaxY(from) + 3)];
            [path addLineToPoint:CGPointMake(lineX, height)];
        }
    } else {
        CGFloat x = ThreadX();
        if (!CGRectIsNull(face) && fabs(CGRectGetMidX(face) - x) < 8) {
            // A reply: stop above its avatar, go on below it.
            [path moveToPoint:CGPointMake(x, 0)];
            [path addLineToPoint:CGPointMake(x, MAX(0, CGRectGetMinY(face) - 3))];
            if (down) {
                [path moveToPoint:CGPointMake(x, CGRectGetMaxY(face) + 3)];
                [path addLineToPoint:CGPointMake(x, height)];
            }
        } else if (!CGRectIsNull(face)) {
            // The avatar could not be put on the line: bend into it.
            CGFloat y = CGRectGetMidY(face), bend = 10;
            BOOL right = CGRectGetMidX(face) > x;
            CGFloat edge = right ? CGRectGetMinX(face) - 3 : CGRectGetMaxX(face) + 3;
            [path moveToPoint:CGPointMake(x, 0)];
            [path addLineToPoint:CGPointMake(x, y - bend)];
            [path addQuadCurveToPoint:CGPointMake(x + (right ? bend : -bend), y) controlPoint:CGPointMake(x, y)];
            [path addLineToPoint:CGPointMake(edge, y)];
            if (down) {
                [path moveToPoint:CGPointMake(x, y - bend)];
                [path addLineToPoint:CGPointMake(x, height)];
            }
        } else {
            // "Show more replies": straight through.
            [path moveToPoint:CGPointMake(x, 0)];
            [path addLineToPoint:CGPointMake(x, down ? height : height / 2)];
        }
    }
    background.threadLayer.path = path.CGPath;
}

// MARK: Room around the content
// 7.3.86-7.3.93 drew every row smaller about its middle to fit inside its
// card, so the room above and below the content grew with the row's height (a
// tall tweet, or one with a "reposted" line on top, had a wide margin, a short
// one almost none). 7.3.95 gave the list's controller an extra safe area on
// each side; X did not lay its rows out within it (7.3.96 dump: rows still 440
// wide, avatar at 9), so everything was still drawn smaller.
//
// 7.3.97: X lays a row out from a TFNLayoutMetrics, which the list's
// controller hands out from -calculatedLayoutMetrics and which can be asked
// for a copy with other insets (-layoutMetricsWithDisplayAreaEdgeInsets:, as X
// itself does on wide screens). The card margin goes in there, so X lays every
// row out inside its card with its own spacing: nothing is drawn smaller, and
// the room above and below is X's own, the same for every kind of tweet. A row
// X still laid out at full width is drawn smaller as before.

static const void* kListInsetKey = &kListInsetKey;           // on a list's controller: the margin X was given
static const void* kControllerKindKey = &kControllerKindKey; // which list a controller shows
static const void* kMetricsAskedKey = &kMetricsAskedKey;
static NSInteger gMarginVariant = 0; // 1: display area insets, 2: content insets

static UIViewController* OwnerOf(UIView* view) {
    for (UIResponder* responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController*)responder;
        }
    }
    return nil;
}

@interface NFBKindNote : NSObject
@property (nonatomic, assign) NSInteger kind;
@property (nonatomic, assign) void* parent;
@property (nonatomic, assign) BOOL inWindow;
@end

@implementation NFBKindNote
@end

// X asks for its metrics very often, so the answer is remembered: for good
// once the list is told apart, and otherwise until the controller gets another
// parent or its view comes on screen (7.3.97 walked the controllers and
// compared class names on every call).
static NFBListKind KindOfController(UIViewController* controller) {
    NFBKindNote* note = objc_getAssociatedObject(controller, kControllerKindKey);
    UIViewController* parent = controller.parentViewController;
    BOOL inWindow = controller.viewIfLoaded.window != nil;
    if (note && (note.kind != NFBListOther || (note.parent == (__bridge void*)parent && note.inWindow == inWindow))) {
        return (NFBListKind)note.kind;
    }
    NFBListKind kind = NFBListOther;
    for (UIViewController* up = controller; up && kind == NFBListOther; up = up.parentViewController) {
        NSString* name = NSStringFromClass(up.class);
        if ([name containsString:@"HomeTimeline"]) {
            kind = NFBListHome;
        } else if ([name containsString:@"NotificationsViewController"]) {
            kind = NFBListNotifications;
        }
    }
    if (kind == NFBListOther && inWindow) {
        for (UIResponder* responder = controller.viewIfLoaded.superview; responder && kind == NFBListOther;
             responder = responder.nextResponder) {
            if (![responder isKindOfClass:[UIViewController class]]) {
                continue;
            }
            NSString* name = NSStringFromClass(responder.class);
            if ([name containsString:@"HomeTimeline"]) {
                kind = NFBListHome;
            } else if ([name containsString:@"NotificationsViewController"]) {
                kind = NFBListNotifications;
            }
        }
    }
    note = [NFBKindNote new];
    note.kind = kind;
    note.parent = (__bridge void*)parent;
    note.inWindow = inWindow;
    objc_setAssociatedObject(controller, kControllerKindKey, note, OBJC_ASSOCIATION_RETAIN);
    return kind;
}

// What was answered for a controller's metrics, so the same question gets the
// very same object back (see the hook on -calculatedLayoutMetrics).
@interface NFBMetricsNote : NSObject
@property (nonatomic, strong) id source;
@property (nonatomic, strong) id result;
@property (nonatomic, assign) CGFloat extra;
@end

@implementation NFBMetricsNote
@end

static const void* kMetricsNoteKey = &kMetricsNoteKey;

static UIEdgeInsets MetricInsets(id metrics, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    return [metrics respondsToSelector:selector] ? ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(metrics, selector)
                                                 : UIEdgeInsetsZero;
}

static CGFloat MetricNumber(id metrics, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    return [metrics respondsToSelector:selector] ? ((CGFloat (*)(id, SEL))objc_msgSend)(metrics, selector) : 0;
}

static CGPoint MetricPoint(id metrics, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    return [metrics respondsToSelector:selector] ? ((CGPoint (*)(id, SEL))objc_msgSend)(metrics, selector) : CGPointZero;
}

static CGSize MetricSize(id metrics, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    return [metrics respondsToSelector:selector] ? ((CGSize (*)(id, SEL))objc_msgSend)(metrics, selector) : CGSizeZero;
}

static id MetricsWithInsets(id metrics, NSString* name, UIEdgeInsets insets) {
    SEL selector = NSSelectorFromString(name);
    return [metrics respondsToSelector:selector]
               ? ((id (*)(id, SEL, UIEdgeInsets))objc_msgSend)(metrics, selector, insets)
               : nil;
}

// X's metrics with `extra` more room on each side, or nil when X does not
// take it (then the rows are drawn smaller as before).
static id MetricsWithMargin(id metrics, CGFloat extra) {
    CGFloat before = MetricNumber(metrics, @"contentWidth");
    if (before <= extra * 2 + 80) {
        return nil;
    }
    UIEdgeInsets display = MetricInsets(metrics, @"displayAreaEdgeInsets");
    display.left += extra;
    display.right += extra;
    id result = MetricsWithInsets(metrics, @"layoutMetricsWithDisplayAreaEdgeInsets:", display);
    NSInteger variant = 1;
    if (!result || MetricNumber(result, @"contentWidth") > before - extra) {
        UIEdgeInsets content = MetricInsets(metrics, @"contentEdgeInsets");
        content.left += extra;
        content.right += extra;
        result = MetricsWithInsets(metrics, @"layoutMetricsWithContentEdgeInsets:", content);
        variant = 2;
        if (!result || MetricNumber(result, @"contentWidth") > before - extra) {
            result = nil;
            variant = 0;
        }
    }
    gMarginVariant = variant;
    gMetricsMisses++;
    gMetricsLog = [NSString stringWithFormat:@"variant=%ld extra=%.0f canvas=%.0f content %.0f>%.0f avatarX %.1f>%.1f bodyX %.1f>%.1f",
                                             (long)variant, extra, MetricNumber(metrics, @"canvasWidth"), before,
                                             result ? MetricNumber(result, @"contentWidth") : -1,
                                             MetricPoint(metrics, @"avatarOrigin").x,
                                             result ? MetricPoint(result, @"avatarOrigin").x : -1,
                                             MetricPoint(metrics, @"bodyOrigin").x,
                                             result ? MetricPoint(result, @"bodyOrigin").x : -1];
    return result;
}

// Asks X to work its layout metrics out again (after a switch or the card
// margin changed), which lays the rows out anew.
static void UpdateListMetrics(UITableView* table) {
    SEL update = NSSelectorFromString(@"setNeedsLayoutMetricsUpdate");
    UIViewController* owner = OwnerOf(table);
    if ([owner respondsToSelector:update]) {
        ((void (*)(id, SEL))objc_msgSend)(owner, update);
    }
    if ([table respondsToSelector:update]) {
        ((void (*)(id, SEL))objc_msgSend)(table, update);
    }
}

// MARK: Replies laid out further in
// A reply inside a thread card sits further right, its avatar on the line
// under the first tweet's reply button. 7.3.94-7.3.96 moved the row there and
// drew it smaller to fit, which again made its margins depend on its height.
// Now X lays the reply out narrower itself: where it makes a tweet row's
// layout (+[T1StatusCell cellLayoutForViewModel:options:account:layoutMetrics:
// withPreviousLayout:], which also gives the row its height), a reply (X's
// own connector type says so) gets metrics with more room on the left.

static const NSUInteger kConnectorUpBit = 1;
static __thread __unsafe_unretained id tAnatomyFeatures = nil;

static CGFloat ReplyIndentFor(id metrics) {
    if (gReplyIndent > 0) {
        return gReplyIndent;
    }
    // Not measured yet: the reply button starts with the text column, and its
    // icon is about 20 wide.
    CGSize avatar = MetricSize(metrics, @"avatarSize");
    CGFloat avatarX = MetricPoint(metrics, @"avatarOrigin").x, bodyX = MetricPoint(metrics, @"bodyOrigin").x;
    if (avatar.width < 16 || bodyX <= avatarX) {
        return 40;
    }
    CGFloat drawnCentre = avatarX + avatar.width - avatar.width * gStyle.avatarScale / 2;
    return MAX(20, MIN(80, bodyX + 10 - drawnCentre));
}

// X's thread connector for a tweet (1 = joined to the row above, 2 = to the
// row below), where a row's layout is made.
static NSUInteger ConnectorFor(id viewModel, NSUInteger options) {
    static Class config = Nil;
    static SEL selector = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        selector = NSSelectorFromString(@"connectorTypeForViewModel:anatomyFeatures:statusOptions:");
        Class found = objc_getClass("T1StandardStatusConversationConnectorsConfiguration");
        config = (found && [found respondsToSelector:selector]) ? found : Nil;
    });
    if (!config || !viewModel) {
        return 0;
    }
    return ((NSUInteger (*)(id, SEL, id, id, NSUInteger))objc_msgSend)(config, selector, viewModel, tAnatomyFeatures, options);
}

// Are these the metrics of a list with cards? They carry the card margin.
static BOOL AreCardMetrics(id metrics) {
    if (gMarginVariant != 1 || !metrics || (!gCardsOn && !gNoteCardsOn)) {
        return NO;
    }
    UIEdgeInsets display = MetricInsets(metrics, @"displayAreaEdgeInsets");
    CGFloat margin = kCardSide + gStyle.inner;
    return fabs(display.left - margin) <= 0.5 && fabs(display.right - margin) <= 0.5;
}

// The metrics for one row: further in on the left (a reply in a thread card)
// and narrower on the right (one small photo beside the text). The last
// answer is kept: rows are laid out in runs, and making a copy of X's metrics
// for each tweet was part of 7.3.97's slow start.
static os_unfair_lock gRowLock = OS_UNFAIR_LOCK_INIT;
static id gRowSource = nil, gRowResult = nil;
static CGFloat gRowLeft = -1, gRowRight = -1;

static id MetricsForRow(id metrics, CGFloat left, CGFloat right) {
    id result = nil;
    os_unfair_lock_lock(&gRowLock);
    if (gRowResult && fabs(gRowLeft - left) < 0.01 && fabs(gRowRight - right) < 0.01 &&
        (gRowSource == metrics || [gRowSource isEqual:metrics])) {
        result = gRowResult;
    }
    os_unfair_lock_unlock(&gRowLock);
    if (!result) {
        CGFloat before = MetricNumber(metrics, @"contentWidth");
        UIEdgeInsets content = MetricInsets(metrics, @"contentEdgeInsets");
        content.left += left;
        content.right += right;
        result = MetricsWithInsets(metrics, @"layoutMetricsWithContentEdgeInsets:", content);
        if (!result || MetricNumber(result, @"contentWidth") > before - (left + right) / 2) {
            return nil;
        }
        os_unfair_lock_lock(&gRowLock);
        gRowSource = metrics;
        gRowResult = result;
        gRowLeft = left;
        gRowRight = right;
        os_unfair_lock_unlock(&gRowLock);
    }
    if (left > 0) {
        gIndentedRows++;
    }
    return result;
}

// MARK: Room above and below a card
// Until 7.3.97 a card was drawn inside the row X had measured: half the gap
// was taken off its top and bottom. So a wider gap did not move the cards
// apart, it made each card shorter and its content sit closer to its edges,
// and the "room inside a card" setting only worked sideways.
//
// Now the row itself is made taller where X makes a tweet row's layout: by
// half the gap plus the inner room at each end that is not joined to another
// row of its thread. The gap is then really between the cards, and the inner
// room is added above and below the content as it is at the sides. The cell
// puts its content that much lower (X's -contentFrame, and once more after
// X's layout in case X does not take the frame from there). What was added is
// remembered on the layout, so the cell takes off exactly that, and a layout X
// hands out again is only changed by the difference.

static const void* kRoomKey = &kRoomKey; // on a row's layout: the room added, as insets

static void GiveCardRoom(id layout, BOOL cards, NSUInteger connector) {
    if (!layout) {
        return;
    }
    NSValue* was = objc_getAssociatedObject(layout, kRoomKey);
    if (!cards && !was) {
        return;
    }
    CGFloat edge = gStyle.gap / 2 + gStyle.innerV;
    CGFloat top = (cards && !(connector & 1)) ? edge : 0;
    CGFloat bottom = (cards && !(connector & 2)) ? edge : 0;
    // A tweet with a line above it ("... reposted") starts its name and avatar
    // about 19 points lower, and the line is small and grey, so the card looks
    // as if it had a wide margin on top. Such a row gets up to 8 points less
    // room above. X's layout says where the avatar is.
    SEL stateSelector = NSSelectorFromString(@"statusViewLayoutState"), avatarSelector = NSSelectorFromString(@"avatarFrame");
    if (top > 0 && [layout respondsToSelector:stateSelector]) {
        id state = ((id (*)(id, SEL))objc_msgSend)(layout, stateSelector);
        if ([state respondsToSelector:avatarSelector] &&
            ((CGRect (*)(id, SEL))objc_msgSend)(state, avatarSelector).origin.y > 22) {
            top = MAX(0, top - 8);
        }
    }
    UIEdgeInsets old = was ? was.UIEdgeInsetsValue : UIEdgeInsetsZero;
    if (fabs(old.top - top) < 0.01 && fabs(old.bottom - bottom) < 0.01) {
        return;
    }
    SEL getter = NSSelectorFromString(@"size"), setter = NSSelectorFromString(@"setSize:");
    if (![layout respondsToSelector:getter] || ![layout respondsToSelector:setter]) {
        return;
    }
    CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(layout, getter);
    if (size.height <= 0) {
        return; // a row that measures itself
    }
    size.height += (top + bottom) - (old.top + old.bottom);
    ((void (*)(id, SEL, CGSize))objc_msgSend)(layout, setter, size);
    objc_setAssociatedObject(layout, kRoomKey, [NSValue valueWithUIEdgeInsets:UIEdgeInsetsMake(top, 0, bottom, 0)],
                             OBJC_ASSOCIATION_RETAIN);
    gRoomRows++;
}

// `frame` (the content's place in its row) with the row's added room taken
// off, when the row really is as tall as its layout says.
static CGRect FrameWithRoom(UITableViewCell* cell, CGRect frame) {
    SEL layoutSelector = NSSelectorFromString(@"cellLayout");
    if (![cell respondsToSelector:layoutSelector]) {
        return frame;
    }
    id layout = ((id (*)(id, SEL))objc_msgSend)(cell, layoutSelector);
    NSValue* note = layout ? objc_getAssociatedObject(layout, kRoomKey) : nil;
    if (!note) {
        return frame;
    }
    UIEdgeInsets room = note.UIEdgeInsetsValue;
    SEL sizeSelector = NSSelectorFromString(@"size");
    if (room.top + room.bottom < 0.5 || ![layout respondsToSelector:sizeSelector]) {
        return frame;
    }
    CGFloat layoutHeight = ((CGSize (*)(id, SEL))objc_msgSend)(layout, sizeSelector).height;
    CGFloat rowHeight = CGRectGetHeight(cell.bounds);
    if (fabs(rowHeight - layoutHeight) > 2 || CGRectGetHeight(frame) < rowHeight - 2 || CGRectGetMinY(frame) > 0.5) {
        return frame; // the row did not get the room, or the frame has it taken off already
    }
    frame.origin.y += room.top;
    frame.size.height -= room.top + room.bottom;
    return frame;
}

// MARK: A pressed card
// A card that is pressed goes in a little (0.98, 140 ms), like something that
// can be pressed. It follows the row's own highlight, which UIKit only sets
// when the touch is not a scroll, and not when the finger is on a picture, a
// link preview, a quoted tweet, the avatar or a button. The row's sublayer
// transform is used, so nothing X lays out is touched.
static void MoveSublayers(CALayer* layer, CATransform3D to, CFTimeInterval duration, BOOL spring);

static void PressCard(UITableViewCell* cell, BOOL down) {
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    BOOL press = down && gPressOn && memory.active;
    if (press) {
        UITableView* table = TableOf(cell);
        if (table.isDragging || table.isDecelerating) {
            press = NO;
        } else {
            CGPoint point = [table.panGestureRecognizer locationInView:cell];
            UIView* hit = CGRectContainsPoint(cell.bounds, point) ? [cell hitTest:point withEvent:nil] : nil;
            for (UIView* view = hit; view && view != cell; view = view.superview) {
                NSString* name = NSStringFromClass(view.class);
                if ([view isKindOfClass:[UIControl class]] || [name containsString:@"Media"] ||
                    [name containsString:@"Photo"] || [name containsString:@"Video"] ||
                    [name containsString:@"Attachment"] || [name containsString:@"Card"] ||
                    [name containsString:@"Quoted"] || [name containsString:@"Avatar"] ||
                    [name containsString:@"FleetLine"]) {
                    press = NO;
                    break;
                }
            }
        }
    }
    CATransform3D target = press ? CATransform3DMakeScale(0.98, 0.98, 1) : CATransform3DIdentity;
    if (CATransform3DEqualToTransform(cell.layer.sublayerTransform, target)) {
        return;
    }
    MoveSublayers(cell.layer, target, press ? 0.14 : 0.2, NO);
}

// MARK: Putting a card on a row

static void ApplyCard(UITableViewCell* cell, NFBListKind kind) {
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    UITableView* table = TableOf(cell);
    BOOL listOn = CardsOnFor(kind);
    if (kind == NFBListHome && table && gHomeTable != table) {
        gHomeTable = table;
    }
    if (listOn && table) {
        if (!gCardTables) {
            gCardTables = [NSHashTable weakObjectsHashTable];
        }
        if (![gCardTables containsObject:table]) {
            [gCardTables addObject:table];
        }
    }
    NFBThreadFlags flags = (listOn && kind == NFBListHome) ? ThreadFlags(table, cell) : 0;
    BOOL want = listOn && CGRectGetWidth(cell.bounds) > 120 &&
                (CGRectGetHeight(cell.bounds) >= 36 || (flags & NFBThreadUp));
    if (!want) {
        RemoveCard(cell, memory);
        if (!listOn && kind != NFBListOther) {
            SetTablePage(table, nil);
        }
        return;
    }
    if (!memory) {
        memory = [NFBCardMemory new];
        objc_setAssociatedObject(cell, kCardMemoryKey, memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!memory.active) {
        memory.xPaper = XPaperColor(cell, table);
        memory.xPaperStyle = cell.traitCollection.userInterfaceStyle;
        memory.oldBackgroundView = cell.backgroundView;
        memory.oldCellColor = cell.backgroundColor;
        memory.oldContentColor = cell.contentView.backgroundColor;
        memory.oldSelectedBackgroundView = cell.selectedBackgroundView;
        if (!memory.background) {
            memory.background = [[NFBCardBackground alloc] initWithFrame:cell.bounds];
        }
        memory.stamp = -1;
        memory.active = YES;
    }
    UIColor* pageNow = objc_getAssociatedObject(table, kTablePageColorKey);
    BOOL repainted = pageNow && !SameColor(table.backgroundColor, pageNow, table.traitCollection);
    if (memory.stamp != gStamp || repainted) {
        memory.stamp = gStamp;
        UIColor* paper = NFBCardPaperColor(gStyle, GuardedPaper(memory.xPaper, memory.xPaperStyle), CurrentAccentColor());
        UIColor* page = NFBCardPageColor(paper);
        [memory.background setPaper:paper page:page];
        if (!memory.highlight) {
            memory.highlight = [[NFBCardBackground alloc] initWithFrame:cell.bounds];
        }
        [memory.highlight setPaper:NFBCardBlend(paper, [UIColor labelColor], 0.07) page:page];
        NSNumber* tableStamp = objc_getAssociatedObject(table, kTablePageStampKey);
        if (tableStamp.integerValue != gStamp || !tableStamp || repainted ||
            !SameColor(pageNow, page, table.traitCollection)) {
            SetTablePage(table, page);
        }
    }
    if (cell.backgroundView != memory.background) {
        cell.backgroundView = memory.background;
    }
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    SetDividersHidden(cell, YES);
    SetBackingCleared(cell, memory, YES);

    // 7.3.86-7.3.93 drew a notification that gathers several people as a
    // little pile; it meant nothing (there is nothing to open), so every
    // notification is a plain card again.
    BOOL pile = NO;
    if (kind == NFBListNotifications) {
        gNoteCards++;
    } else {
        gHomeCards++;
    }

    // A thread: the first tweet keeps the top of the card, the replies go in
    // the inner box under it.
    NFBCardBackground* background = memory.background;
    BOOL nested = (flags & NFBThreadUp) != 0;
    if (flags) {
        gThreadRows++;
    }
    if (background.pile != pile || background.openTop != !!(flags & NFBThreadUp) ||
        background.openBottom != !!(flags & NFBThreadDown) || background.nested != nested ||
        background.nestOpenTop != !!(flags & NFBThreadNestUp)) {
        background.pile = pile;
        background.openTop = (flags & NFBThreadUp) != 0;
        background.openBottom = (flags & NFBThreadDown) != 0;
        background.nested = nested;
        background.nestOpenTop = (flags & NFBThreadNestUp) != 0;
        [background setNeedsLayout];
    }
    // Tapping a row shows a highlight the shape of its card, not a square.
    NFBCardBackground* highlight = memory.highlight;
    highlight.openTop = background.openTop;
    highlight.openBottom = background.openBottom;
    [highlight setNeedsLayout];
    if (highlight && cell.selectedBackgroundView != highlight) {
        cell.selectedBackgroundView = highlight;
    }
    SetThreadLinesHidden(cell, memory, flags != 0);
    if (memory.thread != flags) {
        // The neighbours decide their own edges from this row; let them look again.
        if ((memory.thread ^ flags) & NFBThreadUp) {
            [Neighbour(table, cell, -1) setNeedsLayout];
        }
        if ((memory.thread ^ flags) & NFBThreadDown) {
            [Neighbour(table, cell, 1) setNeedsLayout];
        }
        memory.thread = flags;
    }

    CGFloat width = CGRectGetWidth(cell.contentView.bounds);
    CGFloat height = CGRectGetHeight(cell.contentView.bounds);
    if (width <= 0 || height <= 0) {
        return;
    }
    UIView* contentView = cell.contentView;
    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    CGFloat originX = CGRectGetMinX(contentView.frame);
    CGFloat margin = kCardSide + gStyle.inner;
    UIViewController* owner = OwnerOf(table);
    NSNumber* listInset = owner ? objc_getAssociatedObject(owner, kListInsetKey) : nil;
    if (owner && !listInset) {
        // X was asked for its metrics before this list could be told apart
        // (or before the switch was read): have it ask again, once per look.
        NSNumber* asked = objc_getAssociatedObject(owner, kMetricsAskedKey);
        if (!asked || asked.integerValue != gStamp) {
            objc_setAssociatedObject(owner, kMetricsAskedKey, @(gStamp), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UITableView* weakTable = table;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakTable) {
                    UpdateListMetrics(weakTable);
                }
            });
        }
    }
    // Did X lay this row out inside the margin? The content view itself, or
    // the avatar where there is one, tells; a row without an avatar is taken
    // on the word of the metrics the list was given.
    UIView* avatar = AvatarOf(cell);
    CGRect face = PlainRectInCell(avatar, cell);
    BOOL fits = originX >= margin - 1;
    if (!fits && listInset && fabs(listInset.doubleValue - margin) < 0.5) {
        fits = CGRectIsNull(face) || CGRectGetMinX(face) >= margin - 0.5;
    }
    if (fits) {
        gFitRows++;
    } else {
        gScaledRows++;
    }
    CATransform3D transform = CATransform3DIdentity;
    if (nested) {
        CGRect drawn = AvatarDrawnRect(avatar, cell);
        CGFloat line = ThreadX();
        if (fits && CGRectIsNull(drawn)) {
            // "Show more replies" and other rows without an avatar: as X laid
            // them out, inside the inner box.
            background.nestLeft = line - 23 - 8;
        } else if (fits && !CGRectIsNull(drawn) && fabs(CGRectGetMidX(drawn) - line) <= 16) {
            // X laid this reply out further in already: only settle its
            // avatar on the line, at full size.
            CGFloat delta = line - CGRectGetMidX(drawn);
            if (fabs(delta) > 0.25) {
                transform = CATransform3DMakeTranslation(delta, 0, 0);
            }
            background.nestLeft = line - CGRectGetWidth(drawn) / 2 - 8;
        } else {
            // Laid out like any other row: move the reply so its avatar sits
            // on the line and draw it small enough to fit the inner box. All
            // in content view coordinates.
            CGFloat lineX = line - originX;
            CGFloat avatarX = !CGRectIsNull(drawn) ? CGRectGetMidX(drawn) - originX
                                                    : (gNestAvatarX > 0 ? gNestAvatarX : (fits ? margin + 28 : 28));
            if (!CGRectIsNull(drawn)) {
                gNestAvatarX = avatarX;
            }
            CGFloat leftRoom = MAX(16, avatarX - 20);
            CGFloat contentRight = width - leftRoom;
            CGFloat boxRight = cellWidth - kCardSide - 8 - originX;
            CGFloat scale = MAX(0.6, MIN(1, (boxRight - 6 - lineX) / MAX(1, contentRight - avatarX)));
            CGFloat shift = lineX - width / 2 - scale * (avatarX - width / 2);
            transform = CATransform3DScale(CATransform3DMakeTranslation(shift, 0, 0), scale, scale, 1);
            background.nestLeft = line - 22 * scale - 8;
        }
    } else if (!fits) {
        CGFloat scale = MAX(0.8, (cellWidth - margin * 2) / MAX(1, width));
        transform = CATransform3DMakeScale(scale, scale, 1);
    }
    // A row being pulled sideways (notifications) keeps its pull.
    memory.baseTransform = transform;
    CATransform3D shown = fabs(memory.swipeOffset) > 0.01
                              ? CATransform3DConcat(transform, CATransform3DMakeTranslation(memory.swipeOffset, 0, 0))
                              : transform;
    if (!CATransform3DEqualToTransform(contentView.layer.sublayerTransform, shown) &&
        ![contentView.layer animationForKey:@"nfbSwipe"]) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        contentView.layer.sublayerTransform = shown;
        [CATransaction commit];
        [background setNeedsLayout];
    }
    DrawThreadLine(cell, background, flags);
}

// After a change on the settings page: every row on screen takes the new look.
static void RefreshViews(UIView* view, int depth) {
    if (depth > 40) {
        return;
    }
    if ([view isKindOfClass:[UITableViewCell class]]) {
        [view setNeedsLayout];
        NFBCardMemory* memory = objc_getAssociatedObject(view, kCardMemoryKey);
        [memory.background setNeedsLayout];
    }
    if ([NSStringFromClass(view.class) isEqualToString:@"T1StandardStatusView"]) {
        [view setNeedsLayout];
    }
    // The card margin is part of X's layout metrics for the list.
    if ([view isKindOfClass:[UITableView class]] && ListKind((UITableView*)view) != NFBListOther) {
        UpdateListMetrics((UITableView*)view);
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
    // The gap and the inner room are part of each row's height: the lists
    // that show cards measure their rows again, on screen or not (the home
    // timeline is under the settings page while the sliders are moved).
    for (UITableView* table in gCardTables.allObjects) {
        UpdateListMetrics(table);
        [table reloadData];
    }
}

// MARK: Pull a notification to answer it
//
// 7.3.86 moved the card only once the pan gesture began, and on device it
// began only when the finger lifted (another gesture kept it waiting), so the
// card sat still and the reply mark just flashed. The pull is now followed
// straight from the touches: the card moves with the finger from the first
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
// The pull used to set the content view's transform and each card piece's
// transform; in 7.3.97 the reply mark showed and nothing moved: X lays the
// row out again while it is touched and puts those views back. A sublayer
// transform is not part of that layout, and ApplyCard keeps the pull in it.
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
@property (nonatomic, assign) BOOL tracking; // the card is following the finger
@property (nonatomic, assign) BOOL armed;    // pulled far enough to answer on release
@property (nonatomic, assign) NSInteger moves;
@end

@implementation NFBReplySwipe

- (void)showMark:(CGFloat)offset {
    UIView* mark = self.mark;
    CGFloat progress = MIN(1.0, -offset / kReplyPull);
    mark.alpha = progress;
    CGFloat scale = self.armed ? 1.15 : 0.5 + 0.5 * progress;
    // The mark rides a little behind the card's edge until it is fully shown.
    mark.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale),
                                             CGAffineTransformMakeTranslation((1 - progress) * 24, 0));
}

- (void)setOffset:(CGFloat)offset duration:(CFTimeInterval)duration spring:(BOOL)spring {
    UITableViewCell* cell = self.cell;
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    CATransform3D move = CATransform3DMakeTranslation(offset, 0, 0);
    if (memory.active) {
        memory.swipeOffset = offset;
        MoveSublayers(cell.contentView.layer, CATransform3DConcat(memory.baseTransform, move), duration, spring);
        MoveSublayers(memory.background.layer, move, duration, spring);
        MoveSublayers(memory.highlight.layer, move, duration, spring);
    } else {
        MoveSublayers(cell.contentView.layer, move, duration, spring);
    }
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
    self.mark.center = CGPointMake(CGRectGetWidth(cell.bounds) - kCardSide - kReplyPull / 2,
                                   CGRectGetMidY(cell.bounds));
    self.mark.alpha = 0;
    [cell insertSubview:self.mark belowSubview:cell.contentView];
    // Stop the list scrolling up and down while the card is pulled.
    UITableView* table = TableOf(cell);
    if (table.panGestureRecognizer.enabled) {
        table.panGestureRecognizer.enabled = NO;
        table.panGestureRecognizer.enabled = YES;
    }
}

- (void)followTo:(CGFloat)dx {
    dx = MIN(0, dx);
    self.moves++;
    // Past the answer point the card still follows, but stiffer.
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
// refused, and failed, so no more touches came and the card stayed put. Decide
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
        if (sideways && gNoteCardsOn && ListKind(TableOf(cell)) == NFBListNotifications && ReplyButton(cell)) {
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
    // Another gesture (the list scrolling) took over: put the card back.
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
    // decided; once the card follows the finger the list is stopped anyway.
    return [other.view isKindOfClass:[UITableView class]];
}

// The card is moved from the touches themselves; nothing to do here.
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


// (7.3.94 opened a sheet listing who is behind a grouped notification from its
// avatars; taken out again in 7.3.95 at the user's wish.)

// MARK: Hooks

// X's base class for rows, and what makes a tweet row's layout (not in Headers/).
@interface TFNTableViewCell : UITableViewCell
@end

@interface TFNRoundedCornerView : UIView
@end

@interface ConversationConnectorView : UIView
@end

@interface T1StatusTableRowAdapter : NSObject
@end

// What a row with a card needs again after X or UIKit has touched it: its
// dividers off and X's backing clear.
static void KeepCardClean(UITableViewCell* cell) {
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    if (memory.active) {
        SetDividersHidden(cell, YES);
        SetBackingCleared(cell, memory, YES);
    }
}

// X fades its highlight in and out; whatever it sets when that ends is
// cleared too.
static void KeepCardCleanSoon(UITableViewCell* cell) {
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    if (!memory.active) {
        return;
    }
    KeepCardClean(cell);
    __weak UITableViewCell* weakCell = cell;
    for (NSNumber* delay in @[ @0.0, @0.15, @0.45 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           UITableViewCell* strongCell = weakCell;
                           if (strongCell) {
                               KeepCardClean(strongCell);
                           }
                       });
    }
}

static void LayoutCard(UITableViewCell* cell) {
    if (!gCardsOn && !gNoteCardsOn && !objc_getAssociatedObject(cell, kCardMemoryKey)) {
        return;
    }
    NFBListKind kind = ListKind(TableOf(cell));
    ApplyCard(cell, kind);
    if (kind == NFBListNotifications && gNoteCardsOn) {
        AttachReplySwipe(cell);
    }
}

%hook UITableViewCell

// X paints a row again while it animates back from a tweet (7.3.95: the plain
// timeline showed for a moment), and when the theme changes. A row with a
// card stays clear, and the colour X wanted becomes the card's.
- (void)setBackgroundColor:(UIColor*)color {
    NFBCardMemory* memory = objc_getAssociatedObject(self, kCardMemoryKey);
    if (memory.active && color) {
        CGFloat r = 0, g = 0, b = 0, alpha = 0;
        [color getRed:&r green:&g blue:&b alpha:&alpha];
        if (alpha > 0.01) {
            NoteXPaper((UITableViewCell*)self, memory, color);
            %orig([UIColor clearColor]);
            return;
        }
    }
    %orig;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    KeepCardClean((UITableViewCell*)self);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    KeepCardClean((UITableViewCell*)self);
}

- (void)layoutSubviews {
    %orig;
    // X's own rows get their card after X's part of the layout (below).
    static Class tfnCell = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tfnCell = objc_getClass("TFNTableViewCell");
    });
    if (gCellHooked && tfnCell && [self isKindOfClass:tfnCell]) {
        return;
    }
    LayoutCard((UITableViewCell*)self);
}

%end

// X's rows are TFNTableViewCells, which override all three methods above and
// do their own work after calling UIKit's: lay the separator out, show two
// hairlines above and below a pressed row (TFNDataViewCellAppearanceHelper's
// highlight separators), paint the backing. The hooks above run inside that
// call to UIKit, so before X's part: X then undid them, which is the square
// that flashed over a card on the way back from a tweet (7.3.94-7.3.96).
// These run after X's part.
%group TFNCell

%hook TFNTableViewCell

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    KeepCardCleanSoon((UITableViewCell*)self);
    PressCard((UITableViewCell*)self, highlighted);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    KeepCardCleanSoon((UITableViewCell*)self);
}

- (void)prepareForReuse {
    %orig;
    PressCard((UITableViewCell*)self, NO);
}

- (void)layoutSubviews {
    %orig;
    // The room added above and below a card (see GiveCardRoom): the content
    // sits that much lower, before the tweet is laid out inside it.
    UITableViewCell* cell = (UITableViewCell*)self;
    CGRect frame = cell.contentView.frame;
    CGRect wanted = FrameWithRoom(cell, frame);
    if (!CGRectEqualToRect(frame, wanted)) {
        cell.contentView.frame = wanted;
        gRoomInsets++;
    }
    LayoutCard(cell);
}

%end

%end

// Where X takes the content's place in a row from, if it does.
%group TFNFrame

%hook TFNTableViewCell

- (CGRect)contentFrame {
    return FrameWithRoom((UITableViewCell*)self, %orig);
}

%end

%end

// X's two kinds of thread line stay hidden while they are marked (see KeepsHidden).
%group RoundedLines

%hook TFNRoundedCornerView

- (void)setHidden:(BOOL)hidden {
    %orig(hidden || KeepsHidden((UIView*)self));
}

%end

%end

%group ConnectorLines

%hook ConversationConnectorView

- (void)setHidden:(BOOL)hidden {
    %orig(hidden || KeepsHidden((UIView*)self));
}

%end

%end

// The margin of a list with cards, as part of X's own layout metrics.
%hook TFNDataViewController

// X asks for these all the time while it lays a screen out. 7.3.97 made a new
// copy of the metrics, and a line for the dump, on every call, and handed X a
// different object each time: slow, and X may take a different object for
// changed metrics and lay the list out again. The same question now gets the
// same object back, and off the main thread only what was worked out before.
- (id)calculatedLayoutMetrics {
    id metrics = %orig;
    if (!gSwitchesRead) {
        ReadSwitches();
    }
    if (!metrics || (!gCardsOn && !gNoteCardsOn)) {
        return metrics;
    }
    UIViewController* controller = (UIViewController*)self;
    NFBMetricsNote* note = objc_getAssociatedObject(controller, kMetricsNoteKey);
    if (![NSThread isMainThread]) {
        BOOL same = note.result && (note.source == metrics || [note.source isEqual:metrics]);
        return same ? note.result : metrics;
    }
    gMetricsCalls++;
    CGFloat extra = CardsOnFor(KindOfController(controller)) ? kCardSide + gStyle.inner : 0;
    if (extra <= 0) {
        if (note) {
            objc_setAssociatedObject(controller, kMetricsNoteKey, nil, OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(controller, kListInsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return metrics;
    }
    if (note && fabs(note.extra - extra) < 0.01 && (note.source == metrics || [note.source isEqual:metrics])) {
        return note.result ?: metrics;
    }
    id inset = MetricsWithMargin(metrics, extra);
    NFBMetricsNote* fresh = [NFBMetricsNote new];
    fresh.source = metrics;
    fresh.result = inset;
    fresh.extra = extra;
    objc_setAssociatedObject(controller, kMetricsNoteKey, fresh, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(controller, kListInsetKey, inset ? @(extra) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return inset ?: metrics;
}

%end

// A reply in a thread card is laid out further in (see MetricsForReply).
%group ReplyIndent

%hook T1StatusTableRowAdapter

- (id)dataViewController:(id)controller
       cellLayoutForItem:(id)item
             withOptions:(id)options
          previousLayout:(id)previousLayout
             atIndexPath:(id)indexPath {
    // Held here while X makes the layout: the thread-local below does not
    // keep it alive.
    SEL selector = NSSelectorFromString(@"anatomyFeatures");
    NSMethodSignature* signature = [self respondsToSelector:selector] ? [self methodSignatureForSelector:selector] : nil;
    NS_VALID_UNTIL_END_OF_SCOPE id features =
        (signature && signature.methodReturnType[0] == '@') ? ((id (*)(id, SEL))objc_msgSend)(self, selector) : nil;
    __unsafe_unretained id before = tAnatomyFeatures;
    tAnatomyFeatures = features;
    id layout = %orig;
    tAnatomyFeatures = before;
    return layout;
}

%end

%hook T1StatusCell

+ (id)cellLayoutForViewModel:(id)viewModel
                     options:(NSUInteger)options
                     account:(id)account
               layoutMetrics:(id)layoutMetrics
          withPreviousLayout:(id)previousLayout {
    BOOL cards = AreCardMetrics(layoutMetrics);
    NSUInteger connector = cards ? ConnectorFor(viewModel, options) : 0;
    CGFloat left = (cards && gCardsOn && (connector & kConnectorUpBit)) ? ReplyIndentFor(layoutMetrics) : 0;
    CGFloat thumb = NFBCornerThumbFor(viewModel);
    CGFloat right = thumb > 0 ? thumb + NFBCornerGap() : 0;
    id narrowed = (layoutMetrics && (left > 0 || right > 0)) ? MetricsForRow(layoutMetrics, left, right) : nil;
    id layout = narrowed ? %orig(viewModel, options, account, narrowed, previousLayout) : %orig;
    NFBCornerAdjustLayout(layout, (narrowed && right > 0) ? thumb : 0);
    GiveCardRoom(layout, cards, connector);
    return layout;
}

%end

%end

static const void* kDimmedKey = &kDimmedKey;

// The avatar and the name line can be drawn larger (chosen on the settings
// page). X's layout is left as it is: the views are scaled after X has placed
// them. The avatar grows toward the left margin and down (its top right corner
// stays put, keeping its distance to the name); the name line grows from its
// left middle. Before X lays the row out again the scale is taken off, so X
// never sets a frame on a scaled view.
static BOOL gOwnTransform = NO;

static void ScaleFrom(UIView* view, CGFloat scale, CGPoint anchor) {
    if (!view) {
        return;
    }
    // anchor in unit coordinates of the view's bounds (0,0 top left).
    CGSize size = view.bounds.size;
    CGFloat tx = (anchor.x - 0.5) * size.width * (1 - scale);
    CGFloat ty = (anchor.y - 0.5) * size.height * (1 - scale);
    gOwnTransform = YES;
    view.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(tx, ty), scale, scale);
    gOwnTransform = NO;
    objc_setAssociatedObject(view, kScaledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void Unscale(UIView* view) {
    if (view && objc_getAssociatedObject(view, kScaledKey)) {
        gOwnTransform = YES;
        view.transform = CGAffineTransformIdentity;
        gOwnTransform = NO;
        objc_setAssociatedObject(view, kScaledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// MARK: The name line
// TTAStatusAuthorView lays out separate UILabels: the name ("StatusFullname",
// semibold), the @handle ("StatusUsername"), a "·", and the time
// ("StatusTimeStamp"); the "..." button is a TFNDismissButton in a screenshot
// container at its right end. 7.3.89-7.3.95 scaled the whole view, which
// pushed that button off the card. Nothing is scaled: the labels get a larger
// font, and are placed again after X:
//  - the name where X put it, then its badges, the alias (StatusRowTweaks.x)
//    and the handle,
//  - the time, a little smaller, at the right end just left of the button
//    (left out in replies inside a thread card), the "·" hidden,
//  - all of them on one baseline,
//  - a name too long for what is left cut and faded at its end.
// The line moves up by the chosen gap (only the labels and badges, not the button).
//
// 7.3.96 told the labels apart by their text, and the handle's text does not
// start with "@": X wraps it in invisible direction marks (U+2066 ... U+2069).
// So the handle was taken for the time and sent to the right end, and the real
// time stayed where X had put it, in the middle and on another height. The
// labels are now known by X's own accessibility identifiers, with the text
// (marks stripped) only as a fallback.

static const void* kBaseFontKey = &kBaseFontKey;   // X's own font for a label
static const void* kOurFontKey = &kOurFontKey;     // the font we last gave it
static const void* kArrangedKey = &kArrangedKey;   // the line was arranged by us
static const void* kHiddenTimeKey = &kHiddenTimeKey;

// StatusRowTweaks.x: the alias label of a name line, if it shows one.
extern UILabel* NFBAliasLabelOf(UIView* author);

static BOOL IsBoldFont(UIFont* font) {
    NSString* name = font.fontName;
    return (font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) || [name containsString:@"Semibold"] ||
           [name containsString:@"Bold"] || [name containsString:@"Heavy"];
}

// A label's text without spaces and without invisible marks.
static NSString* CleanText(NSString* text) {
    if (text.length == 0) {
        return @"";
    }
    static NSCharacterSet* drop;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet* set = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [set formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]]; // Cc and Cf: the direction marks
        [set addCharactersInRange:NSMakeRange(0x200B, 5)];
        [set addCharactersInRange:NSMakeRange(0x202A, 5)];
        [set addCharactersInRange:NSMakeRange(0x2060, 16)];
        [set addCharactersInRange:NSMakeRange(0xFEFF, 1)];
        drop = [set copy];
    });
    return [[text componentsSeparatedByCharactersInSet:drop] componentsJoinedByString:@""];
}

static void FadeEnd(UIView* view, BOOL fade) {
    if (!fade) {
        if ([view.layer.mask isKindOfClass:[CAGradientLayer class]]) {
            view.layer.mask = nil;
        }
        return;
    }
    CGFloat width = CGRectGetWidth(view.bounds);
    CAGradientLayer* mask = [view.layer.mask isKindOfClass:[CAGradientLayer class]] ? (CAGradientLayer*)view.layer.mask
                                                                                    : [CAGradientLayer layer];
    mask.frame = CGRectMake(0, -4, width, CGRectGetHeight(view.bounds) + 8);
    mask.startPoint = CGPointMake(0, 0.5);
    mask.endPoint = CGPointMake(1, 0.5);
    mask.colors = @[ (__bridge id)[UIColor blackColor].CGColor, (__bridge id)[UIColor blackColor].CGColor,
                     (__bridge id)[UIColor clearColor].CGColor ];
    CGFloat fadeWidth = MIN(18, width / 2);
    mask.locations = @[ @0, @(MAX(0, (width - fadeWidth) / MAX(1, width))), @1 ];
    view.layer.mask = mask;
}

// Gives a label X's font times `factor`, remembering X's own.
static void SizeLabel(UILabel* label, CGFloat factor) {
    UIFont* ours = objc_getAssociatedObject(label, kOurFontKey);
    if (!ours || ![label.font isEqual:ours]) {
        objc_setAssociatedObject(label, kBaseFontKey, label.font, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIFont* base = objc_getAssociatedObject(label, kBaseFontKey) ?: label.font;
    UIFont* font = fabs(factor - 1) < 0.005 ? base : [base fontWithSize:base.pointSize * factor];
    if (![label.font isEqual:font]) {
        label.font = font;
    }
    objc_setAssociatedObject(label, kOurFontKey, font, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The card row a name line belongs to, if it is a tweet's own line in the
// home timeline or notifications with cards on (not a quoted tweet's).
static UITableViewCell* CardRowOf(UIView* line) {
    for (UIView* up = line.superview; up; up = up.superview) {
        if ([NSStringFromClass(up.class) containsString:@"Quoted"]) {
            return nil;
        }
        if ([up isKindOfClass:[UITableViewCell class]]) {
            NFBCardMemory* memory = objc_getAssociatedObject(up, kCardMemoryKey);
            return memory.active ? (UITableViewCell*)up : nil;
        }
    }
    return nil;
}

static BOOL InNestedReply(UITableViewCell* cell) {
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    return memory.active && memory.background.nested;
}

// X gives the small pieces at the right end of the name line (the "..."
// button) the row's own colour as a solid background, so they draw faster. On
// a reply's tinted inner box that is a white square behind the button.
static void ClearSolid(UIView* view, int depth) {
    if (depth > 3 || [view isKindOfClass:[UIImageView class]]) {
        return;
    }
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [[view.backgroundColor resolvedColorWithTraitCollection:view.traitCollection] getRed:&r green:&g blue:&b alpha:&a];
    if (a > 0.5) {
        view.backgroundColor = [UIColor clearColor];
        view.opaque = NO;
    }
    for (UIView* sub in view.subviews) {
        ClearSolid(sub, depth + 1);
    }
}

// The first few characters of a text as code points, for the dump.
static NSString* CodePoints(NSString* text) {
    NSMutableString* out = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN((NSUInteger)3, text.length); i++) {
        [out appendFormat:@"%04X ", [text characterAtIndex:i]];
    }
    return out;
}

static void ArrangeNameLine(UIView* line) {
    if (CGRectGetWidth(line.bounds) < 40) {
        return;
    }
    UITableViewCell* row = CardRowOf(line);
    if (!row) {
        return;
    }
    UILabel* alias = NFBAliasLabelOf(line);
    UILabel *name = nil, *handle = nil, *dot = nil, *time = nil;
    NSMutableArray<UILabel*>* unknown = [NSMutableArray array];
    for (UIView* sub in line.subviews) {
        if (![sub isKindOfClass:[UILabel class]]) {
            continue;
        }
        UILabel* label = (UILabel*)sub;
        if (label.tag == 0x4E46414C) {
            continue; // the alias label, shown or not
        }
        NSString* identifier = label.accessibilityIdentifier;
        if ([identifier isEqualToString:@"StatusFullname"]) {
            name = label;
        } else if ([identifier isEqualToString:@"StatusUsername"]) {
            handle = label;
        } else if ([identifier isEqualToString:@"StatusTimeStamp"]) {
            time = label;
        } else {
            NSString* text = CleanText(label.text);
            if ([text isEqualToString:@"·"] || [text isEqualToString:@"•"] || [text isEqualToString:@"∙"]) {
                dot = dot ?: label;
            } else if (text.length > 0) {
                [unknown addObject:label];
            }
        }
    }
    // Without X's identifiers: by look.
    BOOL byIdentifier = name != nil;
    for (UILabel* label in unknown) {
        NSString* text = CleanText(label.text);
        if (!name && IsBoldFont(objc_getAssociatedObject(label, kBaseFontKey) ?: label.font)) {
            name = label;
        } else if (!handle && [text hasPrefix:@"@"]) {
            handle = label;
        } else if (!time && ![text hasPrefix:@"@"]) {
            time = label;
        }
    }
    if (handle && CleanText(handle.text).length == 0) {
        handle = nil;
    }
    if (time && CleanText(time.text).length == 0) {
        time = nil;
    }
    if (!name || CleanText(name.text).length == 0) {
        return; // drawn some other way: leave it to X
    }
    objc_setAssociatedObject(line, kArrangedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat height = CGRectGetHeight(line.bounds);
    CGFloat lift = gStyle.nameGap;

    // The trailing pieces ("..." and friends): not labels, at the right end.
    CGFloat limit = CGRectGetWidth(line.bounds);
    for (UIView* sub in line.subviews) {
        if (![sub isKindOfClass:[UILabel class]] && !sub.hidden && CGRectGetWidth(sub.frame) > 0 &&
            CGRectGetMinX(sub.frame) > CGRectGetWidth(line.bounds) * 0.6) {
            limit = MIN(limit, CGRectGetMinX(sub.frame));
            ClearSolid(sub, 0);
        }
    }

    SizeLabel(name, gStyle.nameScale);
    if (handle) {
        SizeLabel(handle, gStyle.nameScale);
    }
    if (dot) {
        dot.hidden = YES;
    }
    // The time is only hidden by us in a reply of a thread card, and only
    // shown again if it was us who hid it.
    BOOL showTime = NO;
    if (time) {
        SizeLabel(time, 0.9);
        BOOL hideTime = InNestedReply(row);
        if (hideTime && !time.hidden) {
            time.hidden = YES;
            objc_setAssociatedObject(time, kHiddenTimeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (!hideTime && objc_getAssociatedObject(time, kHiddenTimeKey)) {
            time.hidden = NO;
            objc_setAssociatedObject(time, kHiddenTimeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        showTime = !time.hidden;
    }

    // One baseline for everything, the name's: a label draws its line of text
    // in the middle of its height, so each label's top follows from its font.
    CGFloat pixel = 1.0 / MAX(1.0, UIScreen.mainScreen.scale);
    CGFloat (^lineHeight)(UILabel*) = ^CGFloat(UILabel* label) {
        return ceil(label.font.lineHeight);
    };
    CGFloat nameTop = round((height - lineHeight(name)) / 2) - lift;
    CGFloat baseline = nameTop + (lineHeight(name) - name.font.lineHeight) / 2 + name.font.ascender;
    CGFloat (^top)(UILabel*) = ^CGFloat(UILabel* label) {
        CGFloat y = baseline - label.font.ascender - (lineHeight(label) - label.font.lineHeight) / 2;
        return round(y / pixel) * pixel;
    };
    CGFloat (^fit)(UILabel*) = ^CGFloat(UILabel* label) {
        return ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)].width);
    };

    // The time at the right end.
    CGFloat end = limit - 6;
    if (showTime) {
        CGFloat timeWidth = fit(time);
        time.frame = CGRectMake(limit - 6 - timeWidth, top(time), timeWidth, lineHeight(time));
        end = CGRectGetMinX(time.frame) - 8;
    }

    // Badges (verified mark and the like) that sat between the name and the handle.
    CGRect nameFrame = name.frame;
    CGFloat nameStart = CGRectGetMinX(nameFrame);
    NSMutableArray<UIView*>* badges = [NSMutableArray array];
    CGFloat badgesWidth = 0;
    CGFloat handleWasAt = handle ? CGRectGetMinX(handle.frame) : CGFLOAT_MAX;
    for (UIView* sub in line.subviews) {
        if ([sub isKindOfClass:[UILabel class]] || sub.hidden || CGRectGetWidth(sub.frame) <= 0) {
            continue;
        }
        CGRect frame = sub.frame;
        if (CGRectGetMinX(frame) >= CGRectGetMaxX(nameFrame) - 1 && CGRectGetMaxX(frame) <= handleWasAt + 1 &&
            CGRectGetMinX(frame) < limit) {
            [badges addObject:sub];
            badgesWidth += CGRectGetWidth(frame) + 3;
        }
    }

    // What the name can have: the handle gives way first (down to a stub,
    // X cuts it with "..."), then the alias, then the handle altogether.
    CGFloat nameWidth = fit(name);
    CGFloat handleWidth = handle ? fit(handle) : 0;
    CGFloat aliasWidth = alias ? fit(alias) : 0;
    const CGFloat handleGap = handle ? 4 : 0, aliasGap = alias ? 5 : 0;
    const CGFloat minimumName = 36, handleStub = 44;
    CGFloat fixed = end - nameStart - badgesWidth - handleGap - aliasGap;
    CGFloat room = fixed - handleWidth - aliasWidth;
    if (room < nameWidth && handleWidth > handleStub) {
        handleWidth = MAX(handleStub, handleWidth - (nameWidth - room));
        room = fixed - handleWidth - aliasWidth;
    }
    if (room < MIN(nameWidth, minimumName) && aliasWidth > 0) {
        aliasWidth = MAX(0, aliasWidth - (MIN(nameWidth, minimumName) - room));
        room = fixed - handleWidth - aliasWidth;
    }
    if (room < MIN(nameWidth, minimumName) && handleWidth > 0) {
        handleWidth = MAX(0, handleWidth - (MIN(nameWidth, minimumName) - room));
        room = fixed - handleWidth - aliasWidth;
    }
    CGFloat shownName = MAX(0, MIN(nameWidth, room));
    BOOL cut = shownName < nameWidth - 0.5;
    name.lineBreakMode = cut ? NSLineBreakByClipping : NSLineBreakByTruncatingTail;
    name.frame = CGRectMake(nameStart, nameTop, shownName, lineHeight(name));
    FadeEnd(name, cut);

    CGFloat middle = nameTop + lineHeight(name) / 2;
    CGFloat x = CGRectGetMaxX(name.frame) + 3;
    for (UIView* badge in badges) {
        CGRect frame = badge.frame;
        frame.origin.x = x;
        frame.origin.y = round(middle - CGRectGetHeight(frame) / 2);
        badge.frame = frame;
        x += CGRectGetWidth(frame) + 3;
    }
    if (alias) {
        alias.frame = CGRectMake(x, top(alias), aliasWidth, lineHeight(alias));
        alias.hidden = aliasWidth < 14;
        if (!alias.hidden) {
            x += aliasWidth + aliasGap;
        }
    }
    if (handle) {
        handle.lineBreakMode = NSLineBreakByTruncatingTail;
        handle.frame = CGRectMake(x + handleGap - 3, top(handle), handleWidth, lineHeight(handle));
        handle.hidden = handleWidth < 8;
    }
    gNameLineLog = [NSString stringWithFormat:@"byId=%d name=%.0f@%.0f handle=%@ time=%@ dot=%d alias=%d limit=%.0f width=%.0f baseline=%.1f",
                                              byIdentifier, shownName, nameStart,
                                              handle ? [NSString stringWithFormat:@"%.0f@%.0f(%@)", handleWidth,
                                                                                  CGRectGetMinX(handle.frame),
                                                                                  CodePoints(handle.text)]
                                                     : @"-",
                                              time ? [NSString stringWithFormat:@"%.0f@%.0f%@", CGRectGetWidth(time.frame),
                                                                                CGRectGetMinX(time.frame),
                                                                                time.hidden ? @"(hidden)" : @""]
                                                   : @"-",
                                              dot != nil, alias != nil, limit, CGRectGetWidth(line.bounds), baseline];
}

// StatusRowTweaks.x calls this after it has placed the alias, so the order on
// every layout is X, then the alias, then this.
void NFBArrangeNameLine(UIView* line) {
    ArrangeNameLine(line);
}

// MARK: The tweets on screen, for the settings preview
// The "Cards and text" page draws its preview from the tweets that were on
// screen in the home timeline: their names, text, pictures and threads. Only
// read from the views that are already there; nothing is asked of X's server.

static id ObjectFrom(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) {
        return nil;
    }
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.methodReturnType[0] != '@') {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void BiggestImage(UIView* view, int depth, UIImage** best, CGFloat* bestArea) {
    if (!view || depth > 8 || view.hidden) {
        return;
    }
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage* image = ((UIImageView*)view).image;
        CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
        if (image && area > *bestArea) {
            *best = image;
            *bestArea = area;
        }
    }
    for (UIView* sub in view.subviews) {
        BiggestImage(sub, depth + 1, best, bestArea);
    }
}

static NSString* TextIn(UIView* view, int depth) {
    if (!view || depth > 6 || view.hidden) {
        return nil;
    }
    if ([view isKindOfClass:[UILabel class]] && ((UILabel*)view).text.length > 0) {
        return ((UILabel*)view).text;
    }
    id text = ObjectFrom(view, @"text");
    if ([text isKindOfClass:[NSString class]] && [text length] > 0) {
        return text;
    }
    id attributed = ObjectFrom(view, @"attributedText");
    if ([attributed isKindOfClass:[NSAttributedString class]] && [attributed length] > 0) {
        return [attributed string];
    }
    for (UIView* sub in view.subviews) {
        NSString* found = TextIn(sub, depth + 1);
        if (found.length > 0) {
            return found;
        }
    }
    return view.accessibilityLabel.length > 0 && depth == 0 ? view.accessibilityLabel : nil;
}

NSArray<NSDictionary*>* NFBTimelineSamples(void) {
    UITableView* table = gHomeTable;
    NSMutableArray<NSDictionary*>* samples = [NSMutableArray array];
    if (!table) {
        return samples;
    }
    NSArray<UITableViewCell*>* cells =
        [table.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UITableViewCell* a, UITableViewCell* b) {
            return CGRectGetMinY(a.frame) < CGRectGetMinY(b.frame) ? NSOrderedAscending : NSOrderedDescending;
        }];
    for (UITableViewCell* cell in cells) {
        if (samples.count >= 6) {
            break;
        }
        UIView* status = FindView(cell.contentView, @"T1StandardStatusView", 0);
        UIView* author = ObjectFrom(status, @"visibleAuthorView");
        if (![author isKindOfClass:[UIView class]]) {
            continue;
        }
        NSString *name = nil, *handle = nil, *time = nil;
        for (UIView* sub in author.subviews) {
            if (![sub isKindOfClass:[UILabel class]]) {
                continue;
            }
            NSString* identifier = sub.accessibilityIdentifier;
            NSString* text = ((UILabel*)sub).text;
            if ([identifier isEqualToString:@"StatusFullname"]) {
                name = text;
            } else if ([identifier isEqualToString:@"StatusUsername"]) {
                handle = CleanText(text);
            } else if ([identifier isEqualToString:@"StatusTimeStamp"]) {
                time = text;
            }
        }
        if (CleanText(name).length == 0) {
            continue;
        }
        NSMutableDictionary* sample = [NSMutableDictionary dictionary];
        sample[@"name"] = name;
        if (handle.length > 0) {
            sample[@"handle"] = handle;
        }
        if (time.length > 0) {
            sample[@"time"] = time;
        }
        NSString* body = TextIn(ObjectFrom(status, @"visibleBodyTextView"), 0);
        if (body.length > 0) {
            sample[@"body"] = body.length > 280 ? [body substringToIndex:280] : body;
        }
        UIImage* face = nil;
        CGFloat faceArea = 0;
        BiggestImage(ObjectFrom(status, @"visibleAvatarView"), 0, &face, &faceArea);
        if (face) {
            sample[@"avatar"] = face;
        }
        UIImage* picture = nil;
        CGFloat pictureArea = 0;
        BiggestImage(ObjectFrom(status, @"visibleMediaForwardView"), 0, &picture, &pictureArea);
        if (picture && pictureArea >= 40 * 40) {
            sample[@"media"] = picture;
        }
        // "... reposted", above the tweet.
        UIView* context = FindView(status, @"SocialContext", 0);
        NSString* contextText = context ? TextIn(context, 0) : nil;
        if (contextText.length > 0 && contextText.length < 60) {
            sample[@"context"] = contextText;
        }
        sample[@"connector"] = @(ConnectorOf(cell));
        [samples addObject:sample];
    }
    return samples;
}

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

// With small media on, a scrolled photo strip never makes X shrink the avatar
// (X does that so wide carousels can pass under it; the strip is short and
// never reaches the avatar here). X's own transforms on the avatar are let
// through only when small media is off.
%hook T1TappableStatusFleetLineItemView

- (void)setTransform:(CGAffineTransform)transform {
    if (gOwnTransform || !gCompactOn) {
        %orig;
        return;
    }
    gAvatarShrinksKept++;
}

%end

// The same for the row's content view.
%hook UITableViewCellContentView

// UIKit puts the content view over the whole row on every layout, then X (or
// the hook on its row, below) took the room off again: the content changed
// size twice per layout, and the tweet inside was laid out again each time.
// The room is taken off right here, so the frame only ever has one value.
- (void)setFrame:(CGRect)frame {
    UIView* cell = ((UIView*)self).superview;
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        CGRect wanted = FrameWithRoom((UITableViewCell*)cell, frame);
        if (!CGRectEqualToRect(wanted, frame)) {
            gRoomInsets++;
            %orig(wanted);
            return;
        }
    }
    %orig;
}

- (void)setBackgroundColor:(UIColor*)color {
    UIView* cell = ((UIView*)self).superview;
    NFBCardMemory* memory = cell ? objc_getAssociatedObject(cell, kCardMemoryKey) : nil;
    if (memory.active && color) {
        CGFloat r = 0, g = 0, b = 0, alpha = 0;
        [color getRed:&r green:&g blue:&b alpha:&alpha];
        if (alpha > 0.01) {
            // Only kept clear: the row's colour is taken from the cell alone
            // (X may paint the two differently, and taking both would lay
            // the row out again on every pass).
            %orig([UIColor clearColor]);
            return;
        }
    }
    %orig;
}

%end

// X can lay the name line out again on its own; it is arranged again then,
// from StatusRowTweaks.x's hook on its layout (after the alias is placed).

%hook T1StandardStatusView

- (void)layoutSubviews {
    T1StandardStatusView* status = (T1StandardStatusView*)self;
    BOOL plain = [NSStringFromClass(object_getClass(self)) isEqualToString:@"T1StandardStatusView"];
    UIView* avatar = [status respondsToSelector:@selector(visibleAvatarView)] ? [status visibleAvatarView] : nil;
    UIView* author = [status respondsToSelector:@selector(visibleAuthorView)] ? [status visibleAuthorView] : nil;
    Unscale(avatar);
    %orig;
    // Quoted tweets and other kinds keep X's sizes.
    if (plain) {
        // First, so the thread line and the card below see the tweet as it ends up.
        NFBPlaceCornerMedia((UIView*)status);
        avatar = [status respondsToSelector:@selector(visibleAvatarView)] ? [status visibleAvatarView] : nil;
        author = [status respondsToSelector:@selector(visibleAuthorView)] ? [status visibleAuthorView] : nil;
        if (fabs(gStyle.avatarScale - 1) > 0.005 && CGRectGetWidth(avatar.bounds) > 20 &&
            CGRectGetWidth(avatar.bounds) < 80) {
            ScaleFrom(avatar, gStyle.avatarScale, CGPointMake(1, 0));
        }
        if (author) {
            ArrangeNameLine(author);
        }
        // A row is laid out before the tweet inside it: when the row's card
        // was set up, the avatar and the reply button still sat where the
        // row's last tweet had them (or the avatar was not scaled yet), so
        // the thread line and a reply's place were worked out from old
        // numbers, and X shows its own thread lines again right here. Now
        // that the tweet is in place, the card is set up once more.
        for (UIView* up = status.superview; up; up = up.superview) {
            if ([up isKindOfClass:[UITableViewCell class]]) {
                NFBCardMemory* memory = objc_getAssociatedObject(up, kCardMemoryKey);
                if (memory.active) {
                    ApplyCard((UITableViewCell*)up, ListKind(TableOf(up)));
                    if (author) {
                        ArrangeNameLine(author); // a reply's time is left out once the row knows it is one
                    }
                    if (memory.thread) {
                        // X's connectors lay themselves out after this and may
                        // add a line that was not there yet: once more when
                        // this layout pass is over.
                        __weak UITableViewCell* weakRow = (UITableViewCell*)up;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UITableViewCell* row = weakRow;
                            NFBCardMemory* later = row ? objc_getAssociatedObject(row, kCardMemoryKey) : nil;
                            if (later.active && later.thread) {
                                SetThreadLinesHidden(row, later, YES);
                            }
                        });
                    }
                }
                break;
            }
        }
    }
    UIView* actions = [self respondsToSelector:@selector(visibleInlineActionsView)]
                          ? [(T1StandardStatusView*)self visibleInlineActionsView]
                          : nil;
    if (!actions) {
        return;
    }
    DimActions(actions);
}

%end

// Tweet text comes from X's "content" font; a positive offset makes it larger,
// and X measures the rows with the same font, so the row grows with it.
%hook XFontCatalog

+ (UIFont*)contentFontWithOffset:(CGFloat)offset weight:(NSInteger)weight {
    if (fabs(gStyle.bodyStep) < 0.05) {
        return %orig;
    }
    gFontCalls++;
    return %orig(offset + gStyle.bodyStep, weight);
}

%end

// MARK: Pull to refresh
// 7.3.90-7.3.96 put a small card-coloured pill behind X's refresh spinner: a
// view of ours first inside the refresh control, then (7.3.96) beside it in
// the control's parent, placed again whenever the control was laid out, moved
// or shown. With it the spinner no longer showed, and in 7.3.96 the top bar
// moved down with the pull and showed X's logo. All of it is gone: nothing
// here adds to, moves or hooks the refresh control any more, and pulling to
// refresh is X's own again.
//
// What a pull looked like the moment the refresh started is still noted for
// the dump (read only, called from HeaderLogoLoading.x's hook), in case the
// top bar or the spinner is still wrong without the pill.

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
        // How far in a reply sits, as measured the last time the app ran.
        double savedIndent = [[NSUserDefaults standardUserDefaults] doubleForKey:kReplyIndentKey];
        if (gReplyIndent < 0 && savedIndent >= 15 && savedIndent <= 90) {
            gReplyIndent = savedIndent;
        }
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
    // Hooks on X's own classes whose methods were read from X's class list
    // (11.37) and not seen in a dump of this version: only where they exist.
    Class tfnCell = objc_getClass("TFNTableViewCell");
    if (tfnCell && class_getInstanceMethod(tfnCell, @selector(setHighlighted:animated:)) &&
        class_getInstanceMethod(tfnCell, @selector(layoutSubviews))) {
        %init(TFNCell);
        gCellHooked = YES;
        if (class_getInstanceMethod(tfnCell, NSSelectorFromString(@"contentFrame"))) {
            %init(TFNFrame);
        }
    }
    if (objc_getClass("TFNRoundedCornerView")) {
        %init(RoundedLines);
    }
    if (objc_getClass("ConversationConnectorView")) {
        %init(ConnectorLines);
    }
    Class statusCell = objc_getClass("T1StatusCell");
    Class rowAdapter = objc_getClass("T1StatusTableRowAdapter");
    Class connectors = objc_getClass("T1StandardStatusConversationConnectorsConfiguration");
    if (statusCell && rowAdapter && connectors &&
        class_getClassMethod(statusCell, NSSelectorFromString(@"cellLayoutForViewModel:options:account:layoutMetrics:withPreviousLayout:")) &&
        class_getInstanceMethod(rowAdapter, NSSelectorFromString(@"dataViewController:cellLayoutForItem:withOptions:previousLayout:atIndexPath:")) &&
        class_getClassMethod(connectors, NSSelectorFromString(@"connectorTypeForViewModel:anatomyFeatures:statusOptions:"))) {
        %init(ReplyIndent);
        gIndentHooked = YES;
    }
}
