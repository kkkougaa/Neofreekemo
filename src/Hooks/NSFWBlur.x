//
//  NSFWBlur.x
//  NeoFreeBird
//

#import <CoreML/CoreML.h>
#import <Vision/Vision.h>
#import "HookHelpers.h"

// The container that holds a timeline tweet's photos, carousel and inline video.
@interface T1StatusPhotoVideoForwardView : UIView
@end

// MARK: - On-device NSFW blur for timeline images
// Runs two models on every image shown inside a tweet's media view (photos, and frames of
// inline videos): GantMan/nsfw_model (MIT, NSFWModel-LICENSE.txt, converted by
// tools/convert_nsfw_model.py) for photos, and deepghs/anime_dbrating (OpenRAIL,
// AnimeRatingModel-LICENSE.txt) for anime-style illustrations. An image either model
// scores above its threshold is covered until tapped; when it was the anime model, the
// cover carries an "R15" or "R18" chip. Answers are cached on the UIImage itself, so a
// reused cell never re-runs the models for a known image.

static NSString* const kBlurSettingKey = @"nsfw_ai_blur";
static float NFBThreshold(void) {
    return [BHTSettings integerForKey:@"nsfw_ai_threshold"] / 100.0f;
}
static const CGFloat kMinImageEdge = 120.0; // px; skips icons and placeholders
static const NSInteger kOverlayTag = 0x4e464232;

static const void* kScoreKey = &kScoreKey;        // UIImage -> the models' answer, or @{pending} while it runs
static const void* kRevealedKey = &kRevealedKey;  // media view -> the image or video the user opened
static const void* kScheduledKey = &kScheduledKey;

// NSFW mode (the drawer toggle) shows everything, so the cover only works while it is off.
static BOOL NFBBlurActive(void) {
    return [BHTSettings boolForKey:kBlurSettingKey] &&
           ![BHTSettings boolForKey:@"disable_sensitive_tweet_warnings"];
}

// MARK: Models

// Compiles a bundled .mlmodel once (the result is kept in Caches) and loads it for Vision.
static VNCoreMLModel* NFBLoadModel(NSString* resource, NSString* cacheName) {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSURL* caches = [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL* compiled = [caches URLByAppendingPathComponent:cacheName];
    NSError* error = nil;

    if (![fm fileExistsAtPath:compiled.path]) {
        NSURL* source = [[BHTBundle sharedBundle] pathForFile:resource];
        if (!source) {
            return nil;
        }
        NSURL* temp = [MLModel compileModelAtURL:source error:&error];
        if (!temp) {
            return nil;
        }
        [fm removeItemAtURL:compiled error:nil];
        if (![fm moveItemAtURL:temp toURL:compiled error:&error]) {
            compiled = temp;
        }
    }

    MLModelConfiguration* config = [MLModelConfiguration new];
    MLModel* ml = [MLModel modelWithContentsOfURL:compiled configuration:config error:&error];
    return ml ? [VNCoreMLModel modelForMLModel:ml error:&error] : nil;
}

// Photos and drawings, five classes (GantMan/nsfw_model).
static VNCoreMLModel* NFBModel(void) {
    static VNCoreMLModel* model = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        model = NFBLoadModel(@"NSFW.mlmodel", @"nfb_nsfw5.mlmodelc");
    });
    return model;
}

// Anime-style illustrations, four ratings (deepghs/anime_dbrating): general, sensitive,
// questionable, explicit. "questionable" and "explicit" are what gets the R15 / R18 chip.
static VNCoreMLModel* NFBAnimeModel(void) {
    static VNCoreMLModel* model = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        model = NFBLoadModel(@"AnimeRating.mlmodel", @"nfb_anime1.mlmodelc");
    });
    return model;
}

static float NFBAnimeThreshold(void) {
    return [BHTSettings integerForKey:@"nsfw_anime_threshold"] / 100.0f;
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

// What the two models said about one picture: "nsfw" (the photo model's score), "anime"
// (questionable + explicit from the anime model) and "r18" (explicit is the stronger of the
// two). A value of -1 means that model gave no answer.
static NSDictionary* NFBNoAnswer(void) {
    return @{@"nsfw" : @(-1.0f), @"anime" : @(-1.0f), @"r18" : @NO};
}

static NSDictionary* NFBMergeAnswers(NSDictionary* a, NSDictionary* b) {
    return @{
        @"nsfw" : @(MAX([a[@"nsfw"] floatValue], [b[@"nsfw"] floatValue])),
        @"anime" : @(MAX([a[@"anime"] floatValue], [b[@"anime"] floatValue])),
        @"r18" : @([a[@"r18"] boolValue] || [b[@"r18"] boolValue]),
    };
}

static BOOL NFBIsFlagged(NSDictionary* answer) {
    return [answer[@"nsfw"] floatValue] >= NFBThreshold() ||
           [answer[@"anime"] floatValue] >= NFBAnimeThreshold();
}

// The chip on the cover: only the anime model rates by age, so only its verdict gets one.
static NSString* NFBChipFor(NSDictionary* answer) {
    if ([answer[@"anime"] floatValue] < NFBAnimeThreshold()) {
        return nil;
    }
    return [answer[@"r18"] boolValue] ? @"R18" : @"R15";
}

// Calls back on the main queue with both models' answers (see above).
static void NFBScoreImage(UIImage* image, void (^done)(NSDictionary* answer)) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        done(NFBNoAnswer());
        return;
    }
    CGImageRetain(cgImage);
    dispatch_async(NFBQueue(), ^{
        float score = -1;
        float anime = -1;
        BOOL r18 = NO;

        VNCoreMLModel* model = NFBModel();
        if (model) {
            VNCoreMLRequest* request = [[VNCoreMLRequest alloc] initWithModel:model];
            request.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFill; // trained on whole resized images
            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
            if ([handler performRequests:@[request] error:nil]) {
                // Classes: drawings, hentai, neutral, porn, sexy. "sexy" is only
                // suggestive, so it counts for half.
                float porn = 0, hentai = 0, sexy = 0;
                BOOL found = NO;
                for (VNClassificationObservation* observation in request.results) {
                    if (![observation isKindOfClass:[VNClassificationObservation class]]) {
                        continue;
                    }
                    found = YES;
                    if ([observation.identifier isEqualToString:@"porn"]) {
                        porn = observation.confidence;
                    } else if ([observation.identifier isEqualToString:@"hentai"]) {
                        hentai = observation.confidence;
                    } else if ([observation.identifier isEqualToString:@"sexy"]) {
                        sexy = observation.confidence;
                    }
                }
                if (found) {
                    score = MIN(porn + hentai + sexy * 0.5f, 1.0f);
                }
            }
        }

        VNCoreMLModel* animeModel = NFBAnimeModel();
        if (animeModel) {
            VNCoreMLRequest* request = [[VNCoreMLRequest alloc] initWithModel:animeModel];
            request.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFill;
            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCGImage:cgImage options:@{}];
            if ([handler performRequests:@[request] error:nil]) {
                for (VNObservation* observation in request.results) {
                    if (![observation isKindOfClass:[VNCoreMLFeatureValueObservation class]]) {
                        continue;
                    }
                    MLMultiArray* logits = ((VNCoreMLFeatureValueObservation*)observation).featureValue.multiArrayValue;
                    if (logits.count < 4) {
                        continue;
                    }
                    // Logits for general, sensitive, questionable, explicit -> probabilities.
                    float values[4];
                    float peak = -1e30f;
                    for (NSInteger i = 0; i < 4; i++) {
                        values[i] = logits[(NSUInteger)i].floatValue;
                        peak = MAX(peak, values[i]);
                    }
                    float sum = 0;
                    for (NSInteger i = 0; i < 4; i++) {
                        values[i] = expf(values[i] - peak);
                        sum += values[i];
                    }
                    float questionable = values[2] / sum;
                    float explicitness = values[3] / sum;
                    anime = MIN(questionable + explicitness, 1.0f);
                    r18 = explicitness > questionable;
                    break;
                }
            }
        }
        CGImageRelease(cgImage);
        NSDictionary* answer = @{@"nsfw" : @(score), @"anime" : @(anime), @"r18" : @(r18)};
        dispatch_async(dispatch_get_main_queue(), ^{
            done(answer);
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

static const void* kChipKey = &kChipKey;

static void NFBShowOverlay(UIView* mediaView, id flagged, NSString* chip) {
    UIView* existing = [mediaView viewWithTag:kOverlayTag];
    if (existing) {
        NSString* shown = objc_getAssociatedObject(existing, kChipKey);
        if ([(shown ?: @"") isEqualToString:(chip ?: @"")]) {
            existing.frame = mediaView.bounds;
            [mediaView bringSubviewToFront:existing];
            return;
        }
        [existing removeFromSuperview];
    }

    NFBBlurOverlay* overlay = [[NFBBlurOverlay alloc] initWithFrame:mediaView.bounds];
    overlay.tag = kOverlayTag;
    overlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.layer.cornerRadius = mediaView.layer.cornerRadius;
    overlay.clipsToBounds = YES;
    overlay.backgroundColor = [UIColor systemGrayColor];
    objc_setAssociatedObject(overlay, kChipKey, chip, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // "R15" / "R18" in the top-left corner when the anime model made the call.
    if (chip.length > 0) {
        UILabel* chipLabel = [UILabel new];
        chipLabel.text = chip;
        chipLabel.textColor = [UIColor whiteColor];
        chipLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
        chipLabel.textAlignment = NSTextAlignmentCenter;
        chipLabel.backgroundColor = [chip isEqualToString:@"R18"] ? [UIColor systemRedColor]
                                                                   : [UIColor systemOrangeColor];
        chipLabel.layer.cornerRadius = 9;
        chipLabel.clipsToBounds = YES;
        [chipLabel sizeToFit];
        chipLabel.frame = CGRectMake(10, 10, CGRectGetWidth(chipLabel.bounds) + 16, 22);
        [overlay addSubview:chipLabel];
    }

    static const CGFloat kBadgeSize = 28.0;
    static const CGFloat kBadgeInset = 10.0;
    UIView* badge = NFBBadgeIcon(kBadgeSize);
    badge.frame = CGRectMake(CGRectGetWidth(overlay.bounds) - kBadgeSize - kBadgeInset,
                             CGRectGetHeight(overlay.bounds) - kBadgeSize - kBadgeInset,
                             kBadgeSize, kBadgeSize);
    badge.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [overlay addSubview:badge];

    // Centered explanation and the button that opens the image.
    UILabel* message = [UILabel new];
    message.text = [[BHTBundle sharedBundle] localizedStringForKey:@"NSFW_AI_BLUR_OVERLAY_TITLE"];
    message.textColor = [UIColor whiteColor];
    message.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;

    UIButton* showButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [showButton setTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"NSFW_AI_BLUR_SHOW"]
                forState:UIControlStateNormal];
    [showButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    showButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    showButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    showButton.contentEdgeInsets = UIEdgeInsetsMake(8, 18, 8, 18);
    showButton.layer.cornerRadius = 16;
    [showButton addTarget:overlay
                   action:@selector(nfb_reveal)
         forControlEvents:UIControlEventTouchUpInside];

    UIStackView* stack =
        [[UIStackView alloc] initWithArrangedSubviews:@[ message, showButton ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor
                                                         constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor
                                                       constant:-16],
    ]];

    __weak UIView* weakMedia = mediaView;
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

// MARK: Videos
// Timeline videos (T1InlineVideoView) have no thumbnail image view, so a frame is
// taken from the video itself: a bitmap already sitting in one of its layers if
// there is one, otherwise a snapshot of the view. A few frames are checked right
// after it appears, and the worst score wins. State is kept per video URL so a
// reused cell doesn't inherit another video's verdict.

@interface NFBVideoState : NSObject
@property (nonatomic, strong) NSDictionary* answer; // the worst answer over the frames checked
@property (nonatomic, assign) NSInteger checks;
@property (nonatomic, assign) CFTimeInterval lastCheck;
@property (nonatomic, assign) BOOL pending;
@property (nonatomic, strong) NSObject* token; // identity for the "opened" state
@end

@implementation NFBVideoState
- (instancetype)init {
    if ((self = [super init])) {
        _answer = NFBNoAnswer();
        _token = [NSObject new];
    }
    return self;
}
@end

static const void* kVideoStateKey = &kVideoStateKey;
static const NSInteger kMaxVideoChecks = 4;

static AVPlayerLayer* NFBFindPlayerLayer(CALayer* layer) {
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        return (AVPlayerLayer*)layer;
    }
    for (CALayer* sub in layer.sublayers) {
        AVPlayerLayer* found = NFBFindPlayerLayer(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

static NSString* NFBVideoKey(UIView* video) {
    AVPlayerLayer* playerLayer = NFBFindPlayerLayer(video.layer);
    AVAsset* asset = playerLayer.player.currentItem.asset;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        return ((AVURLAsset*)asset).URL.absoluteString;
    }
    return nil;
}

static NFBVideoState* NFBStateForVideo(UIView* video) {
    static NSCache<NSString*, NFBVideoState*>* byURL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        byURL = [NSCache new];
        byURL.countLimit = 300;
    });

    NSString* key = NFBVideoKey(video);
    NFBVideoState* state = key ? [byURL objectForKey:key]
                               : objc_getAssociatedObject(video, kVideoStateKey);
    if (!state) {
        state = [NFBVideoState new];
        if (key) {
            [byURL setObject:state forKey:key];
        } else {
            objc_setAssociatedObject(video, kVideoStateKey, state,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return state;
}

static UIView* NFBFindVideo(UIView* root) {
    static Class videoClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        videoClass = NSClassFromString(@"T1InlineVideoView");
    });
    if (!videoClass) {
        return nil;
    }
    __block UIView* found = nil;
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if (!found && [view isKindOfClass:videoClass]) {
            found = view;
        }
    });
    return found;
}

static UIImage* NFBBitmapInLayer(CALayer* layer, int depth) {
    id contents = layer.contents;
    if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
        CGImageRef image = (__bridge CGImageRef)contents;
        if (MIN(CGImageGetWidth(image), CGImageGetHeight(image)) >= kMinImageEdge) {
            return [UIImage imageWithCGImage:image];
        }
    }
    if (depth < 8) {
        for (CALayer* sub in layer.sublayers) {
            UIImage* found = NFBBitmapInLayer(sub, depth + 1);
            if (found) {
                return found;
            }
        }
    }
    return nil;
}

static UIImage* NFBVideoFrame(UIView* video) {
    UIImage* bitmap = NFBBitmapInLayer(video.layer, 0);
    if (bitmap) {
        return bitmap;
    }

    CGSize size = video.bounds.size;
    if (size.width < 50 || size.height < 50) {
        return nil;
    }
    // Small snapshot; the model only sees 224x224 anyway.
    UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = MIN(1.0, 320.0 / MAX(size.width, size.height));
    format.opaque = YES;
    UIGraphicsImageRenderer* renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        [video drawViewHierarchyInRect:CGRectMake(0, 0, size.width, size.height)
                    afterScreenUpdates:NO];
    }];
}

// MARK: Scan

static void NFBScanMediaView(UIView* mediaView);

static void NFBRescanLater(UIView* mediaView, NSTimeInterval delay) {
    __weak UIView* weakMedia = mediaView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       UIView* media = weakMedia;
                       if (media.window) {
                           NFBScanMediaView(media);
                       }
                   });
}

static void NFBScanMediaView(UIView* mediaView) {
    if (!NFBBlurActive()) {
        NFBRemoveOverlay(mediaView);
        return;
    }

    __block id flagged = nil;
    __block NSDictionary* flaggedAnswer = nil;

    // Photos
    UIView* existingOverlay = [mediaView viewWithTag:kOverlayTag];
    EnumerateSubviewsRecursively(mediaView, ^(UIView* view) {
        if (![view isKindOfClass:[UIImageView class]] ||
            (existingOverlay && [view isDescendantOfView:existingOverlay])) {
            return;
        }
        UIImage* image = ((UIImageView*)view).image;
        if (!image.CGImage ||
            MIN(image.size.width, image.size.height) * image.scale < kMinImageEdge) {
            return;
        }

        NSDictionary* answer = objc_getAssociatedObject(image, kScoreKey);
        if (!answer) {
            objc_setAssociatedObject(image, kScoreKey, @{@"pending" : @YES},
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIView* weakMedia = mediaView;
            NFBScoreImage(image, ^(NSDictionary* result) {
                objc_setAssociatedObject(image, kScoreKey, result,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                UIView* media = weakMedia;
                if (media) {
                    NFBScanMediaView(media);
                }
            });
        } else if (!answer[@"pending"] && NFBIsFlagged(answer) && !flagged) {
            flagged = image;
            flaggedAnswer = answer;
        }
    });

    // Video
    UIView* video = NFBFindVideo(mediaView);
    if (video.window) {
        NFBVideoState* state = NFBStateForVideo(video);
        CFTimeInterval now = CACurrentMediaTime();
        if (!state.pending && state.checks < kMaxVideoChecks && now - state.lastCheck > 0.9) {
            UIImage* frame = NFBVideoFrame(video);
            state.lastCheck = now;
            state.checks += 1;
            if (frame) {
                state.pending = YES;
                __weak UIView* weakMedia = mediaView;
                NFBScoreImage(frame, ^(NSDictionary* result) {
                    state.pending = NO;
                    state.answer = NFBMergeAnswers(state.answer, result);
                    UIView* media = weakMedia;
                    if (media) {
                        NFBScanMediaView(media);
                    }
                });
            }
        }
        if (state.checks < kMaxVideoChecks) {
            NFBRescanLater(mediaView, 1.0);
        }
        if (NFBIsFlagged(state.answer) && !flagged) {
            flagged = state.token;
            flaggedAnswer = state.answer;
        }
    }

    id revealed = objc_getAssociatedObject(mediaView, kRevealedKey);
    if (flagged && flagged != revealed) {
        NFBShowOverlay(mediaView, flagged, NFBChipFor(flaggedAnswer));
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

// One container holds a tweet's photos, carousel and inline video alike.
%hook T1StatusPhotoVideoForwardView

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

    Class mediaClass = %c(T1StatusPhotoVideoForwardView);
    UIView* ancestor = self.superview;
    for (int depth = 0; ancestor && depth < 12; depth++, ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:mediaClass]) {
            NFBScheduleScan(ancestor);
            return;
        }
    }
}

%end
