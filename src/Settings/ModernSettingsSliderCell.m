//
//  ModernSettingsSliderCell.m
//  NeoFreeBird
//

#import "Settings/ModernSettingsCells.h"
#import "Core/BHTManager.h"
#import "Headers/Helpers.h"
#import "Headers/TWHeaders.h"
#import "ThemeColor/Palette.h"

@implementation ModernSettingsSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString*)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [Palette currentBackgroundColor];

        self.titleLabel = [UILabel new];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.titleLabel];

        self.valueLabel = [UILabel new];
        self.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.valueLabel.textAlignment = NSTextAlignmentRight;
        [self.valueLabel setContentHuggingPriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
        [self.contentView addSubview:self.valueLabel];

        self.slider = [UISlider new];
        self.slider.translatesAutoresizingMaskIntoConstraints = NO;
        self.slider.minimumTrackTintColor = CurrentAccentColor();
        [self.contentView addSubview:self.slider];

        [self applyTheme];
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                          constant:20],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                      constant:14],
            [self.valueLabel.trailingAnchor
                constraintEqualToAnchor:self.contentView.trailingAnchor
                               constant:-20],
            [self.valueLabel.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
            [self.titleLabel.trailingAnchor
                constraintLessThanOrEqualToAnchor:self.valueLabel.leadingAnchor
                                         constant:-12],
            [self.slider.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.slider.trailingAnchor constraintEqualToAnchor:self.valueLabel.trailingAnchor],
            [self.slider.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor
                                                  constant:8],
            [self.slider.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                     constant:-14]
        ]];
    }
    return self;
}

- (void)configureWithTitle:(NSString*)title
                   minimum:(float)minimum
                   maximum:(float)maximum
                     value:(float)value {
    self.titleLabel.text = title;
    self.slider.minimumValue = minimum;
    self.slider.maximumValue = maximum;
    self.slider.value = value;
    [self updateValueLabel];
}

- (void)updateValueLabel {
    self.valueLabel.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(self.slider.value)];
}

- (void)applyTheme {
    id fontGroup = [BHTManager sharedFontGroup];
    self.titleLabel.font = [fontGroup performSelector:@selector(bodyBoldFont)];
    self.valueLabel.font = [fontGroup performSelector:@selector(subtext2Font)];
    Class TAEColorSettingsCls = objc_getClass("TAEColorSettings");
    id settings = [TAEColorSettingsCls sharedSettings];
    id colorPalette = [[settings currentColorPalette] colorPalette];
    self.titleLabel.textColor = [colorPalette performSelector:@selector(textColor)];
    self.valueLabel.textColor = [colorPalette performSelector:@selector(tabBarItemColor)];
}

- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyTheme];
}

@end
