//
//  TweetSheet.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - A tweet opens as a sheet
// With "kemo_sheet_open" on (iPhone), a tweet opened from the first screen of a
// tab (the home timeline, notifications, ...) comes up as a sheet over that
// screen instead of sliding in from the side: the list steps back behind it,
// and pulling the sheet down goes back to the same place in the list.
//
// X opens a tweet by pushing a T1ConversationContainerViewController on the
// tab's navigation controller (or, at times, by setting the stack with it
// appended). That push is taken here and the controller is presented in a
// navigation controller of its own, as a page sheet. Anything opened from
// inside the sheet (a profile, another tweet) is pushed inside the sheet.
//
// Only a push on a stack of one, on screen, is taken: a tweet opened from
// deeper in (a profile's tweet, a tweet inside a sheet) is pushed as before.

static NSString* const kSheetKey = @"kemo_sheet_open";
static const void* kSheetNavKey = &kSheetNavKey;

// For the shake dump.
static NSInteger gSheetsOpened = 0;
static NSString* gSheetLog = @"(no tweet opened yet)";

NSString* NFBTweetSheetDebugText(void) {
    return [NSString stringWithFormat:@"on=%d opened=%ld last=%@", [BHTSettings boolForKey:kSheetKey], (long)gSheetsOpened,
                                      gSheetLog];
}

static BOOL OpenAsSheet(UINavigationController* navigation, UIViewController* controller) {
    if (!controller || ![BHTSettings boolForKey:kSheetKey]) {
        return NO;
    }
    Class conversation = NSClassFromString(@"T1ConversationContainerViewController");
    if (!conversation || ![controller isKindOfClass:conversation]) {
        return NO;
    }
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) {
        return NO;
    }
    if (navigation.viewControllers.count != 1 || navigation.presentedViewController || !navigation.viewIfLoaded.window ||
        objc_getAssociatedObject(navigation, kSheetNavKey) || controller.parentViewController || controller.presentingViewController) {
        gSheetLog = [NSString stringWithFormat:@"pushed as usual on %@ (stack %lu)", NSStringFromClass(navigation.class),
                                               (unsigned long)navigation.viewControllers.count];
        return NO;
    }
    if (@available(iOS 15.0, *)) {
        // X's own base navigation controller where there is one, so its
        // controllers find the bar they expect.
        Class navigationClass = NSClassFromString(@"TFNNavigationController") ?: [UINavigationController class];
        UINavigationController* sheetNavigation = [[navigationClass alloc] initWithRootViewController:controller];
        objc_setAssociatedObject(sheetNavigation, kSheetNavKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sheetNavigation.modalPresentationStyle = UIModalPresentationPageSheet;
        UISheetPresentationController* sheet = sheetNavigation.sheetPresentationController;
        sheet.detents = @[ [UISheetPresentationControllerDetent largeDetent] ];
        sheet.prefersGrabberVisible = YES;
        sheet.preferredCornerRadius = 30;
        [navigation presentViewController:sheetNavigation animated:YES completion:nil];
        gSheetsOpened++;
        gSheetLog = [NSString stringWithFormat:@"sheet from %@ in %@", NSStringFromClass(navigation.class),
                                               NSStringFromClass(navigationClass)];
        return YES;
    }
    return NO;
}

// The stack is set with one more controller at its end: that one.
static UIViewController* Appended(UINavigationController* navigation, NSArray<UIViewController*>* controllers) {
    NSArray<UIViewController*>* now = navigation.viewControllers;
    if (now.count != 1 || controllers.count != 2 || controllers.firstObject != now.firstObject) {
        return nil;
    }
    return controllers.lastObject;
}

%hook T1TabNavigationController

- (void)pushViewController:(UIViewController*)controller animated:(BOOL)animated {
    if (OpenAsSheet(self, controller)) {
        return;
    }
    %orig;
}

- (void)setViewControllers:(NSArray<UIViewController*>*)controllers animated:(BOOL)animated {
    UIViewController* added = Appended(self, controllers);
    if (added && OpenAsSheet(self, added)) {
        return;
    }
    %orig;
}

%end

%hook XNAVNavigationController

- (void)pushViewController:(UIViewController*)controller animated:(BOOL)animated {
    if (OpenAsSheet(self, controller)) {
        return;
    }
    %orig;
}

- (void)setViewControllers:(NSArray<UIViewController*>*)controllers animated:(BOOL)animated {
    UIViewController* added = Appended(self, controllers);
    if (added && OpenAsSheet(self, added)) {
        return;
    }
    %orig;
}

%end
