//
//  NSFWBlur.x
//  NeoFreeBird
//

#import <CoreML/CoreML.h>
#import <Vision/Vision.h>
#import "HookHelpers.h"

// MARK: - On-device NSFW blur for timeline images
// Runs lovoo/NSFWDetector (BSD-3-Clause, see NSFWDetector-LICENSE.txt in the tweak
// bundle) on every image shown inside a tweet's media view. Images scoring above
// the threshold are covered with a blur until tapped. Scores are cached on the
// UIImage itself, so a reused cell never re-runs the model for a known image.

static NSString* const kBlurSettingKey = @"nsfw_ai_blur";
static const float kNSFWThreshold = 0.7f;
static const CGFloat kMinImageEdge = 120.0; // px; skips icons and placeholders
static const NSInteger kOverlayTag = 0x4e464232;

static const void* kScoreKey = &kScoreKey;        // UIImage -> @(score), or @(-1) while pending
static const void* kRevealedKey = &kRevealedKey;  // media view -> the UIImage the user opened
static const void* kScheduledKey = &kScheduledKey;

static BOOL NFBBlurActive(void) {
    return [BHTSettings boolForKey:kBlurSettingKey];
}

// MARK: Model

static VNCoreMLModel* NFBModel(void) {
    static VNCoreMLModel* model = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager* fm = [NSFileManager defaultManager];
        NSURL* caches = [[fm URLsForDirectory:NSCachesDirectory
                                     inDomains:NSUserDomainMask] firstObject];
        NSURL* compiled = [caches URLByAppendingPathComponent:@"nfb_NSFW.mlmodelc"];
        NSError* error = nil;

        if (![fm fileExistsAtPath:compiled.path]) {
            NSURL* source = [[BHTBundle sharedBundle] pathForFile:@"NSFW.mlmodel"];
            if (!source) {
                return;
            }
            NSURL* temp = [MLModel compileModelAtURL:source error:&error];
            if (!temp) {
                return;
            }
            [fm removeItemAtURL:compiled error:nil];
            if (![fm moveItemAtURL:temp toURL:compiled error:&error]) {
                compiled = temp;
            }
        }

        MLModelConfiguration* config = [MLModelConfiguration new];
        MLModel* ml = [MLModel modelWithContentsOfURL:compiled
                                        configuration:config
                                                error:&error];
        if (ml) {
            model = [VNCoreMLModel modelForMLModel:ml error:&error];
        }
    });
    return model;
}

static dispatch_queue_t NFBQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("nfb.nsfw", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(
            queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

// Calls back on the main queue with the NSFW confidence, or -2 on failure.
static void NFBScoreImage(UIImage* image, void (^done)(float score)) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        done(-2);
        return;
    }
    CGImageRetain(cgImage);
    dispatch_async(NFBQueue(), ^{
        float score = -2;
        VNCoreMLModel* model = NFBModel();
        if (model) {
            VNCoreMLRequest* request = [[VNCoreMLRequest alloc] initWithModel:model];
            request.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFill;
            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
            if ([handler performRequests:@[request] error:nil]) {
                for (VNClassificationObservation* observation in request.results) {
                    if ([observation isKindOfClass:[VNClassificationObservation class]] &&
                        [observation.identifier isEqualToString:@"NSFW"]) {
                        score = observation.confidence;
                        break;
                    }
                }
            }
        }
        CGImageRelease(cgImage);
        dispatch_async(dispatch_get_main_queue(), ^{
            done(score);
        });
    });
}

// MARK: Overlay

@interface NFBBlurOverlay : UIView
- (void)nfb_reveal;
@end

@implementation NFBBlurOverlay

- (void)nfb_reveal {
    void (^block)(void) = objc_getAssociatedObject(self, @selector(nfb_reveal));
    if (block) {
        block();
    }
}

@end

static UIImage* OverlayImage(NSString* name) {
    NSURL* url = [[BHTBundle sharedBundle] pathForFile:name];
    UIImage* image = url ? [UIImage imageWithContentsOfFile:url.path] : nil;
    return image.CGImage ? [UIImage imageWithCGImage:image.CGImage
                                               scale:3.0
                                         orientation:UIImageOrientationUp]
                         : nil;
}

// The side-drawer toggle's "on" icon (accent badge, white art, pink blush) as a
// small corner badge.
static UIView* NFBBadgeIcon(CGFloat size) {
    UIView* icon = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    icon.userInteractionEnabled = NO;

    NSArray* layers = @[ @"badge", @"art", @"blush" ];
    for (NSString* layer in layers) {
        UIImage* image =
            OverlayImage([NSString stringWithFormat:@"nfb_sens_on_%@.png", layer]);
        BOOL tinted = ![layer isEqualToString:@"blush"];
        UIImageView* view = [[UIImageView alloc]
            initWithImage:tinted ? [image imageWithRenderingMode:
                                              UIImageRenderingModeAlwaysTemplate]
                                 : image];
        view.frame = icon.bounds;
        if ([layer isEqualToString:@"badge"]) {
            view.tintColor = CurrentAccentColor();
        } else if (tinted) {
            view.tintColor = [UIColor whiteColor];
        }
        [icon addSubview:view];
    }
    return icon;
}

static void NFBRemoveOverlay(UIView* mediaView) {
    [[mediaView viewWithTag:kOverlayTag] removeFromSuperview];
}

static void NFBShowOverlay(UIView* mediaView, UIImage* flagged) {
    UIView* existing = [mediaView viewWithTag:kOverlayTag];
    if (existing) {
        existing.frame = mediaView.bounds;
        [mediaView bringSubviewToFront:existing];
        return;
    }

    NFBBlurOverlay* overlay = [[NFBBlurOverlay alloc] initWithFrame:mediaView.bounds];
    overlay.tag = kOverlayTag;
    overlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.layer.cornerRadius = mediaView.layer.cornerRadius;
    overlay.clipsToBounds = YES;
    overlay.backgroundColor = [UIColor systemGrayColor];
    overlay.isAccessibilityElement = YES;
    overlay.accessibilityLabel = @"Sensitive image";
    overlay.accessibilityTraits = UIAccessibilityTraitButton;

    static const CGFloat kBadgeSize = 28.0;
    static const CGFloat kBadgeInset = 10.0;
    UIView* badge = NFBBadgeIcon(kBadgeSize);
    badge.frame = CGRectMake(CGRectGetWidth(overlay.bounds) - kBadgeSize - kBadgeInset,
                             CGRectGetHeight(overlay.bounds) - kBadgeSize - kBadgeInset,
                             kBadgeSize, kBadgeSize);
    badge.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [overlay addSubview:badge];

    __weak UIView* weakMedia = mediaView;
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc]
        initWithTarget:overlay action:@selector(nfb_reveal)];
    [overlay addGestureRecognizer:tap];
    objc_setAssociatedObject(overlay, @selector(nfb_reveal), ^{
        UIView* media = weakMedia;
        if (!media) {
            return;
        }
        objc_setAssociatedObject(media, kRevealedKey, flagged,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIView* current = [media viewWithTag:kOverlayTag];
        [UIView animateWithDuration:0.2
            animations:^{
                current.alpha = 0;
            }
            completion:^(BOOL finished) {
                [current removeFromSuperview];
            }];
    }, OBJC_ASSOCIATION_COPY_NONATOMIC);

    [mediaView addSubview:overlay];
}

// MARK: Scan

static void NFBScanMediaView(UIView* mediaView) {
    if (!NFBBlurActive()) {
        NFBRemoveOverlay(mediaView);
        return;
    }

    __block UIImage* flagged = nil;
    EnumerateSubviewsRecursively(mediaView, ^(UIView* view) {
        if (![view isKindOfClass:[UIImageView class]] ||
            [view isDescendantOfView:[mediaView viewWithTag:kOverlayTag]]) {
            return;
        }
        UIImage* image = ((UIImageView*)view).image;
        if (!image.CGImage ||
            MIN(image.size.width, image.size.height) * image.scale < kMinImageEdge) {
            return;
        }

        NSNumber* score = objc_getAssociatedObject(image, kScoreKey);
        if (!score) {
            objc_setAssociatedObject(image, kScoreKey, @(-1),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIView* weakMedia = mediaView;
            NFBScoreImage(image, ^(float result) {
                objc_setAssociatedObject(image, kScoreKey, @(result),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UIView* media = weakMedia;
                if (media) {
                    NFBScanMediaView(media);
                }
            });
        } else if (score.floatValue >= kNSFWThreshold && !flagged) {
            flagged = image;
        }
    });

    UIImage* revealed = objc_getAssociatedObject(mediaView, kRevealedKey);
    if (flagged && flagged != revealed) {
        NFBShowOverlay(mediaView, flagged);
    } else {
        NFBRemoveOverlay(mediaView);
    }
}

static void NFBScheduleScan(UIView* mediaView) {
    if ([objc_getAssociatedObject(mediaView, kScheduledKey) boolValue]) {
        return;
    }
    objc_setAssociatedObject(mediaView, kScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(mediaView, kScheduledKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NFBScanMediaView(mediaView);
    });
}

%hook _TtC21TweetMediaAttachments14MultiMediaView

- (void)layoutSubviews {
    %orig;
    if (NFBBlurActive() || [self viewWithTag:kOverlayTag]) {
        NFBScheduleScan((UIView*)self);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (NFBBlurActive() || [self viewWithTag:kOverlayTag]) {
        NFBScheduleScan((UIView*)self);
    }
}

%end

// Images arrive after layout, so rescan the owning media view whenever one lands.
%hook UIImageView

- (void)setImage:(UIImage*)image {
    %orig;
    if (!image || !NFBBlurActive()) {
        return;
    }

    Class mediaClass = %c(_TtC21TweetMediaAttachments14MultiMediaView);
    UIView* ancestor = self.superview;
    for (int depth = 0; ancestor && depth < 12; depth++, ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:mediaClass]) {
            NFBScheduleScan(ancestor);
            return;
        }
    }
}

%end
