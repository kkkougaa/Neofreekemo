//
//  DebugDump.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - View tree dump (shake)
// With "kemo_shake_dump" on, shaking the device copies a text outline of what's currently on screen to the
// pasteboard: view classes, owning view controllers, label/button text, and the
// contents of every table or collection view. For working out how an app screen
// is built when its class names aren't known.

// Defined in Hooks/Timeline.x
extern NSString* BHTMediaProbeSummary(void);
#import "Core/NFBFirstResponder.h"

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

// Builds the outline of what's on screen and puts it on the pasteboard.
static void PerformDump(UIWindow* window) {
    NSMutableString* out = [NSMutableString
        stringWithFormat:@"%s\nwindow %@\n", NFB_VERSION_STRING, NSStringFromCGRect(window.frame)];
    NSUInteger mediaCount = 0;
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

    // Last, because it is the longest and the least specific.
    [out appendFormat:@"== TREE (no drawer) ==%c", 10];
    NSUInteger lines = 0;
    DumpView(window, 0, out, &lines);
    [UIPasteboard generalPasteboard].string = out;
    [[[UINotificationFeedbackGenerator alloc]
        init] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

%hook UIWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent*)event {
    %orig;
    if (motion != UIEventSubtypeMotionShake || ![BHTSettings boolForKey:@"kemo_shake_dump"]) {
        return;
    }
    PerformDump(self);

    // Menus and sheets can't be open while shaking, so a second dump follows a few
    // seconds later (a second haptic marks it): shake, open the menu, wait for it.
    __weak UIWindow* weakWindow = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIWindow* window = weakWindow;
                       if (window && [BHTSettings boolForKey:@"kemo_shake_dump"]) {
                           PerformDump(window);
                       }
                   });
}

%end
