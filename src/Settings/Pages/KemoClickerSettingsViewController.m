//
//  KemoClickerSettingsViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoClickerSettingsViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/BHTBundle.h"
#import "Core/NFBClickerStore.h"

// The clicker character on the home timeline and the composer (src/Hooks/Clicker.x). Every
// row is read live, so the character moves and resizes while the sliders move. The three
// buttons on top choose, bring in and remove characters from BUG Clicker .cvclk files.
@interface KemoClickerSettingsViewController () <UIDocumentPickerDelegate>
@end

@implementation KemoClickerSettingsViewController

- (NSString*)pageKey {
    return @"kemo_clicker";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSString*)text:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (UIView*)sourceViewFor:(NSDictionary*)sender {
    NSString* key = sender[@"key"];
    for (UITableViewCell* cell in self.tableView.visibleCells) {
        NSIndexPath* path = [self.tableView indexPathForCell:cell];
        if (path && path.row < (NSInteger)self.visibleToggles.count &&
            [self.visibleToggles[path.row][@"key"] isEqual:key]) {
            return cell;
        }
    }
    return self.view;
}

- (void)presentSheet:(UIAlertController*)sheet from:(NSDictionary*)sender {
    UIView* source = [self sourceViewFor:sender];
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showMessage:(NSString*)title detail:(NSString*)detail {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:detail
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"DISMISS_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Every character in every file; a file not opened yet shows its file name once.
- (void)pickClickerCharacter:(NSDictionary*)sender {
    UIAlertController* sheet = [UIAlertController alertControllerWithTitle:[self text:@"KEMO_CLICKER_PICK_TITLE"]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSString* selected = [NFBClickerStore selectedEntry];
    NSInteger selectedIndex = [NFBClickerStore selectedIndex];
    __weak typeof(self) weakSelf = self;
    void (^add)(NSString*, NSString*, NSInteger) = ^(NSString* title, NSString* entryId, NSInteger index) {
        BOOL current = [selected isEqualToString:entryId] && (entryId.length == 0 || selectedIndex == index);
        NSString* shown = current ? [@"✓ " stringByAppendingString:title] : title;
        [sheet addAction:[UIAlertAction actionWithTitle:shown
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [NFBClickerStore selectEntry:entryId index:index];
                                                    [weakSelf.tableView reloadData];
                                                }]];
    };
    add([self text:@"KEMO_CLICKER_DEFAULT_CHARACTER"], @"", 0);
    for (NSDictionary* e in [NFBClickerStore entries]) {
        NSArray* names = [e[@"names"] isKindOfClass:[NSArray class]] ? e[@"names"] : @[];
        NSString* label = e[@"label"] ?: @"";
        if ([e[@"error"] length] > 0) {
            label = [NSString stringWithFormat:@"%@ (%@)", label, [self text:@"KEMO_CLICKER_BROKEN"]];
        }
        if (names.count == 0) {
            add(label, e[@"id"], 0);
            continue;
        }
        for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
            NSString* name = [names[i] isKindOfClass:[NSString class]] ? names[i] : label;
            add(names.count > 1 ? [NSString stringWithFormat:@"%@ · %@", name, label] : name, e[@"id"], i);
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[self text:@"DISMISS_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentSheet:sheet from:sender];
}

// Sliders over the real timeline (Clicker.x NFBClickerAdjustPanel) until its Done.
- (void)startClickerAdjust:(NSDictionary*)sender {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"kemo_clicker_adjust"];
    [self showMessage:[self text:@"KEMO_CLICKER_ADJUST_HERE_TITLE"] detail:[self text:@"KEMO_CLICKER_ADJUST_HERE_DETAIL"]];
}

- (void)importClickerCharacter:(NSDictionary*)sender {
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    NSURL* url = urls.firstObject;
    if (!url) {
        return;
    }
    NSString* error = nil;
    NSString* entryId = [NFBClickerStore importFileAtURL:url error:&error];
    if (!entryId) {
        [self showMessage:[self text:@"KEMO_CLICKER_IMPORT_FAILED"] detail:error];
        return;
    }
    [NFBClickerStore selectEntry:entryId index:0];
    [self.tableView reloadData];
    [self showMessage:[self text:@"KEMO_CLICKER_IMPORT_DONE"] detail:[self text:@"KEMO_CLICKER_IMPORT_DONE_DETAIL"]];
}

- (void)removeClickerCharacter:(NSDictionary*)sender {
    NSArray* entries = [NFBClickerStore entries];
    if (entries.count == 0) {
        [self showMessage:[self text:@"KEMO_CLICKER_REMOVE_TITLE"] detail:[self text:@"KEMO_CLICKER_REMOVE_NONE"]];
        return;
    }
    UIAlertController* sheet = [UIAlertController alertControllerWithTitle:[self text:@"KEMO_CLICKER_REMOVE_TITLE"]
                                                                   message:[self text:@"KEMO_CLICKER_REMOVE_DETAIL"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary* e in entries) {
        NSArray* names = [e[@"names"] isKindOfClass:[NSArray class]] ? e[@"names"] : @[];
        NSString* title = e[@"label"] ?: @"";
        if (names.count > 0) {
            title = [NSString stringWithFormat:@"%@ (%@)", title, [names componentsJoinedByString:@", "]];
        }
        NSString* entryId = e[@"id"];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction* action) {
                                                    [NFBClickerStore removeEntry:entryId];
                                                    [weakSelf.tableView reloadData];
                                                }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[self text:@"DISMISS_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentSheet:sheet from:sender];
}

@end
