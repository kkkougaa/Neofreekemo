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
#import "Settings/Pages/KemoEventListViewController.h"
#import "Settings/Pages/KemoKeywordListViewController.h"

extern UIViewController* NFBMakeRecentViewController(void);
extern NSUInteger NFBRecentCount(void);

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
    if ([data[@"key"] isEqualToString:@"kemo_recent_list"]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                            forIndexPath:indexPath];
        [cell configureWithTitle:[self localized:data[@"titleKey"]]
                        subtitle:[NSString stringWithFormat:@"%lu", (unsigned long)NFBRecentCount()]];
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

- (void)openRecentTweets:(NSDictionary*)sender {
    [self.navigationController pushViewController:NFBMakeRecentViewController() animated:YES];
}

- (void)openBubbleSettings:(NSDictionary*)sender {
    [self.navigationController pushViewController:[[KemoBubbleSettingsViewController alloc] initWithAccount:self.account]
                                         animated:YES];
}

- (void)openEventEditor:(NSDictionary*)sender {
    [self.navigationController pushViewController:[KemoEventListViewController new] animated:YES];
}

- (void)openKeywordEditor:(NSDictionary*)sender {
    [self.navigationController pushViewController:[KemoKeywordListViewController new] animated:YES];
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
