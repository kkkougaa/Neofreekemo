//
//  MediaOnlyTray.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Media-only row in the home filter tray
// Tapping the For You tab opens a tray for choosing topics to hide for a while. Its
// list gets one more row on top: a switch for "media tweets only" (kemo_media_only,
// applied by the timeline filter in Timeline.x). The row is the table's header view,
// so it doesn't depend on how the tray's own rows are built.

static NSString* const kMediaOnlyKey = @"kemo_media_only";
static const NSInteger kHeaderTag = 0x4e464234;
static const CGFloat kRowHeight = 48.0;
static const CGFloat kSideInset = 24.0;

@interface NFBMediaOnlyRow : UIView
@property (nonatomic, strong) UIImageView* icon;
@property (nonatomic, strong) UILabel* label;
@property (nonatomic, strong) UISwitch* toggle;
@end

@implementation NFBMediaOnlyRow

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.tag = kHeaderTag;
        self.backgroundColor = [UIColor clearColor];

        UIImageSymbolConfiguration* config =
            [UIImageSymbolConfiguration configurationWithPointSize:19
                                                            weight:UIImageSymbolWeightRegular];
        _icon = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:@"photo.on.rectangle" withConfiguration:config]];
        _icon.tintColor = [UIColor labelColor];
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_icon];

        _label = [UILabel new];
        _label.text = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_MEDIA_ONLY_TITLE"];
        _label.textColor = [UIColor labelColor];
        _label.font = [UIFont systemFontOfSize:17];
        [self addSubview:_label];

        _toggle = [UISwitch new];
        _toggle.onTintColor = CurrentAccentColor();
        _toggle.on = [BHTSettings boolForKey:kMediaOnlyKey];
        [_toggle addTarget:self
                      action:@selector(toggled)
            forControlEvents:UIControlEventValueChanged];
        [self addSubview:_toggle];
    }
    return self;
}

- (void)toggled {
    [[NSUserDefaults standardUserDefaults] setBool:self.toggle.isOn forKey:kMediaOnlyKey];
    [[[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    self.icon.frame = CGRectMake(kSideInset, (kRowHeight - 24) / 2, 24, 24);
    CGSize switchSize = self.toggle.intrinsicContentSize;
    self.toggle.frame = CGRectMake(width - kSideInset - switchSize.width,
                                   (kRowHeight - switchSize.height) / 2, switchSize.width,
                                   switchSize.height);
    CGFloat labelX = kSideInset + 24 + 16;
    self.label.frame = CGRectMake(labelX, 0, CGRectGetMinX(self.toggle.frame) - labelX - 8,
                                  kRowHeight);
}

@end

static UITableView* FirstTableView(UIView* root) {
    if ([root isKindOfClass:[UITableView class]]) {
        return (UITableView*)root;
    }
    for (UIView* sub in root.subviews) {
        UITableView* found = FirstTableView(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

static void InstallRow(UIViewController* tray) {
    if (!tray.isViewLoaded) {
        return;
    }
    UITableView* table = FirstTableView(tray.view);
    if (!table || CGRectGetWidth(table.bounds) < 100) {
        return;
    }

    UIView* existing = table.tableHeaderView;
    if (existing.tag == kHeaderTag) {
        existing.frame = CGRectMake(0, 0, CGRectGetWidth(table.bounds), kRowHeight);
        return;
    }
    table.tableHeaderView = [[NFBMediaOnlyRow alloc]
        initWithFrame:CGRectMake(0, 0, CGRectGetWidth(table.bounds), kRowHeight)];
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // The tray's content class is a private Swift type; match it by name.
    if (![NSStringFromClass(self.class) hasSuffix:@"HomeFiltersTrayContentViewController"]) {
        return;
    }
    UIViewController* tray = self;
    for (NSNumber* delay in @[ @0.0, @0.15, @0.5 ]) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                InstallRow(tray);
            });
    }
}

%end
