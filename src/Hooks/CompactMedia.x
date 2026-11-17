//
//  CompactMedia.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Small media in timeline tweets
// With "kemo_compact_media" on and NSFW mode off, timeline tweets show their media small
// (this replaced the on-device AI blur in 7.3.76):
//
//  - one photo or video: a small square under the text;
//  - several: X's own horizontal carousel, only short, so it still scrolls sideways;
//  - link previews (cards): laid out at a narrow width, so the picture is small too.
//
// Everything is done where X computes the layout, so the row height shrinks along with
// the media and nothing is covered:
//  - -[T1StandardStatusAttachmentViewAdapter _t1_photoVideoForwardViewSizeForViewModel:...]
//    sizes the media block;
//  - +[MultiMediaCarouselView carouselHeightFor:...] gives the carousel its height, and
//    the items take their width from that height;
//  - the two card layout getters take the width the card is laid out in.
//
// Layout states and row heights are cached, so a change of mode (the switch, or NSFW
// mode from the drawer) marks old layout states stale and reloads visible timelines.

static NSString* const kCompactKey = @"kemo_compact_media";
static NSString* const kSensitiveKey = @"disable_sensitive_tweet_warnings"; // NSFW mode
static const CGFloat kThumbSide = 92.0;
static const CGFloat kCardWidth = 190.0;

static const void* kLayoutModeKey = &kLayoutModeKey;

// Probe for the debug dump: how often each path ran, and the last view model class.
static NSInteger gSizeCalls = 0, gSquares = 0, gStrips = 0, gCarouselCalls = 0, gCardCalls = 0;
static NSString* gLastViewModelClass = nil;

static BOOL NFBCompactMedia(void) {
    return [BHTSettings boolForKey:kCompactKey] && ![BHTSettings boolForKey:kSensitiveKey];
}

static id NFBObjectForSelector(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

// The status a layout view model stands for (the original for a retweet).
static id NFBStatusOf(id viewModel) {
    id status = viewModel;
    for (NSString* name in @[ @"representedStatus", @"status" ]) {
        id inner = NFBObjectForSelector(status, name);
        if (inner) {
            status = inner;
        }
    }
    return status;
}

static NSUInteger NFBMediaCount(id viewModel) {
    for (id object in @[ viewModel ?: [NSNull null], NFBStatusOf(viewModel) ?: [NSNull null] ]) {
        for (NSString* name in @[ @"inlineMediaInfos", @"representedMediaEntities" ]) {
            id list = NFBObjectForSelector(object, name);
            if ([list isKindOfClass:[NSArray class]] && [list count] > 0) {
                return [list count];
            }
        }
    }
    return 0;
}

// Polls and other interactive cards keep their size; only link-style cards shrink.
static BOOL NFBIsPreviewCard(id viewModel) {
    id card = NFBObjectForSelector(NFBStatusOf(viewModel), @"cardData");
    NSString* name = NFBObjectForSelector(card, @"name");
    if (![name isKindOfClass:[NSString class]]) {
        return NO;
    }
    return [name containsString:@"summary"] || [name containsString:@"player"] ||
           [name containsString:@"website"] || [name containsString:@"link"];
}

%hook T1StandardStatusAttachmentViewAdapter

- (CGSize)_t1_photoVideoForwardViewSizeForViewModel:(id)viewModel
                                      layoutMetrics:(id)layoutMetrics
                                              width:(CGFloat)width
                                     attachmentType:(NSUInteger)attachmentType {
    CGSize size = %orig;
    gSizeCalls++;
    gLastViewModelClass = NSStringFromClass([viewModel class]);
    if (!NFBCompactMedia() || size.width <= 0 || size.height <= 0) {
        return size;
    }
    if (NFBMediaCount(viewModel) > 1) {
        gStrips++;
        return CGSizeMake(size.width, MIN(size.height, kThumbSide));
    }
    gSquares++;
    CGFloat side = MIN(kThumbSide, MIN(size.width, width));
    return CGSizeMake(side, side);
}

- (id)_t1_cardViewLayoutStateForViewModel:(id)viewModel layoutMetrics:(id)layoutMetrics width:(CGFloat)width {
    if (NFBCompactMedia() && width > kCardWidth && NFBIsPreviewCard(viewModel)) {
        gCardCalls++;
        return %orig(viewModel, layoutMetrics, kCardWidth);
    }
    return %orig;
}

- (id)_t1_unifiedCardViewLayoutStateForViewModel:(id)viewModel
                                     unifiedCard:(id)unifiedCard
                                shouldHideFooter:(BOOL)shouldHideFooter
                                   layoutMetrics:(id)layoutMetrics
                                           width:(CGFloat)width {
    if (NFBCompactMedia() && width > kCardWidth) {
        gCardCalls++;
        return %orig(viewModel, unifiedCard, shouldHideFooter, layoutMetrics, kCardWidth);
    }
    return %orig;
}

// Layout states are cached per row; one made in the other mode is stale.
- (id)layoutStateForViewModel:(id)viewModel layoutMetrics:(id)layoutMetrics {
    id state = %orig;
    if (state) {
        objc_setAssociatedObject(state, kLayoutModeKey, @(NFBCompactMedia()),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (BOOL)isLayoutState:(id)state validForViewModel:(id)viewModel layoutMetrics:(id)layoutMetrics {
    NSNumber* mode = state ? objc_getAssociatedObject(state, kLayoutModeKey) : nil;
    if ((mode ? mode.boolValue : NO) != NFBCompactMedia()) {
        return NO;
    }
    return %orig;
}

%end

%hook _TtC21TweetMediaAttachments22MultiMediaCarouselView

+ (CGFloat)carouselHeightFor:(CGFloat)width
                 heightRatio:(CGFloat)heightRatio
           maxItemWidthRatio:(CGFloat)maxItemWidthRatio
              maxHeightRatio:(CGFloat)maxHeightRatio
                  mediaInfos:(id)mediaInfos {
    CGFloat height = %orig;
    gCarouselCalls++;
    return NFBCompactMedia() ? MIN(height, kThumbSide) : height;
}

+ (CGFloat)carouselHeightFor:(CGFloat)width
                 heightRatio:(CGFloat)heightRatio
           maxItemWidthRatio:(CGFloat)maxItemWidthRatio
              maxHeightRatio:(CGFloat)maxHeightRatio
            itemAspectRatios:(id)ratios {
    CGFloat height = %orig;
    gCarouselCalls++;
    return NFBCompactMedia() ? MIN(height, kThumbSide) : height;
}

%end

// MARK: Mode changes

static void NFBReloadTimelines(UIView* view) {
    if ([view isKindOfClass:[UITableView class]] && view.window) {
        [(UITableView*)view reloadData];
        return;
    }
    for (UIView* sub in view.subviews) {
        NFBReloadTimelines(sub);
    }
}

static void NFBWatchMode(void) {
    static BOOL lastMode;
    lastMode = NFBCompactMedia();
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSUserDefaultsDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
                    BOOL mode = NFBCompactMedia();
                    if (mode == lastMode) {
                        return;
                    }
                    lastMode = mode;
                    for (UIWindow* window in UIApplication.sharedApplication.windows) {
                        NFBReloadTimelines(window);
                    }
                }];
}

// Read by Hooks/DebugDump.x.
NSString* NFBCompactMediaDebugText(void) {
    return [NSString stringWithFormat:@"active=%d switch=%d nsfwMode=%d sizeCalls=%ld squares=%ld "
                                      @"strips=%ld carouselCalls=%ld cardCalls=%ld lastViewModel=%@",
                                      NFBCompactMedia(), [BHTSettings boolForKey:kCompactKey],
                                      [BHTSettings boolForKey:kSensitiveKey], (long)gSizeCalls,
                                      (long)gSquares, (long)gStrips, (long)gCarouselCalls,
                                      (long)gCardCalls, gLastViewModelClass ?: @"-"];
}

// MARK: - Leftovers of the AI blur
// Builds before 7.3.76 compiled the two NSFW models into Caches on first use
// (nfb_nsfw5.mlmodelc, nfb_anime1.mlmodelc, roughly the size of the models) and kept
// a few settings. An app update doesn't clear Caches, so remove them once, off the
// main thread, a little after launch. 7.3.78 also drops the double-tap-to-like setting.
%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        NFBWatchMode();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       NSFileManager* fm = [NSFileManager defaultManager];
                       NSURL* caches = [[fm URLsForDirectory:NSCachesDirectory
                                                   inDomains:NSUserDomainMask] firstObject];
                       for (NSString* name in @[ @"nfb_nsfw5.mlmodelc", @"nfb_anime1.mlmodelc" ]) {
                           NSURL* url = [caches URLByAppendingPathComponent:name];
                           if ([fm fileExistsAtPath:url.path]) {
                               [fm removeItemAtURL:url error:nil];
                           }
                       }
                       NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
                       for (NSString* key in @[ @"nsfw_ai_blur", @"nsfw_ai_threshold",
                                                 @"nsfw_anime_threshold", @"nfb_nsfw_blur_before",
                                                 @"kemo_double_tap_like" ]) {
                           if ([defaults objectForKey:key]) {
                               [defaults removeObjectForKey:key];
                           }
                       }
                   });
}
