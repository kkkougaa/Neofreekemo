//
//  Readability.x
//  NeoFreeBird
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"

// MARK: - Easier reading in the home timeline and notifications
// Each has its own switch:
//
//  - kemo_timeline_cards: every home timeline row sits on a rounded card with a
//    gap of page colour around it, so tweets read as separate pieces.
//  - kemo_notification_cards: the same for the notifications list. A
//    notification that gathers several people ("A and 6 others liked") gets two
//    more card edges peeking out under it, like a small pile. Replies and
//    mentions there can be pulled from right to left to answer them.
//  - kemo_dim_actions: the reply / repost / like / views row is faded, so the
//    numbers no longer pull the eye away from the text.
//  - kemo_bigger_text: tweet text is set a little larger.
//
// Added in 7.3.86. Not yet done: media beside the text and the short list of
// people when a pile is tapped (the shake dump now probes for both).
//
// The cards never change X's layout (moving views after X has laid them out
// made 7.3.76's small media jump back and forth). The row's content is only
// drawn a little smaller inside its card (the content view's sublayer
// transform), and the card itself is the cell's background view.
//
// The swipe only exists in the notifications list. On the home timeline a
// sideways drag stays X's (it changes tabs).

static NSString* const kCardsKey = @"kemo_timeline_cards";
static NSString* const kNoteCardsKey = @"kemo_notification_cards";
static NSString* const kDimKey = @"kemo_dim_actions";
static NSString* const kBiggerKey = @"kemo_bigger_text";

static const CGFloat kCardSide = 8.0;    // page colour left and right of a card
static const CGFloat kCardGap = 4.0;     // page colour above and below (half the gap between cards)
static const CGFloat kCardInner = 6.0;   // extra room between the card edge and the row's content
static const CGFloat kCardRadius = 16.0;
static const CGFloat kPileStep = 5.0;    // how far each card edge under a pile peeks out
static const CGFloat kDimAlpha = 0.45;
static const CGFloat kBiggerTextStep = 1.5;
static const CGFloat kReplyPull = 80.0;  // pull this far to answer

// Switches, read once and refreshed when settings change (the cell hook runs a lot).
static BOOL gCardsOn, gNoteCardsOn, gDimOn, gBiggerOn;

static void ReadSwitches(void) {
    gCardsOn = [BHTSettings boolForKey:kCardsKey];
    gNoteCardsOn = [BHTSettings boolForKey:kNoteCardsKey];
    gDimOn = [BHTSettings boolForKey:kDimKey];
    gBiggerOn = [BHTSettings boolForKey:kBiggerKey];
}

// For the shake dump.
static NSInteger gHomeCards = 0, gNoteCards = 0, gPiles = 0, gFontCalls = 0, gSwipeBegins = 0;
static NSString* gSwipeLog = @"(no swipe yet)";

NSString* NFBReadabilityDebugText(void) {
    return [NSString stringWithFormat:@"cards=%d noteCards=%d dim=%d bigger=%d homeCards=%ld noteCards=%ld "
                                      @"piles=%ld contentFontCalls=%ld swipes=%ld last=%@",
                                      gCardsOn, gNoteCardsOn, gDimOn, gBiggerOn, (long)gHomeCards,
                                      (long)gNoteCards, (long)gPiles, (long)gFontCalls, (long)gSwipeBegins,
                                      gSwipeLog];
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
@property (nonatomic, strong) UIView* card;
@property (nonatomic, strong) UIView* edge1;
@property (nonatomic, strong) UIView* edge2;
@property (nonatomic, assign) BOOL pile;
@end

@implementation NFBCardBackground

- (UIView*)makeCard {
    UIView* view = [UIView new];
    view.userInteractionEnabled = NO;
    view.layer.cornerRadius = kCardRadius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    return view;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        _edge2 = [self makeCard];
        _edge1 = [self makeCard];
        _card = [self makeCard];
        [self addSubview:_edge2];
        [self addSubview:_edge1];
        [self addSubview:_card];
    }
    return self;
}

- (void)setPaper:(UIColor*)paper page:(UIColor*)page {
    self.backgroundColor = page;
    UIColor* line = [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:0.10]
                                                                     : [UIColor colorWithWhite:0 alpha:0.08];
    }];
    for (UIView* view in @[ self.card, self.edge1, self.edge2 ]) {
        view.backgroundColor = paper;
        view.layer.borderColor = [line resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection*)previous {
    [super traitCollectionDidChange:previous];
    [self setPaper:self.card.backgroundColor page:self.backgroundColor];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat bottomRoom = self.pile ? kPileStep * 2 : 0;
    CGRect card = CGRectMake(kCardSide, kCardGap, CGRectGetWidth(bounds) - kCardSide * 2,
                             MAX(0, CGRectGetHeight(bounds) - kCardGap * 2 - bottomRoom));
    self.card.frame = card;
    self.edge1.hidden = !self.pile;
    self.edge2.hidden = !self.pile;
    if (self.pile) {
        self.edge1.frame = CGRectOffset(CGRectInset(card, 10, 0), 0, kPileStep);
        self.edge2.frame = CGRectOffset(CGRectInset(card, 20, 0), 0, kPileStep * 2);
        self.edge2.alpha = 0.6;
    }
}

@end

// What a cell looked like before it got a card, to put back when switched off.
@interface NFBCardMemory : NSObject
@property (nonatomic, strong) NFBCardBackground* background;
@property (nonatomic, strong) UIView* oldBackgroundView;
@property (nonatomic, strong) UIColor* oldCellColor;
@property (nonatomic, strong) UIColor* oldContentColor;
@property (nonatomic, assign) BOOL active;
@end

@implementation NFBCardMemory
@end

static const void* kCardMemoryKey = &kCardMemoryKey;

// The page between cards: a touch darker than the card in light mode, a touch
// lighter in dark mode.
static UIColor* PageColor(UIColor* paper) {
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        if (traits.userInterfaceStyle != UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.937 green:0.949 blue:0.957 alpha:1];
        }
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [[paper resolvedColorWithTraitCollection:traits] getRed:&r green:&g blue:&b alpha:&a];
        return [UIColor colorWithRed:MIN(1, r + 0.07) green:MIN(1, g + 0.07) blue:MIN(1, b + 0.08) alpha:1];
    }];
}

static UIColor* PaperColor(UITableViewCell* cell, UITableView* table) {
    for (UIColor* color in @[ cell.backgroundColor ?: [UIColor clearColor],
                              cell.contentView.backgroundColor ?: [UIColor clearColor],
                              table.backgroundColor ?: [UIColor clearColor] ]) {
        CGFloat r = 0, g = 0, b = 0, alpha = 0;
        [[color resolvedColorWithTraitCollection:cell.traitCollection] getRed:&r green:&g blue:&b alpha:&alpha];
        if (alpha > 0.5) {
            return color;
        }
    }
    return [UIColor systemBackgroundColor];
}

static void SetDividersHidden(UITableViewCell* cell, BOOL hidden) {
    for (UIView* view in cell.subviews) {
        if (IsDivider(view)) {
            view.hidden = hidden;
        }
    }
    for (UIView* view in cell.contentView.subviews) {
        if (IsDivider(view)) {
            view.hidden = hidden;
        }
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
}

static void ApplyCard(UITableViewCell* cell, NFBListKind kind) {
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    BOOL want = ((kind == NFBListHome && gCardsOn) || (kind == NFBListNotifications && gNoteCardsOn)) &&
                CGRectGetHeight(cell.bounds) >= 36 && CGRectGetWidth(cell.bounds) > 120;
    if (!want) {
        RemoveCard(cell, memory);
        return;
    }
    if (!memory) {
        memory = [NFBCardMemory new];
        objc_setAssociatedObject(cell, kCardMemoryKey, memory, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!memory.active) {
        UITableView* table = TableOf(cell);
        UIColor* paper = PaperColor(cell, table);
        memory.oldBackgroundView = cell.backgroundView;
        memory.oldCellColor = cell.backgroundColor;
        memory.oldContentColor = cell.contentView.backgroundColor;
        if (!memory.background) {
            memory.background = [[NFBCardBackground alloc] initWithFrame:cell.bounds];
        }
        [memory.background setPaper:paper page:PageColor(paper)];
        memory.active = YES;
    }
    if (cell.backgroundView != memory.background) {
        cell.backgroundView = memory.background;
    }
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    SetDividersHidden(cell, YES);

    // A notification that gathers several people is drawn as a little pile.
    BOOL pile = NO;
    if (kind == NFBListNotifications) {
        pile = CountViews(cell.contentView, @"TFNAvatarHeaderView", 2, 0) >= 2;
        if (pile) {
            gPiles++;
        }
        gNoteCards++;
    } else {
        gHomeCards++;
    }
    if (memory.background.pile != pile) {
        memory.background.pile = pile;
        [memory.background setNeedsLayout];
    }

    // Draw the row's content a little smaller so it sits inside the card,
    // leaving X's own layout untouched.
    CGFloat width = CGRectGetWidth(cell.contentView.bounds);
    CGFloat height = CGRectGetHeight(cell.contentView.bounds);
    CGFloat scale = MAX(0.85, (width - (kCardSide + kCardInner) * 2) / width);
    // A pile keeps its content clear of the peeking edges at the bottom.
    CGFloat lift = pile ? -kPileStep : 0;
    CATransform3D transform = CATransform3DMakeTranslation(0, lift, 0);
    transform = CATransform3DScale(transform, scale, scale, 1);
    if (height > 0) {
        cell.contentView.layer.sublayerTransform = transform;
    }
}

// MARK: Pull a notification to answer it

@interface NFBReplySwipe : UIPanGestureRecognizer
@property (nonatomic, weak) UITableViewCell* cell;
@property (nonatomic, strong) UIView* mark;
@property (nonatomic, assign) BOOL armed;
@end

@implementation NFBReplySwipe
@end

@interface NFBReplySwipeHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

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
    if (![gesture isKindOfClass:[NFBReplySwipe class]] || !gNoteCardsOn) {
        return NO;
    }
    NFBReplySwipe* swipe = (NFBReplySwipe*)gesture;
    UITableViewCell* cell = swipe.cell;
    if (!cell || ListKind(TableOf(cell)) != NFBListNotifications) {
        return NO;
    }
    // Right to left, and clearly sideways.
    CGPoint speed = [swipe velocityInView:cell];
    if (!(speed.x < 0 && fabs(speed.x) > fabs(speed.y) * 1.5)) {
        return NO;
    }
    return ReplyButton(cell) != nil;
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
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return NO;
}

- (void)setOffset:(CGFloat)offset for:(NFBReplySwipe*)swipe {
    UITableViewCell* cell = swipe.cell;
    CGAffineTransform move = CGAffineTransformMakeTranslation(offset, 0);
    cell.contentView.transform = move;
    NFBCardMemory* memory = objc_getAssociatedObject(cell, kCardMemoryKey);
    if (memory.active) {
        memory.background.card.transform = move;
    }
    UIView* mark = swipe.mark;
    CGFloat progress = MIN(1.0, -offset / kReplyPull);
    mark.alpha = progress;
    CGFloat scale = swipe.armed ? 1.15 : 0.6 + 0.4 * progress;
    mark.transform = CGAffineTransformMakeScale(scale, scale);
}

- (void)swiped:(NFBReplySwipe*)swipe {
    UITableViewCell* cell = swipe.cell;
    if (!cell) {
        return;
    }
    CGFloat dx = MIN(0, [swipe translationInView:cell].x);
    switch (swipe.state) {
        case UIGestureRecognizerStateBegan: {
            gSwipeBegins++;
            swipe.armed = NO;
            if (!swipe.mark) {
                UIImageSymbolConfiguration* config =
                    [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
                UIImageView* mark = [[UIImageView alloc]
                    initWithImage:[UIImage systemImageNamed:@"arrowshape.turn.up.left.fill" withConfiguration:config]];
                mark.contentMode = UIViewContentModeCenter;
                mark.tintColor = [UIColor whiteColor];
                mark.bounds = CGRectMake(0, 0, 40, 40);
                mark.layer.cornerRadius = 20;
                mark.userInteractionEnabled = NO;
                swipe.mark = mark;
            }
            swipe.mark.backgroundColor = CurrentAccentColor();
            swipe.mark.center = CGPointMake(CGRectGetWidth(cell.bounds) - kCardSide - 34, CGRectGetMidY(cell.bounds));
            swipe.mark.alpha = 0;
            [cell insertSubview:swipe.mark belowSubview:cell.contentView];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat shown = dx < -kReplyPull ? -kReplyPull + (dx + kReplyPull) * 0.3 : dx;
            BOOL armed = dx <= -kReplyPull;
            if (armed != swipe.armed) {
                swipe.armed = armed;
                if (armed && !NSProcessInfo.processInfo.isLowPowerModeEnabled) {
                    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid]
                        impactOccurredWithIntensity:0.8];
                }
            }
            [self setOffset:shown for:swipe];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            BOOL answer = swipe.armed && swipe.state == UIGestureRecognizerStateEnded;
            swipe.armed = NO;
            UIView* mark = swipe.mark;
            [UIView animateWithDuration:0.35
                delay:0
                usingSpringWithDamping:0.75
                initialSpringVelocity:0.5
                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                animations:^{
                    [self setOffset:0 for:swipe];
                    mark.alpha = 0;
                }
                completion:^(BOOL finished) {
                    [mark removeFromSuperview];
                }];
            if (answer) {
                UIView* button = ReplyButton(cell);
                BOOL pressed = PressReply(button);
                gSwipeLog = [NSString stringWithFormat:@"reply %@ via %@", pressed ? @"opened" : @"NOT opened",
                                                       button ? NSStringFromClass(button.class) : @"(no button)"];
            }
            break;
        }
        default:
            break;
    }
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
    swipe.delegate = [NFBReplySwipeHandler shared];
    [cell addGestureRecognizer:swipe];
    objc_setAssociatedObject(cell, kReplySwipeKey, swipe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: Hooks

%hook UITableViewCell

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

%hook T1StandardStatusView

- (void)layoutSubviews {
    %orig;
    UIView* actions = [self respondsToSelector:@selector(visibleInlineActionsView)]
                          ? [(T1StandardStatusView*)self visibleInlineActionsView]
                          : nil;
    if (!actions) {
        return;
    }
    if (gDimOn) {
        actions.alpha = kDimAlpha;
        objc_setAssociatedObject(actions, kDimmedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (objc_getAssociatedObject(actions, kDimmedKey)) {
        actions.alpha = 1.0;
        objc_setAssociatedObject(actions, kDimmedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

// Tweet text comes from X's "content" font; a positive offset makes it larger,
// and X measures the rows with the same font, so the row grows with it.
%hook XFontCatalog

+ (UIFont*)contentFontWithOffset:(CGFloat)offset weight:(NSInteger)weight {
    if (!gBiggerOn) {
        return %orig;
    }
    gFontCalls++;
    return %orig(offset + kBiggerTextStep, weight);
}

%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        ReadSwitches();
    });
    // Never the main queue here (7.3.86 hung on the splash screen, as 7.3.79 did):
    // X changes defaults from background threads during launch while the main
    // thread waits on them, and a main-queue observer makes that thread wait for
    // the main thread in turn. Reading four switches is safe on any thread.
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification* note) {
                                                      ReadSwitches();
                                                  }];
    %init;
}
