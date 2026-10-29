//
//  KemoSettingsViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTAliases.h"
#import "Core/BHTHashtags.h"
#import "Core/BHTSettings.h"
#import "Core/BHTSpotify.h"
#import "Settings/ModernSettingsCells.h"
#import "Settings/Pages/KemoAliasListViewController.h"
#import "Settings/Pages/KemoHashtagListViewController.h"

static NSString* const kClientIDKey = @"spotify_client_id";
static NSString* const kSpotifyRedirectURI = @"http://127.0.0.1/callback";

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
        [cell configureWithTitle:[self localized:data[@"titleKey"]]
                        subtitle:[self localized:state]];
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
    if ([data[@"key"] isEqualToString:@"kemo_hashtags"]) {
        ModernSettingsCompactButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                            forIndexPath:indexPath];
        [cell configureWithTitle:[self localized:data[@"titleKey"]]
                        subtitle:[[BHTHashtags favorites] componentsJoinedByString:@" "]];
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)openAliasEditor:(NSDictionary*)sender {
    [self.navigationController pushViewController:[KemoAliasListViewController new] animated:YES];
}

- (void)copySpotifyRedirect:(NSDictionary*)sender {
    [UIPasteboard generalPasteboard].string = kSpotifyRedirectURI;
    [self showMessage:[self localized:@"SPOTIFY_COPIED_LABEL"]];
}

- (void)openHashtagEditor:(NSDictionary*)sender {
    [self.navigationController pushViewController:[KemoHashtagListViewController new] animated:YES];
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
