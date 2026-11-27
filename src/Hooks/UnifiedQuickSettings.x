//
//  UnifiedQuickSettings.x
//  NeoFreeBird
//
//  7.3.151: the A/B unified account's settings in one place, with two ways in:
//  the kemo settings page (KemoSettingsViewController.m) and a long press on
//  the unified circle of the account dock (AccountBubbles.x).
//  - NFBUnifiedPickAccount(): the sheet that picks A or B
//    (kemo_unified_a_id / _name, kemo_unified_b_id / _name; A and B are never
//    the same account).
//  - NFBUnifiedPickBColor(): the sheet that picks the colour of posts only B
//    sees (kemo_unified_b_color / _name), with the system colour picker for
//    any colour.
//  - NFBUnifiedPresentQuickSettings(): the dock's sheet: A, B, the colour,
//    "always ask" (kemo_unified_always_ask) and the dock's order editor.
//  Everything here is on-device settings: nothing is sent to X, and the
//  unified mode itself (kemo_unified_mode) is never changed here.
//

#import "HookHelpers.h"

extern void NFBPresentAccountSheet(NSString* title, NSString* message, NSArray<NSDictionary*>* rows);
extern NSUInteger NFBAccountSheetToken(void);
extern void NFBUpdateAccountSheetRow(NSUInteger token, NSUInteger index, NSDictionary* changes);
extern NSArray<NSDictionary*>* NFBUnifiedAccountChoices(void);
extern UIColor* NFBUnifiedBColor(void);
extern BOOL NFBUnifiedDockPair(id* outA, id* outB);
extern void NFBShowAccountOrderEditor(void);

void NFBUnifiedPickAccount(BOOL isA, void (^changed)(void));
void NFBUnifiedPickBColor(void (^changed)(void));
void NFBUnifiedPresentQuickSettings(void);

static NSString* const kQuickAlwaysAsk = @"kemo_unified_always_ask";
static NSString* const kQuickBColor = @"kemo_unified_b_color";
static NSString* const kQuickBColorName = @"kemo_unified_b_color_name";

// For the shake dump: how the quick sheet was last asked for, and the last choice made in these sheets.
static NSString* gQuickLastTrigger;
static NSString* gQuickLastChoice;

NSString* NFBUnifiedQuickSettingsDebugText(void) {
    return [NSString stringWithFormat:@"quick settings: last trigger %@, last choice %@", gQuickLastTrigger ?: @"(none)",
                                      gQuickLastChoice ?: @"(none)"];
}

// The same strings the settings page shows (the BHT bundle).
static NSString* QSLocalized(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

static UIWindow* QSKeyWindow(void) {
    UIWindow* window = nil;
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* candidate in ((UIWindowScene*)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    return window;
}

static UIViewController* QSTop(void) {
    UIViewController* top = QSKeyWindow().rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

// RRGGBB to a colour (nil when it is not six hex digits).
static UIColor* QSColorFromHex(NSString* hex) {
    unsigned int value = 0;
    if (hex.length != 6) return nil;
    NSScanner* scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return nil;
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0 green:((value >> 8) & 0xFF) / 255.0 blue:(value & 0xFF) / 255.0 alpha:1];
}

// A small filled circle of a colour as a sheet row's image. The sheet draws
// row images in a 40pt aspect-fill box, so the 24pt circle sits in a clear
// 40pt canvas.
static UIImage* QSColorDot(UIColor* color) {
    if (!color) return nil;
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(8, 8, 24, 24)] fill];
    }];
}

// MARK: - A / B account

// A and B of the unified timeline. `changed` runs after a choice is saved.
void NFBUnifiedPickAccount(BOOL isA, void (^changed)(void)) {
    NSString* idKey = isA ? @"kemo_unified_a_id" : @"kemo_unified_b_id";
    NSString* nameKey = isA ? @"kemo_unified_a_name" : @"kemo_unified_b_name";
    NSString* otherKey = isA ? @"kemo_unified_b_id" : @"kemo_unified_a_id";
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* current = [defaults stringForKey:idKey];
    NSString* other = [defaults stringForKey:otherKey];
    void (^done)(void) = [changed copy];
    NSMutableArray<NSDictionary*>* rows = [NSMutableArray array];
    for (NSDictionary* choice in NFBUnifiedAccountChoices()) {
        NSString* accountID = choice[@"id"];
        NSString* accountName = choice[@"name"];
        if (!accountID || !accountName) continue;
        if ([accountID isEqualToString:other]) continue;  // A and B are never the same
        void (^pick)(void) = ^{
            [defaults setObject:accountID forKey:idKey];
            [defaults setObject:accountName forKey:nameKey];
            gQuickLastChoice = [NSString stringWithFormat:@"%@ = %@", isA ? @"A" : @"B", accountName];
            if (done) done();
        };
        NSMutableDictionary* row = [@{@"title" : accountName, @"action" : [pick copy]} mutableCopy];
        if ([choice[@"active"] boolValue]) row[@"detail"] = QSLocalized(@"KEMO_UNIFIED_B_ACTIVE");
        if ([accountID isEqualToString:current]) {
            row[@"button"] = QSLocalized(@"KEMO_UNIFIED_CHOSEN");
            row[@"buttonStyle"] = @"outline";
        }
        [rows addObject:row];
    }
    void (^clear)(void) = ^{
        [defaults removeObjectForKey:idKey];
        [defaults removeObjectForKey:nameKey];
        gQuickLastChoice = [NSString stringWithFormat:@"%@ cleared", isA ? @"A" : @"B"];
        if (done) done();
    };
    [rows addObject:@{@"title" : QSLocalized(@"KEMO_UNIFIED_B_CLEAR"), @"destructive" : @YES, @"action" : [clear copy]}];
    NFBPresentAccountSheet(QSLocalized(isA ? @"KEMO_UNIFIED_A_TITLE" : @"KEMO_UNIFIED_B_TITLE"), nil, rows);
}

// MARK: - B's colour

// The system colour picker's delegate; kept alive by the one shared instance.
@interface NFBUnifiedColorPickerDelegate : NSObject <UIColorPickerViewControllerDelegate>
@property (nonatomic, copy) void (^changed)(void);
+ (instancetype)shared;
@end

@implementation NFBUnifiedColorPickerDelegate

+ (instancetype)shared {
    static NFBUnifiedColorPickerDelegate* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [NFBUnifiedColorPickerDelegate new];
    });
    return shared;
}

// Any colour, kept as RRGGBB like the presets.
- (void)save:(UIColor*)color {
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return;
    int r = (int)lround(MAX(0, MIN(1, red)) * 255), g = (int)lround(MAX(0, MIN(1, green)) * 255),
        b = (int)lround(MAX(0, MIN(1, blue)) * 255);
    NSString* hex = [NSString stringWithFormat:@"%02X%02X%02X", r, g, b];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:hex forKey:kQuickBColor];
    [defaults setObject:[NSString stringWithFormat:@"%@ #%@", QSLocalized(@"KEMO_UNIFIED_COLOR_CUSTOM"), hex] forKey:kQuickBColorName];
    gQuickLastChoice = [NSString stringWithFormat:@"B colour = #%@ (picker)", hex];
    if (self.changed) self.changed();
}

- (void)colorPickerViewController:(UIColorPickerViewController*)picker didSelectColor:(UIColor*)color continuously:(BOOL)continuously {
    if (!continuously) [self save:color];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController*)picker {
    [self save:picker.selectedColor];
    self.changed = nil;
}

@end

static void QSShowColorPicker(void (^changed)(void)) {
    UIViewController* top = QSTop();
    if (!top) return;
    UIColorPickerViewController* picker = [UIColorPickerViewController new];
    picker.supportsAlpha = NO;
    picker.title = QSLocalized(@"KEMO_UNIFIED_B_COLOR_TITLE");
    UIColor* current = QSColorFromHex([[NSUserDefaults standardUserDefaults] stringForKey:kQuickBColor]);
    if (current) picker.selectedColor = current;
    NFBUnifiedColorPickerDelegate* delegate = [NFBUnifiedColorPickerDelegate shared];
    delegate.changed = changed;
    picker.delegate = delegate;
    [top presentViewController:picker animated:YES completion:nil];
}

// The colour of posts only B sees (folded corner and display name). `changed`
// runs after a choice is saved.
void NFBUnifiedPickBColor(void (^changed)(void)) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* current = [defaults stringForKey:kQuickBColor] ?: @"FF7A00";
    NSString* chosenText = QSLocalized(@"KEMO_UNIFIED_CHOSEN");
    void (^done)(void) = [changed copy];
    NSArray<NSArray<NSString*>*>* choices = @[
        @[ @"FF7A00", @"KEMO_UNIFIED_COLOR_ORANGE" ], @[ @"1D9BF0", @"KEMO_UNIFIED_COLOR_BLUE" ],
        @[ @"00BA7C", @"KEMO_UNIFIED_COLOR_GREEN" ], @[ @"F91880", @"KEMO_UNIFIED_COLOR_PINK" ],
        @[ @"7856FF", @"KEMO_UNIFIED_COLOR_PURPLE" ], @[ @"E0A800", @"KEMO_UNIFIED_COLOR_YELLOW" ]
    ];
    NSMutableArray<NSDictionary*>* rows = [NSMutableArray array];
    BOOL presetChosen = NO;
    for (NSArray<NSString*>* choice in choices) {
        NSString* hex = choice[0];
        NSString* name = QSLocalized(choice[1]);
        void (^pick)(void) = ^{
            [defaults setObject:hex forKey:kQuickBColor];
            [defaults setObject:name forKey:kQuickBColorName];
            gQuickLastChoice = [NSString stringWithFormat:@"B colour = #%@", hex];
            if (done) done();
        };
        NSMutableDictionary* row = [@{@"title" : name, @"action" : [pick copy]} mutableCopy];
        UIImage* dot = QSColorDot(QSColorFromHex(hex));
        if (dot) row[@"image"] = dot;
        if ([hex isEqualToString:current]) {
            presetChosen = YES;
            row[@"button"] = chosenText;
            row[@"buttonStyle"] = @"outline";
        }
        [rows addObject:row];
    }

    // X's theme colour: the window's tint, which is what the timeline uses for "theme".
    BOOL themeChosen = [current isEqualToString:@"theme"];
    NSString* themeName = QSLocalized(@"KEMO_UNIFIED_COLOR_THEME");
    void (^pickTheme)(void) = ^{
        [defaults setObject:@"theme" forKey:kQuickBColor];
        [defaults setObject:themeName forKey:kQuickBColorName];
        gQuickLastChoice = @"B colour = theme";
        if (done) done();
    };
    NSMutableDictionary* themeRow = [@{@"title" : themeName, @"action" : [pickTheme copy]} mutableCopy];
    UIImage* themeDot = QSColorDot(QSKeyWindow().tintColor);
    if (themeDot) themeRow[@"image"] = themeDot;
    if (themeChosen) {
        themeRow[@"button"] = chosenText;
        themeRow[@"buttonStyle"] = @"outline";
    }
    [rows addObject:themeRow];

    // Any colour: the system picker. A colour picked there before shows as this row's circle.
    void (^pickCustom)(void) = ^{
        QSShowColorPicker(done);
    };
    NSMutableDictionary* customRow = [@{@"title" : QSLocalized(@"KEMO_UNIFIED_COLOR_PICK"), @"action" : [pickCustom copy]} mutableCopy];
    UIColor* customColor = (!presetChosen && !themeChosen) ? QSColorFromHex(current) : nil;
    if (customColor) {
        UIImage* customDot = QSColorDot(customColor);
        if (customDot) customRow[@"image"] = customDot;
        customRow[@"button"] = chosenText;
        customRow[@"buttonStyle"] = @"outline";
    }
    [rows addObject:customRow];
    NFBPresentAccountSheet(QSLocalized(@"KEMO_UNIFIED_B_COLOR_TITLE"), nil, rows);
}

// MARK: - The dock's sheet

static NSDictionary* QSAlwaysAskPill(void) {
    BOOL on = [BHTSettings boolForKey:kQuickAlwaysAsk];
    return @{@"button" : QSLocalized(on ? @"KEMO_UNIFIED_ON" : @"KEMO_UNIFIED_OFF"), @"buttonStyle" : on ? @"filled" : @"outline"};
}

// The unified account's settings as a sheet (long press on its dock circle).
// Only while the feature is on and A and B make a pair; it changes settings
// only, never the mode.
void NFBUnifiedPresentQuickSettings(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NFBUnifiedPresentQuickSettings();
        });
        return;
    }
    if (!NFBUnifiedDockPair(NULL, NULL)) {
        gQuickLastTrigger = @"asked, not shown (feature off or no A/B pair)";
        return;
    }
    gQuickLastTrigger = @"shown";
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray<NSDictionary*>* rows = [NSMutableArray array];

    void (^pickA)(void) = ^{
        NFBUnifiedPickAccount(YES, nil);
    };
    [rows addObject:@{
        @"title" : QSLocalized(@"KEMO_UNIFIED_A_TITLE"),
        @"detail" : [defaults stringForKey:@"kemo_unified_a_name"] ?: QSLocalized(@"KEMO_UNIFIED_A_NONE"),
        @"action" : [pickA copy]
    }];

    void (^pickB)(void) = ^{
        NFBUnifiedPickAccount(NO, nil);
    };
    [rows addObject:@{
        @"title" : QSLocalized(@"KEMO_UNIFIED_B_TITLE"),
        @"detail" : [defaults stringForKey:@"kemo_unified_b_name"] ?: QSLocalized(@"KEMO_UNIFIED_B_NONE"),
        @"action" : [pickB copy]
    }];

    void (^pickColor)(void) = ^{
        NFBUnifiedPickBColor(nil);
    };
    NSMutableDictionary* colorRow = [@{
        @"title" : QSLocalized(@"KEMO_UNIFIED_B_COLOR_TITLE"),
        @"detail" : [defaults stringForKey:kQuickBColorName] ?: QSLocalized(@"KEMO_UNIFIED_COLOR_ORANGE"),
        @"action" : [pickColor copy]
    } mutableCopy];
    UIImage* dot = QSColorDot(NFBUnifiedBColor());
    if (dot) colorRow[@"image"] = dot;
    [rows addObject:colorRow];

    // "Always ask": the tap flips it and the sheet stays, the pill showing the new state.
    NSUInteger askIndex = rows.count;
    __block NSUInteger token = 0;
    void (^toggleAsk)(void) = ^{
        BOOL on = ![BHTSettings boolForKey:kQuickAlwaysAsk];
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:kQuickAlwaysAsk];
        gQuickLastChoice = [NSString stringWithFormat:@"always ask = %d", on];
        NFBUpdateAccountSheetRow(token, askIndex, QSAlwaysAskPill());
    };
    NSMutableDictionary* askRow = [@{@"title" : QSLocalized(@"KEMO_UNIFIED_ALWAYS_ASK_TITLE"), @"stay" : @YES, @"action" : [toggleAsk copy]} mutableCopy];
    [askRow addEntriesFromDictionary:QSAlwaysAskPill()];
    [rows addObject:askRow];

    void (^order)(void) = ^{
        gQuickLastChoice = @"dock order editor";
        NFBShowAccountOrderEditor();
    };
    [rows addObject:@{@"title" : QSLocalized(@"KEMO_UNIFIED_DOCK_ORDER_TITLE"), @"action" : [order copy]}];

    NFBPresentAccountSheet(QSLocalized(@"KEMO_UNIFIED_ACCOUNT_NAME"), nil, rows);
    token = NFBAccountSheetToken();
}
