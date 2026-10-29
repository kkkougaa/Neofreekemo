//
//  LaunchLogo.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Launch animation logo
// The animated launch screen draws its own logo, separate from the static
// LaunchScreen.nib image. Swap any bitmap it holds for the resource pack's launch
// art (LaunchStoryboardBackgroundImage in the app's asset catalog), keeping each
// view's rendering mode so tinting still works. The first launch of each build also
// copies a dump of the view/layer tree to the pasteboard, since the logo may be a
// vector shape this can't replace.

static const void* kReplacedKey = &kReplacedKey;

static UIImage* LaunchArt(void) {
    static UIImage* art;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        art = [UIImage imageNamed:@"LaunchStoryboardBackgroundImage"
                         inBundle:[NSBundle mainBundle]
    compatibleWithTraitCollection:nil];
    });
    return art;
}

static void ReplaceBitmaps(UIView* root) {
    UIImage* art = LaunchArt();
    if (!art.CGImage) {
        return;
    }

    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if ([view isKindOfClass:[UIImageView class]]) {
            UIImageView* imageView = (UIImageView*)view;
            // Full-bleed images are backgrounds, not the logo.
            if (imageView.image && imageView.image != art &&
                CGRectGetWidth(imageView.bounds) < CGRectGetWidth(root.bounds) * 0.9 &&
                ![objc_getAssociatedObject(imageView, kReplacedKey) boolValue]) {
                UIImageRenderingMode mode = imageView.image.renderingMode;
                imageView.image = [art imageWithRenderingMode:mode];
                objc_setAssociatedObject(imageView, kReplacedKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    });
}

static void DescribeLayer(CALayer* layer, int depth, NSMutableString* out) {
    NSString* indent = [@"" stringByPaddingToLength:depth * 2
                                         withString:@" "
                                    startingAtIndex:0];
    [out appendFormat:@"%@L %@ bounds=%@ contents=%@", indent, NSStringFromClass(layer.class),
                      NSStringFromCGRect(layer.bounds), layer.contents ? @"yes" : @"no"];
    if ([layer isKindOfClass:[CAShapeLayer class]]) {
        CGPathRef path = ((CAShapeLayer*)layer).path;
        [out appendFormat:@" path=%@",
                          path ? NSStringFromCGRect(CGPathGetBoundingBox(path)) : @"nil"];
    }
    if (layer.mask) {
        [out appendFormat:@" mask=%@", NSStringFromClass(layer.mask.class)];
    }
    [out appendString:@"\n"];
    if (depth < 7) {
        for (CALayer* sub in layer.sublayers) {
            DescribeLayer(sub, depth + 1, out);
        }
    }
}

static void DescribeView(UIView* view, int depth, NSMutableString* out) {
    NSString* indent = [@"" stringByPaddingToLength:depth * 2
                                         withString:@" "
                                    startingAtIndex:0];
    [out appendFormat:@"%@V %@ frame=%@", indent, NSStringFromClass(view.class),
                      NSStringFromCGRect(view.frame)];
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage* image = ((UIImageView*)view).image;
        [out appendFormat:@" image=%@ mode=%ld", image ? NSStringFromCGSize(image.size) : @"nil",
                          (long)image.renderingMode];
    }
    [out appendString:@"\n"];
    DescribeLayer(view.layer, depth + 1, out);
    if (depth < 7) {
        for (UIView* sub in view.subviews) {
            DescribeView(sub, depth + 1, out);
        }
    }
}

static void DumpOnce(UIView* root) {
    NSString* key = [@"nfb_launch_dump_" stringByAppendingString:@NFB_VERSION_STRING];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:key] || CGRectIsEmpty(root.bounds)) {
        return;
    }
    [defaults setBool:YES forKey:key];

    NSMutableString* out = [NSMutableString stringWithFormat:@"%s\n", NFB_VERSION_STRING];
    DescribeView(root, 0, out);
    [UIPasteboard generalPasteboard].string = out;
}

%hook T1AnimatedLaunchScreenView

- (void)layoutSubviews {
    %orig;
    ReplaceBitmaps((UIView*)self);
    DumpOnce((UIView*)self);
}

// Swap earlier than layout so the stock logo never gets a frame on screen.
- (void)didMoveToWindow {
    %orig;
    ReplaceBitmaps((UIView*)self);
}

- (void)didAddSubview:(UIView*)subview {
    %orig;
    ReplaceBitmaps((UIView*)self);
}

%end

// Logo images set after the view is already in place.
%hook UIImageView

- (void)setImage:(UIImage*)image {
    UIImage* art = image ? LaunchArt() : nil;
    if (art.CGImage && image != art &&
        ![objc_getAssociatedObject(self, kReplacedKey) boolValue] &&
        CGRectGetWidth(self.bounds) < 400) {
        Class launchClass = %c(T1AnimatedLaunchScreenView);
        UIView* ancestor = self.superview;
        for (int depth = 0; ancestor && depth < 8; depth++, ancestor = ancestor.superview) {
            if ([ancestor isKindOfClass:launchClass]) {
                objc_setAssociatedObject(self, kReplacedKey, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                image = [art imageWithRenderingMode:image.renderingMode];
                break;
            }
        }
    }
    %orig(image);
}

%end
