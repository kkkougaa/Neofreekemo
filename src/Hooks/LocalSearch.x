//
//  LocalSearch.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Search inside the loaded home timeline
// With "kemo_local_search" on, pulling the home timeline down well past the point
// where it refreshes opens a small search bar above the keyboard. Typing does
// nothing by itself; Return shows only the loaded tweets that contain every word
// (text, author name and handle, quoted and retweeted tweet included). Nothing is
// sent to X: it is a filter over the items the list already holds.
//
// While results are showing the list is frozen: whatever X wants the list to show
// meanwhile (a refresh, more tweets at the bottom) is kept aside and the results
// stay as they are. Closing the bar puts the latest full list back, at the tweet
// that was at the top before searching.
//
// The freeze is done in Timeline.x, where the list's sections are set
// (NFBLocalSearchHold); the pull is watched on the table's own pan gesture.
//
// 7.3.85: the pull is also watched from X's pull-to-refresh control, which
// sits inside the home list's scroll view, in case the list itself is never
// matched to the home timeline.

static NSString* const kSearchKey = @"kemo_local_search";
// How far the finger must travel down, starting with the list at its top, to
// open the bar. Measured on the finger rather than the list's offset: the
// list only gives way a little (rubber band), and once X starts refreshing it
// moves its own top inset, which made the old offset check almost unreachable.
static const CGFloat kPullToSearch = 170.0;

// For the shake dump.
static NSInteger gAttachedLists = 0;
static NSString* gSearchLog = @"(no pull yet)";
NSString* NFBLocalSearchDebugText(void) {
    return [NSString stringWithFormat:@"on=%d lists=%ld last=%@", [BHTSettings boolForKey:@"kemo_local_search"],
                                      (long)gAttachedLists, gSearchLog];
}
static const CGFloat kBarHeight = 44.0;

extern UIColor* CurrentAccentColor(void);
// Timeline.x
extern NSArray* NFBFilteredTimelineSections(TFNItemsDataViewController* controller, NSArray* sections);

@interface TFNItemsDataViewController (NFBLocalSearch)
- (void)setSections:(NSArray*)sections restoreScrollPosition:(BOOL)restoreScrollPosition;
@end

// The list showing results, what X last wanted it to show, and the results.
static __weak TFNItemsDataViewController* gController;
static NSArray* gHeld;
static NSArray* gShown;
static BOOL gApplying;
static NSString* gAnchorID;
static CGFloat gAnchorOffset;
// Called where the list's sections are set. nil: not involved. Otherwise the
// sections to hand to the list instead (the frozen results, or the list being
// put in place by the search itself).
NSArray* NFBLocalSearchHold(TFNItemsDataViewController* controller, NSArray* sections) {
    if (gApplying) {
        return sections;
    }
    if (gShown && controller == gController) {
        gHeld = sections;
        return gShown;
    }
    return nil;
}

// MARK: Text of a timeline item

// A zero-argument method returning an object, or nil. The view models are not
// documented, so nothing is called unless the runtime says it returns an object.
static id SafeObject(id object, const char* name) {
    if (!object) {
        return nil;
    }
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) {
        return nil;
    }
    char type[8] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != '@') {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void AppendText(NSMutableString* out, id value) {
    if ([value isKindOfClass:[NSAttributedString class]]) {
        value = [(NSAttributedString*)value string];
    }
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        [out appendString:value];
        [out appendString:@"\n"];
    }
}

static void CollectText(NSMutableString* out, id object, int depth) {
    static const char* const texts[] = {"text", "fullText", "displayText", "tweetText",
                                        "fromUserName", "fromUsername", "representedFromUserName",
                                        "fullName", "username"};
    for (size_t i = 0; i < sizeof(texts) / sizeof(texts[0]); i++) {
        AppendText(out, SafeObject(object, texts[i]));
    }
    id user = SafeObject(object, "fromUser");
    AppendText(out, SafeObject(user, "fullName"));
    AppendText(out, SafeObject(user, "username"));
    if (depth >= 2) {
        return;
    }
    static const char* const inner[] = {"representedStatus", "quotedStatus", "status", "displayStatus"};
    for (size_t i = 0; i < sizeof(inner) / sizeof(inner[0]); i++) {
        id status = SafeObject(object, inner[i]);
        if (status && status != object && ![status isKindOfClass:[NSString class]]) {
            CollectText(out, status, depth + 1);
        }
    }
}

static BOOL ItemMatches(id item, NSArray<NSString*>* words) {
    NSMutableString* text = [NSMutableString string];
    CollectText(text, unwrapDataViewItem(item), 0);
    if (text.length == 0) {
        return NO;
    }
    NSStringCompareOptions options =
        NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    for (NSString* word in words) {
        if ([text rangeOfString:word options:options].location == NSNotFound) {
            return NO;
        }
    }
    return YES;
}

static NSArray* MatchingSections(NSArray* sections, NSArray<NSString*>* words, NSUInteger* found,
                                 NSUInteger* scanned) {
    NSMutableArray* result = [NSMutableArray array];
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }
        NSMutableArray* kept = [NSMutableArray array];
        for (id item in (NSArray*)section) {
            (*scanned)++;
            if (ItemMatches(item, words)) {
                [kept addObject:item];
            }
        }
        if (kept.count > 0) {
            *found += kept.count;
            [result addObject:[kept copy]];
        }
    }
    return [result copy];
}

// MARK: Where the list was

static void CaptureAnchor(UITableView* table) {
    gAnchorID = nil;
    gAnchorOffset = 0;
    CGFloat topEdge = table.contentOffset.y + table.adjustedContentInset.top;
    CGFloat best = CGFLOAT_MAX;
    for (UITableViewCell* cell in table.visibleCells) {
        NSString* cellID = cell.accessibilityIdentifier;
        if (cellID.length > 8 && CGRectGetMaxY(cell.frame) > topEdge && CGRectGetMinY(cell.frame) < best) {
            best = CGRectGetMinY(cell.frame);
            gAnchorID = cellID;
            gAnchorOffset = best - topEdge;
        }
    }
}

static void RestoreAnchor(UITableView* table, NSArray* sections) {
    if (!gAnchorID) {
        return;
    }
    for (NSUInteger section = 0; section < sections.count; section++) {
        id items = sections[section];
        if (![items isKindOfClass:[NSArray class]]) {
            continue;
        }
        for (NSUInteger row = 0; row < [items count]; row++) {
            if ([[items[row] description] containsString:gAnchorID] &&
                section < (NSUInteger)table.numberOfSections &&
                row < (NSUInteger)[table numberOfRowsInSection:section]) {
                [table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]
                             atScrollPosition:UITableViewScrollPositionTop
                                     animated:NO];
                [table layoutIfNeeded];
                table.contentOffset = CGPointMake(table.contentOffset.x, table.contentOffset.y - gAnchorOffset);
                return;
            }
        }
    }
}

// MARK: The bar

@interface NFBLocalSearchBar : UIView <UITextFieldDelegate>
@property (nonatomic, weak) TFNItemsDataViewController* controller;
@property (nonatomic, strong) UITextField* field;
@property (nonatomic, strong) UILabel* count;
- (void)close;
@end

static __weak NFBLocalSearchBar* gBar;

@implementation NFBLocalSearchBar

- (instancetype)initWithController:(TFNItemsDataViewController*)controller {
    if ((self = [super initWithFrame:CGRectZero])) {
        _controller = controller;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.18;
        self.layer.shadowRadius = 12;
        self.layer.shadowOffset = CGSizeMake(0, 4);

        UIVisualEffectView* glass = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.layer.cornerRadius = kBarHeight / 2.0;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.layer.masksToBounds = YES;
        [self addSubview:glass];

        UIImageSymbolConfiguration* config =
            [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        UIImageView* icon = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:config]];
        icon.tintColor = [UIColor secondaryLabelColor];
        icon.contentMode = UIViewContentModeCenter;

        _field = [UITextField new];
        _field.delegate = self;
        _field.returnKeyType = UIReturnKeySearch;
        _field.enablesReturnKeyAutomatically = YES;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.font = [UIFont systemFontOfSize:16];
        _field.textColor = [UIColor labelColor];
        _field.tintColor = CurrentAccentColor();
        _field.placeholder = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_LOCAL_SEARCH_PLACEHOLDER"];

        _count = [UILabel new];
        _count.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
        _count.textColor = [UIColor secondaryLabelColor];
        [_count setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_count setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisHorizontal];

        UIButton* closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:config]
                     forState:UIControlStateNormal];
        closeButton.tintColor = [UIColor tertiaryLabelColor];
        closeButton.accessibilityLabel = @"Close";
        [closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

        UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, _field, _count, closeButton ]];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentFill;
        row.spacing = 8;
        [glass.contentView addSubview:row];

        [NSLayoutConstraint activateConstraints:@[
            [glass.topAnchor constraintEqualToAnchor:self.topAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor],
            [row.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:14],
            [row.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-6],
            [icon.widthAnchor constraintEqualToConstant:22],
            [closeButton.widthAnchor constraintEqualToConstant:36],
            [self.heightAnchor constraintEqualToConstant:kBarHeight],
        ]];
    }
    return self;
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField {
    [self search];
    return NO;
}

- (void)search {
    TFNItemsDataViewController* controller = self.controller;
    UITableView* table = (UITableView*)controller.tableView;
    NSMutableArray<NSString*>* words = [NSMutableArray array];
    for (NSString* word in [self.field.text
             componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (word.length > 0) {
            [words addObject:word];
        }
    }
    if (!controller || ![table isKindOfClass:[UITableView class]] || words.count == 0) {
        return;
    }

    // Always search the full list, not the results of the search before.
    BOOL showing = gShown && gController == controller;
    NSArray* base = showing ? gHeld : controller.sections;
    NSUInteger found = 0, scanned = 0;
    NSArray* results = MatchingSections(base, words, &found, &scanned);
    gSearchLog = [NSString stringWithFormat:@"search %lu words: %lu of %lu items in %lu sections",
                                            (unsigned long)words.count, (unsigned long)found,
                                            (unsigned long)scanned, (unsigned long)base.count];
    self.count.text = [NSString stringWithFormat:@"%lu", (unsigned long)found];
    if (found == 0) {
        // Nothing to show: leave the list as it is and say so with a shake.
        CAKeyframeAnimation* shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        shake.values = @[ @0, @-7, @6, @-4, @2, @0 ];
        shake.duration = 0.32;
        [self.layer addAnimation:shake forKey:@"nfbShake"];
        if ([BHTSettings boolForKey:@"kemo_haptics"]) {
            [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeWarning];
        }
        return;
    }

    if (!showing) {
        CaptureAnchor(table);
        gHeld = base;
    }
    gController = controller;
    gShown = results;
    gApplying = YES;
    [controller setSections:results restoreScrollPosition:NO];
    gApplying = NO;
    [table layoutIfNeeded];
    table.contentOffset = CGPointMake(table.contentOffset.x, -table.adjustedContentInset.top);
    [self.field resignFirstResponder];
    if ([BHTSettings boolForKey:@"kemo_haptics"]) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
}

// Back to the full list, as X last wanted it, at the tweet that was on top.
- (void)close {
    TFNItemsDataViewController* controller = gController;
    if (gShown && controller) {
        UITableView* table = (UITableView*)controller.tableView;
        NSArray* sections = NFBFilteredTimelineSections(controller, gHeld);
        gShown = nil;
        gApplying = YES;
        [controller setSections:sections restoreScrollPosition:NO];
        gApplying = NO;
        if ([table isKindOfClass:[UITableView class]]) {
            [table layoutIfNeeded];
            RestoreAnchor(table, sections);
        }
    }
    gShown = nil;
    gHeld = nil;
    gController = nil;
    gAnchorID = nil;

    [self.field resignFirstResponder];
    [UIView animateWithDuration:0.18
        animations:^{
            self.alpha = 0;
            self.transform = CGAffineTransformMakeTranslation(0, 12);
        }
        completion:^(BOOL finished) {
            [self removeFromSuperview];
        }];
}

@end

static void OpenSearch(TFNItemsDataViewController* controller) {
    NFBLocalSearchBar* existing = gBar;
    if (existing.superview) {
        if (existing.controller == controller) {
            [existing.field becomeFirstResponder];
            return;
        }
        [existing close];
    }
    UIView* host = [(UIView*)controller.tableView superview];
    if (!host) {
        return;
    }
    NFBLocalSearchBar* bar = [[NFBLocalSearchBar alloc] initWithController:controller];
    [host addSubview:bar];
    // Rides on the keyboard, and rests at the bottom of the list when it is away.
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.leadingAnchor constant:12],
        [bar.trailingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [bar.bottomAnchor constraintEqualToAnchor:host.keyboardLayoutGuide.topAnchor constant:-8],
    ]];
    gBar = bar;
    bar.alpha = 0;
    bar.transform = CGAffineTransformMakeTranslation(0, 12);
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.6
                        options:0
                     animations:^{
                         bar.alpha = 1;
                         bar.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
    [bar.field becomeFirstResponder];
}

// MARK: The pull

// A magnifier that grows in the gap above the list as the pull nears the
// distance, and fills with the accent colour once letting go will open the bar.
@interface NFBLocalSearchPull : NSObject
@property (nonatomic, strong) UIImageView* hint;
@property (nonatomic, assign) BOOL armed;
// The drag began with the list at its top; how far it has gone at most.
@property (nonatomic, assign) BOOL fromTop;
@property (nonatomic, assign) CGFloat farthest;
@end

@implementation NFBLocalSearchPull

+ (instancetype)shared {
    static NFBLocalSearchPull* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [NFBLocalSearchPull new];
    });
    return shared;
}

- (void)dropHint {
    UIView* hint = self.hint;
    self.hint = nil;
    self.armed = NO;
    [UIView animateWithDuration:0.15
        animations:^{
            hint.alpha = 0;
        }
        completion:^(BOOL finished) {
            [hint removeFromSuperview];
        }];
}

- (void)pan:(UIPanGestureRecognizer*)pan {
    UIScrollView* scroll = (UIScrollView*)pan.view;
    if (![scroll isKindOfClass:[UIScrollView class]] || ![BHTSettings boolForKey:kSearchKey]) {
        return;
    }
    CGFloat stretch = -(scroll.contentOffset.y + scroll.adjustedContentInset.top);

    if (pan.state == UIGestureRecognizerStateBegan) {
        self.fromTop = stretch >= -20.0;
        self.farthest = 0;
        return;
    }
    if (!self.fromTop) {
        return;
    }
    CGFloat pull = MAX(0, [pan translationInView:scroll].y);
    self.farthest = MAX(self.farthest, pull);

    if (pan.state == UIGestureRecognizerStateChanged) {
        CGFloat progress = (pull - kPullToSearch * 0.55) / (kPullToSearch * 0.45);
        if (progress <= 0) {
            if (self.hint) {
                [self dropHint];
            }
            return;
        }
        UIView* host = scroll.superview;
        if (!self.hint && host) {
            UIImageSymbolConfiguration* config =
                [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightBold];
            UIImageView* hint = [[UIImageView alloc]
                initWithImage:[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:config]];
            hint.contentMode = UIViewContentModeCenter;
            hint.bounds = CGRectMake(0, 0, 34, 34);
            hint.layer.cornerRadius = 17;
            [host addSubview:hint];
            self.hint = hint;
        }
        BOOL armed = pull >= kPullToSearch;
        CGFloat shown = MIN(progress, 1.0);
        self.hint.center = CGPointMake(CGRectGetMidX(scroll.frame),
                                       CGRectGetMinY(scroll.frame) + scroll.adjustedContentInset.top +
                                           MAX(24.0, stretch - 24.0));
        self.hint.alpha = shown;
        CGFloat scale = 0.6 + 0.4 * shown;
        self.hint.transform = CGAffineTransformMakeScale(scale, scale);
        self.hint.backgroundColor = armed ? CurrentAccentColor() : [UIColor secondarySystemFillColor];
        self.hint.tintColor = armed ? [UIColor whiteColor] : [UIColor secondaryLabelColor];
        if (armed != self.armed) {
            self.armed = armed;
            if (armed && [BHTSettings boolForKey:@"kemo_haptics"]) {
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid] impactOccurred];
            }
        }
        return;
    }

    if (pan.state == UIGestureRecognizerStateEnded) {
        BOOL open = self.armed && pull >= kPullToSearch * 0.8;
        [self dropHint];
        gSearchLog = [NSString stringWithFormat:@"pull %.0f of %.0f (farthest %.0f) open=%d", pull, kPullToSearch,
                                                self.farthest, open];
        if (!open) {
            return;
        }
        UIResponder* responder = scroll;
        Class listClass = objc_getClass("TFNItemsDataViewController");
        while (responder && !(listClass && [responder isKindOfClass:listClass])) {
            responder = responder.nextResponder;
        }
        if (responder) {
            OpenSearch((TFNItemsDataViewController*)responder);
        } else {
            gSearchLog = [gSearchLog stringByAppendingString:@" (no list found)"];
        }
        return;
    }

    if (pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
        [self dropHint];
    }
}

@end

// Watches one scroll view's pull, once.
static void AttachToScroll(UIScrollView* table, NSString* how) {
    static const void* kAttachedKey = &kAttachedKey;
    if (![table isKindOfClass:[UIScrollView class]] || objc_getAssociatedObject(table, kAttachedKey)) {
        return;
    }
    objc_setAssociatedObject(table, kAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gAttachedLists++;
    gSearchLog = [NSString stringWithFormat:@"attached via %@ to %@", how, NSStringFromClass(table.class)];
    [table.panGestureRecognizer addTarget:[NFBLocalSearchPull shared] action:@selector(pan:)];
}

// Called from Timeline.x for home timeline lists.
void NFBLocalSearchAttach(TFNItemsDataViewController* controller) {
    AttachToScroll((UIScrollView*)controller.tableView, @"list");
}

// The other way in: X's pull-to-refresh control sits inside the home list's
// scroll view, so wherever it shows on the home timeline, watch that scroll view.
@interface TFNPullToRefreshControl : UIView
@end

static void AttachFromRefresh(UIView* control) {
    if (![BHTSettings boolForKey:kSearchKey] || !control.window) {
        return;
    }
    UIScrollView* scroll = nil;
    for (UIView* view = control.superview; view; view = view.superview) {
        if ([view isKindOfClass:[UIScrollView class]]) {
            scroll = (UIScrollView*)view;
            break;
        }
    }
    if (!scroll) {
        return;
    }
    for (UIResponder* responder = scroll; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]] &&
            [NSStringFromClass([(UIViewController*)responder class]) containsString:@"HomeTimeline"]) {
            AttachToScroll(scroll, @"refresh control");
            return;
        }
    }
}

%hook TFNPullToRefreshControl

- (void)didMoveToWindow {
    %orig;
    AttachFromRefresh(self);
}

- (void)_setStatus:(unsigned long long)status fromScrolling:(BOOL)fromScrolling {
    %orig;
    AttachFromRefresh(self);
}

%end
