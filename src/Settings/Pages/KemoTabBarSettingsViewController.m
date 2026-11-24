//
//  KemoTabBarSettingsViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoTabBarSettingsViewController.h"
#import <objc/runtime.h>
#import "Core/BHTBundle.h"

@implementation KemoTabBarSettingsViewController

- (NSString*)pageKey {
    return @"kemo_tab_bar";
}

// X reads both when it builds the tab bar, so they need a restart.
- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if (![key isEqualToString:@"kemo_vertical_tab_bar"] && ![key isEqualToString:@"hide_quick_compose"]) {
        return;
    }
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[bundle localizedStringForKey:@"LIQUID_GLASS_RESTART_ALERT_TITLE"]
                                            message:[bundle localizedStringForKey:@"SETTING_RESTART_ALERT_MESSAGE"]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"LIQUID_GLASS_RESTART_ALERT_RESTART_BUTTON"]
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction* action) {
                                                exit(0);
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"DISMISS_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
