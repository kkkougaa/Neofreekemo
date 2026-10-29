//
//  SensitiveToggle.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Sensitive content warning toggle in the side drawer
// A floating button in the drawer's bottom-left that flips the same
// disable_sensitive_tweet_warnings setting as the settings page. Off is the gray
// bird icon; on is the accent-colored eggplant icon with its pink blush kept.
// Layers: badge (tinted), art (white), blush (original colors).

static NSString* const kSensitiveKey = @"disable_sensitive_tweet_warnings";
static const CGFloat kToggleSize = 56.0;
static const CGFloat kToggleMargin = 20.0;
static const NSInteger kToggleTag = 0x4e464231;

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

@interface NFBSensitiveToggleButton : UIControl
@property (nonatomic, strong) UIImageView* badgeView;
@property (nonatomic, strong) UIImageView* artView;
@property (nonatomic, strong) UIImageView* blushView;
- (void)applyState;
@end

@implementation NFBSensitiveToggleButton

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.tag = kToggleTag;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Disable sensitive content warnings";
        self.accessibilityTraits = UIAccessibilityTraitButton;

        _badgeView = [self layerView];
        _artView = [self layerView];
        _blushView = [self layerView];
        [self addTarget:self
                      action:@selector(tapped)
            forControlEvents:UIControlEventTouchUpInside];
        [self applyState];
    }
    return self;
}

- (UIImageView*)layerView {
    UIImageView* view = [[UIImageView alloc] initWithFrame:self.bounds];
    view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.contentMode = UIViewContentModeScaleAspectFit;
    view.userInteractionEnabled = NO;
    [self addSubview:view];
    return view;
}

- (void)applyState {
    BOOL on = [BHTSettings boolForKey:kSensitiveKey];
    NSString* prefix = on ? @"nfb_sens_on" : @"nfb_sens_off";

    UIImage* badge = [ToggleImage([prefix stringByAppendingString:@"_badge.png"])
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImage* art = [ToggleImage([prefix stringByAppendingString:@"_art.png"])
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImage* blush = on ? ToggleImage([prefix stringByAppendingString:@"_blush.png"])
                        : nil;

    self.badgeView.image = badge;
    self.badgeView.tintColor = on ? CurrentAccentColor() : [UIColor systemGrayColor];
    self.artView.image = art;
    self.artView.tintColor = [UIColor whiteColor];
    self.blushView.image = blush;
    // Accent changes re-tint the badge through this registry; gray must stay gray.
    BHTMarkAccentTintedIcon(self.badgeView, on);

    self.accessibilityValue = on ? @"On" : @"Off";
}

- (void)tapped {
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

static void InstallSensitiveToggle(UIViewController* controller) {
    if (![controller isKindOfClass:[UIViewController class]] ||
        !controller.isViewLoaded) {
        return;
    }

    UIView* host = controller.view;
    NFBSensitiveToggleButton* button =
        (NFBSensitiveToggleButton*)[host viewWithTag:kToggleTag];
    if (!button) {
        button = [[NFBSensitiveToggleButton alloc]
            initWithFrame:CGRectMake(0, 0, kToggleSize, kToggleSize)];
        [host addSubview:button];
    } else {
        [button applyState];
    }

    UIEdgeInsets inset = host.safeAreaInsets;
    button.frame = CGRectMake(
        inset.left + kToggleMargin,
        CGRectGetHeight(host.bounds) - inset.bottom - kToggleMargin - kToggleSize,
        kToggleSize, kToggleSize);
    [host bringSubviewToFront:button];
}

// iPhone drawer
%hook T1DashContentController

- (void)viewDidLayoutSubviews {
    %orig;
    InstallSensitiveToggle((UIViewController*)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    InstallSensitiveToggle((UIViewController*)self);
}

%end

// iPad sidebar
%hook T1AppSplitSideBarViewController

- (void)viewDidLayoutSubviews {
    %orig;
    InstallSensitiveToggle(self);
}

%end
