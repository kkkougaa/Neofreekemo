//
//  SensitiveToggle.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Core/BHTEvents.h"
#import "Settings/ModernSettingsPageViewController.h"

// MARK: - NSFW mode row in the side drawer
// A row appended to the drawer's menu list (after Profile, Lists, Communities...)
// that flips the same disable_sensitive_tweet_warnings setting as the settings
// page. Off is the gray bird icon; on is the accent-colored eggplant icon with its
// pink blush kept. Icon layers: badge (tinted), art (white), blush (original colors).
//
// The drawer is SwiftUI (TwitterDash.DashHostingController): its menu is a
// collection view of SwiftUI cells, with no UILabels to copy a style from, so the
// row uses fixed metrics that match the other rows.

static NSString* const kSensitiveKey = @"disable_sensitive_tweet_warnings";
static const CGFloat kIconSize = 28.0;
static const NSInteger kRowTag = 0x4e464231;

static UIImage* ToggleImage(NSString* name) {
    NSURL* url = [[BHTBundle sharedBundle] pathForFile:name];
    UIImage* image = url ? [UIImage imageWithContentsOfFile:url.path] : nil;
    if (!image.CGImage) {
        return nil;
    }
    return [UIImage imageWithCGImage:image.CGImage
                               scale:3.0
                         orientation:UIImageOrientationUp];
}

// MARK: Icon

@interface NFBSensitiveIcon : UIView
@property (nonatomic, strong) UIImageView* badgeView;
@property (nonatomic, strong) UIImageView* artView;
@property (nonatomic, strong) UIImageView* blushView;
- (void)applyState;
- (void)toggle;
@end

@implementation NFBSensitiveIcon

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        _badgeView = [self layerView];
        _artView = [self layerView];
        _blushView = [self layerView];
        [self applyState];
    }
    return self;
}

- (UIImageView*)layerView {
    UIImageView* view = [[UIImageView alloc] initWithFrame:self.bounds];
    view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:view];
    return view;
}

- (void)applyState {
    BOOL on = [BHTSettings boolForKey:kSensitiveKey];
    NSString* prefix = on ? @"nfb_sens_on" : @"nfb_sens_off";

    self.badgeView.image = [ToggleImage([prefix stringByAppendingString:@"_badge.png"])
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.badgeView.tintColor = on ? CurrentAccentColor() : [UIColor systemGrayColor];
    self.artView.image = [ToggleImage([prefix stringByAppendingString:@"_art.png"])
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.artView.tintColor = [UIColor whiteColor];
    self.blushView.image =
        on ? ToggleImage([prefix stringByAppendingString:@"_blush.png"]) : nil;
    // Accent changes re-tint the badge through this registry; gray must stay gray.
    BHTMarkAccentTintedIcon(self.badgeView, on);
}

- (void)toggle {
    BOOL on = ![BHTSettings boolForKey:kSensitiveKey];
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kSensitiveKey];

    [[[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];

    // Squash, swap the artwork at the bottom of the squash, then spring back.
    [UIView animateWithDuration:0.08
        delay:0
        options:UIViewAnimationOptionCurveEaseIn |
                UIViewAnimationOptionAllowUserInteraction
        animations:^{
            self.transform = CGAffineTransformMakeScale(0.7, 0.7);
        }
        completion:^(BOOL finished) {
            [self applyState];
            [UIView animateWithDuration:0.5
                                  delay:0
                 usingSpringWithDamping:0.4
                  initialSpringVelocity:8
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                                 self.transform = CGAffineTransformIdentity;
                             }
                             completion:nil];
        }];
}

@end

// MARK: Row

@interface NFBSensitiveRow : UIControl
@property (nonatomic, strong) NFBSensitiveIcon* icon;
@property (nonatomic, strong) UILabel* label;
@property (nonatomic, strong) UIColor* baseTextColor;
- (void)applyLabelColor;
@end

@implementation NFBSensitiveRow

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.tag = kRowTag;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel =
            [[BHTBundle sharedBundle] localizedStringForKey:@"NSFW_MODE_TITLE"];

        _icon = [[NFBSensitiveIcon alloc]
            initWithFrame:CGRectMake(0, 0, kIconSize, kIconSize)];
        [self addSubview:_icon];
        _label = [UILabel new];
        _label.text = self.accessibilityLabel;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        [self addTarget:self
                      action:@selector(rowTapped)
            forControlEvents:UIControlEventTouchUpInside];

        UILongPressGestureRecognizer* press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(rowLongPressed:)];
        press.minimumPressDuration = 0.45;
        [self addGestureRecognizer:press];
    }
    return self;
}

// Long press opens the NSFW detail page as a sheet.
- (void)rowLongPressed:(UILongPressGestureRecognizer*)press {
    if (press.state != UIGestureRecognizerStateBegan) {
        return;
    }
    [[[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];

    UIViewController* top = self.window.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if (!top) {
        return;
    }

    ModernSettingsPageViewController* page =
        [[ModernSettingsPageViewController alloc] initWithAccount:nil pageKey:@"kemo_nsfw"];
    UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:page];
    __weak UINavigationController* weakNav = nav;
    __weak NFBSensitiveRow* weakRow = self;
    page.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                      primaryAction:[UIAction actionWithHandler:^(UIAction* action) {
                          [weakNav dismissViewControllerAnimated:YES
                                                      completion:^{
                                                          [weakRow.icon applyState];
                                                          [weakRow applyLabelColor];
                                                      }];
                      }]];
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.detents = @[
            [UISheetPresentationControllerDetent mediumDetent],
            [UISheetPresentationControllerDetent largeDetent]
        ];
    }
    [top presentViewController:nav animated:YES completion:nil];
}

// Label follows the icon: accent when on, the menu's own text color when off.
- (void)applyLabelColor {
    self.label.textColor = [BHTSettings boolForKey:kSensitiveKey]
                               ? CurrentAccentColor()
                               : self.baseTextColor;
}

- (void)rowTapped {
    [self.icon toggle];
    [UIView transitionWithView:self.label
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        [self applyLabelColor];
                    }
                    completion:nil];
    self.accessibilityValue = [BHTSettings boolForKey:kSensitiveKey] ? @"On" : @"Off";
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1.0;
}

@end

// MARK: Locating the drawer list

static BOOL IsDrawerList(UIScrollView* list) {
    if (![list isKindOfClass:[UICollectionView class]] ||
        [[(id)list performSelector:@selector(visibleCells)] count] < 3) {
        return NO;
    }
    UIView* ancestor = list.superview;
    for (int depth = 0; ancestor && depth < 12; depth++, ancestor = ancestor.superview) {
        if ([NSStringFromClass(ancestor.class) containsString:@"TwitterDash"] ||
            [NSStringFromClass(ancestor.nextResponder.class) containsString:@"DashHostingController"]) {
            return YES;
        }
    }
    return NO;
}

// MARK: D-day lines under the NSFW row

static const CGFloat kEventRowHeight = 40.0;
static const CGFloat kEventGap = 8.0;
static const NSUInteger kMaxEventRows = 4;

@interface NFBEventRow : UIControl
@property (nonatomic, copy) NSString* handle;
@end

@implementation NFBEventRow

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 1.0;
}

@end

// Rows for the soonest events: "D-12  Event name"; tapping one opens the event's
// account when it has one.
@interface NFBEventRows : UIView
@property (nonatomic, copy) NSString* signature;
- (CGFloat)reloadWithIconX:(CGFloat)iconX width:(CGFloat)width;
@end

@implementation NFBEventRows

- (void)openAccount:(NFBEventRow*)row {
    if (row.handle.length == 0) {
        return;
    }
    NSString* encoded =
        [row.handle stringByAddingPercentEncodingWithAllowedCharacters:
                        [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL* url = [NSURL URLWithString:[@"twitter://user?screen_name=" stringByAppendingString:encoded]];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

// Returns the height the rows need (0 when there are no upcoming events).
- (CGFloat)reloadWithIconX:(CGFloat)iconX width:(CGFloat)width {
    NSArray<NSDictionary*>* events = [BHTEvents upcoming:kMaxEventRows];
    NSMutableString* signature = [NSMutableString stringWithFormat:@"%.0f|%.0f|", iconX, width];
    for (NSDictionary* event in events) {
        NSDate* date = [NSDate dateWithTimeIntervalSince1970:[event[@"time"] doubleValue]];
        [signature appendFormat:@"%@:%ld:%@;", event[@"name"], (long)[BHTEvents daysUntil:date],
                                event[@"handle"]];
    }
    [signature appendFormat:@"%@", CurrentAccentColor()];

    if (![signature isEqualToString:self.signature]) {
        self.signature = signature;
        for (UIView* old in [self.subviews copy]) {
            [old removeFromSuperview];
        }
        CGFloat y = 0;
        for (NSDictionary* event in events) {
            NSDate* date = [NSDate dateWithTimeIntervalSince1970:[event[@"time"] doubleValue]];
            NSInteger days = [BHTEvents daysUntil:date];

            NFBEventRow* row = [[NFBEventRow alloc]
                initWithFrame:CGRectMake(0, y, width, kEventRowHeight)];
            row.handle = event[@"handle"];
            [row addTarget:self action:@selector(openAccount:) forControlEvents:UIControlEventTouchUpInside];

            UILabel* count = [UILabel new];
            count.text = days == 0 ? @"D-Day" : [NSString stringWithFormat:@"D-%ld", (long)days];
            count.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightBold];
            count.textColor = CurrentAccentColor();
            count.frame = CGRectMake(iconX, 0, 64, kEventRowHeight);
            count.userInteractionEnabled = NO;
            [row addSubview:count];

            UILabel* name = [UILabel new];
            name.text = event[@"name"];
            name.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
            name.textColor = [UIColor labelColor];
            name.lineBreakMode = NSLineBreakByTruncatingTail;
            name.frame = CGRectMake(iconX + 68, 0, MAX(width - iconX - 68 - 16, 0), kEventRowHeight);
            name.userInteractionEnabled = NO;
            [row addSubview:name];

            [self addSubview:row];
            y += kEventRowHeight;
        }
    }
    return self.subviews.count * kEventRowHeight;
}

@end

static __weak NFBSensitiveRow* gRow;
static __weak NFBEventRows* gEventRows;
static const void* kInsetAddedKey = &kInsetAddedKey;

static void InstallRow(UIScrollView* list) {
    if (!list.window || !IsDrawerList(list)) {
        return;
    }

    // Sit right under the last menu row, as tall as the first one.
    NSArray<UIView*>* cells = [(id)list performSelector:@selector(visibleCells)];
    CGFloat bottom = 0;
    for (UIView* cell in cells) {
        bottom = MAX(bottom, CGRectGetMaxY(cell.frame));
    }
    CGFloat rowHeight = 52.0;
    CGFloat iconX = 32.0;
    CGFloat labelX = iconX + kIconSize + 16.0;

    NFBSensitiveRow* row = gRow;
    if (!row || row.superview != list) {
        [gRow removeFromSuperview];
        row = [[NFBSensitiveRow alloc] initWithFrame:CGRectZero];
        gRow = row;
        row.label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        row.baseTextColor = [UIColor labelColor];
        [list addSubview:row];
    }
    [row applyLabelColor];
    row.frame = CGRectMake(0, bottom, CGRectGetWidth(list.bounds), rowHeight);
    row.icon.frame = CGRectMake(iconX, (rowHeight - kIconSize) / 2, kIconSize, kIconSize);
    row.label.frame = CGRectMake(
        labelX, 0, MAX(CGRectGetWidth(row.bounds) - labelX - 12, 0), rowHeight);
    [row.icon applyState];

    // D-day lines right under it.
    NFBEventRows* events = gEventRows;
    if (!events || events.superview != list) {
        [gEventRows removeFromSuperview];
        events = [NFBEventRows new];
        gEventRows = events;
        [list addSubview:events];
    }
    CGFloat eventsHeight = [events reloadWithIconX:iconX width:CGRectGetWidth(list.bounds)];
    events.frame = CGRectMake(0, bottom + rowHeight + kEventGap, CGRectGetWidth(list.bounds),
                              eventsHeight);
    events.hidden = eventsHeight == 0;
    CGFloat totalHeight = rowHeight + (eventsHeight > 0 ? kEventGap + eventsHeight : 0);

    // Let the list scroll far enough to reach the extra rows.
    CGFloat added = [objc_getAssociatedObject(list, kInsetAddedKey) doubleValue];
    if (fabs(added - totalHeight) > 0.5) {
        UIEdgeInsets inset = list.contentInset;
        inset.bottom += totalHeight - added;
        list.contentInset = inset;
        objc_setAssociatedObject(list, kInsetAddedKey, @(totalHeight),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static const void* kCheckedAtKey = &kCheckedAtKey;

// The drawer may be built long after launch and without any view controller
// appearance, so watch the lists themselves; throttled per list.
static void CheckList(UIScrollView* list) {
    if (!list.window) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber* last = objc_getAssociatedObject(list, kCheckedAtKey);
    if (last && now - last.doubleValue < 0.5) {
        return;
    }
    objc_setAssociatedObject(list, kCheckedAtKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    InstallRow(list);
}

%hook UITableView

- (void)layoutSubviews {
    %orig;
    CheckList(self);
}

%end

%hook UICollectionView

- (void)layoutSubviews {
    %orig;
    CheckList(self);
}

%end
