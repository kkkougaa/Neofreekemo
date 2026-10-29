//
//  KemoKeywordListViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoKeywordListViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTKeywords.h"

@interface KemoKeywordListViewController ()
@property (nonatomic, strong) NSMutableArray<NSString*>* words;
@end

@implementation KemoKeywordListViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSString*)localized:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self localized:@"KEMO_KEYWORDS_TITLE"];
    self.words = [[BHTKeywords all] mutableCopy];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Word"];

    __weak KemoKeywordListViewController* weakSelf = self;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                      primaryAction:[UIAction actionWithHandler:^(UIAction* action) {
                          [weakSelf promptForWord];
                      }]];
}

- (void)save {
    [BHTKeywords setAll:[self.words copy]];
}

- (void)promptForWord {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[self localized:@"KEMO_KEYWORD_ADD_TITLE"]
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak KemoKeywordListViewController* weakSelf = self;
    __weak UIAlertController* weakAlert = alert;
    [alert addAction:[UIAlertAction
                         actionWithTitle:[self localized:@"OK_ACTION_LABEL"]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     NSString* word = [weakAlert.textFields.firstObject.text
                                         stringByTrimmingCharactersInSet:
                                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                     KemoKeywordListViewController* strongSelf = weakSelf;
                                     if (word.length == 0 || [strongSelf.words containsObject:word]) {
                                         return;
                                     }
                                     [strongSelf.words addObject:word];
                                     [strongSelf save];
                                     [strongSelf.tableView reloadData];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return self.words.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"Word"
                                                            forIndexPath:indexPath];
    cell.textLabel.text = self.words[indexPath.row];
    return cell;
}

- (void)tableView:(UITableView*)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath*)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }
    [self.words removeObjectAtIndex:indexPath.row];
    [self save];
    [tableView deleteRowsAtIndexPaths:@[ indexPath ]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end
