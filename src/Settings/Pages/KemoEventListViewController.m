//
//  KemoEventListViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoEventListViewController.h"
#import <objc/runtime.h>
#import "Core/BHTBundle.h"
#import "Core/BHTEvents.h"

@interface KemoEventListViewController ()
@property (nonatomic, copy) NSArray<NSDictionary*>* events;
@property (nonatomic, strong) NSDateFormatter* formatter;
@end

@implementation KemoEventListViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSString*)localized:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (void)reload {
    self.events = [BHTEvents all];
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self localized:@"KEMO_EVENTS_TITLE"];
    self.formatter = [NSDateFormatter new];
    self.formatter.dateStyle = NSDateFormatterMediumStyle;
    self.formatter.timeStyle = NSDateFormatterNoStyle;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Event"];

    __weak KemoEventListViewController* weakSelf = self;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                      primaryAction:[UIAction actionWithHandler:^(UIAction* action) {
                          [weakSelf promptForEvent];
                      }]];
    [self reload];
}

- (void)dateChanged:(UIDatePicker*)picker {
    UITextField* field = objc_getAssociatedObject(picker, @selector(dateChanged:));
    field.text = [self.formatter stringFromDate:picker.date];
}

- (void)promptForEvent {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:[self localized:@"KEMO_EVENT_ADD_TITLE"]
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = [self localized:@"KEMO_EVENT_NAME_PLACEHOLDER"];
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = [self localized:@"KEMO_EVENT_ACCOUNT_PLACEHOLDER"];
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    // The date field opens a date wheel instead of the keyboard.
    UIDatePicker* picker = [UIDatePicker new];
    picker.datePickerMode = UIDatePickerModeDate;
    picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    picker.date = [NSDate date];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = [self localized:@"KEMO_EVENT_DATE_PLACEHOLDER"];
        field.text = [self.formatter stringFromDate:picker.date];
        field.inputView = picker;
        objc_setAssociatedObject(picker, @selector(dateChanged:), field,
                                 OBJC_ASSOCIATION_ASSIGN);
        [picker addTarget:self
                      action:@selector(dateChanged:)
            forControlEvents:UIControlEventValueChanged];
    }];

    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak KemoEventListViewController* weakSelf = self;
    __weak UIAlertController* weakAlert = alert;
    [alert addAction:[UIAlertAction
                         actionWithTitle:[self localized:@"OK_ACTION_LABEL"]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     NSArray<UITextField*>* fields = weakAlert.textFields;
                                     [BHTEvents addName:fields[0].text
                                                   date:picker.date
                                                 handle:fields[1].text];
                                     [weakSelf reload];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return self.events.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"Event"
                                                            forIndexPath:indexPath];
    NSDictionary* event = self.events[indexPath.row];
    NSDate* date = [NSDate dateWithTimeIntervalSince1970:[event[@"time"] doubleValue]];
    NSInteger days = [BHTEvents daysUntil:date];
    NSString* handle = event[@"handle"];

    UIListContentConfiguration* content = [UIListContentConfiguration valueCellConfiguration];
    content.text = event[@"name"];
    content.secondaryText = [NSString
        stringWithFormat:@"%@  %@", days == 0 ? @"D-Day" : (days > 0 ? [NSString stringWithFormat:@"D-%ld", (long)days]
                                                                    : [NSString stringWithFormat:@"D+%ld", (long)-days]),
                         [self.formatter stringFromDate:date]];
    cell.contentConfiguration = content;
    cell.accessibilityHint = handle.length ? [@"@" stringByAppendingString:handle] : nil;
    return cell;
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
    [BHTEvents removeEvent:self.events[indexPath.row]];
    [self reload];
}

@end
