//
//  DebugDump.x
//  NeoFreeBird
//

#import <CoreText/CoreText.h>
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
extern NSString* NFBAccountBubblesDebugText(void);
extern NSString* NFBTimelineFilterDebugText(void);
extern NSString* NFBChatDebugText(void);
extern NSString* NFBStringProbeText(void);
extern NSString* NFBTimelineProbeText(void);
extern NSString* NFBUnifiedProbeText(void);
extern NSString* NFBUnifiedTimelineDebugText(void);
extern void NFBUnifiedProbeKick(void);
extern NSString* NFBWebAccountsDebugText(void);
extern NSString* NFBLastCrashText(void);
extern NSString* NFBCompactMediaDebugText(void);
extern NSString* NFBVerticalTabBarDebugText(void);
extern NSString* NFBReadabilityDebugText(void);
extern NSArray<NSString*>* NFBRowLayoutClasses(void);
extern CGFloat NFBLastMediaWidth(void);
extern NSString* NFBPullAnimationDebugText(void);
extern NSString* NFBParodyLabelDebugText(void);
extern NSString* NFBChirpFontDebugText(void);
extern NSString* NFBClickerDebugText(void);
#import "Core/NFBChirpFonts.h"

static const NSUInteger kMaxLines = 200;
static const int kMaxDepth = 16;

static NSString* Trim(NSString* text) {
    NSString* flat = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return flat.length > 40 ? [[flat substringToIndex:40] stringByAppendingString:@"…"] : flat;
}

// While set, hidden and transparent views are listed too (and marked).
static BOOL gIncludeHidden = NO;
static BOOL gImageDetails = NO;

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
            if (gImageDetails) {
                // Which picture it is: an image from an asset catalogue says its name here.
                NSString* about = image.description;
                [out appendFormat:@" %@ mode=%ld", about.length > 110 ? [about substringToIndex:110] : about,
                                  (long)image.renderingMode];
            }
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
static void DumpClassInfoMatching(Class cls, NSMutableString* out, NSArray<NSString*>* words, unsigned int limit) {
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
    for (unsigned int i = 0; i < count && i < limit; i++) {
        [out appendFormat:@"  prop %s %s%c", property_getName(properties[i]),
                          property_getAttributes(properties[i]), 10];
    }
    free(properties);

    Ivar* ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count && i < limit; i++) {
        [out appendFormat:@"  ivar %s %s%c", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]), 10];
    }
    free(ivars);

    Method* methods = class_copyMethodList(cls, &count);
    unsigned int printed = 0;
    for (unsigned int i = 0; i < count && printed < limit + 30; i++) {
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
    // Class methods too (X computes row sizes in some of these).
    methods = class_copyMethodList(object_getClass(cls), &count);
    printed = 0;
    for (unsigned int i = 0; i < count && printed < 25; i++) {
        NSString* name = NSStringFromSelector(method_getName(methods[i]));
        for (NSString* word in words) {
            if ([name localizedCaseInsensitiveContainsString:word]) {
                [out appendFormat:@"  +method %@%c", name, 10];
                printed++;
                break;
            }
        }
    }
    free(methods);
}

static void DumpClassInfo(Class cls, NSMutableString* out) {
    DumpClassInfoMatching(cls, out,
                          @[ @"page", @"tab", @"title", @"item", @"segment", @"content", @"child", @"select",
                             @"reload", @"update", @"data", @"source", @"controller", @"index", @"setup",
                             @"make", @"configure", @"build", @"create" ],
                          60);
}

// MARK: Row probes (cards, media beside the text, notification piles)

static UITableViewCell* FindPileCell(UIView* view, int depth) {
    if (depth > 30 || view.hidden) {
        return nil;
    }
    if ([view isKindOfClass:[UITableViewCell class]] && view.window) {
        NSUInteger avatars = 0;
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:view];
        NSUInteger budget = 400;
        while (queue.count > 0 && budget-- > 0) {
            UIView* inner = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([NSStringFromClass(inner.class) isEqualToString:@"TFNAvatarHeaderView"]) {
                avatars++;
            }
            [queue addObjectsFromArray:inner.subviews];
        }
        return avatars >= 2 ? (UITableViewCell*)view : nil;
    }
    for (UIView* sub in view.subviews) {
        UITableViewCell* found = FindPileCell(sub, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

// The biggest list on screen (the timeline or notifications being looked at).
static UITableView* FindMainTable(UIView* view, int depth, UITableView* best) {
    if (depth > 30 || view.hidden || view.alpha < 0.05) {
        return best;
    }
    if ([view isKindOfClass:[UITableView class]] && view.window) {
        CGRect frame = [view convertRect:view.bounds toView:nil];
        CGRect visible = CGRectIntersection(frame, view.window.bounds);
        CGFloat area = CGRectIsNull(visible) ? 0 : CGRectGetWidth(visible) * CGRectGetHeight(visible);
        CGRect bestFrame = best ? CGRectIntersection([best convertRect:best.bounds toView:nil], best.window.bounds) : CGRectNull;
        CGFloat bestArea = CGRectIsNull(bestFrame) ? 0 : CGRectGetWidth(bestFrame) * CGRectGetHeight(bestFrame);
        if (area > bestArea) {
            best = (UITableView*)view;
        }
    }
    for (UIView* sub in view.subviews) {
        best = FindMainTable(sub, depth + 1, best);
    }
    return best;
}

static NSString* ColorText(UIColor* color, UITraitCollection* traits) {
    if (!color) {
        return @"nil";
    }
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [[color resolvedColorWithTraitCollection:traits] getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02x%02x%02x/%.2f", (int)(r * 255), (int)(g * 255), (int)(b * 255), a];
}

// Views inside a row that paint a solid colour or round their corners.
static void DumpPainted(UIView* view, UIView* cell, int depth, NSMutableString* out, NSUInteger* lines) {
    if (depth > 6 || *lines > 4) {
        return;
    }
    if ([NSStringFromClass(view.class) hasPrefix:@"NFBCard"]) {
        return;
    }
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [[view.backgroundColor resolvedColorWithTraitCollection:view.traitCollection] getRed:&r green:&g blue:&b alpha:&a];
    if (view != cell && (a > 0.3 || view.layer.cornerRadius > 0) && !view.hidden) {
        CGRect frame = [view convertRect:view.bounds toView:cell];
        [out appendFormat:@"     %*s%@ %@ bg=%@ r=%.0f%@%c", depth, "", NSStringFromClass(view.class),
                          NSStringFromCGRect(frame), ColorText(view.backgroundColor, view.traitCollection),
                          view.layer.cornerRadius, view.clipsToBounds ? @" clip" : @"", 10];
        (*lines)++;
    }
    for (UIView* sub in view.subviews) {
        DumpPainted(sub, cell, depth + 1, out, lines);
    }
}

static NSString* FirstText(UIView* view, int depth) {
    if (depth > 14 || view.hidden) {
        return nil;
    }
    if ([view isKindOfClass:[UILabel class]] && ((UILabel*)view).text.length > 0) {
        return Trim(((UILabel*)view).text);
    }
    if (view.accessibilityLabel.length > 0 && ![view isKindOfClass:[UIButton class]] && depth > 0) {
        return Trim(view.accessibilityLabel);
    }
    for (UIView* sub in view.subviews) {
        NSString* found = FirstText(sub, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

// Thin lines still showing in a row (views and bare layers), to find what draws
// the line between cards.
static void CountLines(CALayer* layer, CALayer* root, CGFloat width, int depth, NSMutableArray<NSString*>* found) {
    if (depth > 8 || layer.hidden || layer.opacity < 0.05 || found.count >= 3) {
        return;
    }
    CGRect frame = [layer.superlayer convertRect:layer.frame toLayer:root];
    if (depth > 0 && CGRectGetHeight(frame) <= 1.5 && CGRectGetWidth(frame) > width * 0.3) {
        id owner = layer.delegate;
        [found addObject:[NSString stringWithFormat:@"%@%@", owner ? NSStringFromClass([owner class]) : NSStringFromClass(layer.class),
                                                    NSStringFromCGRect(frame)]];
    }
    for (CALayer* sub in layer.sublayers) {
        CountLines(sub, root, width, depth + 1, found);
    }
}

static void DumpCardRows(UIWindow* window, NSMutableString* out) {
    UITableView* table = FindMainTable(window, 0, nil);
    if (!table) {
        [out appendFormat:@"== CARD ROWS == (no list)%c", 10];
        return;
    }
    UIViewController* owner = nil;
    for (UIResponder* r = table.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) {
            owner = (UIViewController*)r;
            break;
        }
    }
    [out appendFormat:@"== CARD ROWS == %@ in %@ bg=%@ inset=%@ offset=%.0f%c", NSStringFromClass(table.class),
                      owner ? NSStringFromClass(owner.class) : @"-", ColorText(table.backgroundColor, table.traitCollection),
                      NSStringFromUIEdgeInsets(table.adjustedContentInset), table.contentOffset.y, 10];
    for (UIView* sub in table.subviews) {
        if (![sub isKindOfClass:[UITableViewCell class]] && !sub.hidden && sub.alpha > 0.05 &&
            CGRectGetHeight(sub.frame) > 2) {
            [out appendFormat:@"  [list sub] %@ %@ bg=%@%c", NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
                              ColorText(sub.backgroundColor, sub.traitCollection), 10];
        }
    }
    NSArray<UITableViewCell*>* cells = [table.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UIView* a, UIView* b) {
        return CGRectGetMinY(a.frame) < CGRectGetMinY(b.frame) ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSUInteger shown = 0;
    for (UITableViewCell* cell in cells) {
        if (shown++ >= 5) {
            break;
        }
        NSString* connector = @"-";
        UIView* status = FindViewByClassParts(cell.contentView, @[ @"T1StandardStatusView" ]);
        if (status && [status respondsToSelector:NSSelectorFromString(@"conversationConnectorType")]) {
            NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(status, NSSelectorFromString(@"conversationConnectorType"));
            connector = [NSString stringWithFormat:@"%lu", (unsigned long)type];
        }
        NSString* texts = FirstText(cell.contentView, 0) ?: @"";
        if (texts.length > 40) {
            texts = [texts substringToIndex:40];
        }
        [out appendFormat:@"  %@ y=%.0f h=%.0f card=%@ bgView=%@ conn=%@ cellBg=%@ \"%@\"%c", NSStringFromClass(cell.class),
                          CGRectGetMinY(cell.frame), CGRectGetHeight(cell.frame),
                          [NSStringFromClass(cell.backgroundView.class) hasPrefix:@"NFBCard"] ? @"Y" : @"n",
                          cell.backgroundView ? NSStringFromClass(cell.backgroundView.class) : @"nil", connector,
                          ColorText(cell.backgroundColor, cell.traitCollection), texts, 10];
        NSMutableArray<NSString*>* thin = [NSMutableArray array];
        CountLines(cell.layer, cell.layer, CGRectGetWidth(cell.bounds), 0, thin);
        if (thin.count) {
            [out appendFormat:@"     lines: %@%c", [thin componentsJoinedByString:@" "], 10];
        }
        NSUInteger lines = 0;
        for (UIView* sub in cell.subviews) {
            if (sub == cell.backgroundView) {
                continue;
            }
            DumpPainted(sub, cell, 0, out, &lines);
        }
    }
}

// The name line of the first tweet: what draws it and in which font.
static void DumpAuthorFonts(UIView* view, int depth, NSMutableString* out, NSUInteger* lines) {
    if (depth > 3 || *lines > 24) {
        return;
    }
    UIFont* font = [view respondsToSelector:@selector(font)] ? ((UILabel*)view).font : nil;
    CGFloat backingAlpha = 0;
    [[view.backgroundColor resolvedColorWithTraitCollection:view.traitCollection] getWhite:NULL alpha:&backingAlpha];
    [out appendFormat:@"   %*s%@ %@%@%@%@%@%c", depth, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
                      [font isKindOfClass:[UIFont class]]
                          ? [NSString stringWithFormat:@" font=%@ %.1f", font.fontName, font.pointSize]
                          : @"",
                      view.accessibilityIdentifier.length ? [@" id=" stringByAppendingString:view.accessibilityIdentifier] : @"",
                      view.hidden ? @" [hidden]" : @"",
                      backingAlpha > 0.05 ? [NSString stringWithFormat:@" bg=%.2f%@", backingAlpha, view.opaque ? @" opaque" : @""] : @"",
                      10];
    (*lines)++;
    for (UIView* sub in view.subviews) {
        DumpAuthorFonts(sub, depth + 1, out, lines);
    }
}

static void DumpRowProbe(UIWindow* window, NSMutableString* out) {
    [out appendFormat:@"== COMPACT MEDIA ==%c%@ mediaWidth=%.1f%c", 10, NFBCompactMediaDebugText(), NFBLastMediaWidth(), 10];
    [out appendFormat:@"== READABILITY ==%c%@%c", 10, NFBReadabilityDebugText(), 10];
    [out appendFormat:@"== VERTICAL TAB BAR ==%c%@%c", 10, NFBVerticalTabBarDebugText(), 10];
    [out appendFormat:@"== CLICKER ==%c%@", 10, NFBClickerDebugText()];
    DumpCardRows(window, out);
    // The header (logo place and look), early so it is never cut off.
    [out appendFormat:@"== HEADER ==%c%@%c%@%cparodyLabel: %@%c", 10, NFBBubbleDebugText(), 10, NFBPullAnimationDebugText(),
                      10, NFBParodyLabelDebugText(), 10];
    // The top navigation bar (where the logo is), hidden pieces included, with
    // which picture each image view shows.
    UIView* navBar = FindViewByClassParts(window, @[ @"XNavigation", @"Bar" ]);
    if (navBar) {
        [out appendFormat:@"== NAV BAR %@ %@ ==%c", NSStringFromClass(navBar.class),
                          NSStringFromCGRect([navBar convertRect:navBar.bounds toView:window]), 10];
        NSUInteger navLines = kMaxLines - 70;
        gIncludeHidden = YES;
        gImageDetails = YES;
        DumpView(navBar, 0, out, &navLines);
        gIncludeHidden = NO;
        gImageDetails = NO;
    }
    // What X answers when asked for the list's layout metrics (the card margin
    // is put in there).
    UITableView* list = FindMainTable(window, 0, nil);
    UIResponder* owner = list.nextResponder;
    while (owner && ![owner isKindOfClass:[UIViewController class]]) {
        owner = owner.nextResponder;
    }
    if (owner) {
        UIViewController* controller = (UIViewController*)owner;
        [out appendFormat:@"== LIST CONTROLLER == %@ safe=%@ extra=%@ cellContent=%@%c",
                          NSStringFromClass(controller.class), NSStringFromUIEdgeInsets(list.safeAreaInsets),
                          NSStringFromUIEdgeInsets(controller.additionalSafeAreaInsets),
                          list.visibleCells.count ? NSStringFromCGRect(list.visibleCells.firstObject.contentView.frame) : @"-",
                          10];
        SEL metricsSel = NSSelectorFromString(@"calculatedLayoutMetrics");
        id metrics = [controller respondsToSelector:metricsSel] ? ((id (*)(id, SEL))objc_msgSend)(controller, metricsSel) : nil;
        if (metrics) {
            [out appendFormat:@"  metrics %@:", NSStringFromClass([metrics class])];
            for (NSString* name in @[ @"displayAreaEdgeInsets", @"contentEdgeInsets", @"horizontalSafeAreaInsets" ]) {
                SEL sel = NSSelectorFromString(name);
                if ([metrics respondsToSelector:sel]) {
                    UIEdgeInsets insets = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(metrics, sel);
                    [out appendFormat:@" %@=%@", name, NSStringFromUIEdgeInsets(insets)];
                }
            }
            for (NSString* name in @[ @"canvasWidth", @"displayAreaWidth", @"contentWidth", @"bodyWidth" ]) {
                SEL sel = NSSelectorFromString(name);
                if ([metrics respondsToSelector:sel]) {
                    [out appendFormat:@" %@=%.1f", name, ((CGFloat (*)(id, SEL))objc_msgSend)(metrics, sel)];
                }
            }
            for (NSString* name in @[ @"avatarOrigin", @"bodyOrigin" ]) {
                SEL sel = NSSelectorFromString(name);
                if ([metrics respondsToSelector:sel]) {
                    [out appendFormat:@" %@=%@", name, NSStringFromCGPoint(((CGPoint (*)(id, SEL))objc_msgSend)(metrics, sel))];
                }
            }
            [out appendFormat:@"%c", 10];
        }
    }
    // The first tweet's media on screen, from its container down: what would
    // have to move for a small photo to sit at the right.
    UIView* mediaBox = FindViewByClassParts(window, @[ @"T1StatusViewAttachmentContainerView" ]);
    if (mediaBox) {
        [out appendFormat:@"== MEDIA ROW == in %@ %@%c", NSStringFromClass(mediaBox.superview.class),
                          NSStringFromCGRect(mediaBox.superview.bounds), 10];
        NSUInteger mediaLines = kMaxLines - 22;
        DumpView(mediaBox, 0, out, &mediaLines);
    }
    // The first link preview on screen, to see what it is made of (for a
    // one-line preview with small media).
    UIView* linkCard = FindViewByClassParts(window, @[ @"T1", @"CardView" ]);
    if (linkCard) {
        [out appendFormat:@"== LINK CARD == in %@ %@%c", NSStringFromClass(linkCard.superview.class),
                          NSStringFromCGRect(linkCard.superview.bounds), 10];
        NSUInteger cardLines = kMaxLines - 26;
        DumpView(linkCard, 0, out, &cardLines);
    }
    UIView* status = FindViewByClassParts(window, @[ @"T1StandardStatusView" ]);
    SEL authorSel = NSSelectorFromString(@"visibleAuthorView");
    SEL avatarSel = NSSelectorFromString(@"visibleAvatarView");
    if (status && [status respondsToSelector:authorSel]) {
        UIView* author = ((id (*)(id, SEL))objc_msgSend)(status, authorSel);
        UIView* avatar = [status respondsToSelector:avatarSel] ? ((id (*)(id, SEL))objc_msgSend)(status, avatarSel) : nil;
        [out appendFormat:@"== AUTHOR LINE == avatar=%@ %@ t=%@%c", avatar ? NSStringFromClass(avatar.class) : @"-",
                          avatar ? NSStringFromCGRect(avatar.frame) : @"", avatar ? NSStringFromCGAffineTransform(avatar.transform) : @"", 10];
        NSUInteger lines = 0;
        if (author) {
            DumpAuthorFonts(author, 0, out, &lines);
        }
        // What sits at the top right of the tweet (the "..." button), and where.
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:status];
        NSUInteger budget = 300, shown = 0;
        CGFloat width = CGRectGetWidth(status.bounds);
        while (queue.count > 0 && budget-- > 0 && shown < 6) {
            UIView* view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            CGRect frame = [view convertRect:view.bounds toView:status];
            if (view != status && CGRectGetMinX(frame) > width * 0.75 && CGRectGetMinY(frame) < 50 &&
                CGRectGetWidth(frame) > 4 && CGRectGetWidth(frame) < 60) {
                [out appendFormat:@"   top right: %@ %@ hidden=%d alpha=%.2f in %@%c", NSStringFromClass(view.class),
                                  NSStringFromCGRect(frame), view.hidden, view.alpha,
                                  NSStringFromClass(view.superview.class), 10];
                shown++;
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
    [out appendFormat:@"== END OF ROW PROBES ==%c", 10];
}

// Builds the outline of what's on screen and puts it on the pasteboard.
// Which file each Chirp font really comes from, and whose font it is. The fonts
// can be swapped inside the IPA; this shows whether the installed app has the
// swapped files and which copy X ends up drawing with.
static NSString* FontCopyright(CTFontRef font) {
    CFStringRef copyright = CTFontCopyName(font, kCTFontCopyrightNameKey);
    NSString* text = copyright ? [(__bridge_transfer NSString*)copyright copy] : @"-";
    return text.length > 70 ? [text substringToIndex:70] : text;
}

static void DumpFonts(NSMutableString* out) {
    [out appendFormat:@"== FONTS ==%c%@%c%@%c", 10, NFBChirpFontDebugText(), 10, NFBChirpFontsDebugText(), 10];
    NSString* bundle = [[NSBundle mainBundle] pathForResource:@"TwitterSharedResources_TFNUIAppResources"
                                                       ofType:@"bundle"];
    for (NSString* file in @[ @"Chirp-Regular.otf", @"Chirp-Bold.otf",
                              @"Chirp-UI-VF-With-Overriden-Emoji-202601.ttf" ]) {
        NSString* path = [bundle stringByAppendingPathComponent:file];
        NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSString* who = @"-";
        CGDataProviderRef provider = CGDataProviderCreateWithFilename(path.fileSystemRepresentation);
        if (provider) {
            CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
            if (cgFont) {
                CTFontRef font = CTFontCreateWithGraphicsFont(cgFont, 12, NULL, NULL);
                if (font) {
                    who = FontCopyright(font);
                    CFRelease(font);
                }
                CGFontRelease(cgFont);
            }
            CGDataProviderRelease(provider);
        }
        [out appendFormat:@"file %@ %@ bytes, %@%c", file,
                          attrs ? attrs[NSFileSize] : @"missing", who, 10];
    }
    for (NSString* name in @[ @"Chirp-Regular", @"Chirp-Bold", @"ChirpUIVF202601" ]) {
        UIFont* font = [UIFont fontWithName:name size:12];
        if (!font) {
            [out appendFormat:@"use %@: none%c", name, 10];
            continue;
        }
        CTFontRef ct = (__bridge CTFontRef)font;
        NSURL* url = (__bridge_transfer NSURL*)CTFontCopyAttribute(ct, kCTFontURLAttribute);
        [out appendFormat:@"use %@: %@ (%@)%c", name, url.lastPathComponent ?: @"?", FontCopyright(ct), 10];
        CTFontDescriptorRef wanted = CTFontDescriptorCreateWithNameAndSize((__bridge CFStringRef)name, 12);
        NSArray* all = (__bridge_transfer NSArray*)CTFontDescriptorCreateMatchingFontDescriptors(wanted, NULL);
        CFRelease(wanted);
        if (all.count > 1) {
            for (id descriptor in all) {
                NSURL* other = (__bridge_transfer NSURL*)CTFontDescriptorCopyAttribute(
                    (__bridge CTFontDescriptorRef)descriptor, kCTFontURLAttribute);
                [out appendFormat:@"  also %@%c", other.path ?: @"?", 10];
            }
        }
    }
}

// What the timeline's tweet text is really drawn with: the fonts in the first
// rows' TFNAttributedTextView text, and what X's own font getters hand out.
static NSString* FontLine(UIFont* font) {
    if (![font isKindOfClass:[UIFont class]]) return @"nil";
    NSURL* url = (__bridge_transfer NSURL*)CTFontCopyAttribute((__bridge CTFontRef)font, kCTFontURLAttribute);
    return [NSString stringWithFormat:@"%@ %.1f (%@)", font.fontName, font.pointSize, url.lastPathComponent ?: @"?"];
}

static void CollectTextViews(UIView* view, NSMutableArray<UIView*>* found, int depth) {
    if (found.count >= 4 || depth > 30) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"TFNAttributedTextView"]) {
        [found addObject:view];
        return;
    }
    for (UIView* sub in view.subviews) CollectTextViews(sub, found, depth + 1);
}

static void DumpBodyFonts(UIWindow* window, NSMutableString* out) {
    [out appendFormat:@"== BODY FONTS ==%c", 10];
    Class catalog = objc_getClass("XFontCatalog");
    if (catalog && [catalog respondsToSelector:NSSelectorFromString(@"contentFontWithOffset:weight:")]) {
        UIFont* (*content)(id, SEL, CGFloat, NSInteger) = (void*)objc_msgSend;
        [out appendFormat:@"catalog content: %@%c", FontLine(content(catalog, NSSelectorFromString(@"contentFontWithOffset:weight:"), 0, 0)), 10];
    }
    id group = [objc_getClass("TFNUIDefaultFontGroup") respondsToSelector:@selector(sharedFontGroup)]
                   ? [objc_getClass("TFNUIDefaultFontGroup") performSelector:@selector(sharedFontGroup)]
                   : nil;
    if (group && [group respondsToSelector:NSSelectorFromString(@"bodyFont")]) {
        [out appendFormat:@"group body: %@%c", FontLine([group valueForKey:@"bodyFont"]), 10];
    }
    NSMutableArray<UIView*>* cells = [NSMutableArray array];
    EnumerateSubviewsRecursively(window, ^(UIView* view) {
        if (cells.count < 2 && [NSStringFromClass(view.class) isEqualToString:@"T1StatusCell"]) [cells addObject:view];
    });
    for (UIView* cell in cells) {
        NSMutableArray<UIView*>* texts = [NSMutableArray array];
        CollectTextViews(cell, texts, 0);
        for (UIView* text in texts) {
            id model = [text respondsToSelector:NSSelectorFromString(@"textModel")] ? [text valueForKey:@"textModel"] : nil;
            NSAttributedString* string = [model respondsToSelector:NSSelectorFromString(@"attributedString")]
                                             ? [model valueForKey:@"attributedString"]
                                             : nil;
            if (![string isKindOfClass:[NSAttributedString class]] || string.length == 0) continue;
            NSMutableOrderedSet* fonts = [NSMutableOrderedSet orderedSet];
            [string enumerateAttribute:NSFontAttributeName
                               inRange:NSMakeRange(0, string.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL* stop) {
                                if (fonts.count < 3) [fonts addObject:FontLine(value)];
                            }];
            NSString* head = string.string.length > 16 ? [string.string substringToIndex:16] : string.string;
            [out appendFormat:@"text \"%@\": %@%c", head, [fonts.array componentsJoinedByString:@" | "], 10];
        }
    }
}

static void PerformDump(UIWindow* window) {
    NSMutableString* out = [NSMutableString
        stringWithFormat:@"%s\nwindow %@\n", NFB_VERSION_STRING, NSStringFromCGRect(window.frame)];
    NSUInteger mediaCount = 0;
    // First, so it survives a paste that gets cut short.
    DumpFonts(out);
    DumpBodyFonts(window, out);
    DumpRowProbe(window, out);
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
            if (([name containsString:@"ActivityHistory"] || [name containsString:@"Bookmarks"]) &&
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

    // What the speech bubble has seen and decided.
    [out appendFormat:@"== BUBBLE STATE ==%c%@%c", 10, NFBBubbleDebugText(), 10];
    [out appendFormat:@"== ACCOUNT BUBBLES ==%c%@%c", 10, NFBAccountBubblesDebugText(), 10];
    [out appendFormat:@"== TIMELINE FILTER ==%c%@%c", 10, NFBTimelineFilterDebugText(), 10];
    [out appendFormat:@"== CHAT ==%c%@%c", 10, NFBChatDebugText(), 10];
    [out appendFormat:@"== TIME STRINGS ==%c%@%c", 10, NFBStringProbeText(), 10];
    [out appendFormat:@"== WEB ACCOUNTS ==%c%@%c", 10, NFBWebAccountsDebugText(), 10];
    [out appendFormat:@"== UNIFIED TIMELINE ==%c%@%c", 10, NFBUnifiedTimelineDebugText(), 10];
    [out appendFormat:@"== UNIFIED TIMELINE PROBE ==%c%@%c", 10, NFBUnifiedProbeText(), 10];
    [out appendFormat:@"== TIMELINE REQUESTS ==%c%@%c", 10, NFBTimelineProbeText(), 10];
    [out appendFormat:@"== LAST CRASH ==%c%@%c", 10, NFBLastCrashText(), 10];

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
    // Also kept as a file: a paste into a chat gets cut short, a file does not.
    // Settings > "Send the last dump as a file" shares it; the dump before it
    // is kept beside it.
    NSString* folder = NSTemporaryDirectory();
    NSString* latest = [folder stringByAppendingPathComponent:@"NeoFreeBird-dump.txt"];
    NSString* previous = [folder stringByAppendingPathComponent:@"NeoFreeBird-dump-previous.txt"];
    NSFileManager* files = [NSFileManager defaultManager];
    [files removeItemAtPath:previous error:nil];
    [files moveItemAtPath:latest toPath:previous error:nil];
    [out writeToFile:latest atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
    // Starts the other account's timeline refresh; the second dump below shows the result.
    NFBUnifiedProbeKick();
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
