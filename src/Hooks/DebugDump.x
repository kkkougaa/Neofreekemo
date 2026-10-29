//
//  DebugDump.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - View tree dump (shake)
// Shaking the device copies a text outline of what's currently on screen to the
// pasteboard: view classes, owning view controllers, label/button text, and the
// contents of every table or collection view. For working out how an app screen
// is built when its class names aren't known.

static const NSUInteger kMaxLines = 1500;
static const int kMaxDepth = 16;

static NSString* Trim(NSString* text) {
    NSString* flat = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return flat.length > 40 ? [[flat substringToIndex:40] stringByAppendingString:@"…"] : flat;
}

static void DumpView(UIView* view, int depth, NSMutableString* out, NSUInteger* lines) {
    if (*lines >= kMaxLines || depth > kMaxDepth || view.hidden || view.alpha < 0.01) {
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
    if (view.accessibilityIdentifier.length) {
        [out appendFormat:@" id=%@", view.accessibilityIdentifier];
    }
    if ([view isKindOfClass:[UILabel class]]) {
        [out appendFormat:@" \"%@\"", Trim(((UILabel*)view).text ?: @"")];
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
    [out appendString:@"\n"];

    for (UIView* sub in view.subviews) {
        DumpView(sub, depth + 1, out, lines);
    }
}

%hook UIWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent*)event {
    %orig;
    if (motion != UIEventSubtypeMotionShake) {
        return;
    }

    NSMutableString* out = [NSMutableString
        stringWithFormat:@"%s\nwindow %@\n", NFB_VERSION_STRING, NSStringFromCGRect(self.frame)];
    NSUInteger lines = 0;
    DumpView(self, 0, out, &lines);
    [UIPasteboard generalPasteboard].string = out;
    [[[UINotificationFeedbackGenerator alloc]
        init] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

%end
