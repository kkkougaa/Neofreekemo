//
//  KemoMoodSettingsViewController.m
//  NeoFreeBird
//

#import <objc/runtime.h>
#import "Settings/Pages/KemoMoodSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"
#import "Mood/NFBMoodFaceView.h"
#import "Settings/ModernSettingsCells.h"
#import "ThemeColor/Palette.h"

static NSString* const kSensitivityKey = @"kemo_mood_sensitivity";
static NSString* const kRageKey = @"kemo_mood_rage";

@interface ModernSettingsPageViewController (NFBMoodSlider)
- (void)sliderChanged:(UISlider*)sender;
@end

@interface NFBMoodLegendCell : UITableViewCell
@end

@implementation NFBMoodLegendCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString*)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [Palette currentBackgroundColor];
        UIStackView* row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.alignment = UIStackViewAlignmentCenter;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [row.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
            [row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12]
        ]];
        for (NSInteger level = 1; level <= 6; level++) {
            UIStackView* column = [[UIStackView alloc] init];
            column.axis = UILayoutConstraintAxisVertical;
            column.alignment = UIStackViewAlignmentCenter;
            column.spacing = 4;
            NFBMoodFaceView* face = [[NFBMoodFaceView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
            face.translatesAutoresizingMaskIntoConstraints = NO;
            face.level = level;
            [face.widthAnchor constraintEqualToConstant:28].active = YES;
            [face.heightAnchor constraintEqualToConstant:28].active = YES;
            UILabel* label = [UILabel new];
            NSString* key = [NSString stringWithFormat:@"KEMO_MOOD_LEVEL_%ld_TITLE", (long)level];
            label.text = [[BHTBundle sharedBundle] localizedStringForKey:key];
            label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
            label.textColor = [UIColor secondaryLabelColor];
            label.textAlignment = NSTextAlignmentCenter;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.6;
            label.numberOfLines = 2;
            [column addArrangedSubview:face];
            [column addArrangedSubview:label];
            [row addArrangedSubview:column];
        }
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.backgroundColor = [Palette currentBackgroundColor];
}

@end

@implementation KemoMoodSettingsViewController

- (NSString*)pageKey {
    return @"kemo_mood";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:[NFBMoodLegendCell class] forCellReuseIdentifier:@"MoodLegendCell"];
}

- (NSString*)localized:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (NSString*)sensitivityName:(float)value {
    if (value < 35.0f) {
        return [self localized:@"KEMO_MOOD_SENSITIVITY_LOOSE"];
    }
    if (value > 65.0f) {
        return [self localized:@"KEMO_MOOD_SENSITIVITY_SHARP"];
    }
    return [self localized:@"KEMO_MOOD_SENSITIVITY_NORMAL"];
}

- (NSString*)rageName:(NSInteger)mode {
    if (mode <= 0) {
        return [self localized:@"KEMO_MOOD_RAGE_OFF"];
    }
    if (mode == 1) {
        return [self localized:@"KEMO_MOOD_RAGE_BLUR"];
    }
    return [self localized:@"KEMO_MOOD_RAGE_HIDE"];
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* data = self.visibleToggles[indexPath.row];
    if ([data[@"type"] isEqualToString:@"legend"]) {
        return [tableView dequeueReusableCellWithIdentifier:@"MoodLegendCell" forIndexPath:indexPath];
    }
    if ([data[@"key"] isEqualToString:kRageKey]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell" forIndexPath:indexPath];
        [cell configureWithTitle:[self localized:@"KEMO_MOOD_RAGE_TITLE"]
                        subtitle:[self rageName:[BHTSettings integerForKey:kRageKey]]];
        return cell;
    }
    UITableViewCell* cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    if ([data[@"key"] isEqualToString:kSensitivityKey] &&
        [cell isKindOfClass:[ModernSettingsSliderCell class]]) {
        ModernSettingsSliderCell* sliderCell = (ModernSettingsSliderCell*)cell;
        sliderCell.valueLabel.text = [self sensitivityName:sliderCell.slider.value];
    }
    return cell;
}

- (void)sliderChanged:(UISlider*)sender {
    [super sliderChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if (![key isEqualToString:kSensitivityKey]) {
        return;
    }
    UIView* view = sender;
    while (view && ![view isKindOfClass:[ModernSettingsSliderCell class]]) {
        view = view.superview;
    }
    if ([view isKindOfClass:[ModernSettingsSliderCell class]]) {
        ((ModernSettingsSliderCell*)view).valueLabel.text = [self sensitivityName:sender.value];
    }
}

- (void)pickMoodRage:(NSDictionary*)sender {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[self localized:@"KEMO_MOOD_RAGE_TITLE"]
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger current = [BHTSettings integerForKey:kRageKey];
    NSArray<NSString*>* keys =
        @[ @"KEMO_MOOD_RAGE_OFF", @"KEMO_MOOD_RAGE_BLUR", @"KEMO_MOOD_RAGE_HIDE" ];
    for (NSInteger mode = 0; mode < 3; mode++) {
        NSInteger chosen = mode;
        NSString* title = [self localized:keys[mode]];
        if (current == chosen) {
            title = [@"✓ " stringByAppendingString:title];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [[NSUserDefaults standardUserDefaults] setInteger:chosen
                                                                                              forKey:kRageKey];
                                                    [self.tableView reloadData];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:alert animated:YES completion:nil];
}

@end
