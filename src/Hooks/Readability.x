//
//  Readability.x
//  NeoFreeBird
//

#import <QuartzCore/QuartzCore.h>
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
// inner box. The spinner of pull to refresh sits on a small card-coloured pill.
//
// 7.3.93: X's white backing view behind each tweet is cleared while a row has
// a card (it showed as square corners over the round card); threads follow
// X's connector (1 up, 2 down); the reply line bends into each reply's avatar;
// floating cards meet without a seam; the refresh pill is placed from the pull.
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
static const CGFloat kDimAlpha = 0.45;
static const CGFloat kReplyPull = 80.0;  // pull this far to answer

// Switches and the card style, read once and refreshed when settings change
// (the cell hook runs a lot). gStamp changes whenever the style does, so cells
// know to redo their colours.
static BOOL gCardsOn, gNoteCardsOn, gDimOn, gCompactOn;
static NFBCardStyle gStyle;
static NSInteger gStamp = 0;

static void RefreshOnScreen(void);

static BOOL SameStyle(NFBCardStyle a, NFBCardStyle b) {
    return a.look == b.look && a.radius == b.radius && a.gap == b.gap && a.inner == b.inner &&
           a.bodyStep == b.bodyStep && a.nameScale == b.nameScale && a.avatarScale == b.avatarScale &&
           a.paper == b.paper && a.nameGap == b.nameGap;
}

static void ReadSwitches(void) {
    BOOL cards = [BHTSettings boolForKey:kCardsKey];
    BOOL notes = [BHTSettings boolForKey:kNoteCardsKey];
    BOOL dim = [BHTSettings boolForKey:kDimKey];
    gCompactOn = [BHTSettings boolForKey:@"kemo_compact_media"] &&
                 ![BHTSettings boolForKey:@"disable_sensitive_tweet_warnings"];
    NFBCardStyle style = NFBCardStyleCurrent();
    static NSArray* lastRGB;
    NSArray* rgb = [[NSUserDefaults standardUserDefaults] arrayForKey:NFBCardPaperRGBKey];
    BOOL changed = cards != gCardsOn || notes != gNoteCardsOn || dim != gDimOn || !SameStyle(style, gStyle) ||
                   !((rgb == nil && lastRGB == nil) || [rgb isEqual:lastRGB]);
    gCardsOn = cards;
    gNoteCardsOn = notes;
    gDimOn = dim;
    gStyle = style;
    lastRGB = rgb;
    if (changed) {
        gStamp++;
        dispatch_async(dispatch_get_main_queue(), ^{
            RefreshOnScreen();
        });
    }
}

// For the shake dump.
static NSInteger gHomeCards = 0, gNoteCards = 0, gPiles = 0, gThreadRows = 0, gFontCalls = 0, gSwipeBegins = 0,
                 gPills = 0;
static NSString* gSwipeLog = @"(no swipe yet)";
static NSInteger gAvatarShrinksKept = 0;
static NSString* gPillLog = @"(no pull yet)";

NSString* NFBReadabilityDebugText(void) {
    return [NSString stringWithFormat:@"cards=%d noteCards=%d dim=%d look=%ld r=%.0f gap=%.0f inner=%.0f body=%+.1f "
                                      @"name=%.2f avatar=%.2f paper=%ld homeCards=%ld noteCards=%ld piles=%ld "
                                      @"threadRows=%ld pills=%ld contentFontCalls=%ld swipes=%ld avatarShrinksKept=%ld last=%@ pill: %@",
                                      gCardsOn, gNoteCardsOn, gDimOn, (long)gStyle.look, gStyle.radius, gStyle.gap,
                                      gStyle.inner, gStyle.bodyStep, gStyle.nameScale, gStyle.avatarScale,
                                      (long)gStyle.paper, (long)gHomeCards, (long)gNoteCards, (long)gPiles,
                                      (long)gThreadRows, (long)gPills, (long)gFontCalls, (long)gSwipeBegins, (long)gAvatarShrinksKept, gSwipeLog,
                                      gPillLog];
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
@property (nonatomic, assign) NSInteger stamp;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) NSInteger thread; // last thread flags, to notice changes
@property (nonatomic, strong) NSHashTable<UIView*>* hiddenLines;
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
        HideLineLayers(cell.layer, cell, 0);
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
        if (!old) {
            objc_setAssociatedObject(table, kOldTableColorKey, table.backgroundColor ?: [UIColor clearColor],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        table.backgroundColor = page;
        objc_setAssociatedObject(table, kTablePageStampKey, @(gStamp), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (old) {
        NSNumber* separators = objc_getAssociatedObject(table, kOldSeparatorStyleKey);
        if (separators) {
            table.separatorStyle = (UITableViewCellSeparatorStyle)separators.integerValue;
            objc_setAssociatedObject(table, kOldSeparatorStyleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        table.backgroundColor = old;
        objc_setAssociatedObject(table, kOldTableColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static void SetThreadLinesHidden(UITableViewCell* cell, NFBCardMemory* memory, BOOL hidden) {
    if (hidden) {
        NSMutableArray<UIView*>* lines = [NSMutableArray array];
        FindThreadLines(cell.contentView, cell.contentView, 0, lines);
        if (!memory.hiddenLines) {
            memory.hiddenLines = [NSHashTable weakObjectsHashTable];
        }
        for (UIView* line in lines) {
            if (!line.hidden) {
                line.hidden = YES;
                [memory.hiddenLines addObject:line];
            }
        }
    } else if (memory.hiddenLines.count > 0) {
        for (UIView* line in memory.hiddenLines.allObjects) {
            line.hidden = NO;
        }
        [memory.hiddenLines removeAllObjects];
    }
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
// (the avatar's and the name line's scale) and the content view's sublayer
// transform are both left out.
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

// MARK: The reply line
// 7.3.94 (from the 7.3.93 screenshots): the line of a thread card starts under
// the first tweet's reply button and runs straight down; the replies are moved
// so their avatars sit on that line, and it stops just above and goes on just
// below each of them. "Show more replies" rows carry it straight through.
// X's own lines (and the dotted one of "show more") are hidden there.

static CGFloat gThreadX = -1; // the line, in row coordinates
static CGFloat gNestAvatarX = -1; // a reply's avatar centre as X lays it out (content view coordinates)

static UIView* AvatarOf(UITableViewCell* cell) {
    return FindView(cell.contentView, @"StatusFleetLineItemView", 0) ?: FindView(cell.contentView, @"AvatarHeaderView", 0);
}

static CGFloat ThreadX(void) {
    return gThreadX > 0 ? gThreadX : kCardSide + gStyle.inner + 78;
}

static void DrawThreadLine(UITableViewCell* cell, NFBCardBackground* background, NFBThreadFlags flags) {
    if (!flags) {
        background.threadLayer.path = nil;
        return;
    }
    CGFloat height = CGRectGetHeight(cell.bounds);
    UIView* avatar = AvatarOf(cell);
    CGRect face = avatar ? [avatar convertRect:avatar.bounds toView:cell] : CGRectNull;
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
        if (fabs(x - gThreadX) > 0.5) {
            // Replies already on screen were placed for the old line: again.
            gThreadX = x;
            for (UITableViewCell* other in TableOf(cell).visibleCells) {
                if (other != cell) {
                    [other setNeedsLayout];
                }
            }
        }
        if (down) {
            [path moveToPoint:CGPointMake(gThreadX, CGRectGetMaxY(from) + 3)];
            [path addLineToPoint:CGPointMake(gThreadX, height)];
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
// 7.3.86-7.3.93 drew every row smaller about its middle to fit inside its card,
// so the room above and below the content grew with the row's height (a tall
// tweet had a wide margin, a short one almost none). Now the list itself is
// told it has a margin on each side (its controller's additional safe area),
// which X lays its rows out within, so the content keeps X's own spacing and
// size. A row X did not lay out narrower (seen from its avatar) is still drawn
// smaller as before.

static const void* kOldSafeInsetsKey = &kOldSafeInsetsKey;

static UIViewController* OwnerOf(UIView* view) {
    for (UIResponder* responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController*)responder;
        }
    }
    return nil;
}

static void SetListMargin(UITableView* table, BOOL on) {
    UIViewController* owner = OwnerOf(table);
    if (!owner) {
        return;
    }
    NSValue* old = objc_getAssociatedObject(owner, kOldSafeInsetsKey);
    UIEdgeInsets base = old ? old.UIEdgeInsetsValue : owner.additionalSafeAreaInsets;
    UIEdgeInsets wanted = base;
    if (on) {
        CGFloat margin = kCardSide + gStyle.inner;
        wanted.left += margin;
        wanted.right += margin;
    }
    if (UIEdgeInsetsEqualToEdgeInsets(owner.additionalSafeAreaInsets, wanted)) {
        return;
    }
    if (on && !old) {
        objc_setAssociatedObject(owner, kOldSafeInsetsKey, [NSValue valueWithUIEdgeInsets:base],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!on) {
        objc_setAssociatedObject(owner, kOldSafeInsetsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Not from inside a row's layout pass.
    __weak UIViewController* weakOwner = owner;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakOwner.additionalSafeAreaInsets = wanted;
    });
}

// MARK: Putting a card on a row

static void ApplyCard(UITableViewCell* cell, NFBListKind kind) {
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    UITableView* table = TableOf(cell);
    BOOL listOn = CardsOnFor(kind);
    NFBThreadFlags flags = (listOn && kind == NFBListHome) ? ThreadFlags(table, cell) : 0;
    BOOL want = listOn && CGRectGetWidth(cell.bounds) > 120 &&
                (CGRectGetHeight(cell.bounds) >= 36 || (flags & NFBThreadUp));
    if (!want) {
        RemoveCard(cell, memory);
        if (!listOn && kind != NFBListOther) {
            SetTablePage(table, nil);
            SetListMargin(table, NO);
        }
        return;
    }
    if (!memory) {
        memory = [NFBCardMemory new];
        objc_setAssociatedObject(cell, kCardMemoryKey, memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!memory.active) {
        memory.xPaper = XPaperColor(cell, table);
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
    if (memory.stamp != gStamp) {
        memory.stamp = gStamp;
        UIColor* paper = NFBCardPaperColor(gStyle, memory.xPaper, CurrentAccentColor());
        UIColor* page = NFBCardPageColor(paper);
        [memory.background setPaper:paper page:page];
        if (!memory.highlight) {
            memory.highlight = [[NFBCardBackground alloc] initWithFrame:cell.bounds];
        }
        [memory.highlight setPaper:NFBCardBlend(paper, [UIColor labelColor], 0.07) page:page];
        NSNumber* tableStamp = objc_getAssociatedObject(table, kTablePageStampKey);
        if (tableStamp.integerValue != gStamp || !tableStamp) {
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

    // Draw the row's content smaller so it sits inside the card (or inside the
    // inner box for a reply), leaving X's own layout untouched.
    CGFloat width = CGRectGetWidth(cell.contentView.bounds);
    CGFloat height = CGRectGetHeight(cell.contentView.bounds);
    if (width <= 0 || height <= 0) {
        return;
    }
    SetListMargin(table, YES);
    UIView* contentView = cell.contentView;
    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    CGFloat originX = CGRectGetMinX(contentView.frame);
    CGFloat margin = kCardSide + gStyle.inner;
    // Did X lay this row out inside the margin? Its avatar (or, for a row
    // without one, the content view itself) tells.
    UIView* avatar = AvatarOf(cell);
    CGRect face = PlainRectInCell(avatar, cell);
    BOOL fits = originX >= margin - 1 ||
                (!CGRectIsNull(face) && CGRectGetMinX(face) >= margin + (kind == NFBListHome ? 12 : 50));
    CATransform3D transform = CATransform3DIdentity;
    if (nested) {
        // Move the reply so its avatar sits on the thread line, and make it
        // small enough to fit the inner box. All in content view coordinates.
        CGFloat lineX = ThreadX() - originX;
        CGFloat avatarX = !CGRectIsNull(face) ? CGRectGetMidX(face) - originX
                                               : (gNestAvatarX > 0 ? gNestAvatarX : (fits ? 36 : margin + 36));
        if (!CGRectIsNull(face)) {
            gNestAvatarX = avatarX;
        }
        CGFloat leftRoom = MAX(16, avatarX - 20);
        CGFloat contentRight = width - leftRoom;
        CGFloat boxRight = cellWidth - kCardSide - 8 - originX;
        CGFloat scale = MAX(0.6, MIN(1, (boxRight - 6 - lineX) / MAX(1, contentRight - avatarX)));
        CGFloat shift = lineX - width / 2 - scale * (avatarX - width / 2);
        transform = CATransform3DScale(CATransform3DMakeTranslation(shift, 0, 0), scale, scale, 1);
        // Measure where the avatar really landed and correct (its own scale and
        // anything X adds make the sum above slightly off: 7.3.95 lines bent).
        if (avatar) {
            contentView.layer.sublayerTransform = transform;
            CGFloat landed = CGRectGetMidX([avatar convertRect:avatar.bounds toView:cell]);
            CGFloat delta = ThreadX() - landed;
            if (fabs(delta) > 0.25) {
                shift += delta;
                transform = CATransform3DScale(CATransform3DMakeTranslation(shift, 0, 0), scale, scale, 1);
            }
        }
        background.nestLeft = ThreadX() - 22 * scale - 8;
    } else if (!fits) {
        CGFloat scale = MAX(0.8, (cellWidth - margin * 2) / MAX(1, width));
        transform = CATransform3DMakeScale(scale, scale, 1);
    }
    if (!CATransform3DEqualToTransform(contentView.layer.sublayerTransform, transform)) {
        contentView.layer.sublayerTransform = transform;
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

- (void)setOffset:(CGFloat)offset {
    UITableViewCell* cell = self.cell;
    CGAffineTransform move = CGAffineTransformMakeTranslation(offset, 0);
    cell.contentView.transform = move;
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    if (memory.active) {
        for (UIView* piece in memory.background.subviews) {
            piece.transform = move;
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        memory.background.threadLayer.affineTransform = move;
        [CATransaction commit];
    }
    UIView* mark = self.mark;
    CGFloat progress = MIN(1.0, -offset / kReplyPull);
    mark.alpha = progress;
    CGFloat scale = self.armed ? 1.15 : 0.5 + 0.5 * progress;
    // The mark rides a little behind the card's edge until it is fully shown.
    mark.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale),
                                             CGAffineTransformMakeTranslation((1 - progress) * 24, 0));
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
        [UIView animateWithDuration:0.18
                         animations:^{
                             [self setOffset:shown];
                         }];
        return;
    }
    [self setOffset:shown];
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
    [UIView animateWithDuration:0.42
        delay:0
        usingSpringWithDamping:0.78
        initialSpringVelocity:0.4
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:^{
            [self setOffset:0];
            mark.alpha = 0;
        }
        completion:^(BOOL finished) {
            if (finished) {
                [mark removeFromSuperview];
            }
        }];
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

%hook UITableViewCell

// Coming back from a tweet, X unhighlights the row with an animation and
// UIKit shows its separator and X its white backing meanwhile, without a
// layout pass: square corners and a thin line flashed (7.3.94). Keep them off.
// X paints a row white again while it animates back from a tweet (7.3.95: the
// plain timeline showed for a moment). A row with a card stays clear.
- (void)setBackgroundColor:(UIColor*)color {
    NFBCardMemory* memory = objc_getAssociatedObject(self, kCardMemoryKey);
    if (memory.active && color) {
        CGFloat r = 0, g = 0, b = 0, alpha = 0;
        [color getRed:&r green:&g blue:&b alpha:&alpha];
        if (alpha > 0.01) {
            %orig([UIColor clearColor]);
            return;
        }
    }
    %orig;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    NFBCardMemory* memory = objc_getAssociatedObject(self, kCardMemoryKey);
    if (memory.active) {
        SetDividersHidden((UITableViewCell*)self, YES);
        SetBackingCleared((UITableViewCell*)self, memory, YES);
    }
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    NFBCardMemory* memory = objc_getAssociatedObject(self, kCardMemoryKey);
    if (memory.active) {
        SetDividersHidden((UITableViewCell*)self, YES);
        SetBackingCleared((UITableViewCell*)self, memory, YES);
    }
}

- (void)layoutSubviews {
    %orig;
    if (!gCardsOn && !gNoteCardsOn && !objc_getAssociatedObject(self, kCardMemoryKey)) {
        return;
    }
    UITableViewCell* cell = (UITableViewCell*)self;
    NFBListKind kind = ListKind(TableOf(cell));
    ApplyCard(cell, kind);
    if (kind == NFBListNotifications && gNoteCardsOn) {
        AttachReplySwipe(cell);
    }
}

%end

static const void* kDimmedKey = &kDimmedKey;

// The avatar and the name line can be drawn larger (chosen on the settings
// page). X's layout is left as it is: the views are scaled after X has placed
// them. The avatar grows toward the left margin and down (its top right corner
// stays put, keeping its distance to the name); the name line grows from its
// left middle. Before X lays the row out again the scale is taken off, so X
// never sets a frame on a scaled view.
static const void* kScaledKey = &kScaledKey;
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
// TTAStatusAuthorView lays out separate UILabels (7.3.95 dump): the name
// (semibold), the @handle, a "·", and the time; the "..." button is a
// TFNDismissButton in a screenshot container at its right end. 7.3.89-7.3.95
// scaled the whole view, which pushed that button off the card. Now nothing is
// scaled: the labels get a larger font, and are placed again after X:
//  - the time, a little smaller, at the right end just left of the button
//    (left out in replies inside a thread card),
//  - the handle right after the name, the "·" hidden,
//  - a name too long for what is left cut and faded at its end.
// The line moves up by the chosen gap (only the labels and badges, not the button).

static const void* kBaseFontKey = &kBaseFontKey;   // X's own font for a label
static const void* kOurFontKey = &kOurFontKey;     // the font we last gave it
static const void* kArrangedKey = &kArrangedKey;   // the line was arranged by us
static const void* kHiddenTimeKey = &kHiddenTimeKey;

static BOOL IsBoldFont(UIFont* font) {
    NSString* name = font.fontName;
    return (font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) || [name containsString:@"Semibold"] ||
           [name containsString:@"Bold"] || [name containsString:@"Heavy"];
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

static void ArrangeNameLine(UIView* line) {
    if (CGRectGetWidth(line.bounds) < 40) {
        return;
    }
    UITableViewCell* row = CardRowOf(line);
    if (!row) {
        return;
    }
    NSMutableArray<UILabel*>* labels = [NSMutableArray array];
    UILabel *name = nil, *handle = nil, *dot = nil, *time = nil;
    for (UIView* sub in line.subviews) {
        if (![sub isKindOfClass:[UILabel class]]) {
            continue;
        }
        UILabel* label = (UILabel*)sub;
        NSString* text = [label.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (text.length == 0) {
            continue;
        }
        [labels addObject:label];
        if (!name && IsBoldFont(objc_getAssociatedObject(label, kBaseFontKey) ?: label.font)) {
            name = label;
        } else if (!handle && [text hasPrefix:@"@"]) {
            handle = label;
        } else if (!dot && ([text isEqualToString:@"·"] || [text isEqualToString:@"•"])) {
            dot = label;
        } else if (!time) {
            time = label;
        }
    }
    if (!name || !time) {
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
        }
    }

    SizeLabel(name, gStyle.nameScale);
    if (handle) {
        SizeLabel(handle, gStyle.nameScale);
    }
    SizeLabel(time, 0.9);
    BOOL hideTime = InNestedReply(row);
    time.hidden = hideTime;
    objc_setAssociatedObject(time, kHiddenTimeKey, hideTime ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (dot) {
        dot.hidden = YES;
    }

    CGFloat (^lineHeight)(UILabel*) = ^CGFloat(UILabel* label) {
        return ceil(label.font.lineHeight);
    };
    CGFloat (^top)(UILabel*) = ^CGFloat(UILabel* label) {
        return round((height - lineHeight(label)) / 2) - lift;
    };

    // The time at the right end.
    CGFloat timeWidth = ceil([time sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)].width);
    CGRect timeFrame = CGRectMake(limit - 6 - timeWidth, top(time), timeWidth, lineHeight(time));
    time.frame = timeFrame;
    CGFloat end = hideTime ? limit - 6 : CGRectGetMinX(timeFrame) - 8;

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

    CGFloat nameWidth = ceil([name sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)].width);
    CGFloat handleWidth = handle ? ceil([handle sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)].width) : 0;
    CGFloat handleGap = handle ? 4 : 0;
    CGFloat room = end - nameStart - badgesWidth - handleGap - handleWidth;
    const CGFloat minimumName = 36;
    if (room < minimumName && handle) {
        // The handle gives way first (X truncates it with "...").
        handleWidth = MAX(0, handleWidth - (minimumName - room));
        room = minimumName;
    }
    CGFloat shownName = MAX(0, MIN(nameWidth, room));
    BOOL cut = shownName < nameWidth - 0.5;
    name.lineBreakMode = cut ? NSLineBreakByClipping : NSLineBreakByTruncatingTail;
    name.frame = CGRectMake(nameStart, top(name), shownName, lineHeight(name));
    FadeEnd(name, cut);

    CGFloat x = CGRectGetMaxX(name.frame) + 3;
    for (UIView* badge in badges) {
        CGRect frame = badge.frame;
        frame.origin.x = x;
        frame.origin.y = round((height - CGRectGetHeight(frame)) / 2) - lift;
        badge.frame = frame;
        x += CGRectGetWidth(frame) + 3;
    }
    if (handle) {
        handle.lineBreakMode = NSLineBreakByTruncatingTail;
        handle.frame = CGRectMake(x + handleGap - 3, top(handle), handleWidth, lineHeight(handle));
        handle.hidden = handleWidth < 8;
    }
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

- (void)setBackgroundColor:(UIColor*)color {
    UIView* cell = ((UIView*)self).superview;
    NFBCardMemory* memory = cell ? objc_getAssociatedObject(cell, kCardMemoryKey) : nil;
    if (memory.active && color) {
        CGFloat r = 0, g = 0, b = 0, alpha = 0;
        [color getRed:&r green:&g blue:&b alpha:&alpha];
        if (alpha > 0.01) {
            %orig([UIColor clearColor]);
            return;
        }
    }
    %orig;
}

%end

// X can lay the name line out again on its own; arrange it again then.
%hook TTAStatusAuthorView

- (void)layoutSubviews {
    %orig;
    ArrangeNameLine((UIView*)self);
}

%end

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
        avatar = [status respondsToSelector:@selector(visibleAvatarView)] ? [status visibleAvatarView] : nil;
        author = [status respondsToSelector:@selector(visibleAuthorView)] ? [status visibleAuthorView] : nil;
        if (fabs(gStyle.avatarScale - 1) > 0.005 && CGRectGetWidth(avatar.bounds) > 20 &&
            CGRectGetWidth(avatar.bounds) < 80) {
            ScaleFrom(avatar, gStyle.avatarScale, CGPointMake(1, 0));
        }
        if (author) {
            ArrangeNameLine(author);
        }
        // X shows its own thread line again when it lays the tweet out (after
        // the row): hide it again in thread cards.
        for (UIView* up = status.superview; up; up = up.superview) {
            if ([up isKindOfClass:[UITableViewCell class]]) {
                NFBCardMemory* memory = objc_getAssociatedObject(up, kCardMemoryKey);
                if (memory.active && memory.thread) {
                    SetThreadLinesHidden((UITableViewCell*)up, memory, YES);
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

// MARK: The pull to refresh pill
// In a list with cards, X's refresh spinner (or the paws that stand in for it
// on the home timeline) sits on a small card-coloured pill instead of floating
// over the page. The pill fades in as the list is pulled.

@interface TFNPullToRefreshControl : UIView
@end

static const NSInteger kPillTag = 0x4E465050;

static UIView* FindSpinner(UIView* view, int depth) {
    if (depth > 8) {
        return nil;
    }
    for (UIView* sub in view.subviews) {
        if (sub.tag == kPillTag) {
            continue;
        }
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

// The refresh control of a list: among the list's own subviews.
static UIView* RefreshControlIn(UIScrollView* scroll) {
    Class cls = NSClassFromString(@"TFNPullToRefreshControl");
    for (UIView* sub in scroll.subviews) {
        if ((cls && [sub isKindOfClass:cls]) || [NSStringFromClass(sub.class) containsString:@"RefreshControl"]) {
            return sub;
        }
    }
    return nil;
}

// The pill lives beside the control (just under it in its superview), not
// inside it: 7.3.93-7.3.95 put it in the control's subviews, which X and the
// paws code look through.
static const void* kPillKey = &kPillKey;

static void LayoutPill(UIView* control) {
    UIView* pill = objc_getAssociatedObject(control, kPillKey);
    UITableView* table = TableOf(control);
    NFBListKind kind = ListKind(table);
    if (kind == NFBListOther) {
        // The control may sit outside the list (7.3.94 dump: no list found);
        // its controllers tell which screen it is on.
        for (UIResponder* responder = control.nextResponder; responder; responder = responder.nextResponder) {
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
    }
    UIView* spinner = FindSpinner(control, 0);
    if (!CardsOnFor(kind) || !spinner) {
        pill.hidden = YES;
        if (kind != NFBListOther) {
            gPillLog = [NSString stringWithFormat:@"no pill: kind=%ld table=%@ spinner=%@ control=%@ in %@", (long)kind,
                                                  table ? @"yes" : @"no",
                                                  spinner ? NSStringFromClass(spinner.class) : @"none",
                                                  NSStringFromCGRect(control.frame),
                                                  NSStringFromClass(control.superview.class)];
        }
        return;
    }
    UIView* host = control.superview;
    if (!host) {
        return;
    }
    if (![pill isKindOfClass:[NFBCardView class]]) {
        pill = [NFBCardView new];
        pill.tag = kPillTag;
        pill.userInteractionEnabled = NO;
        objc_setAssociatedObject(control, kPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gPills++;
    }
    if (pill.superview != host) {
        [pill removeFromSuperview];
        [host insertSubview:pill belowSubview:control];
    }
    NFBCardView* card = (NFBCardView*)pill;
    card.hidden = NO;

    NFBCardStyle style = gStyle;
    card.style = style;
    // Room for the paws (84 x 36) when they run, else for the spinner alone.
    BOOL paws = NO;
    for (UIView* sub in spinner.subviews) {
        if (CGRectGetWidth(sub.bounds) > 60) {
            paws = YES;
        }
    }
    CGSize size = paws ? CGSizeMake(104, 46) : CGSizeMake(56, 36);
    card.radiusOverride = size.height / 2;
    UIColor* xPaper = (table ? objc_getAssociatedObject(table, kOldTableColorKey) : nil) ?: [UIColor systemBackgroundColor];
    card.backgroundColor = NFBCardPaperColor(style, xPaper, CurrentAccentColor());
    CGPoint center = [spinner.superview convertPoint:spinner.center toView:control];
    CGPoint centerInHost = [spinner.superview convertPoint:spinner.center toView:host];
    card.bounds = CGRectMake(0, 0, size.width, size.height);
    card.center = centerInHost;
    // Fade in with the pull: fully there once the control shows the whole pill.
    CGFloat shown = CGRectGetMaxY(control.bounds) - (center.y - size.height / 2);
    card.alpha = MAX(0, MIN(1, shown / size.height));
    if ([spinner isKindOfClass:[UIActivityIndicatorView class]] && ((UIActivityIndicatorView*)spinner).isAnimating) {
        card.alpha = 1;
    }
    card.alpha *= control.hidden ? 0 : control.alpha;
    gPillLog = [NSString stringWithFormat:@"pill alpha=%.2f at %@ spinner=%@", card.alpha,
                                          NSStringFromCGPoint(center), NSStringFromClass(spinner.class)];
}

%hook TFNPullToRefreshControl

- (void)layoutSubviews {
    %orig;
    LayoutPill(self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    if (gCardsOn || gNoteCardsOn) {
        LayoutPill(self);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    UIView* pill = objc_getAssociatedObject(self, kPillKey);
    if (hidden) {
        pill.hidden = YES;
    } else if (gCardsOn || gNoteCardsOn) {
        LayoutPill(self);
    }
}

%end

// 7.3.93 also hooked -[UITableView setContentOffset:] to place the pill while
// pulling. UITableView does not implement that method itself, so the hook
// added one that skipped later hooks on UIScrollView's (Timeline.x keeps the
// reading position with one): it is gone.

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
