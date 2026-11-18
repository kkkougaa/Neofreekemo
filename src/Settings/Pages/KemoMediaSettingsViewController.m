#import "Settings/Pages/KemoMediaSettingsViewController.h"
#import "Settings/Pages/KemoCardStyleViewController.h"

@implementation KemoMediaSettingsViewController

- (NSString*)pageKey {
    return @"kemo_media";
}

// "Cards and text": card look, corner radius, gaps, colour and text sizes.
- (void)openCardStyle:(NSDictionary*)sender {
    [self.navigationController pushViewController:[KemoCardStyleViewController new] animated:YES];
}

@end
