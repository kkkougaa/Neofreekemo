//
//  SensitiveToggle.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Core/BHTAvatars.h"
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

// A few small hearts pop out around the icon and drift away (the blush stays as it is).
- (void)burstHearts {
    UIView* host = self.superview;
    if (!host) {
        return;
    }
    static const CGFloat angles[] = {-0.9, -0.2, 0.5, -1.7, 1.2};
    static const CGFloat sizes[] = {9, 7, 8, 7, 6};
    UIColor* pink = [UIColor colorWithRed:1.0 green:0.45 blue:0.62 alpha:1.0];
    UIImageSymbolConfiguration* config =
        [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold];
    CGPoint center = [host convertPoint:CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds))
                               fromView:self];
    CGFloat radius = CGRectGetWidth(self.bounds) / 2;
    for (int i = 0; i < 5; i++) {
        UIImageView* heart = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:@"heart.fill" withConfiguration:config]];
        heart.tintColor = pink;
        heart.contentMode = UIViewContentModeScaleAspectFit;
        heart.bounds = CGRectMake(0, 0, sizes[i], sizes[i]);
        CGFloat angle = angles[i] - M_PI_2;
        heart.center = CGPointMake(center.x + cos(angle) * radius * 0.7, center.y + sin(angle) * radius * 0.7);
        heart.alpha = 0;
        heart.transform = CGAffineTransformMakeScale(0.3, 0.3);
        [host addSubview:heart];

        NSTimeInterval delay = 0.06 * i;
        [UIView animateWithDuration:0.25
                              delay:delay
             usingSpringWithDamping:0.55
              initialSpringVelocity:0
                            options:0
                         animations:^{
                             heart.alpha = 1;
                             heart.transform = CGAffineTransformIdentity;
                         }
                         completion:nil];
        [UIView animateWithDuration:0.8
            delay:delay + 0.15
            options:UIViewAnimationOptionCurveEaseOut
            animations:^{
                heart.center = CGPointMake(center.x + cos(angle) * (radius + 16),
                                           center.y + sin(angle) * (radius + 16) - 6);
                heart.alpha = 0;
            }
            completion:^(BOOL finished) {
                [heart removeFromSuperview];
            }];
    }
}

- (void)toggle {
    BOOL on = ![BHTSettings boolForKey:kSensitiveKey];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:on forKey:kSensitiveKey];

    // NSFW mode shows everything: the AI cover goes off with it, and goes back to what
    // it was before when the mode is turned off again.
    static NSString* const kBlurKey = @"nsfw_ai_blur";
    static NSString* const kBlurBeforeKey = @"nfb_nsfw_blur_before";
    if (on) {
        [defaults setBool:[BHTSettings boolForKey:kBlurKey] forKey:kBlurBeforeKey];
        [defaults setBool:NO forKey:kBlurKey];
    } else {
        [defaults setBool:[defaults boolForKey:kBlurBeforeKey] forKey:kBlurKey];
    }

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
            if (on) {
                [self burstHearts];
            }
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

// MARK: Open original X app row
// A plain button above the NSFW row that hands the user over to the original X app.
// This build is re-signed without the app's associated domains, so a universal link to
// x.com is not claimed by it and iOS gives it to the original X app. Universal-links-only
// keeps it from falling into Safari when X is not installed; then the plain URL is tried.

static const NSInteger kOpenXRowTag = 0x4e464232;

@interface NFBOpenXRow : UIControl
@property (nonatomic, strong) UIImageView* icon;
@property (nonatomic, strong) UILabel* label;
@end

@implementation NFBOpenXRow

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.tag = kOpenXRowTag;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel =
            [[BHTBundle sharedBundle] localizedStringForKey:@"OPEN_ORIGINAL_X_TITLE"];

        UIImageSymbolConfiguration* config =
            [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
        _icon = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:@"arrow.up.forward.app" withConfiguration:config]];
        _icon.contentMode = UIViewContentModeCenter;
        _icon.tintColor = [UIColor systemGrayColor];
        _icon.userInteractionEnabled = NO;
        [self addSubview:_icon];

        _label = [UILabel new];
        _label.text = self.accessibilityLabel;
        _label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        _label.textColor = [UIColor labelColor];
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        [self addTarget:self
                      action:@selector(rowTapped)
            forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)rowTapped {
    [[[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    NSURL* url = [NSURL URLWithString:@"https://x.com/home"];
    UIApplication* app = [UIApplication sharedApplication];
    [app openURL:url
                  options:@{UIApplicationOpenURLOptionUniversalLinksOnly : @YES}
        completionHandler:^(BOOL success) {
            if (!success) {
                [app openURL:url options:@{} completionHandler:nil];
            }
        }];
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

// MARK: D-day group under the menu list

static const CGFloat kEventRowHeight = 40.0;
static const CGFloat kEventTitleHeight = 22.0;
static const CGFloat kEventGroupGap = 14.0;
static const CGFloat kAvatarSize = 28.0;
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

// A small "D-day" title and rows for the soonest events: "D-12  (avatar) Event name".
// Tapping a row opens the event's account when it has one.
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

// Returns the height the group needs (0 when there are no upcoming events).
- (CGFloat)reloadWithIconX:(CGFloat)iconX width:(CGFloat)width {
    NSArray<NSDictionary*>* events = [BHTEvents upcoming:kMaxEventRows];
    __weak NFBEventRows* weakSelf = self;

    // Pictures that are already here (this also starts the download of the others).
    NSMutableDictionary<NSString*, UIImage*>* avatars = [NSMutableDictionary dictionary];
    NSMutableString* signature = [NSMutableString stringWithFormat:@"%.0f|%.0f|", iconX, width];
    for (NSDictionary* event in events) {
        NSDate* date = [NSDate dateWithTimeIntervalSince1970:[event[@"time"] doubleValue]];
        NSString* handle = event[@"handle"];
        UIImage* avatar = [BHTAvatars imageForHandle:handle
                                          completion:^{
                                              weakSelf.signature = nil;
                                              [weakSelf.superview setNeedsLayout];
                                          }];
        if (avatar) {
            avatars[handle] = avatar;
        }
        [signature appendFormat:@"%@:%ld:%@:%d;", event[@"name"], (long)[BHTEvents daysUntil:date],
                                handle, avatar != nil];
    }
    [signature appendFormat:@"%@", CurrentAccentColor()];

    if (![signature isEqualToString:self.signature]) {
        self.signature = signature;
        for (UIView* old in [self.subviews copy]) {
            [old removeFromSuperview];
        }
        if (events.count == 0) {
            return 0;
        }

        UILabel* title = [UILabel new];
        title.text = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_DDAY_HEADER"];
        title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        title.textColor = [UIColor secondaryLabelColor];
        title.frame = CGRectMake(iconX, 0, MAX(width - iconX - 16, 0), kEventTitleHeight);
        [self addSubview:title];

        CGFloat y = kEventTitleHeight;
        for (NSDictionary* event in events) {
            NSDate* date = [NSDate dateWithTimeIntervalSince1970:[event[@"time"] doubleValue]];
            NSInteger days = [BHTEvents daysUntil:date];
            NSString* handle = event[@"handle"];

            NFBEventRow* row = [[NFBEventRow alloc]
                initWithFrame:CGRectMake(0, y, width, kEventRowHeight)];
            row.handle = handle;
            [row addTarget:self action:@selector(openAccount:) forControlEvents:UIControlEventTouchUpInside];

            UILabel* count = [UILabel new];
            count.text = days == 0 ? @"D-Day" : [NSString stringWithFormat:@"D-%ld", (long)days];
            count.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightBold];
            count.textColor = CurrentAccentColor();
            count.frame = CGRectMake(iconX, 0, 60, kEventRowHeight);
            count.userInteractionEnabled = NO;
            [row addSubview:count];

            // The account's picture, or a plain disc until it has arrived.
            CGFloat nameX = iconX + 64;
            if (handle.length > 0) {
                UIImageView* avatar = [UIImageView new];
                avatar.frame = CGRectMake(nameX, (kEventRowHeight - kAvatarSize) / 2, kAvatarSize,
                                          kAvatarSize);
                avatar.contentMode = UIViewContentModeScaleAspectFill;
                avatar.layer.cornerRadius = kAvatarSize / 2;
                avatar.clipsToBounds = YES;
                avatar.backgroundColor = [UIColor tertiarySystemFillColor];
                avatar.image = avatars[handle];
                avatar.userInteractionEnabled = NO;
                [row addSubview:avatar];
                nameX += kAvatarSize + 10;
            }

            UILabel* name = [UILabel new];
            name.text = event[@"name"];
            name.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
            name.textColor = [UIColor labelColor];
            name.lineBreakMode = NSLineBreakByTruncatingTail;
            name.frame = CGRectMake(nameX, 0, MAX(width - nameX - 16, 0), kEventRowHeight);
            name.userInteractionEnabled = NO;
            [row addSubview:name];

            [self addSubview:row];
            y += kEventRowHeight;
        }
    }
    return self.subviews.count == 0 ? 0 : kEventTitleHeight + (self.subviews.count - 1) * kEventRowHeight;
}

@end

static __weak NFBSensitiveRow* gRow;
static __weak NFBOpenXRow* gOpenXRow;
static __weak NFBEventRows* gEventRows;
static const void* kInsetAddedKey = &kInsetAddedKey;
static const void* kDashPinnedKey = &kDashPinnedKey;
static const void* kAppliedShiftKey = &kAppliedShiftKey;
static const void* kSizeExtraKey = &kSizeExtraKey;

// The two rows belong in the official menu, directly under Spaces. Cells below
// that row are pushed down. D-day stays at the end. Until Spaces has been seen,
// the rows stay at the end so they never cover a menu item.

static BOOL TextIsSpaces(NSString* text) {
    if (text.length == 0 || text.length > 24) {
        return NO;
    }
    NSString* trimmed =
        [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasSuffix:@", 버튼"] || [trimmed hasSuffix:@", Button"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 4];
        trimmed = [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    for (NSString* name in @[ @"스페이스", @"Spaces", @"Space", @"スペース", @"Espacios", @"Espaces" ]) {
        if ([trimmed caseInsensitiveCompare:name] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

static BOOL ViewIsSpaces(UIView* view) {
    if ([view isKindOfClass:[UILabel class]] && TextIsSpaces(((UILabel*)view).text)) {
        return YES;
    }
    if (TextIsSpaces(view.accessibilityLabel)) {
        return YES;
    }
    for (UIView* sub in view.subviews) {
        if (ViewIsSpaces(sub)) {
            return YES;
        }
    }
    return NO;
}

static const void* kSpacesPathKey = &kSpacesPathKey;

static CGFloat SpacesInsertY(UICollectionView* list) {
    for (UICollectionViewCell* cell in list.visibleCells) {
        if (!ViewIsSpaces(cell)) {
            continue;
        }
        NSIndexPath* path = [list indexPathForCell:cell];
        if (path) {
            objc_setAssociatedObject(list, kSpacesPathKey, path, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return CGRectGetMaxY(cell.frame);
    }
    NSIndexPath* saved = objc_getAssociatedObject(list, kSpacesPathKey);
    if (saved) {
        UICollectionViewLayoutAttributes* attr = [list layoutAttributesForItemAtIndexPath:saved];
        if (attr) {
            return CGRectGetMaxY(attr.frame);
        }
    }

    // The menu titles are drawn by SwiftUI, not UILabels. On screen the first
    // group is 프로필, 커뮤니티, 리스트, 스페이스, then a gap, then 설정.
    NSMutableArray<UIView*>* rows = [NSMutableArray array];
    for (UICollectionViewCell* cell in list.visibleCells) {
        CGFloat height = CGRectGetHeight(cell.frame);
        if (height < 44.0 || height > 80.0 || CGRectGetWidth(cell.frame) < 200.0) {
            continue;
        }
        [rows addObject:cell];
    }
    [rows sortUsingComparator:^NSComparisonResult(UIView* a, UIView* b) {
        CGFloat ay = CGRectGetMinY(a.frame);
        CGFloat by = CGRectGetMinY(b.frame);
        return ay < by ? NSOrderedAscending : (ay > by ? NSOrderedDescending : NSOrderedSame);
    }];
    if (rows.count < 4) {
        return -1;
    }
    CGFloat bestGap = 12.0;
    UIView* beforeGap = nil;
    for (NSUInteger i = 1; i < rows.count; i++) {
        CGFloat gap = CGRectGetMinY(rows[i].frame) - CGRectGetMaxY(rows[i - 1].frame);
        if (gap > bestGap) {
            bestGap = gap;
            beforeGap = rows[i - 1];
        }
    }
    if (!beforeGap) {
        beforeGap = rows[3];
    }
    return CGRectGetMaxY(beforeGap.frame);
}

static void ShiftContentBelow(UIScrollView* list, CGFloat insertY, CGFloat shift, UIView* events,
                              UIView* openX, UIView* row) {
    // Undo the previous nudge first. Otherwise every layout pushes the same
    // row down another 104pt and settings, help and follow requests leave the screen.
    for (UIView* sub in list.subviews) {
        if (sub == events || sub == openX || sub == row) {
            continue;
        }
        if (![sub isKindOfClass:[UICollectionReusableView class]]) {
            continue;
        }
        CGFloat applied = [objc_getAssociatedObject(sub, kAppliedShiftKey) doubleValue];
        CGRect frame = sub.frame;
        frame.origin.y -= applied;
        CGFloat next = 0;
        if (frame.origin.y + 0.5 >= insertY) {
            frame.origin.y += shift;
            next = shift;
        }
        if (fabs(applied - next) > 0.5 || fabs(sub.frame.origin.y - frame.origin.y) > 0.5) {
            sub.frame = frame;
            objc_setAssociatedObject(sub, kAppliedShiftKey, next > 0 ? @(next) : nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void InstallRow(UIScrollView* list) {
    if (!list.window || !IsDrawerList(list)) {
        return;
    }

    CGFloat rowHeight = 52.0;
    CGFloat iconX = 32.0;
    CGFloat labelX = iconX + kIconSize + 16.0;
    CGFloat width = CGRectGetWidth(list.bounds);
    CGFloat sizeExtra = [objc_getAssociatedObject(list, kSizeExtraKey) doubleValue];
    CGFloat anchor = list.contentSize.height - sizeExtra;
    if (anchor < 1) {
        return;
    }

    NFBEventRows* events = gEventRows;
    if (!events || events.superview != list) {
        [gEventRows removeFromSuperview];
        events = [NFBEventRows new];
        gEventRows = events;
        [list addSubview:events];
    }
    CGFloat eventsHeight = [events reloadWithIconX:iconX width:width];

    NFBOpenXRow* openX = gOpenXRow;
    if (!openX || openX.superview != list) {
        [gOpenXRow removeFromSuperview];
        openX = [[NFBOpenXRow alloc] initWithFrame:CGRectZero];
        gOpenXRow = openX;
        [list addSubview:openX];
    }
    NFBSensitiveRow* row = gRow;
    if (!row || row.superview != list) {
        [gRow removeFromSuperview];
        row = [[NFBSensitiveRow alloc] initWithFrame:CGRectZero];
        gRow = row;
        row.label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        row.baseTextColor = [UIColor labelColor];
        [list addSubview:row];
    }

    CGFloat insertY = -1;
    CGFloat shift = 0;
    if ([list isKindOfClass:[UICollectionView class]]) {
        insertY = SpacesInsertY((UICollectionView*)list);
    }
    // The dash hosting view already pinned these under Spaces. Leave them there
    // unless this list itself has the Spaces row.
    if (insertY < 0 && objc_getAssociatedObject(gOpenXRow, kDashPinnedKey)) {
        return;
    }
    if (insertY >= 0) {
        objc_setAssociatedObject(gOpenXRow, kDashPinnedKey, nil, OBJC_ASSOCIATION_ASSIGN);
        shift = rowHeight * 2;
    }

    CGFloat menuY = insertY >= 0 ? insertY : anchor;
    if (insertY < 0 && eventsHeight > 0) {
        menuY += kEventGroupGap + eventsHeight;
    }

    CGFloat eventsY = anchor + shift + (eventsHeight > 0 ? kEventGroupGap : 0);
    CGFloat eventsExtra = eventsHeight > 0 ? kEventGroupGap + eventsHeight : 0;
    CGFloat tail = (insertY >= 0 ? shift : rowHeight * 2) + eventsExtra + 16.0;
    CGFloat added = [objc_getAssociatedObject(list, kInsetAddedKey) doubleValue];
    if (fabs(added - tail) > 0.5) {
        UIEdgeInsets inset = list.contentInset;
        inset.bottom += tail - added;
        list.contentInset = inset;
        objc_setAssociatedObject(list, kInsetAddedKey, @(tail), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Changing the inset lays the list out again and puts the cells back.
        // Place the rows after that, below.
        if ([list isKindOfClass:[UICollectionView class]]) {
            CGFloat again = SpacesInsertY((UICollectionView*)list);
            if (again >= 0) {
                insertY = again;
                shift = rowHeight * 2;
                menuY = insertY;
            }
        }
        eventsY = anchor + shift + (eventsHeight > 0 ? kEventGroupGap : 0);
    }

    if (insertY >= 0) {
        ShiftContentBelow(list, insertY, shift, events, openX, row);
        if (fabs(sizeExtra - shift) > 0.5) {
            CGSize size = list.contentSize;
            size.height += shift - sizeExtra;
            list.contentSize = size;
            objc_setAssociatedObject(list, kSizeExtraKey, @(shift), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    openX.frame = CGRectMake(0, menuY, width, rowHeight);
    openX.icon.frame = CGRectMake(iconX, (rowHeight - kIconSize) / 2, kIconSize, kIconSize);
    openX.label.frame = CGRectMake(labelX, 0, MAX(width - labelX - 12, 0), rowHeight);
    [row applyLabelColor];
    row.frame = CGRectMake(0, CGRectGetMaxY(openX.frame), width, rowHeight);
    row.icon.frame = CGRectMake(iconX, (rowHeight - kIconSize) / 2, kIconSize, kIconSize);
    row.label.frame = CGRectMake(labelX, 0, MAX(width - labelX - 12, 0), rowHeight);
    [row.icon applyState];
    events.frame = CGRectMake(0, eventsY, width, eventsHeight);
    events.hidden = eventsHeight == 0;
}

static NSInteger gInstallDepth;

static void CheckList(UIScrollView* list) {
    if (!list.window || gInstallDepth > 0) {
        return;
    }
    gInstallDepth++;
    InstallRow(list);
    gInstallDepth--;
}

static UIView* FindSpacesView(UIView* root) {
    __block UIView* found = nil;
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if (found || view == gOpenXRow || view == gRow || view == gEventRows) {
            return;
        }
        if ([view isKindOfClass:[UILabel class]] && TextIsSpaces(((UILabel*)view).text)) {
            found = view;
            return;
        }
        if (TextIsSpaces(view.accessibilityLabel)) {
            found = view;
        }
    });
    return found;
}

static void PlaceRowsUnderSpaces(UIView* root) {
    if (!root.window) {
        return;
    }
    UIView* spaces = FindSpacesView(root);
    if (!spaces) {
        return;
    }
    UIView* rowView = spaces;
    while (rowView.superview && rowView.superview != root && CGRectGetHeight(rowView.bounds) < 48.0) {
        rowView = rowView.superview;
    }
    CGRect spot = [rowView convertRect:rowView.bounds toView:root];
    if (CGRectIsEmpty(spot)) {
        return;
    }

    CGFloat rowHeight = 52.0;
    CGFloat width = CGRectGetWidth(root.bounds);
    CGFloat iconX = 32.0;
    CGFloat labelX = iconX + kIconSize + 16.0;

    NFBOpenXRow* openX = gOpenXRow;
    if (!openX) {
        openX = [[NFBOpenXRow alloc] initWithFrame:CGRectZero];
        gOpenXRow = openX;
    }
    NFBSensitiveRow* row = gRow;
    if (!row) {
        row = [[NFBSensitiveRow alloc] initWithFrame:CGRectZero];
        gRow = row;
        row.label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        row.baseTextColor = [UIColor labelColor];
    }
    if (openX.superview != root) {
        [root addSubview:openX];
    }
    if (row.superview != root) {
        [root addSubview:row];
    }
    objc_setAssociatedObject(openX, kDashPinnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat y = CGRectGetMaxY(spot);
    openX.frame = CGRectMake(0, y, width, rowHeight);
    openX.icon.frame = CGRectMake(iconX, (rowHeight - kIconSize) / 2, kIconSize, kIconSize);
    openX.label.frame = CGRectMake(labelX, 0, MAX(width - labelX - 12, 0), rowHeight);
    row.frame = CGRectMake(0, y + rowHeight, width, rowHeight);
    row.icon.frame = CGRectMake(iconX, (rowHeight - kIconSize) / 2, kIconSize, kIconSize);
    row.label.frame = CGRectMake(labelX, 0, MAX(width - labelX - 12, 0), rowHeight);
    [row applyLabelColor];
    [row.icon applyState];
    openX.backgroundColor = root.backgroundColor ?: [UIColor systemBackgroundColor];
    row.backgroundColor = openX.backgroundColor;
    [root bringSubviewToFront:openX];
    [root bringSubviewToFront:row];
}

%hook _TtC11TwitterDash21DashHostingController

- (void)viewDidLayoutSubviews {
    %orig;
    PlaceRowsUnderSpaces(((UIViewController*)self).view);
}

%end

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
