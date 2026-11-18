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
static NSString* const kThumbKey = @"kemo_thumb_side";     // the small square's side, 32-92
static NSString* const kCornerKey = @"kemo_corner_media";  // one photo sits beside the text
static const CGFloat kCornerGap = 8.0;
static const CGFloat kCardWidth = 190.0;

static const void* kLayoutModeKey = &kLayoutModeKey;

// Probe for the debug dump: how often each path ran, and the last view model class.
static NSInteger gSizeCalls = 0, gSquares = 0, gStrips = 0, gCarouselCalls = 0, gCardCalls = 0, gAdaptiveOff = 0, gVertical = 0, gRightAligned = 0;
static NSInteger gVerticalVideos = 0;
static BOOL gVerticalVideoHooked = NO;
static NSString* gLastViewModelClass = nil;
// Where X lays a row out, for working out how to put the media beside the text.
// Class pointers, not strings: these are set while rows are laid out, which can be
// off the main thread, and a Class needs no retain.
static Class gLayoutStateClass = Nil;
static Class gLayoutMetricsClass = Nil;
static CGFloat gLastMediaWidth = 0;

static BOOL NFBCompactMedia(void) {
    return [BHTSettings boolForKey:kCompactKey] && ![BHTSettings boolForKey:kSensitiveKey];
}

// 7.3.99: 92 points was large next to a line or two of text; 56 is about three
// lines. Chosen on the "Cards and text" page.
static CGFloat ThumbSide(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kThumbKey];
    CGFloat side = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 56;
    return MAX(32, MIN(92, side));
}

// What X's cached layouts were made for: off, or the side and whether one
// photo goes beside the text. Any change makes the old layouts stale.
static NSInteger NFBMediaMode(void) {
    if (!NFBCompactMedia()) {
        return 0;
    }
    return (NSInteger)ThumbSide() * 2 + ([BHTSettings boolForKey:kCornerKey] ? 1 : 0);
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

// Tall single photos (7.3.90 dump: 328 x 438 while every size call returned a
// square) go through X's "adaptive" media layout, which sizes them on its own
// and never asks the size method below. With small media on, that layout is
// turned off so every photo takes the size path that is shrunk.
- (BOOL)_t1_useAdaptiveMediaLayoutForAttachmentType:(NSUInteger)attachmentType {
    BOOL adaptive = %orig;
    if (adaptive && NFBCompactMedia()) {
        gAdaptiveOff++;
        return NO;
    }
    return adaptive;
}

- (CGSize)_t1_photoVideoForwardViewSizeForViewModel:(id)viewModel
                                      layoutMetrics:(id)layoutMetrics
                                              width:(CGFloat)width
                                     attachmentType:(NSUInteger)attachmentType {
    CGSize size = %orig;
    gSizeCalls++;
    gLastViewModelClass = NSStringFromClass([viewModel class]);
    if (layoutMetrics) {
        gLayoutMetricsClass = [layoutMetrics class];
    }
    gLastMediaWidth = width;
    if (!NFBCompactMedia() || size.width <= 0 || size.height <= 0) {
        return size;
    }
    if (NFBMediaCount(viewModel) > 1) {
        gStrips++;
        return CGSizeMake(size.width, MIN(size.height, ThumbSide()));
    }
    gSquares++;
    CGFloat side = MIN(ThumbSide(), MIN(size.width, width));
    return CGSizeMake(side, side);
}

// Tall single photos (7.3.94: still 328 x 438 with the adaptive layout off) take
// their size from this, after the size method above has run.
- (CGSize)_t1_verticalPhotoSizeForAspectRatio:(CGFloat)ratio width:(CGFloat)width {
    CGSize size = %orig;
    if (!NFBCompactMedia() || size.width <= 0 || size.height <= 0) {
        return size;
    }
    gVertical++;
    CGFloat side = MIN(ThumbSide(), MIN(size.width, width));
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
        gLayoutStateClass = [state class];
        objc_setAssociatedObject(state, kLayoutModeKey, @(NFBMediaMode()),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (BOOL)isLayoutState:(id)state validForViewModel:(id)viewModel layoutMetrics:(id)layoutMetrics {
    NSNumber* mode = state ? objc_getAssociatedObject(state, kLayoutModeKey) : nil;
    if ((mode ? mode.integerValue : 0) != NFBMediaMode()) {
        return NO;
    }
    return %orig;
}

%end

// Tall single videos take their size from a method of their own (7.3.96
// dump: a video row 687 high while every size call above returned a square).
// Read from X's class list, not seen in a dump of this version, so it is only
// hooked where it exists (see the constructor).
%group VerticalVideo

%hook T1StandardStatusAttachmentViewAdapter

- (CGSize)_t1_verticalVideoViewSizeForViewModel:(id)viewModel width:(CGFloat)width anatomyFeatures:(id)anatomyFeatures {
    CGSize size = %orig;
    if (!NFBCompactMedia() || size.width <= 0 || size.height <= 0) {
        return size;
    }
    gVerticalVideos++;
    CGFloat side = MIN(ThumbSide(), MIN(size.width, width));
    return CGSizeMake(side, side);
}

%end

%end

// 7.3.100: X 12.44 does not have the method above (the build's own class
    // list says so: the hook was never installed, and tall videos stayed large).
    // There, +isVerticalVideoLayoutForViewModel:displayType: decides whether a
    // video takes X's tall layout, and a second switch lets it fill the width.
    // With small media both say no, and the video takes the size path that is
    // already made small.
%group VerticalVideoLayout

%hook T1StandardStatusAttachmentViewAdapter

+ (BOOL)isVerticalVideoLayoutForViewModel:(id)viewModel displayType:(NSUInteger)displayType {
    if (NFBCompactMedia()) {
        gVerticalVideos++;
        return NO;
    }
    return %orig;
}

+ (BOOL)_t1_isVerticalVideoFillWidthEligibleForViewModel:(id)viewModel displayType:(NSUInteger)displayType {
    return NFBCompactMedia() ? NO : %orig;
}

%end

%end

// A single small photo sits at the right end of the tweet's text column
// instead of the left.
//
// 7.3.95 moved the photo view inside its container, 7.3.96 the first small
// square found below the container: neither moved a single photo (the dump
// only ever showed one hit, a picture inside a carousel). X sizes the
// attachment container itself to the media, so there is nothing narrower
// inside it to move; the container is what has to move. Its frame is set by
// the tweet's layout, so the x is changed right where the frame is set: the
// container never sits at the left first.
@interface T1StatusViewAttachmentContainerView : UIView
@property (readonly, nonatomic) UIView* photoVideoView;
@property (readonly, nonatomic) UIView* attachmentView;
@end

static NSString* gRightLog = @"-";
static NSInteger gRightContainers = 0;

static BOOL NFBIsThumb(CGSize size) {
    return size.width >= 30 && size.width <= ThumbSide() + 1 && fabs(size.width - size.height) <= 1.5;
}

// The right edge of the tweet's text column, in `host` coordinates: the right
// end of the name line of the tweet the container belongs to. 0 if unknown.
static CGFloat NFBColumnRight(UIView* host) {
    SEL authorSelector = NSSelectorFromString(@"visibleAuthorView");
    int depth = 0;
    for (UIView* up = host; up && depth < 4; up = up.superview, depth++) {
        if ([NSStringFromClass(up.class) containsString:@"Quoted"]) {
            return 0;
        }
        if (![up respondsToSelector:authorSelector]) {
            continue;
        }
        UIView* author = ((id (*)(id, SEL))objc_msgSend)(up, authorSelector);
        if (!author || CGRectGetWidth(author.bounds) < 60 || !author.superview) {
            return 0;
        }
        CGRect frame = [author.superview convertRect:author.frame toView:host];
        return CGRectGetMaxX(frame);
    }
    return 0;
}

// `frame` as X wants it for the container, moved to the right end of the text
// column when it is one small photo or video.
static CGRect NFBRightAligned(T1StatusViewAttachmentContainerView* container, CGRect frame) {
    UIView* host = container.superview;
    if (!host || !NFBCompactMedia() || !NFBIsThumb(frame.size)) {
        return frame;
    }
    if ([container respondsToSelector:@selector(photoVideoView)] && !container.photoVideoView) {
        return frame; // a card, a quoted tweet, a poll
    }
    CGFloat right = NFBColumnRight(host);
    CGFloat x = right - CGRectGetWidth(frame);
    if (right <= 0 || x <= CGRectGetMinX(frame) + 0.5) {
        return frame;
    }
    gRightContainers++;
    gRightLog = [NSString stringWithFormat:@"container %@ > x %.0f (column ends %.0f) in %@", NSStringFromCGRect(frame),
                                           x, right, NSStringFromClass(host.class)];
    frame.origin.x = x;
    return frame;
}

// The small square inside a container that is wider than it: the first view,
// looking down from the container, that is square, thumbnail sized and
// narrower than its parent.
static UIView* SmallSquare(UIView* view, int depth) {
    if (depth > 4 || view.hidden) {
        return nil;
    }
    for (UIView* sub in view.subviews) {
        NSString* name = NSStringFromClass(sub.class);
        // Link previews, quoted tweets and the pictures of a carousel keep their own layout.
        if ([name containsString:@"Card"] || [name containsString:@"Quoted"] || [name containsString:@"Avatar"] ||
            [name containsString:@"Carousel"] || [sub isKindOfClass:[UIScrollView class]]) {
            continue;
        }
        CGRect frame = sub.frame;
        CGFloat w = CGRectGetWidth(frame), h = CGRectGetHeight(frame);
        if (!sub.hidden && w >= 40 && w <= ThumbSide() + 1 && fabs(w - h) <= 1.5 &&
            CGRectGetWidth(view.bounds) >= w + 8) {
            return sub;
        }
        UIView* found = SmallSquare(sub, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

// MARK: One small photo beside the text
// A single small photo sat under the text, alone on its own line, however
// short the text: most of that line was empty. With "kemo_corner_media" it
// sits at the top right, beside the name line and the first lines of text:
//
//  - where X makes the row's layout, the tweet's column is made narrower on the
//    right by the photo and a gap (Readability.x does that, with the reply
//    indent, in its hook on +[T1StatusCell cellLayoutForViewModel:...]), so the
//    name line and the text wrap before the photo;
//  - the row is made shorter by the room the photo no longer takes under the
//    text (never shorter than the photo needs), noted on the layout;
//  - after X has laid the tweet out, the photo's container is moved up into the
//    freed strip and everything X had put below it moves up by what was noted.
//
// X's text view cannot wrap around a shape, so the text is narrower all the
// way down, not just beside the photo.

static const void* kCornerNoteKey = &kCornerNoteKey; // on a row's layout: {side, taken off the height}
static BOOL gPlacingCorner = NO;
static NSInteger gCornerPlaced = 0, gCornerSkipped = 0;

// The side of the photo that goes beside the text for this tweet, or 0.
CGFloat NFBCornerThumbFor(id viewModel) {
    if (!viewModel || !NFBCompactMedia() || ![BHTSettings boolForKey:kCornerKey]) {
        return 0;
    }
    return NFBMediaCount(viewModel) == 1 ? ThumbSide() : 0;
}

CGFloat NFBCornerGap(void) {
    return kCornerGap;
}

// Takes the photo's old place under the text off the row's height. Safe to
// call again on a layout X hands out a second time.
void NFBCornerAdjustLayout(id layout, CGFloat thumb) {
    if (!layout) {
        return;
    }
    NSValue* was = objc_getAssociatedObject(layout, kCornerNoteKey);
    CGPoint old = was ? was.CGPointValue : CGPointZero;
    if (fabs(old.x - thumb) < 0.01) {
        return;
    }
    SEL getter = NSSelectorFromString(@"size"), setter = NSSelectorFromString(@"setSize:");
    if (![layout respondsToSelector:getter] || ![layout respondsToSelector:setter]) {
        return;
    }
    CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(layout, getter);
    if (size.height <= 0) {
        return;
    }
    CGFloat natural = size.height + old.y;
    CGFloat reduction = thumb > 0 ? MAX(0, MIN(thumb, natural - (thumb + 26))) : 0;
    size.height = natural - reduction;
    ((void (*)(id, SEL, CGSize))objc_msgSend)(layout, setter, size);
    objc_setAssociatedObject(layout, kCornerNoteKey,
                             thumb > 0 ? [NSValue valueWithCGPoint:CGPointMake(thumb, reduction)] : nil,
                             OBJC_ASSOCIATION_RETAIN);
}

static BOOL NFBIsThumb(CGSize size);

static UIView* ThumbContainer(UIView* view, int depth) {
    Class containerClass = NSClassFromString(@"T1StatusViewAttachmentContainerView");
    if (depth > 2 || !containerClass) {
        return nil;
    }
    for (UIView* sub in view.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"Quoted"]) {
            continue;
        }
        if ([sub isKindOfClass:containerClass] && !sub.hidden && NFBIsThumb(sub.frame.size)) {
            return sub;
        }
        UIView* found = ThumbContainer(sub, depth + 1);
        if (found) {
            return found;
        }
    }
    return nil;
}

// Called by Readability.x right after X has laid a tweet out.
void NFBPlaceCornerMedia(UIView* status) {
    UITableViewCell* cell = nil;
    int depth = 0;
    for (UIView* up = status.superview; up && depth < 8; up = up.superview, depth++) {
        if ([up isKindOfClass:[UITableViewCell class]]) {
            cell = (UITableViewCell*)up;
            break;
        }
    }
    SEL layoutSelector = NSSelectorFromString(@"cellLayout");
    if (!cell || ![cell respondsToSelector:layoutSelector]) {
        return;
    }
    id layout = ((id (*)(id, SEL))objc_msgSend)(cell, layoutSelector);
    NSValue* note = layout ? objc_getAssociatedObject(layout, kCornerNoteKey) : nil;
    if (!note) {
        return;
    }
    CGFloat thumb = note.CGPointValue.x, reduction = note.CGPointValue.y;
    SEL sizeSelector = NSSelectorFromString(@"size");
    CGFloat layoutHeight = [layout respondsToSelector:sizeSelector]
                               ? ((CGSize (*)(id, SEL))objc_msgSend)(layout, sizeSelector).height
                               : 0;
    // Only when the row really is as tall as its layout says.
    if (thumb <= 0 || fabs(CGRectGetHeight(cell.bounds) - layoutHeight) > 2) {
        gCornerSkipped++;
        return;
    }
    UIView* container = ThumbContainer(status, 0);
    SEL authorSelector = NSSelectorFromString(@"visibleAuthorView");
    UIView* author = [status respondsToSelector:authorSelector] ? ((id (*)(id, SEL))objc_msgSend)(status, authorSelector) : nil;
    UIView* host = container.superview;
    if (!container || !host || !author.superview) {
        gCornerSkipped++;
        return;
    }
    CGRect name = [author.superview convertRect:author.frame toView:host];
    CGRect old = container.frame;
    CGRect target = CGRectMake(CGRectGetMaxX(name) + kCornerGap, CGRectGetMinY(name), CGRectGetWidth(old),
                               CGRectGetHeight(old));
    if (fabs(CGRectGetMinX(old) - CGRectGetMinX(target)) < 0.5 && fabs(CGRectGetMinY(old) - CGRectGetMinY(target)) < 0.5) {
        return; // already there, and what was below it already moved
    }
    if (CGRectGetMinY(old) <= CGRectGetMaxY(name)) {
        gCornerSkipped++;
        return; // not where X puts media (under the text)
    }
    for (UIView* view in host.subviews) {
        if (view != container && CGRectGetMinY(view.frame) >= CGRectGetMaxY(old) - 0.5) {
            view.frame = CGRectOffset(view.frame, 0, -reduction);
        }
    }
    gPlacingCorner = YES;
    container.frame = target;
    gPlacingCorner = NO;
    gCornerPlaced++;
}

%hook T1StatusViewAttachmentContainerView

- (void)setFrame:(CGRect)frame {
    if (gPlacingCorner) {
        %orig; // our own move beside the text
        return;
    }
    %orig(NFBRightAligned((T1StatusViewAttachmentContainerView*)self, frame));
}

- (void)layoutSubviews {
    %orig;
    if (!NFBCompactMedia()) {
        return;
    }
    T1StatusViewAttachmentContainerView* container = (T1StatusViewAttachmentContainerView*)self;
    // Placed by its centre, or before it had a parent: once more.
    CGRect frame = container.frame;
    CGRect aligned = NFBRightAligned(container, frame);
    if (fabs(CGRectGetMinX(aligned) - CGRectGetMinX(frame)) > 0.5) {
        container.frame = aligned;
        return;
    }
    if (NFBIsThumb(frame.size)) {
        return;
    }
    // A container as wide as the column with the square inside it: every
    // view from the square up to the container goes to the right edge of its
    // parent, so the square ends up at the container's right edge.
    UIView* square = SmallSquare(container, 0);
    if (!square) {
        return;
    }
    for (UIView* view = square; view && view != container; view = view.superview) {
        CGRect inner = view.frame;
        CGFloat x = CGRectGetWidth(view.superview.bounds) - CGRectGetWidth(inner);
        if (x > 0.5 && fabs(CGRectGetMinX(inner) - x) > 0.5 && CGRectGetWidth(inner) <= ThumbSide() + 1) {
            inner.origin.x = x;
            view.frame = inner;
            gRightAligned++;
        }
    }
    gRightLog = [NSString stringWithFormat:@"%@ in %@ (%.0f wide)", NSStringFromClass(square.class),
                                           NSStringFromClass(square.superview.class),
                                           CGRectGetWidth(square.superview.bounds)];
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
    return NFBCompactMedia() ? MIN(height, ThumbSide()) : height;
}

+ (CGFloat)carouselHeightFor:(CGFloat)width
                 heightRatio:(CGFloat)heightRatio
           maxItemWidthRatio:(CGFloat)maxItemWidthRatio
              maxHeightRatio:(CGFloat)maxHeightRatio
            itemAspectRatios:(id)ratios {
    CGFloat height = %orig;
    gCarouselCalls++;
    return NFBCompactMedia() ? MIN(height, ThumbSide()) : height;
}

%end

// MARK: The content warning on a small photo
// X's cover over sensitive media (HFSensitiveTweetBlurredInterstitialView) has
// an eye icon, a title, an explanation and a "View" button, laid out for a
// full-width photo. On a small square the two texts ran into the icon and the
// button. There they are left out: the icon sits above, the button below.
// A cover on media of normal size is left as X draws it.
@interface HFSensitiveTweetBlurredInterstitialView : UIView
@end

static const void* kCoverHiddenKey = &kCoverHiddenKey;

static void CollectCover(UIView* view, int depth, NSMutableArray<UILabel*>* labels, UIImageView* __strong* icon,
                         UIControl* __strong* button) {
    if (depth > 5) {
        return;
    }
    for (UIView* sub in view.subviews) {
        if ([sub isKindOfClass:[UIControl class]]) {
            if (!*button) {
                *button = (UIControl*)sub; // its own title is not one of the texts
            }
            continue;
        }
        if ([sub isKindOfClass:[UILabel class]]) {
            [labels addObject:(UILabel*)sub];
            continue;
        }
        if ([sub isKindOfClass:[UIImageView class]] && !*icon && ((UIImageView*)sub).image &&
            CGRectGetWidth(sub.bounds) > 0 && CGRectGetWidth(sub.bounds) <= 48) {
            *icon = (UIImageView*)sub;
        }
        CollectCover(sub, depth + 1, labels, icon, button);
    }
}

static void TidyCover(UIView* cover) {
    CGRect bounds = cover.bounds;
    BOOL small = NFBCompactMedia() && CGRectGetWidth(bounds) > 0 && CGRectGetWidth(bounds) <= 130 &&
                 CGRectGetHeight(bounds) <= 130;
    NSMutableArray<UILabel*>* labels = [NSMutableArray array];
    UIImageView* icon = nil;
    UIControl* button = nil;
    CollectCover(cover, 0, labels, &icon, &button);
    for (UILabel* label in labels) {
        BOOL ours = objc_getAssociatedObject(label, kCoverHiddenKey) != nil;
        if (small && !label.hidden) {
            label.hidden = YES;
            objc_setAssociatedObject(label, kCoverHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (!small && ours) {
            label.hidden = NO;
            objc_setAssociatedObject(label, kCoverHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (!small) {
        return;
    }
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    if (icon.superview) {
        icon.center = [cover convertPoint:CGPointMake(width / 2, height * (button ? 0.30 : 0.5)) toView:icon.superview];
    }
    if (button.superview) {
        CGFloat buttonHeight = MIN(28, MAX(20, height * 0.36));
        button.bounds = CGRectMake(0, 0, MAX(24, width - 12), buttonHeight);
        button.center = [cover convertPoint:CGPointMake(width / 2, height * (icon ? 0.72 : 0.5)) toView:button.superview];
    }
}

%group SensitiveCover

%hook HFSensitiveTweetBlurredInterstitialView

- (void)layoutSubviews {
    %orig;
    TidyCover((UIView*)self);
}

%end

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
    static NSInteger lastMode;
    lastMode = NFBMediaMode();
    // No queue here: with the main queue, a background thread that changes a default
    // waits for the main thread to run this block, and X writes defaults from
    // background threads during launch while the main thread waits on them (7.3.79
    // hung on the splash screen). Check on the posting thread, hop over only on a change.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSUserDefaultsDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* note) {
                    if (NFBMediaMode() == lastMode) {
                        return;
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSInteger mode = NFBMediaMode();
                        if (mode == lastMode) {
                            return;
                        }
                        lastMode = mode;
                        for (UIWindow* window in UIApplication.sharedApplication.windows) {
                            NFBReloadTimelines(window);
                        }
                    });
                }];
}

// Read by Hooks/DebugDump.x.
NSString* NFBCompactMediaDebugText(void) {
    return [NSString stringWithFormat:@"active=%d switch=%d nsfwMode=%d sizeCalls=%ld squares=%ld "
                                      @"strips=%ld carouselCalls=%ld cardCalls=%ld adaptiveOff=%ld vertical=%ld "
                                      @"verticalVideo=%ld(hook=%d) rightContainers=%ld rightInner=%ld (%@) side=%.0f corner=%d "
                                      @"cornerPlaced=%ld cornerSkipped=%ld lastViewModel=%@",
                                      NFBCompactMedia(), [BHTSettings boolForKey:kCompactKey],
                                      [BHTSettings boolForKey:kSensitiveKey], (long)gSizeCalls,
                                      (long)gSquares, (long)gStrips, (long)gCarouselCalls,
                                      (long)gCardCalls, (long)gAdaptiveOff, (long)gVertical, (long)gVerticalVideos,
                                      gVerticalVideoHooked, (long)gRightContainers, (long)gRightAligned, gRightLog,
                                      ThumbSide(), [BHTSettings boolForKey:kCornerKey], (long)gCornerPlaced,
                                      (long)gCornerSkipped, gLastViewModelClass ?: @"-"];
}

// Classes the shake dump describes, to find where the text column's width is set.
NSArray<NSString*>* NFBRowLayoutClasses(void) {
    NSMutableArray* names = [NSMutableArray array];
    Class state = gLayoutStateClass, metrics = gLayoutMetricsClass;
    if (state) {
        [names addObject:NSStringFromClass(state)];
    }
    if (metrics) {
        [names addObject:NSStringFromClass(metrics)];
    }
    return names;
}

CGFloat NFBLastMediaWidth(void) {
    return gLastMediaWidth;
}

// MARK: - Leftovers of the AI blur
// Builds before 7.3.76 compiled the two NSFW models into Caches on first use
// (nfb_nsfw5.mlmodelc, nfb_anime1.mlmodelc, roughly the size of the models) and kept
// a few settings. An app update doesn't clear Caches, so remove them once, off the
// main thread, a little after launch. 7.3.78 also drops the double-tap-to-like setting.
%ctor {
    %init;
    Class adapter = objc_getClass("T1StandardStatusAttachmentViewAdapter");
    if (adapter &&
        class_getInstanceMethod(adapter, NSSelectorFromString(@"_t1_verticalVideoViewSizeForViewModel:width:anatomyFeatures:"))) {
        %init(VerticalVideo);
        gVerticalVideoHooked = YES;
    }
    if (adapter &&
        class_getClassMethod(adapter, NSSelectorFromString(@"isVerticalVideoLayoutForViewModel:displayType:")) &&
        class_getClassMethod(adapter, NSSelectorFromString(@"_t1_isVerticalVideoFillWidthEligibleForViewModel:displayType:"))) {
        %init(VerticalVideoLayout);
        gVerticalVideoHooked = YES;
    }
    if (objc_getClass("HFSensitiveTweetBlurredInterstitialView")) {
        %init(SensitiveCover);
    }
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
