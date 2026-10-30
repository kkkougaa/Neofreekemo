//
//  LogoMenu.x
//  NeoFreeBird
//

#import "Core/BHTManager.h"
#import "Headers/XHeaders.h"
#import "HookHelpers.h"

// MARK: - Recently viewed tweets, and the menu under the header logo

// Tweets that stay on screen for half a second are remembered (the last 30, on this
// device only), and tapping the header logo opens a small menu with the list and the
// settings. Everything here reads what the app already shows; nothing goes to any server.

extern UIImageView* HeaderLogoInWindow(UIWindow* window);
extern UIWindow* NFBKeyWindow(void);

static NSString* const kRecentKey = @"nfb_recent_tweets";
static const NSUInteger kRecentLimit = 30;
static const NSTimeInterval kDwellSeconds = 0.5;

static NSString* Localized(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

// MARK: Store

// Kept in memory; the file is written a few seconds after the last change, so a tweet seen
// every half second does not mean a disk write every half second.
static NSMutableArray<NSDictionary*>* gRecent;
static BOOL gRecentSavePending;

static NSArray<NSDictionary*>* RecentTweets(void) {
    if (!gRecent) {
        NSArray* saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kRecentKey];
        gRecent = saved ? [saved mutableCopy] : [NSMutableArray array];
    }
    return gRecent;
}

static void SaveRecentSoon(void) {
    if (gRecentSavePending) {
        return;
    }
    gRecentSavePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       gRecentSavePending = NO;
                       [[NSUserDefaults standardUserDefaults] setObject:[gRecent copy] forKey:kRecentKey];
                   });
}

static void RememberTweet(NSString* tweetID, NSString* label) {
    RecentTweets();
    for (NSDictionary* entry in [gRecent copy]) {
        if ([entry[@"id"] isEqualToString:tweetID]) {
            [gRecent removeObject:entry];
        }
    }
    [gRecent insertObject:@{
        @"id" : tweetID,
        @"label" : label ?: @"",
        @"at" : @([[NSDate date] timeIntervalSince1970]),
    }
                  atIndex:0];
    while (gRecent.count > kRecentLimit) {
        [gRecent removeLastObject];
    }
    SaveRecentSoon();
}

// MARK: Watching the timeline

static __weak UITableView* gSeenTable;
static NSMutableDictionary<NSString*, NSDate*>* gDwell;

%hook TFNTableView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        gSeenTable = (UITableView*)self;
    }
}

%end

// Looked at twice a second: a tweet that is (mostly) in view and has stayed there for a couple
// of seconds counts as seen. While the list is moving nothing counts.
static void WatchTimeline(void) {
    UITableView* table = gSeenTable;
    if (!table || !table.window || table.isDragging || table.isDecelerating) {
        [gDwell removeAllObjects];
        return;
    }
    if (!gDwell) {
        gDwell = [NSMutableDictionary dictionary];
    }
    CGFloat top = table.contentOffset.y + table.adjustedContentInset.top;
    CGFloat bottom = table.contentOffset.y + CGRectGetHeight(table.bounds) - table.adjustedContentInset.bottom;
    CGFloat viewportHeight = MAX(bottom - top, 1);

    NSMutableSet<NSString*>* visibleNow = [NSMutableSet set];
    for (UITableViewCell* cell in table.visibleCells) {
        NSString* tweetID = cell.accessibilityIdentifier;
        if (tweetID.length <= 8) {
            continue;
        }
        CGFloat shown = MIN(CGRectGetMaxY(cell.frame), bottom) - MAX(CGRectGetMinY(cell.frame), top);
        // Mostly in view: most of a short tweet, or half the screen for a tall one.
        if (shown < MIN(CGRectGetHeight(cell.frame) * 0.6, viewportHeight * 0.5)) {
            continue;
        }
        [visibleNow addObject:tweetID];
        NSDate* since = gDwell[tweetID];
        if (!since) {
            gDwell[tweetID] = [NSDate date];
        } else if (-[since timeIntervalSinceNow] >= kDwellSeconds) {
            NSDictionary* first = RecentTweets().firstObject;
            NSString* label = [first[@"id"] isEqualToString:tweetID] ? nil : cell.accessibilityLabel;
            if (label.length > 0) {
                RememberTweet(tweetID, label);
            }
        }
    }
    for (NSString* gone in [gDwell.allKeys copy]) {
        if (![visibleNow containsObject:gone]) {
            [gDwell removeObjectForKey:gone];
        }
    }
}

// MARK: The list

@interface NFBRecentViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary*>* items;
@end

@implementation NFBRecentViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.items = RecentTweets();
        self.title = Localized(@"KEMO_MENU_RECENT");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                      primaryAction:[UIAction actionWithHandler:^(UIAction* action) {
                          [self dismissViewControllerAnimated:YES completion:nil];
                      }]];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(self.items.count, 1);
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"recent"]
                                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                          reuseIdentifier:@"recent"];
    UIListContentConfiguration* content = [UIListContentConfiguration subtitleCellConfiguration];
    if (self.items.count == 0) {
        content.text = Localized(@"KEMO_RECENT_EMPTY");
        content.textProperties.color = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSString* label = self.items[indexPath.row][@"label"];
        // The accessibility sentence starts with the author, then the text.
        NSRange dot = [label rangeOfString:@". "];
        content.text = dot.location != NSNotFound ? [label substringToIndex:dot.location] : label;
        NSString* rest = dot.location != NSNotFound ? [label substringFromIndex:NSMaxRange(dot)] : @"";
        content.secondaryText = rest;
        content.secondaryTextProperties.numberOfLines = 2;
        content.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        content.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.items.count == 0) {
        return;
    }
    NSString* tweetID = self.items[indexPath.row][@"id"];
    NSURL* url = [NSURL URLWithString:[@"twitter://status?id=" stringByAppendingString:tweetID]];
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (url) {
                                     [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                                 }
                             }];
}

@end

// MARK: The menu

static UINavigationController* HomeNavigation(UIImageView* logo) {
    UIResponder* responder = logo;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) {
        responder = responder.nextResponder;
    }
    UIViewController* found = (UIViewController*)responder;
    return [found isKindOfClass:[UINavigationController class]] ? (UINavigationController*)found
                                                                : found.navigationController;
}

static void OpenSettings(UINavigationController* nav) {
    id account = nil;
    Class hostClass = objc_getClass("T1HostViewController");
    if ([hostClass respondsToSelector:@selector(sharedHostViewController)]) {
        id host = [hostClass sharedHostViewController];
        if ([host respondsToSelector:@selector(currentAccount)]) {
            account = [host currentAccount];
        }
    }
    [nav pushViewController:[BHTManager BHTSettingsWithAccount:account] animated:YES];
}

static void OpenRecent(UINavigationController* nav) {
    UINavigationController* sheet =
        [[UINavigationController alloc] initWithRootViewController:[NFBRecentViewController new]];
    sheet.sheetPresentationController.detents = @[
        [UISheetPresentationControllerDetent mediumDetent],
        [UISheetPresentationControllerDetent largeDetent],
    ];
    [nav presentViewController:sheet animated:YES completion:nil];
}

@interface NFBLogoMenu : UIView
@property (nonatomic, strong) NSArray<void (^)(void)>* actions;
@property (nonatomic, strong) NSArray<UIView*>* pills;
- (void)dismissThen:(void (^)(void))after;
@end

static __weak NFBLogoMenu* gMenu;

@implementation NFBLogoMenu

- (void)backgroundTapped {
    [self dismissThen:nil];
}

- (void)pillTapped:(UIButton*)button {
    void (^action)(void) = self.actions[button.tag];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self dismissThen:action];
}

- (void)dismissThen:(void (^)(void))after {
    [UIView animateWithDuration:0.18
        animations:^{
            self.alpha = 0;
            for (UIView* pill in self.pills) {
                pill.transform = CGAffineTransformMakeScale(0.9, 0.9);
            }
        }
        completion:^(BOOL finished) {
            [self removeFromSuperview];
            if (after) {
                after();
            }
        }];
}

@end

static void ShowLogoMenu(UIWindow* window, UIImageView* logo) {
    if (gMenu) {
        return;
    }
    UINavigationController* nav = HomeNavigation(logo);
    if (!nav) {
        return;
    }
    CGRect logoFrame = [window convertRect:logo.bounds fromView:logo];

    NFBLogoMenu* menu = [[NFBLogoMenu alloc] initWithFrame:window.bounds];
    UIVisualEffectView* blur =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blur.frame = menu.bounds;
    blur.alpha = 0.92;
    [menu addSubview:blur];
    UIButton* background = [UIButton buttonWithType:UIButtonTypeCustom];
    background.frame = menu.bounds;
    [background addTarget:menu action:@selector(backgroundTapped) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:background];

    NSArray<NSDictionary*>* entries = @[
        @{@"icon" : @"clock.arrow.circlepath", @"title" : Localized(@"KEMO_MENU_RECENT"), @"kind" : @"recent"},
        @{@"icon" : @"gearshape.fill", @"title" : Localized(@"KEMO_MENU_SETTINGS"), @"kind" : @"settings"},
    ];
    NSMutableArray<void (^)(void)>* actions = [NSMutableArray array];
    NSMutableArray<UIView*>* pills = [NSMutableArray array];
    CGFloat y = CGRectGetMaxY(logoFrame) + 14;
    CGFloat right = CGRectGetWidth(window.bounds) - 20;
    UIColor* accent = CurrentAccentColor();

    for (NSUInteger i = 0; i < entries.count; i++) {
        NSDictionary* entry = entries[i];
        UILabel* label = [UILabel new];
        label.text = entry[@"title"];
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        label.textColor = [UIColor labelColor];
        [label sizeToFit];

        UIImageSymbolConfiguration* config =
            [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        UIImageView* icon = [[UIImageView alloc]
            initWithImage:[UIImage systemImageNamed:entry[@"icon"] withConfiguration:config]];
        icon.tintColor = accent;
        icon.contentMode = UIViewContentModeScaleAspectFit;

        CGFloat width = 16 + 22 + 10 + CGRectGetWidth(label.bounds) + 18;
        UIVisualEffectView* pill = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
        pill.frame = CGRectMake(right - width, y, width, 44);
        pill.layer.cornerRadius = 22;
        pill.clipsToBounds = YES;
        icon.frame = CGRectMake(16, 11, 22, 22);
        label.frame = CGRectMake(16 + 22 + 10, (44 - CGRectGetHeight(label.bounds)) / 2,
                                 CGRectGetWidth(label.bounds), CGRectGetHeight(label.bounds));
        [pill.contentView addSubview:icon];
        [pill.contentView addSubview:label];

        UIButton* hit = [UIButton buttonWithType:UIButtonTypeCustom];
        hit.frame = pill.bounds;
        hit.tag = (NSInteger)i;
        [hit addTarget:menu action:@selector(pillTapped:) forControlEvents:UIControlEventTouchUpInside];
        [pill.contentView addSubview:hit];

        BOOL recent = [entry[@"kind"] isEqualToString:@"recent"];
        [actions addObject:[^{
                     if (recent) {
                         OpenRecent(nav);
                     } else {
                         OpenSettings(nav);
                     }
                 } copy]];
        [pills addObject:pill];
        [menu addSubview:pill];
        y += 44 + 10;
    }
    menu.actions = actions;
    menu.pills = pills;
    gMenu = menu;

    // Opens out of the logo.
    menu.alpha = 0;
    for (UIView* pill in pills) {
        pill.transform = CGAffineTransformConcat(
            CGAffineTransformMakeScale(0.7, 0.7),
            CGAffineTransformMakeTranslation(CGRectGetMidX(logoFrame) - CGRectGetMidX(pill.frame) , -12));
    }
    [window addSubview:menu];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [UIView animateWithDuration:0.4
                          delay:0
         usingSpringWithDamping:0.78
          initialSpringVelocity:0
                        options:0
                     animations:^{
                         menu.alpha = 1;
                         for (UIView* pill in pills) {
                             pill.transform = CGAffineTransformIdentity;
                         }
                     }
                     completion:nil];
}

// MARK: Tapping the logo

@interface NFBLogoTap : NSObject
@end

@implementation NFBLogoTap

- (void)tapped:(UITapGestureRecognizer*)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized || gMenu ||
        ![BHTSettings boolForKey:@"kemo_logo_menu"]) {
        return;
    }
    UIWindow* window = (UIWindow*)recognizer.view;
    UIImageView* logo = HeaderLogoInWindow(window);
    if (!logo || !logo.window) {
        return;
    }
    // Only while the logo is really showing (not faded out with the bar).
    CGFloat alpha = 1;
    for (UIView* view = logo; view; view = view.superview) {
        alpha *= view.alpha;
    }
    CGRect frame = [window convertRect:logo.bounds fromView:logo];
    if (alpha < 0.6 || !CGRectContainsPoint(CGRectInset(frame, -10, -10), [recognizer locationInView:window])) {
        return;
    }
    ShowLogoMenu(window, logo);
}

@end

static const void* kLogoTapKey = &kLogoTapKey;

static void InstallLogoTap(UIWindow* window) {
    if (objc_getAssociatedObject(window, kLogoTapKey)) {
        return;
    }
    NFBLogoTap* target = [NFBLogoTap new];
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(tapped:)];
    tap.cancelsTouchesInView = NO;
    [window addGestureRecognizer:tap];
    objc_setAssociatedObject(window, kLogoTapKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSTimer* gWatchTimer;

// Called twice a second from the bubble's timer.
void NFBRecentTick(void) {
    UIWindow* window = NFBKeyWindow();
    if (window) {
        InstallLogoTap(window);
    }
    // The look at the timeline runs four times a second: it is a handful of cells and
    // a dictionary, with no layout and no drawing, so it costs next to nothing.
    if (!gWatchTimer) {
        gWatchTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                      repeats:YES
                                                        block:^(NSTimer* timer) {
                                                            if ([UIApplication sharedApplication].applicationState ==
                                                                    UIApplicationStateActive &&
                                                                [BHTSettings boolForKey:@"kemo_recent_tweets"]) {
                                                                WatchTimeline();
                                                            }
                                                        }];
    }
}
