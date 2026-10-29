//
//  KemoHashtagListViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoHashtagListViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTHashtags.h"

@interface KemoHashtagListViewController ()
@property (nonatomic, strong) NSMutableArray<NSString*>* tags;
@end

@implementation KemoHashtagListViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSString*)localized:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self localized:@"KEMO_HASHTAGS_TITLE"];
    self.tags = [[BHTHashtags favorites] mutableCopy];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Tag"];

    __weak KemoHashtagListViewController* weakSelf = self;
    UIBarButtonItem* add = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                      primaryAction:[UIAction actionWithHandler:^(UIAction* action) {
                          [weakSelf promptForNewTag];
                      }]];
    self.navigationItem.rightBarButtonItems = @[ add, self.editButtonItem ];
}

- (void)save {
    [BHTHashtags setFavorites:[self.tags copy]];
}

- (void)promptForNewTag {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[self localized:@"KEMO_HASHTAG_ADD_TITLE"]
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = @"#";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak KemoHashtagListViewController* weakSelf = self;
    __weak UIAlertController* weakAlert = alert;
    [alert addAction:[UIAlertAction
                         actionWithTitle:[self localized:@"OK_ACTION_LABEL"]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     NSString* tag = [BHTHashtags
                                         normalized:weakAlert.textFields.firstObject.text];
                                     KemoHashtagListViewController* strongSelf = weakSelf;
                                     if (!tag || [strongSelf.tags containsObject:tag]) {
                                         return;
                                     }
                                     [strongSelf.tags addObject:tag];
                                     [strongSelf save];
                                     [strongSelf.tableView reloadData];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return self.tags.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"Tag"
                                                            forIndexPath:indexPath];
    cell.textLabel.text = self.tags[indexPath.row];
    return cell;
}

- (BOOL)tableView:(UITableView*)tableView canMoveRowAtIndexPath:(NSIndexPath*)indexPath {
    return YES;
}

- (void)tableView:(UITableView*)tableView
    moveRowAtIndexPath:(NSIndexPath*)sourceIndexPath
           toIndexPath:(NSIndexPath*)destinationIndexPath {
    NSString* tag = self.tags[sourceIndexPath.row];
    [self.tags removeObjectAtIndex:sourceIndexPath.row];
    [self.tags insertObject:tag atIndex:destinationIndexPath.row];
    [self save];
}

- (void)tableView:(UITableView*)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath*)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }
    [self.tags removeObjectAtIndex:indexPath.row];
    [self save];
    [tableView deleteRowsAtIndexPaths:@[ indexPath ]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end
