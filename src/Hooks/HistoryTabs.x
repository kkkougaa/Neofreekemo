//
//  HistoryTabs.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Activity history tabs

// The history screen has four tabs: bookmarks, videos, articles, likes. Here they become
// three: recently viewed tweets (in the articles' place), likes, bookmarks. The tab bar and
// the pager both ask the segmented controller (LegacySegmentedViewController) how many
// tabs there are and what is at each index, so that is where the order is changed: index 0
// is the recently viewed list, 1 and 2 are the old tabs 3 and 0, and the videos tab is never
// asked for. It only applies when the controller's data source is the history screen and it
// reports exactly four tabs, so any other layout is left alone.

extern UIViewController* NFBMakeRecentViewController(void);

static const NSInteger kHistoryMap[3] = {2, 3, 0}; // new index -> old index (0 stands for the recent list)

static const void* kActiveKey = &kActiveKey;
static const void* kRecentPageKey = &kRecentPageKey;

static BOOL IsHistoryController(id controller) {
    if (![BHTSettings boolForKey:@"kemo_history_tabs"]) {
        return NO;
    }
    if (![controller respondsToSelector:@selector(dataSource)]) {
        return NO;
    }
    id source = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(dataSource));
    return source && [NSStringFromClass([source class]) containsString:@"ActivityHistory"];
}

static BOOL IsActive(id controller) {
    return [objc_getAssociatedObject(controller, kActiveKey) boolValue];
}

static void SetActive(id controller, BOOL active) {
    objc_setAssociatedObject(controller, kActiveKey, @(active), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The articles label becomes "recently viewed": the leftmost label in the tab bar.
static void FixFirstTabTitle(UIViewController* controller) {
    if (![controller respondsToSelector:@selector(tabBarView)]) {
        return;
    }
    UIView* bar = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(tabBarView));
    if (![bar isKindOfClass:[UIView class]]) {
        return;
    }
    __block UILabel* first = nil;
    EnumerateSubviewsRecursively(bar, ^(UIView* view) {
        if ([view isKindOfClass:[UILabel class]] && ((UILabel*)view).text.length > 0 &&
            (!first || CGRectGetMinX([bar convertRect:view.bounds fromView:view]) <
                           CGRectGetMinX([bar convertRect:first.bounds fromView:first]))) {
            first = (UILabel*)view;
        }
    });
    NSString* title = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_MENU_RECENT"];
    if (first && ![first.text isEqualToString:title]) {
        CGPoint center = first.center;
        first.text = title;
        [first sizeToFit];
        first.center = center;
    }
}

%hook _TtC10TFNUISwift29LegacySegmentedViewController

- (long long)numberOfTabsIn:(id)tabBar {
    long long count = %orig;
    BOOL active = IsHistoryController(self) && count == 4;
    SetActive(self, active);
    return active ? 3 : count;
}

- (long long)numberOfPagesIn:(id)pager {
    long long count = %orig;
    BOOL active = IsHistoryController(self) && count == 4;
    SetActive(self, active);
    return active ? 3 : count;
}

- (id)tabBarView:(id)tabBar descriptorAtIndex:(long long)index {
    if (IsActive(self) && index >= 0 && index < 3) {
        return %orig(tabBar, kHistoryMap[index]);
    }
    return %orig;
}

- (id)tabBarView:(id)tabBar tabGroupAtIndex:(long long)index {
    if (IsActive(self) && index >= 0 && index < 3) {
        return %orig(tabBar, kHistoryMap[index]);
    }
    return %orig;
}

- (id)tabBarView:(id)tabBar menuForTabAtIndex:(long long)index {
    if (IsActive(self) && index >= 0 && index < 3) {
        return %orig(tabBar, kHistoryMap[index]);
    }
    return %orig;
}

- (BOOL)tabBarView:(id)tabBar isUnreadIndicatorTabAt:(long long)index {
    if (IsActive(self) && index >= 0 && index < 3) {
        return %orig(tabBar, kHistoryMap[index]);
    }
    return %orig;
}

- (id)pagingViewController:(id)pager viewControllerAt:(long long)index {
    if (IsActive(self) && index >= 0 && index < 3) {
        if (index == 0) {
            UIViewController* page = objc_getAssociatedObject(self, kRecentPageKey);
            if (!page) {
                page = NFBMakeRecentViewController();
                objc_setAssociatedObject(self, kRecentPageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return page;
        }
        return %orig(pager, kHistoryMap[index]);
    }
    return %orig;
}

- (BOOL)pagingViewController:(id)pager isPrewarmableAt:(long long)index {
    if (IsActive(self) && index >= 0 && index < 3) {
        return index == 0 ? NO : %orig(pager, kHistoryMap[index]);
    }
    return %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (IsActive(self)) {
        FixFirstTabTitle((UIViewController*)self);
    }
}

%end
