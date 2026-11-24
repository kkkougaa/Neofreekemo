//
//  KemoClickerRemindViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/KemoClickerRemindViewController.h"
#import "Core/BHTBundle.h"
#import "Core/NFBClickerRemind.h"

static NSString* T(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

// "월 화 수" for the chosen weekdays (0 = Sunday), or "매일".
static NSString* DaysText(NSArray* days) {
    if (days.count == 7) {
        return T(@"KEMO_CLICKER_REMIND_EVERYDAY");
    }
    NSArray* names = [[NSDateFormatter new] veryShortStandaloneWeekdaySymbols];
    NSMutableArray* out = [NSMutableArray array];
    // Monday first, as most calendars here read.
    for (NSNumber* d in @[@1, @2, @3, @4, @5, @6, @0]) {
        if ([days containsObject:d]) {
            [out addObject:names[d.integerValue]];
        }
    }
    return out.count ? [out componentsJoinedByString:@" "] : T(@"KEMO_CLICKER_REMIND_NO_DAYS");
}

static NSDate* DateFromHHMM(NSString* hhmm) {
    NSArray* p = [hhmm componentsSeparatedByString:@":"];
    return [[NSCalendar currentCalendar] dateBySettingHour:[p.firstObject integerValue]
                                                    minute:[p.lastObject integerValue]
                                                    second:0
                                                    ofDate:[NSDate date]
                                                   options:0];
}

static NSString* HHMMFromDate(NSDate* date) {
    NSDateComponents* c = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:date];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)c.hour, (long)c.minute];
}

// MARK: - Time sheet

// A time wheel in a half sheet; for alarms also weekday buttons and a memo.
@interface NFBRemindTimeSheet : UIViewController
@property (nonatomic, strong) UIDatePicker* picker;
@property (nonatomic, strong) NSMutableArray<NSNumber*>* days; // nil: no weekday row
@property (nonatomic, copy) NSString* memo;                   // nil: no memo row
@property (nonatomic, strong) UITextField* memoField;
@property (nonatomic, strong) NSArray<UIButton*>* dayButtons;
@property (nonatomic, copy) void (^done)(NSString* hhmm, NSArray* days, NSString* memo);
@end

@implementation NFBRemindTimeSheet

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIStackView* stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
    ]];

    UIStackView* bar = [UIStackView new];
    UIButton* cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:T(@"DISMISS_LABEL") forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    UIButton* save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:T(@"KEMO_CLICKER_ADJUST_DONE") forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
    [bar addArrangedSubview:cancel];
    [bar addArrangedSubview:[UIView new]];
    [bar addArrangedSubview:save];
    [stack addArrangedSubview:bar];

    [stack addArrangedSubview:self.picker];

    if (self.days) {
        UIStackView* row = [UIStackView new];
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 6;
        NSArray* names = [[NSDateFormatter new] veryShortStandaloneWeekdaySymbols];
        NSMutableArray* buttons = [NSMutableArray array];
        for (NSNumber* d in @[@1, @2, @3, @4, @5, @6, @0]) {
            UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
            [b setTitle:names[d.integerValue] forState:UIControlStateNormal];
            b.tag = d.integerValue;
            b.layer.cornerRadius = 16;
            [b.heightAnchor constraintEqualToConstant:32].active = YES;
            [b addTarget:self action:@selector(toggleDay:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:b];
            [buttons addObject:b];
        }
        self.dayButtons = buttons;
        [stack addArrangedSubview:row];
        [self paintDays];
    }
    if (self.memo) {
        UITextField* field = [UITextField new];
        field.placeholder = T(@"KEMO_CLICKER_REMIND_MEMO");
        field.text = self.memo;
        field.borderStyle = UITextBorderStyleRoundedRect;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        self.memoField = field;
        [stack addArrangedSubview:field];
    }
}

- (void)paintDays {
    for (UIButton* b in self.dayButtons) {
        BOOL on = [self.days containsObject:@(b.tag)];
        b.backgroundColor = on ? self.view.tintColor : UIColor.secondarySystemFillColor;
        [b setTitleColor:on ? UIColor.whiteColor : UIColor.labelColor forState:UIControlStateNormal];
    }
}

- (void)toggleDay:(UIButton*)b {
    NSNumber* d = @(b.tag);
    if ([self.days containsObject:d]) {
        [self.days removeObject:d];
    } else {
        [self.days addObject:d];
    }
    [self paintDays];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)save {
    NSString* text = self.memoField.text ?: @"";
    NSString* memo = self.memoField ? [text substringToIndex:MIN(text.length, (NSUInteger)40)] : nil;
    NSArray* days = [self.days sortedArrayUsingSelector:@selector(compare:)];
    if (self.done) {
        self.done(HHMMFromDate(self.picker.date), days, memo);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

+ (instancetype)sheetWithTime:(NSString*)hhmm {
    NFBRemindTimeSheet* sheet = [NFBRemindTimeSheet new];
    UIDatePicker* picker = [UIDatePicker new];
    picker.datePickerMode = UIDatePickerModeTime;
    picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    picker.date = DateFromHHMM(hhmm);
    sheet.picker = picker;
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        sheet.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent];
    }
    return sheet;
}

@end

// MARK: - Page

typedef NS_ENUM(NSInteger, RemindSection) {
    RemindAlarms = 0,
    RemindPill,
    RemindWater,
    RemindTest,
};

@interface KemoClickerRemindViewController ()
@property (nonatomic, strong) NSMutableDictionary* r;
@end

@implementation KemoClickerRemindViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = T(@"KEMO_CLICKER_REMIND_PAGE_TITLE");
    self.r = [NFBClickerRemind settings];
}

- (void)save {
    [NFBClickerRemind save:self.r];
    [self.tableView reloadData];
}

- (NSMutableArray*)alarms {
    NSMutableArray* a = [self.r[@"alarms"] mutableCopy];
    self.r[@"alarms"] = a;
    return a;
}

- (NSMutableDictionary*)part:(NSString*)name {
    NSMutableDictionary* d = [self.r[name] mutableCopy];
    self.r[name] = d;
    return d;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return 4;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    return section == RemindAlarms ? T(@"KEMO_CLICKER_REMIND_ALARMS")
           : section == RemindPill ? T(@"KEMO_CLICKER_REMIND_PILL")
           : section == RemindWater ? T(@"KEMO_CLICKER_REMIND_WATER")
                                    : T(@"KEMO_CLICKER_REMIND_TEST");
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    return section == RemindTest ? T(@"KEMO_CLICKER_REMIND_FOOTER") : nil;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case RemindAlarms:
            return [self.r[@"alarms"] count] + 1;
        case RemindPill:
            return [self.r[@"pill"][@"on"] boolValue] ? [self.r[@"pill"][@"times"] count] + 3 : 1;
        case RemindWater:
            return [self.r[@"water"][@"on"] boolValue] ? 4 : 1;
        default:
            return 3;
    }
}

- (UITableViewCell*)cell:(NSString*)text detail:(NSString*)detail {
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = text;
    cell.detailTextLabel.text = detail;
    return cell;
}

- (UITableViewCell*)switchCell:(NSString*)text on:(BOOL)on tag:(NSInteger)tag {
    UITableViewCell* cell = [self cell:text detail:nil];
    UISwitch* sw = [UISwitch new];
    sw.on = on;
    sw.tag = tag;
    [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell*)addCell:(NSString*)text {
    UITableViewCell* cell = [self cell:text detail:nil];
    cell.textLabel.textColor = self.view.tintColor;
    return cell;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)ip {
    NSArray* alarms = self.r[@"alarms"];
    NSDictionary* pill = self.r[@"pill"];
    NSDictionary* water = self.r[@"water"];
    if (ip.section == RemindAlarms) {
        if (ip.row == (NSInteger)alarms.count) {
            return [self addCell:T(@"KEMO_CLICKER_REMIND_ADD_ALARM")];
        }
        NSDictionary* a = alarms[ip.row];
        NSString* memo = [a[@"memo"] length] ? [@" · " stringByAppendingString:a[@"memo"]] : @"";
        UITableViewCell* cell = [self switchCell:a[@"time"] on:[a[@"on"] boolValue] tag:1000 + ip.row];
        cell.textLabel.text = [NSString stringWithFormat:@"%@  %@%@", a[@"time"], DaysText(a[@"days"]), memo];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (ip.section == RemindPill) {
        if (ip.row == 0) {
            return [self switchCell:T(@"KEMO_CLICKER_REMIND_PILL_ON") on:[pill[@"on"] boolValue] tag:1];
        }
        NSArray* times = pill[@"times"];
        if (ip.row - 1 < (NSInteger)times.count) {
            return [self cell:times[ip.row - 1] detail:DaysText(pill[@"days"])];
        }
        if (ip.row - 1 == (NSInteger)times.count) {
            return [self addCell:T(@"KEMO_CLICKER_REMIND_ADD_TIME")];
        }
        return [self cell:T(@"KEMO_CLICKER_REMIND_MEMO") detail:[pill[@"memo"] length] ? pill[@"memo"] : @"-"];
    }
    if (ip.section == RemindWater) {
        if (ip.row == 0) {
            return [self switchCell:T(@"KEMO_CLICKER_REMIND_WATER_ON") on:[water[@"on"] boolValue] tag:2];
        }
        if (ip.row == 1) {
            return [self cell:T(@"KEMO_CLICKER_REMIND_EVERY")
                       detail:[NSString stringWithFormat:T(@"KEMO_CLICKER_REMIND_MINUTES"), (long)[water[@"every"] integerValue]]];
        }
        return [self cell:ip.row == 2 ? T(@"KEMO_CLICKER_REMIND_FROM") : T(@"KEMO_CLICKER_REMIND_TO")
                   detail:ip.row == 2 ? water[@"from"] : water[@"to"]];
    }
    NSString* kinds[] = {@"KEMO_CLICKER_REMIND_ALARMS", @"KEMO_CLICKER_REMIND_PILL", @"KEMO_CLICKER_REMIND_WATER"};
    return [self addCell:T(kinds[ip.row])];
}

- (void)switched:(UISwitch*)sw {
    if (sw.tag >= 1000) {
        NSMutableArray* alarms = [self alarms];
        NSMutableDictionary* a = [alarms[sw.tag - 1000] mutableCopy];
        a[@"on"] = @(sw.on);
        alarms[sw.tag - 1000] = a;
    } else {
        [self part:sw.tag == 1 ? @"pill" : @"water"][@"on"] = @(sw.on);
    }
    [self save];
}

- (void)editTime:(NSString*)time days:(NSArray*)days memo:(NSString*)memo done:(void (^)(NSString*, NSArray*, NSString*))done {
    NFBRemindTimeSheet* sheet = [NFBRemindTimeSheet sheetWithTime:time];
    sheet.days = days ? [days mutableCopy] : nil;
    sheet.memo = memo;
    sheet.done = done;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    __weak typeof(self) weakSelf = self;
    NSArray* alarms = self.r[@"alarms"];
    if (ip.section == RemindAlarms) {
        BOOL adding = ip.row == (NSInteger)alarms.count;
        if (adding && alarms.count >= 20) {
            return;
        }
        NSDictionary* a = adding ? @{@"time": @"09:00", @"days": @[@0, @1, @2, @3, @4, @5, @6], @"memo": @"", @"on": @YES}
                                 : alarms[ip.row];
        [self editTime:a[@"time"] days:a[@"days"] memo:a[@"memo"] done:^(NSString* t, NSArray* d, NSString* m) {
            NSMutableArray* list = [weakSelf alarms];
            NSMutableDictionary* next = [a mutableCopy];
            next[@"time"] = t;
            next[@"days"] = d;
            next[@"memo"] = m ?: @"";
            if (adding) {
                next[@"id"] = [NSString stringWithFormat:@"a%.0f", NSDate.date.timeIntervalSince1970 * 1000];
                [list addObject:next];
            } else {
                list[ip.row] = next;
            }
            [weakSelf save];
        }];
        return;
    }
    if (ip.section == RemindPill && ip.row > 0) {
        NSMutableArray* times = [self.r[@"pill"][@"times"] mutableCopy];
        if (ip.row - 1 <= (NSInteger)times.count) {
            BOOL adding = ip.row - 1 == (NSInteger)times.count;
            if (adding && times.count >= 8) {
                return;
            }
            [self editTime:adding ? @"08:00" : times[ip.row - 1] days:nil memo:nil done:^(NSString* t, NSArray* d, NSString* m) {
                if (adding) {
                    [times addObject:t];
                } else {
                    times[ip.row - 1] = t;
                }
                [weakSelf part:@"pill"][@"times"] = [[[NSOrderedSet orderedSetWithArray:times] array] sortedArrayUsingSelector:@selector(compare:)];
                [weakSelf save];
            }];
            return;
        }
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:T(@"KEMO_CLICKER_REMIND_MEMO")
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
            field.text = weakSelf.r[@"pill"][@"memo"];
        }];
        [alert addAction:[UIAlertAction actionWithTitle:T(@"KEMO_CLICKER_ADJUST_DONE")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    NSString* m = alert.textFields.firstObject.text ?: @"";
                                                    [weakSelf part:@"pill"][@"memo"] = [m substringToIndex:MIN(m.length, (NSUInteger)40)];
                                                    [weakSelf save];
                                                }]];
        [alert addAction:[UIAlertAction actionWithTitle:T(@"DISMISS_LABEL") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (ip.section == RemindWater && ip.row == 1) {
        UIAlertController* sheet = [UIAlertController alertControllerWithTitle:T(@"KEMO_CLICKER_REMIND_EVERY")
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSNumber* m in @[@20, @30, @45, @60, @90, @120, @180]) {
            [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:T(@"KEMO_CLICKER_REMIND_MINUTES"), (long)m.integerValue]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction* action) {
                                                        [weakSelf part:@"water"][@"every"] = m;
                                                        [weakSelf save];
                                                    }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:T(@"DISMISS_LABEL") style:UIAlertActionStyleCancel handler:nil]];
        UITableViewCell* cell = [tableView cellForRowAtIndexPath:ip];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    if (ip.section == RemindWater && ip.row >= 2) {
        NSString* key = ip.row == 2 ? @"from" : @"to";
        [self editTime:self.r[@"water"][key] days:nil memo:nil done:^(NSString* t, NSArray* d, NSString* m) {
            [weakSelf part:@"water"][key] = t;
            [weakSelf save];
        }];
        return;
    }
    if (ip.section == RemindTest) {
        NSString* kinds[] = {@"alarm", @"pill", @"water"};
        [NFBClickerRemind test:kinds[ip.row]];
    }
}

- (BOOL)tableView:(UITableView*)tableView canEditRowAtIndexPath:(NSIndexPath*)ip {
    if (ip.section == RemindAlarms) {
        return ip.row < (NSInteger)[self.r[@"alarms"] count];
    }
    if (ip.section == RemindPill) {
        NSInteger n = [self.r[@"pill"][@"times"] count];
        return ip.row >= 1 && ip.row <= n && n > 1;
    }
    return NO;
}

- (void)tableView:(UITableView*)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)style
     forRowAtIndexPath:(NSIndexPath*)ip {
    if (style != UITableViewCellEditingStyleDelete) {
        return;
    }
    if (ip.section == RemindAlarms) {
        [[self alarms] removeObjectAtIndex:ip.row];
    } else {
        NSMutableArray* times = [self.r[@"pill"][@"times"] mutableCopy];
        [times removeObjectAtIndex:ip.row - 1];
        [self part:@"pill"][@"times"] = times;
    }
    [self save];
}

@end
