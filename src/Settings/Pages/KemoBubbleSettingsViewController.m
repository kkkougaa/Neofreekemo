//
//  KemoBubbleSettingsViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoBubbleSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"
#import "Settings/ModernSettingsCells.h"

static NSString* const kIntervalKey = @"kemo_bubble_spotify_interval";

@implementation KemoBubbleSettingsViewController

- (NSString*)pageKey {
    return @"kemo_bubble";
}

- (NSString*)localized:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (NSString*)secondsLabel:(NSInteger)seconds {
    return [NSString stringWithFormat:[self localized:@"KEMO_BUBBLE_SECONDS"], (long)seconds];
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* data = self.visibleToggles[indexPath.row];
    if ([data[@"key"] isEqualToString:kIntervalKey]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                            forIndexPath:indexPath];
        [cell configureWithTitle:[self localized:data[@"titleKey"]]
                        subtitle:[self secondsLabel:MAX([BHTSettings integerForKey:kIntervalKey], 5)]];
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)pickSpotifyInterval:(NSDictionary*)sender {
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[self localized:@"KEMO_BUBBLE_SPOTIFY_INTERVAL_TITLE"]
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    for (NSNumber* seconds in @[ @5, @10, @15, @20, @30, @60 ]) {
        [alert addAction:[UIAlertAction actionWithTitle:[self secondsLabel:seconds.integerValue]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [[NSUserDefaults standardUserDefaults]
                                                        setInteger:seconds.integerValue
                                                            forKey:kIntervalKey];
                                                    [self.tableView reloadData];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
