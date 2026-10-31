//
//  HistoryTabs.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Activity history tabs

// The history screen's pages come from LegacySegmentedViewController
// -pagingViewController:viewControllerAt:. The articles tab keeps its place.
// That page is the recently viewed list, and the tab title becomes "이전내역".

extern UIViewController* NFBMakeRecentViewController(void);

static const void* kRecentPageKey = &kRecentPageKey;
static const void* kReloadedKey = &kReloadedKey;

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
        title = @"아티클";
    });
    return title;
}

static BOOL IsHistorySegment(id controller) {
    if (![BHTSettings boolForKey:@"kemo_history_tabs"]) {
        return NO;
    }
    if (![controller respondsToSelector:@selector(dataSource)]) {
        return NO;
    }
    id source = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(dataSource));
    return source && [NSStringFromClass([source class]) containsString:@"ActivityHistory"];
}

static void ReplaceArticlesTabTitle(UIView* root) {
    if (!root) {
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

// Left-to-right tab labels. The articles one is titled "아티클" until renamed "이전내역".
static NSInteger ArticlesTabIndex(UIViewController* controller) {
    if (![controller respondsToSelector:@selector(tabBarView)]) {
        return NSNotFound;
    }
    UIView* bar = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(tabBarView));
    if (![bar isKindOfClass:[UIView class]]) {
        return NSNotFound;
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
    NSString* ours = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_HISTORY_TAB_TITLE"];
    NSString* articles = ArticlesTabTitle();
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSString* text = labels[i].text;
        if ([text isEqualToString:ours] || [text isEqualToString:articles]) {
            return (NSInteger)i;
        }
    }
    return NSNotFound;
}

static UIViewController* RecentPage(id controller) {
    UIViewController* page = objc_getAssociatedObject(controller, kRecentPageKey);
    if (!page) {
        page = NFBMakeRecentViewController();
        objc_setAssociatedObject(controller, kRecentPageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return page;
}

%hook _TtC10TFNUISwift29LegacySegmentedViewController

- (id)pagingViewController:(id)pager viewControllerAt:(long long)index {
    if (IsHistorySegment(self) && index == ArticlesTabIndex((UIViewController*)self)) {
        return RecentPage(self);
    }
    return %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!IsHistorySegment(self)) {
        return;
    }
    UIViewController* controller = (UIViewController*)self;
    ReplaceArticlesTabTitle(controller.view);
    if (objc_getAssociatedObject(self, kReloadedKey)) {
        return;
    }
    NSInteger articles = ArticlesTabIndex(controller);
    id controller = self;
    if (articles == NSNotFound || ![controller respondsToSelector:@selector(reloadTabContentAt:)]) {
        return;
    }
    objc_setAssociatedObject(self, kReloadedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, long long))objc_msgSend)(controller, @selector(reloadTabContentAt:), articles);
}

%end
