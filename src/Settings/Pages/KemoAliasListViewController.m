//
//  KemoAliasListViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoAliasListViewController.h"
#import "Core/BHTAliases.h"
#import "Core/BHTBundle.h"

@interface KemoAliasListViewController ()
@property (nonatomic, copy) NSArray<NSString*>* handles; // sorted
@end

@implementation KemoAliasListViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSString*)localized:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (void)reload {
    self.handles = [[[BHTAliases all] allKeys]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self localized:@"KEMO_ALIASES_TITLE"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Alias"];

    __weak KemoAliasListViewController* weakSelf = self;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                      primaryAction:[UIAction actionWithHandler:^(UIAction* action) {
                          [weakSelf promptForHandle:nil];
                      }]];
    [self reload];
}

// Adds an alias, or edits the one for `existingHandle`.
- (void)promptForHandle:(NSString*)existingHandle {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[self localized:@"KEMO_ALIAS_ADD_TITLE"]
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = [self localized:@"KEMO_ALIAS_HANDLE_PLACEHOLDER"];
        field.text = existingHandle ? [@"@" stringByAppendingString:existingHandle] : nil;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = [self localized:@"KEMO_ALIAS_NAME_PLACEHOLDER"];
        field.text = existingHandle ? [BHTAliases aliasForHandle:existingHandle] : nil;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak KemoAliasListViewController* weakSelf = self;
    __weak UIAlertController* weakAlert = alert;
    [alert addAction:[UIAlertAction
                         actionWithTitle:[self localized:@"OK_ACTION_LABEL"]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     NSString* handle = [BHTAliases
                                         normalizedHandle:weakAlert.textFields[0].text];
                                     NSString* alias = weakAlert.textFields[1].text;
                                     if (!handle) {
                                         return;
                                     }
                                     if (existingHandle && ![existingHandle isEqualToString:handle]) {
                                         [BHTAliases setAlias:nil forHandle:existingHandle];
                                     }
                                     [BHTAliases setAlias:alias forHandle:handle];
                                     [weakSelf reload];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return self.handles.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"Alias"
                                                            forIndexPath:indexPath];
    NSString* handle = self.handles[indexPath.row];
    UIListContentConfiguration* content = [UIListContentConfiguration valueCellConfiguration];
    content.text = [@"@" stringByAppendingString:handle];
    content.secondaryText = [BHTAliases aliasForHandle:handle];
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self promptForHandle:self.handles[indexPath.row]];
}

- (BOOL)tableView:(UITableView*)tableView canEditRowAtIndexPath:(NSIndexPath*)indexPath {
    return YES;
}

- (void)tableView:(UITableView*)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath*)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }
    [BHTAliases setAlias:nil forHandle:self.handles[indexPath.row]];
    [self reload];
}

@end
