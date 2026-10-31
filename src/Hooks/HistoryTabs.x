//
//  HistoryTabs.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Activity history tabs

// The on-screen history controller is T1TwitterSwift's private
// T1ActivityHistoryContainerViewController. Its child is a LegacySegmentedViewController.
// The tabs are 북마크, 동영상, 아티클, 마음에 들어요. The 아티클 page is the recently
// viewed list, and that tab's label becomes "이전내역".

extern UIViewController* NFBMakeRecentViewController(void);

static const void* kRecentPageKey = &kRecentPageKey;
static const void* kReloadedKey = &kReloadedKey;

static BOOL IsHistorySegment(UIViewController* controller) {
    if (![BHTSettings boolForKey:@"kemo_history_tabs"] || !controller) {
        return NO;
    }
    // nextResponder only loops between a controller and its own view.
    // The history container is the parent, as in the on-screen controller tree.
    UIViewController* cursor = controller;
    for (int depth = 0; cursor && depth < 8; depth++) {
        if ([NSStringFromClass([cursor class]) containsString:@"ActivityHistory"]) {
            return YES;
        }
        cursor = cursor.parentViewController;
    }
    return NO;
}

static UIView* HistoryTabBar(UIViewController* controller) {
    if ([controller respondsToSelector:@selector(tabBarView)]) {
        id bar = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(tabBarView));
        if ([bar isKindOfClass:[UIView class]]) {
            return bar;
        }
    }
    return nil;
}

static void CollectTabLabels(UIView* root, NSMutableArray<UILabel*>* labels) {
    if (!root) {
        return;
    }
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if (![view isKindOfClass:[UILabel class]]) {
            return;
        }
        UILabel* label = (UILabel*)view;
        if (label.text.length == 0 || label.text.length > 20) {
            return;
        }
        [labels addObject:label];
    });
}

static NSArray<UILabel*>* HistoryTabLabels(UIViewController* controller) {
    NSMutableArray<UILabel*>* labels = [NSMutableArray array];
    CollectTabLabels(HistoryTabBar(controller), labels);
    if (labels.count < 2) {
        [labels removeAllObjects];
        UIView* window = controller.view.window;
        if (window) {
            EnumerateSubviewsRecursively(window, ^(UIView* view) {
                if (![NSStringFromClass(view.class) containsString:@"SegmentedTabCell"]) {
                    return;
                }
                CGRect onScreen = [view convertRect:view.bounds toView:window];
                CGRect page = [controller.view convertRect:controller.view.bounds toView:window];
                if (!CGRectIntersectsRect(onScreen, page)) {
                    return;
                }
                CollectTabLabels(view, labels);
            });
        }
    }
    [labels sortUsingComparator:^NSComparisonResult(UILabel* a, UILabel* b) {
        UIView* root = controller.view.window ?: controller.view;
        CGFloat ax = CGRectGetMinX([a convertRect:a.bounds toView:root]);
        CGFloat bx = CGRectGetMinX([b convertRect:b.bounds toView:root]);
        return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
    }];
    return labels;
}

static NSInteger ArticlesTabIndex(UIViewController* controller) {
    NSArray<UILabel*>* labels = HistoryTabLabels(controller);
    NSString* ours = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_HISTORY_TAB_TITLE"];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSString* text = labels[i].text;
        if ([text isEqualToString:@"아티클"] || [text isEqualToString:ours] ||
            [text isEqualToString:@"Articles"]) {
            return (NSInteger)i;
        }
    }
    return NSNotFound;
}

static void ReplaceArticlesTabTitle(UIViewController* controller) {
    NSString* title = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_HISTORY_TAB_TITLE"];
    if (title.length == 0) {
        return;
    }
    for (UILabel* label in HistoryTabLabels(controller)) {
        if (![label.text isEqualToString:@"아티클"] && ![label.text isEqualToString:@"Articles"]) {
            continue;
        }
        CGPoint center = label.center;
        label.text = title;
        [label sizeToFit];
        label.center = center;
    }
}

static UIViewController* RecentPage(id controller) {
    UIViewController* page = objc_getAssociatedObject(controller, kRecentPageKey);
    if (!page) {
        page = NFBMakeRecentViewController();
        objc_setAssociatedObject(controller, kRecentPageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return page;
}

static BOOL IsRecentController(id controller) {
    return [NSStringFromClass([controller class]) containsString:@"NFBRecent"];
}

static void CoverPage(UIViewController* page, id owner) {
    if (!page.isViewLoaded) {
        return;
    }
    UIViewController* recent = RecentPage(owner);
    if (recent.parentViewController != page) {
        if (recent.parentViewController) {
            [recent willMoveToParentViewController:nil];
            [recent.view removeFromSuperview];
            [recent removeFromParentViewController];
        }
        [page addChildViewController:recent];
        recent.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [page.view addSubview:recent.view];
        [recent didMoveToParentViewController:page];
    }
    recent.view.frame = page.view.bounds;
}

%hook _TtC10TFNUISwift29LegacySegmentedViewController

- (id)pagingViewController:(id)pager viewControllerAt:(long long)index {
    UIViewController* controller = (UIViewController*)self;
    if (IsHistorySegment(controller) && index == ArticlesTabIndex(controller)) {
        return RecentPage(self);
    }
    return %orig;
}

- (id)viewControllerAtTabIndex:(long long)index {
    UIViewController* controller = (UIViewController*)self;
    if (IsHistorySegment(controller) && index == ArticlesTabIndex(controller)) {
        return RecentPage(self);
    }
    return %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController* controller = (UIViewController*)self;
    if (!IsHistorySegment(controller)) {
        return;
    }
    ReplaceArticlesTabTitle(controller);
    NSInteger articles = ArticlesTabIndex(controller);
    if (articles == NSNotFound) {
        return;
    }
    id selected = [controller respondsToSelector:@selector(selectedViewController)]
                       ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(selectedViewController))
                       : nil;
    if (IsRecentController(selected)) {
        return;
    }
    long long selectedIndex = [controller respondsToSelector:@selector(selectedIndex)]
                                  ? ((long long (*)(id, SEL))objc_msgSend)(controller, @selector(selectedIndex))
                                  : -1;
    if (!objc_getAssociatedObject(self, kReloadedKey) &&
        [controller respondsToSelector:@selector(reloadTabContentAt:)]) {
        objc_setAssociatedObject(self, kReloadedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, long long))objc_msgSend)(controller, @selector(reloadTabContentAt:), articles);
        return;
    }
    if (selectedIndex == articles && [selected isKindOfClass:[UIViewController class]]) {
        CoverPage((UIViewController*)selected, self);
    }
}

%end

// The articles page says "읽은 아티클이 여기에 표시됩니다" while it is empty.
// Cover that page even if the pager already cached it.
%hook _TtC16XActivityHistory33ActivityHistoryPageViewController

- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController* page = (UIViewController*)self;
    if (![BHTSettings boolForKey:@"kemo_history_tabs"] || !page.isViewLoaded) {
        return;
    }
    __block BOOL articles = NO;
    EnumerateSubviewsRecursively(page.view, ^(UIView* view) {
        if (![view isKindOfClass:[UILabel class]]) {
            return;
        }
        NSString* text = ((UILabel*)view).text;
        if ([text containsString:@"아티클"] || [text containsString:@"Articles"]) {
            articles = YES;
        }
    });
    if (!articles) {
        return;
    }
    UIViewController* recent = RecentPage(page);
    if (recent.parentViewController != page) {
        if (recent.parentViewController) {
            [recent willMoveToParentViewController:nil];
            [recent.view removeFromSuperview];
            [recent removeFromParentViewController];
        }
        [page addChildViewController:recent];
        recent.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [page.view addSubview:recent.view];
        [recent didMoveToParentViewController:page];
    }
    recent.view.frame = page.view.bounds;
}

%end

%hook UILabel

- (void)layoutSubviews {
    %orig;
    if (![BHTSettings boolForKey:@"kemo_history_tabs"]) {
        return;
    }
    if (![self.text isEqualToString:@"아티클"] && ![self.text isEqualToString:@"Articles"]) {
        return;
    }
    for (UIView* view = self.superview; view; view = view.superview) {
        if ([NSStringFromClass(view.class) containsString:@"SegmentedTabCell"]) {
            self.text = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_HISTORY_TAB_TITLE"];
            return;
        }
    }
}

%end
