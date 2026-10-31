#import "Settings/Pages/KemoHistorySettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Settings/ModernSettingsCells.h"

extern UIViewController* NFBMakeRecentViewController(void);
extern NSUInteger NFBRecentCount(void);

@implementation KemoHistorySettingsViewController

- (NSString*)pageKey {
    return @"kemo_history";
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* data = self.visibleToggles[indexPath.row];
    if ([data[@"key"] isEqualToString:@"kemo_recent_list"]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                            forIndexPath:indexPath];
        NSString* title =
            [[BHTBundle sharedBundle] localizedStringForKey:data[@"titleKey"]];
        [cell configureWithTitle:title
                        subtitle:[NSString stringWithFormat:@"%lu", (unsigned long)NFBRecentCount()]];
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)openRecentTweets:(NSDictionary*)sender {
    [self.navigationController pushViewController:NFBMakeRecentViewController() animated:YES];
}

@end
