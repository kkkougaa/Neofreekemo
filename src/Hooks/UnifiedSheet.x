//
//  UnifiedSheet.x
//  NeoFreeBird
//
//  The A/B unified mode's own UI pieces, drawn in X's tone:
//  - NFBPresentAccountSheet(): the "which account?" sheet that rises from the
//    bottom (iOS 26 shows UIAlertController action sheets as popovers). Rows
//    carry an account picture, a name, a detail line, an optional pill button
//    on the right, and an action. 7.3.150: X's look (Chirp, a heavy title,
//    40pt pictures, black/white pill buttons, an outlined pill to cancel).
//  - NFBShowNotice(): a short notice at the bottom like X's own toasts (a glass
//    capsule above the tab bar), not a dark box in the middle.
//

#import "HookHelpers.h"

// MARK: - X's font

// Chirp when the app has it (X bundles it), the system font otherwise.
UIFont* NFBXFont(CGFloat size, UIFontWeight weight) {
    static NSString* family;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString* name in [UIFont familyNames]) {
            if ([name rangeOfString:@"Chirp" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                family = name;
                break;
            }
        }
    });
    if (family) {
        UIFontDescriptor* descriptor = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
            UIFontDescriptorFamilyAttribute : family,
            UIFontDescriptorTraitsAttribute : @{UIFontWeightTrait : @(weight)}
        }];
        UIFont* font = [UIFont fontWithDescriptor:descriptor size:size];
        if (font) return font;
    }
    return [UIFont systemFontOfSize:size weight:weight];
}

static UIWindow* NFBKeyWindow(void) {
    UIWindow* window = nil;
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* candidate in ((UIWindowScene*)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    return window;
}

static UIVisualEffect* NFBGlass(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (glassClass) {
        id effect = [[glassClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial];
}

// MARK: - Notice (X-style toast)

static const NSInteger kNoticeTag = 0x4E464E;  // "NFN"

void NFBShowNotice(NSString* text) {
    if (text.length == 0) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NFBShowNotice(text);
        });
        return;
    }
    UIWindow* window = NFBKeyWindow();
    if (!window) return;
    [[window viewWithTag:kNoticeTag] removeFromSuperview];

    UIVisualEffectView* toast = [[UIVisualEffectView alloc] initWithEffect:NFBGlass()];
    toast.tag = kNoticeTag;
    toast.userInteractionEnabled = NO;
    toast.clipsToBounds = YES;
    toast.layer.cornerCurve = kCACornerCurveContinuous;

    UILabel* label = [UILabel new];
    label.text = text;
    label.numberOfLines = 2;
    label.font = NFBXFont(15, UIFontWeightMedium);
    label.textColor = [UIColor labelColor];
    [toast.contentView addSubview:label];

    CGFloat maxWidth = MIN(CGRectGetWidth(window.bounds) - 32, 420);
    CGSize size = [label sizeThatFits:CGSizeMake(maxWidth - 40, CGFLOAT_MAX)];
    CGFloat width = MIN(maxWidth, ceil(size.width) + 40);
    CGFloat height = MAX(48, ceil(size.height) + 26);
    label.frame = CGRectMake(20, (height - ceil(size.height)) / 2, width - 40, ceil(size.height));
    toast.layer.cornerRadius = height / 2;
    // Above the tab bar, where X puts its own toasts.
    CGFloat bottom = CGRectGetHeight(window.bounds) - window.safeAreaInsets.bottom - 49 - 12;
    toast.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) / 2, bottom - height, width, height);
    toast.isAccessibilityElement = YES;
    toast.accessibilityLabel = text;
    [window addSubview:toast];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);

    toast.alpha = 0;
    toast.transform = CGAffineTransformMakeTranslation(0, 16);
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        toast.alpha = 1;
        toast.transform = CGAffineTransformIdentity;
    } completion:nil];
    __weak UIView* weakToast = toast;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView* shown = weakToast;
        if (!shown.superview) return;
        [UIView animateWithDuration:0.25 animations:^{
            shown.alpha = 0;
            shown.transform = CGAffineTransformMakeTranslation(0, 12);
        } completion:^(BOOL finished) {
            [shown removeFromSuperview];
        }];
    });
}

// MARK: - Account sheet

@interface NFBSheetRow : UIControl
@end

@implementation NFBSheetRow
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [UIColor secondarySystemFillColor] : UIColor.clearColor;
}
@end

@interface NFBAccountSheetController : UIViewController
@property (nonatomic, copy) NSString* titleText;
@property (nonatomic, copy) NSString* messageText;
@property (nonatomic, strong) NSArray<NSDictionary*>* rows;
@end

static const CGFloat kSheetRowHeight = 64;

@implementation NFBAccountSheetController

- (UIView*)pillWithTitle:(NSString*)title style:(NSString*)style {
    UILabel* pill = [UILabel new];
    pill.text = title;
    pill.textAlignment = NSTextAlignmentCenter;
    pill.font = NFBXFont(14, UIFontWeightBold);
    pill.layer.cornerRadius = 16;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    if ([style isEqualToString:@"filled"]) {
        // X's follow button: black on light, white on dark.
        pill.backgroundColor = [UIColor labelColor];
        pill.textColor = [UIColor systemBackgroundColor];
    } else if ([style isEqualToString:@"outline"]) {
        pill.textColor = [UIColor labelColor];
        pill.layer.borderWidth = 1;
        pill.layer.borderColor = [UIColor separatorColor].CGColor;
    } else {
        pill.textColor = [UIColor tertiaryLabelColor];
        pill.layer.borderWidth = 1;
        pill.layer.borderColor = [UIColor quaternaryLabelColor].CGColor;
    }
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat width = ceil([title sizeWithAttributes:@{NSFontAttributeName : pill.font}].width) + 32;
    [NSLayoutConstraint activateConstraints:@[
        [pill.heightAnchor constraintEqualToConstant:32],
        [pill.widthAnchor constraintEqualToConstant:MAX(width, 76)],
    ]];
    return pill;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UIStackView* stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:30],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    UIView* header = [UIView new];
    UILabel* title = [UILabel new];
    title.text = self.titleText;
    title.font = NFBXFont(21, UIFontWeightHeavy);
    title.textColor = [UIColor labelColor];
    title.numberOfLines = 0;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:title];
    UILabel* message = [UILabel new];
    message.text = self.messageText;
    message.font = NFBXFont(15, UIFontWeightRegular);
    message.textColor = [UIColor secondaryLabelColor];
    message.numberOfLines = 0;
    message.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:message];
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:header.topAnchor],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [title.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24],
        [message.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:self.messageText.length ? 6 : 0],
        [message.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [message.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [message.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-14],
    ]];
    [stack addArrangedSubview:header];

    for (NSUInteger i = 0; i < self.rows.count; i++) {
        NSDictionary* row = self.rows[i];
        BOOL disabled = [row[@"disabled"] boolValue];
        NFBSheetRow* control = [NFBSheetRow new];
        control.tag = (NSInteger)i;
        control.enabled = !disabled;
        control.translatesAutoresizingMaskIntoConstraints = NO;
        [control.heightAnchor constraintEqualToConstant:kSheetRowHeight].active = YES;
        [control addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImage* image = row[@"image"];
        UIImageView* picture = [UIImageView new];
        picture.image = image;
        picture.contentMode = UIViewContentModeScaleAspectFill;
        picture.clipsToBounds = YES;
        picture.layer.cornerRadius = 20;
        picture.translatesAutoresizingMaskIntoConstraints = NO;
        picture.userInteractionEnabled = NO;
        [control addSubview:picture];

        UILabel* name = [UILabel new];
        name.text = row[@"title"];
        name.font = NFBXFont(16, UIFontWeightBold);
        name.textColor = [row[@"destructive"] boolValue] && !row[@"button"] ? [UIColor systemRedColor] : [UIColor labelColor];
        name.translatesAutoresizingMaskIntoConstraints = NO;
        name.userInteractionEnabled = NO;
        [control addSubview:name];

        UILabel* detail = [UILabel new];
        detail.text = row[@"detail"];
        detail.font = NFBXFont(14, UIFontWeightRegular);
        detail.textColor = [UIColor secondaryLabelColor];
        detail.translatesAutoresizingMaskIntoConstraints = NO;
        detail.userInteractionEnabled = NO;
        [control addSubview:detail];

        NSLayoutXAxisAnchor* textEnd = control.trailingAnchor;
        CGFloat textEndInset = -24;
        if ([row[@"button"] length]) {
            UIView* pill = [self pillWithTitle:row[@"button"] style:disabled ? @"disabled" : (row[@"buttonStyle"] ?: @"filled")];
            pill.userInteractionEnabled = NO;
            [control addSubview:pill];
            [NSLayoutConstraint activateConstraints:@[
                [pill.trailingAnchor constraintEqualToAnchor:control.trailingAnchor constant:-20],
                [pill.centerYAnchor constraintEqualToAnchor:control.centerYAnchor],
            ]];
            textEnd = pill.leadingAnchor;
            textEndInset = -12;
        }

        BOOL hasPicture = image != nil;
        BOOL hasDetail = [row[@"detail"] length] > 0;
        [NSLayoutConstraint activateConstraints:@[
            [picture.leadingAnchor constraintEqualToAnchor:control.leadingAnchor constant:24],
            [picture.centerYAnchor constraintEqualToAnchor:control.centerYAnchor],
            [picture.widthAnchor constraintEqualToConstant:hasPicture ? 40 : 0],
            [picture.heightAnchor constraintEqualToConstant:40],
            [name.leadingAnchor constraintEqualToAnchor:picture.trailingAnchor constant:hasPicture ? 12 : 0],
            [name.trailingAnchor constraintLessThanOrEqualToAnchor:textEnd constant:textEndInset],
            hasDetail ? [name.bottomAnchor constraintEqualToAnchor:control.centerYAnchor constant:1]
                      : [name.centerYAnchor constraintEqualToAnchor:control.centerYAnchor],
            [detail.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
            [detail.trailingAnchor constraintLessThanOrEqualToAnchor:textEnd constant:textEndInset],
            [detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],
        ]];
        control.alpha = disabled ? 0.5 : 1;
        control.accessibilityTraits = UIAccessibilityTraitButton | (disabled ? UIAccessibilityTraitNotEnabled : 0);
        control.isAccessibilityElement = YES;
        control.accessibilityLabel = [NSString stringWithFormat:@"%@, %@ %@", row[@"title"] ?: @"", row[@"detail"] ?: @"", row[@"button"] ?: @""];
        [stack addArrangedSubview:control];
    }

    UIView* footer = [UIView new];
    UIButton* cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"취소" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    cancel.titleLabel.font = NFBXFont(16, UIFontWeightBold);
    cancel.layer.cornerRadius = 22;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    cancel.layer.borderWidth = 1;
    cancel.layer.borderColor = [UIColor separatorColor].CGColor;
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:cancel];
    [NSLayoutConstraint activateConstraints:@[
        [cancel.topAnchor constraintEqualToAnchor:footer.topAnchor constant:16],
        [cancel.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:20],
        [cancel.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-20],
        [cancel.heightAnchor constraintEqualToConstant:44],
        [cancel.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor],
    ]];
    [stack addArrangedSubview:footer];
}

- (void)traitCollectionDidChange:(UITraitCollection*)previous {
    [super traitCollectionDidChange:previous];
    // CGColor borders do not follow light / dark on their own.
    [self.view setNeedsLayout];
    for (UIView* view in self.view.subviews) [self refreshBorders:view];
}

- (void)refreshBorders:(UIView*)view {
    if (view.layer.borderWidth > 0) {
        BOOL faint = [view isKindOfClass:[UILabel class]] && [((UILabel*)view).textColor isEqual:[UIColor tertiaryLabelColor]];
        view.layer.borderColor = (faint ? [UIColor quaternaryLabelColor] : [UIColor separatorColor]).CGColor;
    }
    for (UIView* child in view.subviews) [self refreshBorders:child];
}

- (void)rowTapped:(UIControl*)control {
    NSDictionary* row = control.tag < (NSInteger)self.rows.count ? self.rows[(NSUInteger)control.tag] : nil;
    if ([row[@"disabled"] boolValue]) return;
    void (^action)(void) = row[@"action"];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self dismissViewControllerAnimated:YES completion:^{
        if (action) action();
    }];
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static UIViewController* NFBSheetTop(void) {
    UIViewController* top = NFBKeyWindow().rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

// rows: @{ @"title", @"detail", @"image", @"destructive", @"disabled",
//          @"button" (pill text on the right), @"buttonStyle" (filled / outline / disabled),
//          @"action" (block) } — all but title optional.
void NFBPresentAccountSheet(NSString* title, NSString* message, NSArray<NSDictionary*>* rows) {
    NFBAccountSheetController* sheet = [NFBAccountSheetController new];
    sheet.titleText = title;
    sheet.messageText = message;
    sheet.rows = rows;
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController* presentation = sheet.sheetPresentationController;
    if (presentation) {
        CGFloat height = 30 + 28 + (message.length ? 48 : 0) + 14 + rows.count * kSheetRowHeight + 16 + 44 + 20;
        if (@available(iOS 16.0, *)) {
            UISheetPresentationControllerDetent* fit =
                [UISheetPresentationControllerDetent customDetentWithIdentifier:@"nfb.fit"
                                                                       resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                                                                           return MIN(height, context.maximumDetentValue);
                                                                       }];
            presentation.detents = @[ fit ];
        } else {
            presentation.detents = @[ [UISheetPresentationControllerDetent mediumDetent] ];
        }
        presentation.prefersGrabberVisible = YES;
        presentation.preferredCornerRadius = 32;
    }
    [NFBSheetTop() presentViewController:sheet animated:YES completion:nil];
}
