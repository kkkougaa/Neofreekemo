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
// The drawer's class names aren't known, so the list is found by its content: a
// table or collection view whose visible cells carry at least two of the usual
// row titles. The row copies the font, color and icon position of those cells.

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

static NSSet<NSString*>* DrawerRowNames(void) {
    return [NSSet setWithArray:@[
        @"Profile", @"Lists", @"Communities", @"Bookmarks", @"Spaces", @"Premium",
        @"프로필", @"리스트", @"커뮤니티", @"북마크", @"스페이스", @"프리미엄"
    ]];
}

static void CollectLabels(UIView* view, NSMutableArray<UILabel*>* out) {
    if ([view isKindOfClass:[UILabel class]] && ((UILabel*)view).text.length) {
        [out addObject:(UILabel*)view];
    }
    for (UIView* sub in view.subviews) {
        CollectLabels(sub, out);
    }
}

// Whether this list holds the drawer rows; also returns a cell and label to copy.
static BOOL MatchDrawerList(UIScrollView* list, UIView** cellOut, UILabel** labelOut) {
    NSSet<NSString*>* names = DrawerRowNames();
    NSCharacterSet* trim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray* cells = [(id)list performSelector:@selector(visibleCells)];
    NSMutableSet<NSString*>* seen = [NSMutableSet new];
    UIView* templateCell = nil;
    UILabel* templateLabel = nil;

    for (UIView* cell in cells) {
        NSMutableArray<UILabel*>* labels = [NSMutableArray new];
        CollectLabels(cell, labels);
        for (UILabel* label in labels) {
            NSString* text = [label.text stringByTrimmingCharactersInSet:trim];
            if ([names containsObject:text]) {
                [seen addObject:text];
                if (!templateCell) {
                    templateCell = cell;
                    templateLabel = label;
                }
            }
        }
    }
    if (seen.count < 2) {
        return NO;
    }
    *cellOut = templateCell;
    *labelOut = templateLabel;
    return YES;
}

static __weak NFBSensitiveRow* gRow;
static const void* kInsetAddedKey = &kInsetAddedKey;

static void InstallRow(UIScrollView* list) {
    UIView* templateCell = nil;
    UILabel* templateLabel = nil;
    if (!list.window || !MatchDrawerList(list, &templateCell, &templateLabel)) {
        return;
    }

    CGFloat rowHeight = MAX(CGRectGetHeight(templateCell.bounds), 44.0);
    CGRect labelRect = [templateLabel convertRect:templateLabel.bounds toView:list];

    // Left edge of the template's icon, if it has one.
    CGFloat iconX = NAN;
    NSMutableArray<UIView*>* stack = [NSMutableArray arrayWithObject:templateCell];
    while (stack.count) {
        UIView* view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:[UIImageView class]] &&
            CGRectGetWidth(view.bounds) >= 16 && CGRectGetWidth(view.bounds) <= 44) {
            CGRect rect = [view convertRect:view.bounds toView:list];
            CGFloat x = rect.origin.x - (kIconSize - rect.size.width) / 2;
            iconX = isnan(iconX) ? x : MIN(iconX, x);
        }
        [stack addObjectsFromArray:view.subviews];
    }
    if (isnan(iconX)) {
        iconX = MAX(CGRectGetMinX(labelRect) - kIconSize - 16, 12);
    }
    CGFloat labelX = MAX(CGRectGetMinX(labelRect), iconX + kIconSize + 12);

    NFBSensitiveRow* row = gRow;
    if (!row || row.superview != list) {
        [gRow removeFromSuperview];
        row = [[NFBSensitiveRow alloc] initWithFrame:CGRectZero];
        gRow = row;
        [list addSubview:row];
    }
    row.label.font = templateLabel.font;
    row.baseTextColor = templateLabel.textColor;
    [row applyLabelColor];
    row.frame = CGRectMake(0, list.contentSize.height, CGRectGetWidth(list.bounds),
                           rowHeight);
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
