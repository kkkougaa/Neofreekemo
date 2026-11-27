//
//  UnifiedSheet.x
//  NeoFreeBird
//
//  7.3.149: the "which account?" questions of the A/B unified mode as a sheet
//  that rises from the bottom (iOS 26 shows UIAlertController action sheets as
//  popovers next to the tapped button). Rows carry an account picture, a title,
//  a detail line and an action; a cancel row closes it. Used by
//  UnifiedTimeline.x and UnifiedProfile.x through NFBPresentAccountSheet().
//

#import "HookHelpers.h"

@interface NFBAccountSheetController : UIViewController
@property (nonatomic, copy) NSString* titleText;
@property (nonatomic, copy) NSString* messageText;
@property (nonatomic, strong) NSArray<NSDictionary*>* rows;
@end

@implementation NFBAccountSheetController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UIStackView* stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:28],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
    ]];

    UILabel* title = [UILabel new];
    title.text = self.titleText;
    title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    title.numberOfLines = 0;
    [stack addArrangedSubview:title];
    if (self.messageText.length) {
        UILabel* message = [UILabel new];
        message.text = self.messageText;
        message.font = [UIFont systemFontOfSize:14];
        message.textColor = [UIColor secondaryLabelColor];
        message.numberOfLines = 0;
        [stack addArrangedSubview:message];
    }
    [stack setCustomSpacing:16 afterView:stack.arrangedSubviews.lastObject];

    for (NSUInteger i = 0; i < self.rows.count; i++) {
        NSDictionary* row = self.rows[i];
        UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)i;
        button.backgroundColor = [UIColor secondarySystemBackgroundColor];
        button.layer.cornerRadius = 16;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button.heightAnchor constraintEqualToConstant:58].active = YES;
        [button addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView* picture = [UIImageView new];
        picture.image = row[@"image"];
        picture.contentMode = UIViewContentModeScaleAspectFill;
        picture.clipsToBounds = YES;
        picture.layer.cornerRadius = 17;
        picture.translatesAutoresizingMaskIntoConstraints = NO;
        picture.userInteractionEnabled = NO;
        [button addSubview:picture];

        UILabel* label = [UILabel new];
        label.text = row[@"title"];
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        label.textColor = [row[@"destructive"] boolValue] ? [UIColor systemRedColor] : [UIColor labelColor];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.userInteractionEnabled = NO;
        [button addSubview:label];

        UILabel* detail = [UILabel new];
        detail.text = row[@"detail"];
        detail.font = [UIFont systemFontOfSize:13];
        detail.textColor = [UIColor secondaryLabelColor];
        detail.translatesAutoresizingMaskIntoConstraints = NO;
        detail.userInteractionEnabled = NO;
        [button addSubview:detail];

        BOOL hasPicture = row[@"image"] != nil;
        [NSLayoutConstraint activateConstraints:@[
            [picture.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:14],
            [picture.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
            [picture.widthAnchor constraintEqualToConstant:hasPicture ? 34 : 0],
            [picture.heightAnchor constraintEqualToConstant:34],
            [label.leadingAnchor constraintEqualToAnchor:picture.trailingAnchor constant:hasPicture ? 12 : 4],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:button.trailingAnchor constant:-14],
            [label.topAnchor constraintEqualToAnchor:button.topAnchor constant:[row[@"detail"] length] ? 10 : 19],
            [detail.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
            [detail.trailingAnchor constraintLessThanOrEqualToAnchor:button.trailingAnchor constant:-14],
            [detail.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:2],
        ]];
        button.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", row[@"title"] ?: @"", row[@"detail"] ?: @""];
        [stack addArrangedSubview:button];
    }

    UIButton* cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"취소" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [cancel.heightAnchor constraintEqualToConstant:48].active = YES;
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:cancel];
}

- (void)rowTapped:(UIButton*)button {
    NSDictionary* row = button.tag < (NSInteger)self.rows.count ? self.rows[(NSUInteger)button.tag] : nil;
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
    UIWindow* window = nil;
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* candidate in ((UIWindowScene*)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    UIViewController* top = window.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

// rows: @{ @"title", @"detail" (optional), @"image" (optional), @"destructive" (optional), @"action" (block) }
void NFBPresentAccountSheet(NSString* title, NSString* message, NSArray<NSDictionary*>* rows) {
    NFBAccountSheetController* sheet = [NFBAccountSheetController new];
    sheet.titleText = title;
    sheet.messageText = message;
    sheet.rows = rows;
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController* presentation = sheet.sheetPresentationController;
    if (presentation) {
        CGFloat height = 28 + 30 + (message.length ? 40 : 0) + 16 + rows.count * 68.0 + 60 + 20;
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
        presentation.preferredCornerRadius = 28;
    }
    [NFBSheetTop() presentViewController:sheet animated:YES completion:nil];
}
