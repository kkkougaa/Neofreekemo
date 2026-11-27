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
//    7.3.151: a row marked "stay" runs its action and leaves the sheet up (the
//    caller then changes that row in place), so A and B can both be acted for
//    in one sheet; such a sheet's footer says "닫기", not "취소".
//  - NFBShowNotice(): a short notice. 7.3.151: pushed through X's own toaster
//    (TFNToaster / TFNInformationToast), so it is X's black toast from the top;
//    the glass capsule above the tab bar is only the fallback.
//  - NFBShowBlockNotice(): the same notice with a warning haptic, for every
//    "this was stopped" message of the unified mode (7.3.151).
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

// Only a lock token for the notice log.
@interface NFBNoticeLogLock : NSObject
@end
@implementation NFBNoticeLogLock
@end

// 7.3.151: which path each notice took (X's toaster or our own capsule) and
// what was found at runtime; printed by NFBUnifiedSheetDebugText().
static NSMutableArray<NSString*>* gNoticeLog;
static NSUInteger gNoticeXCount;
static NSUInteger gNoticeFallbackCount;
static NSUInteger gNoticeBlockCount;  // notices shown through NFBShowBlockNotice()
// 7.3.151: each sheet's shape as presented and each tap on a "stay" row.
static NSMutableArray<NSString*>* gSheetLog;

static void NFBNoticeLog(NSString* line) {
    @synchronized([NFBNoticeLogLock class]) {
        if (!gNoticeLog) gNoticeLog = [NSMutableArray array];
        [gNoticeLog addObject:line];
        if (gNoticeLog.count > 12) [gNoticeLog removeObjectAtIndex:0];
    }
}

static void NFBSheetLog(NSString* line) {
    @synchronized([NFBNoticeLogLock class]) {
        if (!gSheetLog) gSheetLog = [NSMutableArray array];
        [gSheetLog addObject:line];
        if (gSheetLog.count > 12) [gSheetLog removeObjectAtIndex:0];
    }
}

// 7.3.151: hand the text to X's own toaster so the notice is X's black toast
// that drops from the top (X's queue, position and dismissal), not a look-alike.
// From the 12.44 dump (XServiceLibraries): +[TFNToaster defaultToaster] @16@0:8,
// -[TFNToaster pushToast:] v24@0:8@16, -[TFNToaster toastViewController] @16@0:8,
// -[TFNInformationToast initWithMessageText:] @24@0:8@16 (no icon: the plain one).
// Returns NO, with the reason logged, when a piece is missing or the call throws.
static BOOL NFBShowXToast(NSString* text) {
    NSString* reason = nil;
    @try {
        Class toasterClass = NSClassFromString(@"TFNToaster");
        Class toastClass = NSClassFromString(@"TFNInformationToast");
        SEL defaultToaster = NSSelectorFromString(@"defaultToaster");
        SEL pushToast = NSSelectorFromString(@"pushToast:");
        SEL initWithMessageText = NSSelectorFromString(@"initWithMessageText:");
        SEL toastViewController = NSSelectorFromString(@"toastViewController");
        Method pushMethod = toasterClass ? class_getInstanceMethod(toasterClass, pushToast) : NULL;
        Method initMethod = toastClass ? class_getInstanceMethod(toastClass, initWithMessageText) : NULL;
        if (!toasterClass) {
            reason = @"no class TFNToaster";
        } else if (!toastClass) {
            reason = @"no class TFNInformationToast";
        } else if (!class_getClassMethod(toasterClass, defaultToaster)) {
            reason = @"no +[TFNToaster defaultToaster]";
        } else if (!pushMethod || method_getNumberOfArguments(pushMethod) != 3) {
            reason = @"no -[TFNToaster pushToast:]";
        } else if (!initMethod || method_getNumberOfArguments(initMethod) != 3) {
            reason = @"no -[TFNInformationToast initWithMessageText:]";
        } else {
            id toaster = ((id (*)(id, SEL))objc_msgSend)(toasterClass, defaultToaster);
            if (!toaster) {
                reason = @"defaultToaster is nil";
            } else if (class_getInstanceMethod(toasterClass, toastViewController) &&
                       !((id (*)(id, SEL))objc_msgSend)(toaster, toastViewController)) {
                // Nothing would draw the toast; a notice must not be lost.
                reason = @"toaster has no toastViewController";
            } else {
                id toast = ((id (*)(id, SEL, id))objc_msgSend)([toastClass alloc], initWithMessageText, text);
                if (!toast) {
                    reason = @"initWithMessageText: returned nil";
                } else {
                    ((void (*)(id, SEL, id))objc_msgSend)(toaster, pushToast, toast);
                    gNoticeXCount++;
                    NFBNoticeLog([NSString stringWithFormat:@"X toast: +[TFNToaster defaultToaster]=%@ pushToast: <- %@ (initWithMessageText:) \"%@\"",
                                                            NSStringFromClass([toaster class]), NSStringFromClass([toast class]), text]);
                    return YES;
                }
            }
        }
    } @catch (NSException* exception) {
        reason = [NSString stringWithFormat:@"threw %@: %@", exception.name, exception.reason];
    }
    gNoticeFallbackCount++;
    NFBNoticeLog([NSString stringWithFormat:@"fallback (%@) \"%@\"", reason ?: @"?", text]);
    return NO;
}

NSString* NFBUnifiedSheetDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    Class toasterClass = NSClassFromString(@"TFNToaster");
    Class toastClass = NSClassFromString(@"TFNInformationToast");
    [out appendFormat:@"notice: X toast %lu, fallback %lu, blocked (warning haptic) %lu\n", (unsigned long)gNoticeXCount,
                      (unsigned long)gNoticeFallbackCount, (unsigned long)gNoticeBlockCount];
    [out appendFormat:@"TFNToaster=%d defaultToaster=%d pushToast:=%d TFNInformationToast=%d initWithMessageText:=%d\n",
                      toasterClass != Nil,
                      toasterClass && class_getClassMethod(toasterClass, NSSelectorFromString(@"defaultToaster")) != NULL,
                      toasterClass && class_getInstanceMethod(toasterClass, NSSelectorFromString(@"pushToast:")) != NULL,
                      toastClass != Nil,
                      toastClass && class_getInstanceMethod(toastClass, NSSelectorFromString(@"initWithMessageText:")) != NULL];
    @synchronized([NFBNoticeLogLock class]) {
        [out appendFormat:@"%@\n", gNoticeLog.count ? [gNoticeLog componentsJoinedByString:@"\n"] : @"(no notices)"];
        [out appendFormat:@"sheets:\n%@\n", gSheetLog.count ? [gSheetLog componentsJoinedByString:@"\n"] : @"(no sheets)"];
    }
    return out;
}

void NFBShowNotice(NSString* text) {
    if (text.length == 0) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NFBShowNotice(text);
        });
        return;
    }
    // 7.3.151: X's own toast first; the capsule below only when that is not possible.
    if (NFBShowXToast(text)) return;
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

// 7.3.151: a notice that something was stopped (not sent, not opened): the
// same toast, with the system's warning haptic so it does not pass for a
// "sent" one. Every block message of the unified mode goes through here.
void NFBShowBlockNotice(NSString* text) {
    if (text.length == 0) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NFBShowBlockNotice(text);
        });
        return;
    }
    UINotificationFeedbackGenerator* haptic = [UINotificationFeedbackGenerator new];
    [haptic prepare];
    [haptic notificationOccurred:UINotificationFeedbackTypeWarning];
    gNoticeBlockCount++;
    NFBShowNotice(text);
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
@property (nonatomic, assign) CFAbsoluteTime lastStayTap;
- (void)updateRowAtIndex:(NSUInteger)index changes:(NSDictionary*)changes;
@end

static const CGFloat kSheetRowHeight = 64;
// 7.3.151: a row's detail line and pill, found again by NFBUpdateAccountSheetRow().
static const NSInteger kSheetDetailTag = 0x4E4644;  // "NFD"
static const NSInteger kSheetPillTag = 0x4E4650;    // "NFP"

@implementation NFBAccountSheetController

// The pill's text, colours and width for a style; also restyles one already shown.
- (void)stylePill:(UILabel*)pill title:(NSString*)title style:(NSString*)style {
    pill.text = title;
    pill.backgroundColor = UIColor.clearColor;
    pill.layer.borderWidth = 0;
    if ([style isEqualToString:@"filled"]) {
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
    CGFloat width = MAX(ceil([title sizeWithAttributes:@{NSFontAttributeName : pill.font}].width) + 32, 76);
    for (NSLayoutConstraint* constraint in pill.constraints) {
        if (constraint.firstItem == pill && constraint.firstAttribute == NSLayoutAttributeWidth && !constraint.secondItem) constraint.constant = width;
    }
}

// 7.3.151: change a shown row's detail line and pill in place (keys: detail,
// button, buttonStyle, disabled). The row's action stays; a "stay" row's
// action reads the state again when it is tapped.
- (void)updateRowAtIndex:(NSUInteger)index changes:(NSDictionary*)changes {
    if (index >= self.rows.count || changes.count == 0) return;
    NSMutableDictionary* row = [self.rows[index] mutableCopy];
    for (NSString* key in @[ @"detail", @"button", @"buttonStyle", @"disabled" ]) {
        if (changes[key]) row[key] = changes[key];
    }
    NSMutableArray<NSDictionary*>* rows = [self.rows mutableCopy];
    rows[index] = row;
    self.rows = rows;
    if (!self.isViewLoaded) return;
    UIStackView* stack = (UIStackView*)self.view.subviews.firstObject;
    if (![stack isKindOfClass:[UIStackView class]]) return;
    for (UIView* control in stack.arrangedSubviews) {
        if (![control isKindOfClass:[NFBSheetRow class]] || control.tag != (NSInteger)index) continue;
        BOOL disabled = [row[@"disabled"] boolValue];
        if ([control isKindOfClass:[UIControl class]]) ((UIControl*)control).enabled = !disabled;
        control.alpha = disabled ? 0.5 : 1;
        control.accessibilityTraits = UIAccessibilityTraitButton | (disabled ? UIAccessibilityTraitNotEnabled : 0);
        [UIView transitionWithView:control duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            for (UIView* child in control.subviews) {
                if (![child isKindOfClass:[UILabel class]]) continue;
                if (child.tag == kSheetDetailTag) {
                    ((UILabel*)child).text = row[@"detail"];
                } else if (child.tag == kSheetPillTag && [row[@"button"] length]) {
                    [self stylePill:(UILabel*)child title:row[@"button"] style:disabled ? @"disabled" : (row[@"buttonStyle"] ?: @"filled")];
                }
            }
        } completion:nil];
        control.accessibilityLabel = [NSString stringWithFormat:@"%@, %@ %@", row[@"title"] ?: @"", row[@"detail"] ?: @"", row[@"button"] ?: @""];
        break;
    }
}

- (UIView*)pillWithTitle:(NSString*)title style:(NSString*)style {
    UILabel* pill = [UILabel new];
    pill.tag = kSheetPillTag;
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
        detail.tag = kSheetDetailTag;
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

    // 7.3.151: with rows that keep the sheet up, the footer closes it ("닫기");
    // "취소" would read as undoing what those rows already sent.
    BOOL stays = NO;
    for (NSDictionary* row in self.rows) {
        if ([row[@"stay"] boolValue]) stays = YES;
    }
    UIView* footer = [UIView new];
    UIButton* cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:stays ? @"닫기" : @"취소" forState:UIControlStateNormal];
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
    if ([row[@"stay"] boolValue]) {
        // 7.3.151: the sheet stays up; the action changes this row through
        // NFBUpdateAccountSheetRow(). Two taps closer than half a second are
        // one tap (a second one would undo what the first just sent).
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - self.lastStayTap < 0.5) return;
        self.lastStayTap = now;
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        NFBSheetLog([NSString stringWithFormat:@"stay row %ld tapped in \"%@\" (was: %@ / %@)", (long)control.tag, self.titleText ?: @"",
                                               row[@"detail"] ?: @"-", row[@"button"] ?: @"-"]);
        if (action) action();
        return;
    }
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
//          @"stay" (7.3.151: the tap runs the action and the sheet stays up),
//          @"action" (block) } — all but title optional.
static __weak NFBAccountSheetController* gShownSheet;
static NSUInteger gSheetToken;

// 7.3.151: names the sheet presented last, for NFBUpdateAccountSheetRow().
NSUInteger NFBAccountSheetToken(void) {
    return gSheetToken;
}

// 7.3.151: change a row of the sheet `token` names after it is shown (keys:
// detail, button, buttonStyle, disabled). Nothing happens when that sheet is
// gone or another one has been presented since.
void NFBUpdateAccountSheetRow(NSUInteger token, NSUInteger index, NSDictionary* changes) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NFBUpdateAccountSheetRow(token, index, changes);
        });
        return;
    }
    NFBAccountSheetController* sheet = gShownSheet;
    if (!sheet || token != gSheetToken || sheet.isBeingDismissed) return;
    [sheet updateRowAtIndex:index changes:changes];
}

// (row keys: see above the token functions)
void NFBPresentAccountSheet(NSString* title, NSString* message, NSArray<NSDictionary*>* rows) {
    NFBAccountSheetController* sheet = [NFBAccountSheetController new];
    gShownSheet = sheet;
    gSheetToken++;
    sheet.titleText = title;
    sheet.messageText = message;
    sheet.rows = rows;
    NSUInteger stayRows = 0, pillRows = 0, offRows = 0;
    for (NSDictionary* row in rows) {
        if ([row[@"stay"] boolValue]) stayRows++;
        if ([row[@"button"] length]) pillRows++;
        if ([row[@"disabled"] boolValue]) offRows++;
    }
    NFBSheetLog([NSString stringWithFormat:@"sheet #%lu \"%@\": %lu rows (pill %lu, stay %lu, disabled %lu), footer %@", (unsigned long)gSheetToken,
                                           title ?: @"", (unsigned long)rows.count, (unsigned long)pillRows, (unsigned long)stayRows,
                                           (unsigned long)offRows, stayRows ? @"닫기" : @"취소"]);
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
