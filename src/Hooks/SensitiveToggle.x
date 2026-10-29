//
//  SensitiveToggle.x
//  NeoFreeBird
//

#import "HookHelpers.h"

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
    }
    return self;
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

static __weak NFBSensitiveRow* gRow;
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

    // Let the list scroll far enough to reach the extra row.
    CGFloat added = [objc_getAssociatedObject(list, kInsetAddedKey) doubleValue];
    if (fabs(added - rowHeight) > 0.5) {
        UIEdgeInsets inset = list.contentInset;
        inset.bottom += rowHeight - added;
        list.contentInset = inset;
        objc_setAssociatedObject(list, kInsetAddedKey, @(rowHeight),
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
