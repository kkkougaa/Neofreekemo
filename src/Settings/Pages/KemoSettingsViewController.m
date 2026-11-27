//
//  KemoSettingsViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTAliases.h"
#import "Core/BHTEvents.h"
#import "Core/BHTKeywords.h"
#import "Core/BHTSettings.h"
#import "Core/BHTSpotify.h"
#import "Settings/ModernSettingsCells.h"
#import "Settings/Pages/KemoAliasListViewController.h"
#import "Settings/Pages/KemoBubbleSettingsViewController.h"
#import "Settings/Pages/KemoHistorySettingsViewController.h"
#import "Settings/Pages/KemoMediaSettingsViewController.h"
#import "Settings/Pages/KemoTabBarSettingsViewController.h"
#import "Settings/Pages/KemoClickerSettingsViewController.h"
#import "Settings/Pages/KemoEventListViewController.h"
#import "Settings/Pages/KemoKeywordListViewController.h"

extern NSArray<NSDictionary*>* NFBUnifiedAccountChoices(void);

static NSString* const kClientIDKey = @"spotify_client_id";
static NSString* const kSpotifyRedirectURI = @"http://127.0.0.1:8888/callback";

@implementation KemoSettingsViewController

- (NSString*)pageKey {
    return @"kemo";
}

- (NSString*)localized:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* data = self.visibleToggles[indexPath.row];
    if ([data[@"key"] isEqualToString:@"spotify_login"]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                            forIndexPath:indexPath];
        NSString* state = [BHTSpotify shared].isConnected ? @"SPOTIFY_CONNECTED_LABEL"
                                                         : @"SPOTIFY_DISCONNECTED_LABEL";
        NSString* status = [BHTSpotify shared].lastStatus;
        [cell configureWithTitle:[self localized:data[@"titleKey"]]
                        subtitle:status.length > 0
                                     ? [NSString stringWithFormat:@"%@ · %@", [self localized:state], status]
                                     : [self localized:state]];
        return cell;
    }
    if ([data[@"key"] isEqualToString:@"kemo_events"]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                            forIndexPath:indexPath];
        [cell configureWithTitle:[self localized:data[@"titleKey"]]
                        subtitle:[NSString stringWithFormat:@"%lu",
                                                            (unsigned long)[BHTEvents upcoming:99].count]];
        return cell;
    }
    if ([data[@"key"] isEqualToString:@"kemo_keywords"]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                            forIndexPath:indexPath];
        [cell configureWithTitle:[self localized:data[@"titleKey"]]
                        subtitle:[NSString stringWithFormat:@"%lu",
                                                            (unsigned long)[BHTKeywords all].count]];
        return cell;
    }
    if ([data[@"key"] isEqualToString:@"kemo_aliases"] ||
        [data[@"key"] isEqualToString:@"spotify_redirect"]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                            forIndexPath:indexPath];
        BOOL isAliases = [data[@"key"] isEqualToString:@"kemo_aliases"];
        [cell configureWithTitle:[self localized:data[@"titleKey"]]
                        subtitle:isAliases ? [NSString stringWithFormat:@"%lu", (unsigned long)[BHTAliases all].count]
                                           : kSpotifyRedirectURI];
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

// Opening the page asks Spotify once, so the connection row shows how it is going.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if ([BHTSpotify shared].isConnected) {
        __weak KemoSettingsViewController* weakSelf = self;
        [[BHTSpotify shared] fetchCurrentlyPlaying:^(NSString* title, NSString* artist, NSString* url, NSError* error) {
            [weakSelf.tableView reloadData];
        }];
    }
}

- (void)openKemoMedia:(NSDictionary*)sender {
    [self.navigationController pushViewController:[[KemoMediaSettingsViewController alloc] initWithAccount:self.account]
                                         animated:YES];
}

- (void)openKemoHistory:(NSDictionary*)sender {
    [self.navigationController pushViewController:[[KemoHistorySettingsViewController alloc] initWithAccount:self.account]
                                         animated:YES];
}

- (void)openKemoTabBar:(NSDictionary*)sender {
    [self.navigationController pushViewController:[[KemoTabBarSettingsViewController alloc] initWithAccount:self.account]
                                         animated:YES];
}

- (void)openKemoClicker:(NSDictionary*)sender {
    [self.navigationController pushViewController:[[KemoClickerSettingsViewController alloc] initWithAccount:self.account]
                                         animated:YES];
}

- (void)openBubbleSettings:(NSDictionary*)sender {
    [self.navigationController pushViewController:[[KemoBubbleSettingsViewController alloc] initWithAccount:self.account]
                                         animated:YES];
}

- (void)openEventEditor:(NSDictionary*)sender {
    [self.navigationController pushViewController:[KemoEventListViewController new] animated:YES];
}

// The last two shake dumps as text files, through the share sheet (save to
// Files, AirDrop, or attach to a chat), since a pasted dump gets cut short.
- (void)shareLastDump:(NSDictionary*)sender {
    NSString* folder = NSTemporaryDirectory();
    NSMutableArray<NSURL*>* items = [NSMutableArray array];
    for (NSString* name in @[ @"NeoFreeBird-dump.txt", @"NeoFreeBird-dump-previous.txt" ]) {
        NSString* path = [folder stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [items addObject:[NSURL fileURLWithPath:path]];
        }
    }
    if (items.count == 0) {
        UIAlertController* alert =
            [UIAlertController alertControllerWithTitle:[self localized:@"KEMO_SHARE_DUMP_NONE"]
                                                message:nil
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"OK_ACTION_LABEL"]
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIActivityViewController* share = [[UIActivityViewController alloc] initWithActivityItems:items
                                                                        applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)openKeywordEditor:(NSDictionary*)sender {
    [self.navigationController pushViewController:[KemoKeywordListViewController new] animated:YES];
}

// Account B of the A/B unified timeline experiment. A is whichever account is active.
- (void)pickUnifiedAccountA:(NSDictionary*)sender {
    [self pickUnifiedAccount:@"a"];
}

- (void)pickUnifiedAccountB:(NSDictionary*)sender {
    [self pickUnifiedAccount:@"b"];
}

// A and B of the unified timeline (kemo_unified_a_id / kemo_unified_b_id). The
// account sheet's "A/B" row picks them too (long press).
- (void)pickUnifiedAccount:(NSString*)which {
    BOOL isA = [which isEqualToString:@"a"];
    NSString* idKey = [NSString stringWithFormat:@"kemo_unified_%@_id", which];
    NSString* nameKey = [NSString stringWithFormat:@"kemo_unified_%@_name", which];
    NSString* otherKey = isA ? @"kemo_unified_b_id" : @"kemo_unified_a_id";
    UIAlertController* sheet =
        [UIAlertController alertControllerWithTitle:[self localized:isA ? @"KEMO_UNIFIED_A_TITLE" : @"KEMO_UNIFIED_B_TITLE"]
                                            message:[self localized:isA ? @"KEMO_UNIFIED_A_MESSAGE" : @"KEMO_UNIFIED_B_MESSAGE"]
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* current = [defaults stringForKey:idKey];
    NSString* other = [defaults stringForKey:otherKey];
    for (NSDictionary* choice in NFBUnifiedAccountChoices()) {
        if ([choice[@"id"] isEqualToString:other]) continue;  // A and B are never the same
        NSString* title = choice[@"name"];
        if ([choice[@"id"] isEqualToString:current]) title = [title stringByAppendingString:@" ✓"];
        if ([choice[@"active"] boolValue]) {
            title = [NSString stringWithFormat:@"%@ (%@)", title, [self localized:@"KEMO_UNIFIED_B_ACTIVE"]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [defaults setObject:choice[@"id"] forKey:idKey];
                                                    [defaults setObject:choice[@"name"] forKey:nameKey];
                                                    [self.tableView reloadData];
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[self localized:@"KEMO_UNIFIED_B_CLEAR"]
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction* action) {
                                                [defaults removeObjectForKey:idKey];
                                                [defaults removeObjectForKey:nameKey];
                                                [self.tableView reloadData];
                                            }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

// The colour of tweets only B has (folded corner and display name), kemo_unified_b_color.
- (void)pickUnifiedBColor:(NSDictionary*)sender {
    UIAlertController* sheet = [UIAlertController alertControllerWithTitle:[self localized:@"KEMO_UNIFIED_B_COLOR_TITLE"]
                                                                   message:[self localized:@"KEMO_UNIFIED_B_COLOR_MESSAGE"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* current = [defaults stringForKey:@"kemo_unified_b_color"] ?: @"FF7A00";
    NSArray* choices = @[
        @[ @"FF7A00", @"KEMO_UNIFIED_COLOR_ORANGE" ], @[ @"1D9BF0", @"KEMO_UNIFIED_COLOR_BLUE" ],
        @[ @"00BA7C", @"KEMO_UNIFIED_COLOR_GREEN" ], @[ @"F91880", @"KEMO_UNIFIED_COLOR_PINK" ],
        @[ @"7856FF", @"KEMO_UNIFIED_COLOR_PURPLE" ], @[ @"E0A800", @"KEMO_UNIFIED_COLOR_YELLOW" ]
    ];
    for (NSArray* choice in choices) {
        NSString* name = [self localized:choice[1]];
        NSString* title = [choice[0] isEqualToString:current] ? [name stringByAppendingString:@" ✓"] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [defaults setObject:choice[0] forKey:@"kemo_unified_b_color"];
                                                    [defaults setObject:name forKey:@"kemo_unified_b_color_name"];
                                                    [self.tableView reloadData];
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openAliasEditor:(NSDictionary*)sender {
    [self.navigationController pushViewController:[KemoAliasListViewController new] animated:YES];
}

- (void)copySpotifyRedirect:(NSDictionary*)sender {
    [UIPasteboard generalPasteboard].string = kSpotifyRedirectURI;
    [self showMessage:[self localized:@"SPOTIFY_COPIED_LABEL"]];
}

- (void)showMessage:(NSString*)message {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[self localized:@"SPOTIFY_LOGIN_TITLE"]
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"OK_ACTION_LABEL"]
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editSpotifyClientID:(NSDictionary*)sender {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[self localized:@"SPOTIFY_CLIENT_ID_TITLE"]
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.text = [[NSUserDefaults standardUserDefaults] stringForKey:kClientIDKey];
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak KemoSettingsViewController* weakSelf = self;
    [alert addAction:[UIAlertAction
                         actionWithTitle:[self localized:@"OK_ACTION_LABEL"]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     NSString* value = alert.textFields.firstObject.text;
                                     NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
                                     if (value.length > 0) {
                                         [defaults setObject:value forKey:kClientIDKey];
                                     } else {
                                         [defaults removeObjectForKey:kClientIDKey];
                                     }
                                     [weakSelf.tableView reloadData];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleSpotifyLogin:(NSDictionary*)sender {
    BHTSpotify* spotify = [BHTSpotify shared];
    if (spotify.isConnected) {
        [spotify logout];
        [self.tableView reloadData];
        return;
    }

    if (spotify.clientID.length == 0) {
        [self showMessage:[self localized:@"SPOTIFY_NEED_CLIENT_ID"]];
        return;
    }

    __weak KemoSettingsViewController* weakSelf = self;
    [spotify loginWithCompletion:^(NSError* error) {
        KemoSettingsViewController* strongSelf = weakSelf;
        [strongSelf.tableView reloadData];
        if (error && !([error.domain isEqualToString:@"com.apple.AuthenticationServices.WebAuthenticationSession"] &&
                       error.code == 1)) {
            [strongSelf showMessage:error.localizedDescription];
        }
    }];
}

@end
