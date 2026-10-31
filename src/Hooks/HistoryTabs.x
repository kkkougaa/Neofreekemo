//
//  HistoryTabs.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Activity history tabs

// The history screen has four tabs: bookmarks, videos, articles, likes. Articles (index 2)
// becomes the recently viewed list, titled "이전내역". The other three tabs stay where
// they are. It only applies when the controller's data source is the history screen and
// it reports exactly four tabs, so any other layout is left alone.

extern UIViewController* NFBMakeRecentViewController(void);

static const NSInteger kArticlesTabIndex = 2;

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

// The third tab is articles. Replace that label, not whichever label happens to be leftmost.
static void FixArticlesTabTitle(UIViewController* controller) {
    if (![controller respondsToSelector:@selector(tabBarView)]) {
        return;
    }
    UIView* bar = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(tabBarView));
    if (![bar isKindOfClass:[UIView class]]) {
        return;
    }
    NSMutableArray<UILabel*>* labels = [NSMutableArray array];
    EnumerateSubviewsRecursively(bar, ^(UIView* view) {
        if ([view isKindOfClass:[UILabel class]] && ((UILabel*)view).text.length > 0) {
            [labels addObject:(UILabel*)view];
        }
    });
    [labels sortUsingComparator:^NSComparisonResult(UILabel* a, UILabel* b) {
        CGFloat ax = CGRectGetMinX([bar convertRect:a.bounds fromView:a]);
        CGFloat bx = CGRectGetMinX([bar convertRect:b.bounds fromView:b]);
        return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
    }];
    if (labels.count <= kArticlesTabIndex) {
        return;
    }
    UILabel* articles = labels[kArticlesTabIndex];
    NSString* title = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_HISTORY_TAB_TITLE"];
    if ([articles.text isEqualToString:title]) {
        return;
    }
    CGPoint center = articles.center;
    articles.text = title;
    [articles sizeToFit];
    articles.center = center;
}

%hook _TtC10TFNUISwift29LegacySegmentedViewController

- (long long)numberOfTabsIn:(id)tabBar {
    long long count = %orig;
    SetActive(self, IsHistoryController(self) && count == 4);
    return count;
}

- (long long)numberOfPagesIn:(id)pager {
    long long count = %orig;
    SetActive(self, IsHistoryController(self) && count == 4);
    return count;
}

- (id)pagingViewController:(id)pager viewControllerAt:(long long)index {
    if (IsActive(self) && index == kArticlesTabIndex) {
        UIViewController* page = objc_getAssociatedObject(self, kRecentPageKey);
        if (!page) {
            page = NFBMakeRecentViewController();
            objc_setAssociatedObject(self, kRecentPageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return page;
    }
    return %orig;
}

- (BOOL)pagingViewController:(id)pager isPrewarmableAt:(long long)index {
    if (IsActive(self) && index == kArticlesTabIndex) {
        return NO;
    }
    return %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (IsActive(self)) {
        FixArticlesTabTitle((UIViewController*)self);
    }
}

%end
