//
//  DebugDump.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - View tree dump (volume down)
// With "kemo_shake_dump" on, pressing volume down copies a text outline of what's currently on screen to the
// pasteboard: view classes, owning view controllers, label/button text, and the
// contents of every table or collection view. For working out how an app screen
// is built when its class names aren't known.

// Defined in Hooks/Timeline.x
extern NSString* BHTMediaProbeSummary(void);
#import "Core/NFBFirstResponder.h"

extern NSString* NFBBubbleDebugText(void);
extern NSString* NFBStringProbeText(void);

static const NSUInteger kMaxLines = 200;
static const int kMaxDepth = 16;

static NSString* Trim(NSString* text) {
    NSString* flat = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return flat.length > 40 ? [[flat substringToIndex:40] stringByAppendingString:@"…"] : flat;
}

// While set, hidden and transparent views are listed too (and marked).
static BOOL gIncludeHidden = NO;

static void DumpView(UIView* view, int depth, NSMutableString* out, NSUInteger* lines) {
    BOOL invisible = view.hidden || view.alpha < 0.01;
    if (*lines >= kMaxLines || depth > kMaxDepth || (invisible && !gIncludeHidden) ||
        [NSStringFromClass(view.class) containsString:@"TwitterDash"]) {
        return;
    }
    (*lines)++;

    [out appendFormat:@"%@%@ %@", [@"" stringByPaddingToLength:depth
                                                    withString:@" "
                                               startingAtIndex:0],
                      NSStringFromClass(view.class), NSStringFromCGRect(view.frame)];

    UIResponder* next = view.nextResponder;
    if ([next isKindOfClass:[UIViewController class]]) {
        [out appendFormat:@" VC=%@", NSStringFromClass(next.class)];
    }
    if (invisible) {
        [out appendFormat:@" [hidden=%d alpha=%.2f]", view.hidden, view.alpha];
    }
    if (view.accessibilityIdentifier.length) {
        [out appendFormat:@" id=%@", view.accessibilityIdentifier];
    }
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel* label = (UILabel*)view;
        [out appendFormat:@" \"%@\" font=%.0f", Trim(label.text ?: @""), label.font.pointSize];
    } else if ([view isKindOfClass:[UIButton class]]) {
        NSString* title = [(UIButton*)view titleForState:UIControlStateNormal];
        if (title.length) {
            [out appendFormat:@" title=\"%@\"", Trim(title)];
        }
    } else if ([view isKindOfClass:[UIImageView class]]) {
        UIImage* image = ((UIImageView*)view).image;
        if (image) {
            [out appendFormat:@" image=%@", NSStringFromCGSize(image.size)];
        }
    } else if ([view isKindOfClass:[UITableView class]] ||
               [view isKindOfClass:[UICollectionView class]]) {
        [out appendFormat:@" visibleCells=%lu",
                          (unsigned long)[[(id)view performSelector:@selector(visibleCells)] count]];
    }
    // Custom text views draw their own text; their accessibility label usually has it.
    if (![view isKindOfClass:[UILabel class]] && view.accessibilityLabel.length) {
        [out appendFormat:@" ax=\"%@\"", Trim(view.accessibilityLabel)];
    }
    [out appendString:@"\n"];

    for (UIView* sub in view.subviews) {
        DumpView(sub, depth + 1, out, lines);
    }
}


// MARK: Media-focused outline

static BOOL IsMediaLike(UIView* view) {
    NSString* name = NSStringFromClass(view.class);
    for (NSString* word in @[ @"Media", @"Video", @"Player", @"Poster", @"Thumbnail", @"Playback" ]) {
        if ([name containsString:word]) {
            return YES;
        }
    }
    if ([view.layer isKindOfClass:[AVPlayerLayer class]]) {
        return YES;
    }
    for (CALayer* sub in view.layer.sublayers) {
        if ([sub isKindOfClass:[AVPlayerLayer class]]) {
            return YES;
        }
    }
    return NO;
}

static void DumpLayers(CALayer* layer, int depth, NSMutableString* out) {
    if (depth > 4) {
        return;
    }
    for (CALayer* sub in layer.sublayers) {
        [out appendFormat:@"%@  layer %@ %@%@%c",
                          [@"" stringByPaddingToLength:depth * 2
                                            withString:@" "
                                       startingAtIndex:0],
                          NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
                          sub.contents ? @" contents" : @"", 10];
        DumpLayers(sub, depth + 1, out);
    }
}

static void FindMedia(UIView* view, NSMutableString* out, NSUInteger* count) {
    if (view.hidden || view.alpha < 0.01 || *count >= 12 ||
        [NSStringFromClass(view.class) containsString:@"TwitterDash"]) {
        return;
    }
    CGRect onScreen = [view convertRect:view.bounds toView:nil];
    if (!CGRectIntersectsRect(onScreen, view.window.bounds) || CGRectIsEmpty(onScreen)) {
        return;
    }

    if (IsMediaLike(view) && CGRectGetWidth(view.bounds) > 80) {
        (*count)++;
        [out appendFormat:@"--- MEDIA %@ %@%c  ancestors:", NSStringFromClass(view.class),
                          NSStringFromCGRect(onScreen), 10];
        UIView* ancestor = view.superview;
        for (int i = 0; ancestor && i < 8; i++, ancestor = ancestor.superview) {
            [out appendFormat:@" < %@", NSStringFromClass(ancestor.class)];
        }
        [out appendFormat:@"%c", 10];
        NSUInteger lines = 0;
        NSMutableString* tree = [NSMutableString new];
        DumpView(view, 1, tree, &lines);
        [out appendString:tree];
        DumpLayers(view.layer, 1, out);
        return; // don't repeat nested media views
    }
    for (UIView* sub in view.subviews) {
        FindMedia(sub, out, count);
    }
}

// The view that belongs to a view controller whose class name contains `name`.
static UIView* FindViewOfController(UIView* view, NSString* name) {
    UIResponder* next = view.nextResponder;
    if ([next isKindOfClass:[UIViewController class]] &&
        [NSStringFromClass(next.class) containsString:name] && !view.hidden) {
        return view;
    }
    for (UIView* sub in view.subviews) {
        UIView* found = FindViewOfController(sub, name);
        if (found) {
            return found;
        }
    }
    return nil;
}

// First view whose class name contains all the given fragments.
static UIView* FindViewByClassParts(UIView* view, NSArray<NSString*>* parts) {
    NSString* name = NSStringFromClass(view.class);
    BOOL all = YES;
    for (NSString* part in parts) {
        if (![name containsString:part]) {
            all = NO;
            break;
        }
    }
    if (all) {
        return view;
    }
    for (UIView* sub in view.subviews) {
        UIView* found = FindViewByClassParts(sub, parts);
        if (found) {
            return found;
        }
    }
    return nil;
}

// MARK: First visible tweet cell

static UIView* FindStatusCell(UIView* view) {
    if (view.hidden || view.alpha < 0.01) {
        return nil;
    }
    CGRect onScreen = [view convertRect:view.bounds toView:nil];
    if (([NSStringFromClass(view.class) hasSuffix:@"StatusCell"] ||
         [NSStringFromClass(view.class) hasSuffix:@"FocalStatusViewTableViewCell"]) &&
        CGRectIntersectsRect(onScreen, view.window.bounds) && CGRectGetHeight(onScreen) > 60) {
        return view;
    }
    for (UIView* sub in view.subviews) {
        UIView* found = FindStatusCell(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

// Compact outline: only views that carry text (label, button title, accessibility
// label), with their class, frame and hidden state. Short enough to survive a paste.
static void DumpTexts(UIView* view, int depth, NSMutableString* out) {
    if (depth > 14) {
        return;
    }
    NSString* text = nil;
    if ([view isKindOfClass:[UILabel class]]) {
        text = ((UILabel*)view).text;
    } else if ([view isKindOfClass:[UIButton class]]) {
        text = [(UIButton*)view titleForState:UIControlStateNormal];
    }
    if (text.length == 0) {
        text = view.accessibilityLabel;
    }
    if (text.length > 0 || view.accessibilityIdentifier.length > 0) {
        [out appendFormat:@"%@%@ %@%@%@%@%c",
                          [@"" stringByPaddingToLength:MIN(depth, 8) withString:@" " startingAtIndex:0],
                          NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
                          view.accessibilityIdentifier.length ? [@" id=" stringByAppendingString:view.accessibilityIdentifier] : @"",
                          (view.hidden || view.alpha < 0.01) ? @" [hidden]" : @"",
                          text.length ? [NSString stringWithFormat:@" \"%@\"", Trim(text)] : @"", 10];
    }
    for (UIView* sub in view.subviews) {
        DumpTexts(sub, depth + 1, out);
    }
}

// The screen's view controllers, parents to children: shows how a screen with tabs is put
// together (which controller is the pager, which are the pages).
static NSMutableArray<UIViewController*>* gOnScreenControllers;

static void DumpControllers(UIViewController* controller, int depth, NSMutableString* out, NSUInteger* lines) {
    if (!controller || depth > 12 || *lines > 160) {
        return;
    }
    (*lines)++;
    if (controller.isViewLoaded && controller.view.window) {
        [gOnScreenControllers addObject:controller];
    }
    [out appendFormat:@"%@%@%@%c", [@"" stringByPaddingToLength:(NSUInteger)depth withString:@" " startingAtIndex:0],
                      NSStringFromClass(controller.class),
                      controller.isViewLoaded && controller.view.window ? @" (on screen)" : @"", 10];
    NSMutableArray<UIViewController*>* kids = [NSMutableArray array];
    if ([controller isKindOfClass:[UINavigationController class]]) {
        [kids addObjectsFromArray:((UINavigationController*)controller).viewControllers];
    }
    for (UIViewController* child in controller.childViewControllers) {
        if (![kids containsObject:child]) {
            [kids addObject:child];
        }
    }
    if (controller.presentedViewController) {
        [kids addObject:controller.presentedViewController];
    }
    for (UIViewController* kid in kids) {
        DumpControllers(kid, depth + 1, out, lines);
    }
}

// The inside of a class: its properties, instance variables and (the telling) methods. For
// finding out how a screen keeps its list of pages and tabs.
static void DumpClassInfo(Class cls, NSMutableString* out) {
    [out appendFormat:@"-- %@", NSStringFromClass(cls)];
    for (Class parent = class_getSuperclass(cls); parent && parent != [NSObject class] &&
                                                  parent != [UIViewController class] &&
                                                  parent != [UIView class];
         parent = class_getSuperclass(parent)) {
        [out appendFormat:@" < %@", NSStringFromClass(parent)];
    }
    [out appendFormat:@"%c", 10];

    unsigned int count = 0;
    objc_property_t* properties = class_copyPropertyList(cls, &count);
    for (unsigned int i = 0; i < count && i < 60; i++) {
        [out appendFormat:@"  prop %s %s%c", property_getName(properties[i]),
                          property_getAttributes(properties[i]), 10];
    }
    free(properties);

    Ivar* ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count && i < 60; i++) {
        [out appendFormat:@"  ivar %s %s%c", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]), 10];
    }
    free(ivars);

    NSArray* words = @[ @"page", @"tab", @"title", @"item", @"segment", @"content", @"child", @"select",
                        @"reload", @"update", @"data", @"source", @"controller", @"index", @"setup", @"make",
                        @"configure", @"build", @"create" ];
    Method* methods = class_copyMethodList(cls, &count);
    int printed = 0;
    for (unsigned int i = 0; i < count && printed < 90; i++) {
        NSString* name = NSStringFromSelector(method_getName(methods[i]));
        for (NSString* word in words) {
            if ([name localizedCaseInsensitiveContainsString:word]) {
                [out appendFormat:@"  method %@%c", name, 10];
                printed++;
                break;
            }
        }
    }
    free(methods);
}

// Builds the outline of what's on screen and puts it on the pasteboard.
static void PerformDump(UIWindow* window) {
    NSMutableString* out = [NSMutableString
        stringWithFormat:@"%s\nwindow %@\n", NFB_VERSION_STRING, NSStringFromCGRect(window.frame)];
    NSUInteger mediaCount = 0;
    // How the screen is put together: view controllers, and everything in the top part of the
    // screen (where a row of tabs lives) with its text.
    {
        [out appendFormat:@"== CONTROLLERS ==%c", 10];
        NSUInteger controllerLines = 0;
        gOnScreenControllers = [NSMutableArray array];
        DumpControllers(window.rootViewController, 0, out, &controllerLines);

        // The inside of the screen's own controllers (not the shell around every screen).
        [out appendFormat:@"== CLASS INFO ==%c", 10];
        NSMutableSet<NSString*>* described = [NSMutableSet set];
        for (UIViewController* controller in gOnScreenControllers) {
            NSString* name = NSStringFromClass(controller.class);
            if (([name containsString:@"ActivityHistory"] || [name containsString:@"Segmented"] ||
                 [name containsString:@"Paging"] || [name containsString:@"Bookmarks"]) &&
                ![described containsObject:name] && described.count < 6) {
                [described addObject:name];
                DumpClassInfo(controller.class, out);
            }
        }

        [out appendFormat:@"== TOP REGION ==%c", 10];
        NSMutableArray<UIView*>* topQueue = [NSMutableArray arrayWithObject:window];
        NSUInteger topVisited = 0;
        NSUInteger topLines = 0;
        while (topQueue.count > 0 && topVisited < 6000 && topLines < 120) {
            UIView* view = topQueue.firstObject;
            [topQueue removeObjectAtIndex:0];
            topVisited++;
            CGRect inWindow = [window convertRect:view.bounds fromView:view];
            NSString* text = nil;
            if ([view isKindOfClass:[UILabel class]]) {
                text = ((UILabel*)view).text;
            } else if ([view isKindOfClass:[UIButton class]]) {
                text = [(UIButton*)view titleForState:UIControlStateNormal];
            }
            if (!view.hidden && CGRectGetMinY(inWindow) > 100 && CGRectGetMinY(inWindow) < 230 &&
                CGRectGetHeight(inWindow) < 80 && CGRectGetWidth(inWindow) > 0 &&
                (text.length > 0 || view.accessibilityLabel.length > 0)) {
                topLines++;
                [out appendFormat:@"%@ %@ text=%@ label=%@%c", NSStringFromClass(view.class),
                                  NSStringFromCGRect(inWindow), text, view.accessibilityLabel, 10];
            }
            [topQueue addObjectsFromArray:view.subviews];
        }
    }

    [out appendFormat:@"== MEDIA VIEWS ==%c", 10];
    FindMedia(window, out, &mediaCount);
    if (!mediaCount) {
        [out appendFormat:@"(none found)%c", 10];
    }
    UIResponder* focused = NFBCurrentFirstResponder();
    [out appendFormat:@"== FIRST RESPONDER ==%c", 10];
    if (focused) {
        NSMutableArray<NSString*>* chain = [NSMutableArray array];
        for (Class cls = focused.class; cls; cls = class_getSuperclass(cls)) {
            [chain addObject:NSStringFromClass(cls)];
        }
        [out appendFormat:@"%@%c", [chain componentsJoinedByString:@" < "], 10];
        [out appendFormat:@"UITextInput=%d UIKeyInput=%d UITextInputTraits=%d%c",
                          [focused conformsToProtocol:@protocol(UITextInput)],
                          [focused conformsToProtocol:@protocol(UIKeyInput)],
                          [focused conformsToProtocol:@protocol(UITextInputTraits)], 10];
        if ([focused isKindOfClass:[UIView class]]) {
            UIView* view = (UIView*)focused;
            [out appendFormat:@"frame=%@ window=%@%c", NSStringFromCGRect(view.frame),
                              NSStringFromClass(view.window.class), 10];
        }
    } else {
        [out appendFormat:@"(none)%c", 10];
    }

    // The top navigation bar (where the logo is), hidden pieces included.
    UIView* navBar = FindViewByClassParts(window, @[ @"XNavigation", @"Bar" ]);
    if (navBar) {
        [out appendFormat:@"== NAV BAR %@ ==%c", NSStringFromClass(navBar.class), 10];
        NSUInteger navLines = 0;
        gIncludeHidden = YES;
        DumpView(navBar, 0, out, &navLines);
        gIncludeHidden = NO;
    }

    // What the speech bubble has seen and decided.
    [out appendFormat:@"== BUBBLE STATE ==%c%@%c", 10, NFBBubbleDebugText(), 10];
    [out appendFormat:@"== TIME STRINGS ==%c%@%c", 10, NFBStringProbeText(), 10];

    // The drawer's controller: which methods it has (to see who rebuilds the menu list).
    for (NSString* name in @[ @"T1DashContentController", @"T1TabbedAppNavigationViewController" ]) {
        Class dashClass = NSClassFromString(name);
        if (!dashClass) {
            continue;
        }
        [out appendFormat:@"== METHODS %@ ==%c", name, 10];
        unsigned int count = 0;
        Method* methods = class_copyMethodList(dashClass, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString* selector = NSStringFromSelector(method_getName(methods[i]));
            if ([selector localizedCaseInsensitiveContainsString:@"panel"] ||
                [selector localizedCaseInsensitiveContainsString:@"update"] ||
                [selector localizedCaseInsensitiveContainsString:@"reload"] ||
                [selector localizedCaseInsensitiveContainsString:@"snapshot"] ||
                [selector localizedCaseInsensitiveContainsString:@"visible"]) {
                [out appendFormat:@"%@%c", selector, 10];
            }
        }
        free(methods);
    }

    // Tab bar: the accessibility label and value of every element along the bottom edge
    // (the unread badge counts live there).
    {
        [out appendFormat:@"== TAB BAR ==%c", 10];
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
        NSUInteger visited = 0;
        while (queue.count > 0 && visited < 6000) {
            UIView* view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            visited++;
            CGRect inWindow = [window convertRect:view.bounds fromView:view];
            NSString* label = view.accessibilityLabel;
            NSString* value = view.accessibilityValue;
            if ((label.length > 0 || value.length > 0) &&
                CGRectGetMinY(inWindow) > CGRectGetHeight(window.bounds) - 160) {
                [out appendFormat:@"%@ %@ label=%@ value=%@%c", NSStringFromClass(view.class),
                                  NSStringFromCGRect(inWindow), label, value, 10];
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }

    // Menus, popovers and sheets can live in windows of their own; listed first so a
    // clipped paste still has them.
    for (UIWindow* other in window.windowScene.windows) {
        if (other == window) {
            continue;
        }
        [out appendFormat:@"== OTHER WINDOW %@ level=%.0f ==%c", NSStringFromClass(other.class),
                          other.windowLevel, 10];
        NSUInteger otherLines = 0;
        DumpView(other, 0, out, &otherLines);
    }

    UIView* statusCell = FindStatusCell(window);
    [out appendFormat:@"== STATUS CELL %@ ==%c", statusCell ? NSStringFromClass(statusCell.class) : @"(none)", 10];
    if (statusCell) {
        NSUInteger cellLines = 0;
        DumpView(statusCell, 0, out, &cellLines);
    }

    // The profile header (name, @handle, buttons), hidden pieces included.
    UIView* profileHeader = FindViewOfController(window, @"ProfileHeaderViewController");
    if (profileHeader) {
        [out appendFormat:@"== PROFILE HEADER ==%c", 10];
        NSUInteger headerLines = 0;
        (void)headerLines;
        DumpTexts(profileHeader, 0, out);
    }
    // The whole profile page's text, in case the name and @handle live outside the header.
    UIView* profilePage = FindViewOfController(window, @"T1ProfileViewController");
    if (profilePage) {
        [out appendFormat:@"== PROFILE PAGE TEXTS ==%c", 10];
        DumpTexts(profilePage, 0, out);
    }

    [out appendFormat:@"== TIMELINE ITEM PROBE ==%c%@%c", 10, BHTMediaProbeSummary(), 10];

    UIView* dash = FindViewOfController(window, @"DashHostingController");
    if (dash) {
        [out appendFormat:@"== DRAWER ==%c", 10];
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:dash];
        NSUInteger seen = 0;
        while (queue.count > 0 && seen < 250) {
            UIView* view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            seen++;
            NSString* text = [view isKindOfClass:[UILabel class]] ? ((UILabel*)view).text : nil;
            NSString* ax = view.accessibilityLabel;
            if (text.length > 0 || ax.length > 0) {
                [out appendFormat:@"%@ %@ text=%@ ax=%@%c", NSStringFromClass(view.class),
                                  NSStringFromCGRect([window convertRect:view.bounds fromView:view]), text, ax, 10];
            }
            if ([view isKindOfClass:[UIScrollView class]]) {
                [out appendFormat:@"SCROLL %@ visible=%lu%c", NSStringFromClass(view.class),
                                  (unsigned long)view.subviews.count, 10];
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }

    // Last, because it is the longest and the least specific.
    [out appendFormat:@"== TREE (no drawer) ==%c", 10];
    NSUInteger lines = 0;
    DumpView(window, 0, out, &lines);
    [UIPasteboard generalPasteboard].string = out;
    [[[UINotificationFeedbackGenerator alloc]
        init] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

extern UIWindow* NFBKeyWindow(void);

// Pressing volume down starts the dump (instead of shaking). The volume only reports its
// changes to an app whose audio session is active, so while the dump is switched on a
// quiet "ambient" session (mixes with everything, makes no sound) is kept active, and the
// volume is watched both through that session and through the system's notification.
// At the lowest volume nothing changes, so there is nothing to report.
static float gLastVolume = -1;
static CFAbsoluteTime gLastVolumeDump = 0;

static void DumpFromVolumeButton(void) {
    UIWindow* window = NFBKeyWindow();
    if (!window || ![BHTSettings boolForKey:@"kemo_shake_dump"]) {
        return;
    }
    PerformDump(window);

    // Menus and sheets can't be open while the first dump is made, so a second one follows
    // a few seconds later (a second haptic marks it): press, open the menu, wait for it.
    __weak UIWindow* weakWindow = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIWindow* later = weakWindow;
                       if (later && [BHTSettings boolForKey:@"kemo_shake_dump"]) {
                           PerformDump(later);
                       }
                   });
}

static void HandleVolume(float now) {
    BOOL pressedDown = gLastVolume >= 0 && now < gLastVolume - 0.001;
    gLastVolume = now;
    // Both watchers may report the same press.
    if (pressedDown && CFAbsoluteTimeGetCurrent() - gLastVolumeDump > 1.5) {
        gLastVolumeDump = CFAbsoluteTimeGetCurrent();
        DumpFromVolumeButton();
    }
}

@interface NFBVolumeWatcher : NSObject
@end

@implementation NFBVolumeWatcher

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
    NSNumber* value = change[NSKeyValueChangeNewKey];
    if ([value isKindOfClass:[NSNumber class]]) {
        HandleVolume(value.floatValue);
    }
}

@end

static void ArmVolumeWatcher(void) {
    if (![BHTSettings boolForKey:@"kemo_shake_dump"]) {
        return;
    }
    AVAudioSession* session = [AVAudioSession sharedInstance];
    // Only the plain default category is replaced; if the app has chosen its own, it stays.
    if ([session.category isEqualToString:AVAudioSessionCategorySoloAmbient]) {
        [session setCategory:AVAudioSessionCategoryAmbient
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:nil];
    }
    [session setActive:YES error:nil];

    static NFBVolumeWatcher* watcher;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        watcher = [NFBVolumeWatcher new];
        gLastVolume = session.outputVolume;
        [session addObserver:watcher
                  forKeyPath:@"outputVolume"
                     options:NSKeyValueObservingOptionNew
                     context:nil];
    });
}

%ctor {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:@"AVSystemController_SystemVolumeDidChangeNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
                    NSNumber* volume = note.userInfo[@"AVSystemController_AudioVolumeNotificationParameter"];
                    NSString* reason = note.userInfo[@"AVSystemController_AudioVolumeChangeReasonNotificationParameter"];
                    if (volume && (!reason || [reason isEqualToString:@"ExplicitVolumeChange"])) {
                        HandleVolume(volume.floatValue);
                    }
                }];
    // Also whenever the app comes to the front, since another audio session may have taken over.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
                    ArmVolumeWatcher();
                }];
}
