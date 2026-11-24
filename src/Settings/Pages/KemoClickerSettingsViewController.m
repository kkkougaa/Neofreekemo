//
//  KemoClickerSettingsViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoClickerSettingsViewController.h"

// The clicker character on the home timeline (src/Hooks/Clicker.x). Every row is read live,
// so the character moves and resizes while the sliders move.
@implementation KemoClickerSettingsViewController

- (NSString*)pageKey {
    return @"kemo_clicker";
}

@end
