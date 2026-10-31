//
//  HistoryTabs.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Activity history tabs

// The history screen is XActivityHistory's container. It asks its data source
// (itself) for each page with segmentedViewController:pageViewControllerAtIndex:.
// The articles page is the generic ActivityHistoryPageViewController. That page
// becomes the recently viewed list, and its tab title becomes "이전내역".
// Bookmark, video and likes pages are different classes and stay as they are.

extern UIViewController* NFBMakeRecentViewController(void);

static const void* kRecentPageKey = &kRecentPageKey;
static NSString* const kArticlesPageClass = @"_TtC16XActivityHistory33ActivityHistoryPageViewController";

static NSString* ArticlesTabTitle(void) {
    static NSString* title;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSBundle* bundle in [NSBundle allBundles]) {
            NSString* value = [bundle localizedStringForKey:@"ACTIVITY_HISTORY_CONTENT_TYPE_ARTICLES"
                                                       value:@"__missing"
                                                       table:nil];
            if (value.length > 0 && ![value isEqualToString:@"__missing"] &&
                ![value isEqualToString:@"ACTIVITY_HISTORY_CONTENT_TYPE_ARTICLES"]) {
                title = value;
                return;
            }
        }
        title = @"Articles";
    });
    return title;
}

static void ReplaceArticlesTabTitle(UIView* root) {
    if (![BHTSettings boolForKey:@"kemo_history_tabs"] || !root) {
        return;
    }
    NSString* articles = ArticlesTabTitle();
    NSString* title = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_HISTORY_TAB_TITLE"];
    if (articles.length == 0 || title.length == 0) {
        return;
    }
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if (![view isKindOfClass:[UILabel class]]) {
            return;
        }
        UILabel* label = (UILabel*)view;
        if (![label.text isEqualToString:articles]) {
            return;
        }
        CGPoint center = label.center;
        label.text = title;
        [label sizeToFit];
        label.center = center;
    });
}

static UIViewController* RecentPage(id container) {
    UIViewController* page = objc_getAssociatedObject(container, kRecentPageKey);
    if (!page) {
        page = NFBMakeRecentViewController();
        objc_setAssociatedObject(container, kRecentPageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return page;
}

%hook _TtC16XActivityHistory38ActivityHistoryContainerViewController

- (id)segmentedViewController:(id)controller pageViewControllerAtIndex:(long long)index {
    id page = %orig;
    if (![BHTSettings boolForKey:@"kemo_history_tabs"]) {
        return page;
    }
    if ([NSStringFromClass([page class]) isEqualToString:kArticlesPageClass]) {
        return RecentPage(self);
    }
    return page;
}

- (void)viewDidLayoutSubviews {
    %orig;
    ReplaceArticlesTabTitle(((UIViewController*)self).view);
}

%end
