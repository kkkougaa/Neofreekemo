//
//  CompactMedia.x
//  NeoFreeBird
//

#import <os/lock.h>
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

// While X lays one tweet out (see "The text beside the photo" below). Rows
// are laid out off the main thread too, so these are per thread.
static __thread BOOL tInTweet = NO;       // inside the layout of a row's own tweet
static __thread CGFloat tTextRight = 0;   // how much narrower that tweet's text is laid out
static __thread NSInteger tNested = 0;    // inside the layout of what a tweet carries (a quoted tweet, a card)
static __thread BOOL tTextMiss = NO;      // the text was to be narrower and X did not take it

static BOOL NFBCompactMedia(void) {
    return [BHTSettings boolForKey:kCompactKey] && ![BHTSettings boolForKey:kSensitiveKey];
}

// 7.3.99: 92 points was large next to a line or two of text; 56 is about three
// lines. Chosen with the slider on the media settings page.
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
// What a tweet carries (a quoted tweet with a text of its own) is laid out in
// here: that text is not the one that sits beside the photo.
- (id)layoutStateForViewModel:(id)viewModel layoutMetrics:(id)layoutMetrics {
    tNested++;
    id state = %orig;
    tNested--;
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
//  - the tweet's text, and only its text, is laid out narrower on the right by
//    the photo and a gap (see "The text beside the photo" below);
//  - X's layout for the row is read (its TFNVerticalLayout items): where the
//    photo's place is, and what sits between the name line and the photo. The
//    photo goes up beside the first of those, the row loses what that saves
//    (never more than leaves room for the photo), and both are noted on the
//    layout;
//  - after X has laid the tweet out, the photo's container moves up by what
//    was noted, to the right end of the column, and everything X had put below
//    it moves up by what the row lost.
//
// 7.3.100 put the photo after the right end of the name line, taking the name
// line to be narrower too. X only narrows the text (the dump: text 280 wide,
// name line still 344), so every photo sat past the card's edge, and it would
// have covered the time and the "..." button had it been further left. It now
// sits beside the text, under the name line.
//
// X's text view cannot wrap around a shape, so the text is narrower all the
// way down, not just beside the photo.

static const void* kCornerNoteKey = &kCornerNoteKey; // on a row's layout: {side, taken off the height}
static BOOL gPlacingCorner = NO;
static NSInteger gCornerPlaced = 0, gCornerSkipped = 0;
static NSString* gCornerLog = @"-";
// Set once the hooks that lay the text out narrower are in (see the constructor).
// Without them the photo stays under the text, at the right end.
static BOOL gTextHooked = NO;

// The side of the photo that goes beside the text for this tweet, or 0.
static CGFloat NFBCornerThumbFor(id viewModel) {
    if (!viewModel || !gTextHooked || !NFBCompactMedia() || ![BHTSettings boolForKey:kCornerKey]) {
        return 0;
    }
    return NFBMediaCount(viewModel) == 1 ? ThumbSide() : 0;
}

static CGRect ItemFrame(id item) {
    SEL selector = NSSelectorFromString(@"frame");
    return [item respondsToSelector:selector] ? ((CGRect (*)(id, SEL))objc_msgSend)(item, selector) : CGRectNull;
}

static BOOL ItemVisible(id item) {
    SEL selector = NSSelectorFromString(@"isVisible");
    return [item respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(item, selector) : NO;
}

static id ItemObject(id item, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    return [item respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(item, selector) : nil;
}

// The item of X's layout that is the small photo: visible, and a square of
// the photo's side. Layouts nest (an item can stand for a layout of its own).
static id FindThumbItem(id layout, CGFloat thumb, int depth) {
    if (depth > 4) {
        return nil;
    }
    NSArray* items = ItemObject(layout, @"items");
    if (![items isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (id item in items) {
        if (!ItemVisible(item)) {
            continue;
        }
        CGRect frame = ItemFrame(item);
        if (!CGRectIsNull(frame) && fabs(CGRectGetWidth(frame) - thumb) <= 1 && fabs(CGRectGetHeight(frame) - thumb) <= 1) {
            return item;
        }
        id inner = ItemObject(item, @"representedLayout");
        id found = inner ? FindThumbItem(inner, thumb, depth + 1) : nil;
        if (found) {
            return found;
        }
    }
    return nil;
}

// Reads X's layout of the row and takes off its height what moving the photo
// up beside the text saves. Safe to call again on a layout X hands out a
// second time. The note on the layout is {side, taken off the height, how far
// up the photo goes}.
static void NFBCornerAdjustLayout(id layout, CGFloat thumb) {
    if (!layout) {
        return;
    }
    NSValue* was = objc_getAssociatedObject(layout, kCornerNoteKey);
    CGRect old = was ? was.CGRectValue : CGRectZero;
    if (fabs(CGRectGetMinX(old) - thumb) < 0.01) {
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
    CGFloat natural = size.height + CGRectGetMinY(old);
    CGFloat saved = 0, lift = 0;
    if (thumb > 0) {
        id state = ItemObject(layout, @"statusViewLayoutState");
        id vertical = ItemObject(state, @"verticalLayout");
        SEL avatarSelector = NSSelectorFromString(@"avatarFrame");
        CGFloat nameLine = [state respondsToSelector:avatarSelector]
                               ? ((CGRect (*)(id, SEL))objc_msgSend)(state, avatarSelector).origin.y + 5
                               : 16;
        id photo = vertical ? FindThumbItem(vertical, thumb, 0) : nil;
        CGRect place = photo ? ItemFrame(photo) : CGRectNull;
        // What sits between the name line and the photo: the text, and any
        // line X adds around it (a translation note).
        CGFloat top = CGFLOAT_MAX, bottom = -CGFLOAT_MAX;
        int steps = 0;
        for (id item = ItemObject(photo, @"previousVisibleItem"); item && steps < 8;
             item = ItemObject(item, @"previousVisibleItem"), steps++) {
            CGRect frame = ItemFrame(item);
            if (CGRectIsNull(frame) || CGRectGetMinY(frame) <= nameLine) {
                break; // the name line, or what is above it
            }
            top = MIN(top, CGRectGetMinY(frame));
            bottom = MAX(bottom, CGRectGetMaxY(frame));
        }
        if (!CGRectIsNull(place) && top < CGFLOAT_MAX && top < CGRectGetMinY(place)) {
            lift = CGRectGetMinY(place) - top;
            saved = MAX(0, MIN(thumb + 16, CGRectGetMaxY(place) - MAX(bottom, top + thumb)));
        }
        gCornerLog = [NSString stringWithFormat:@"photo=%@ between=%.0f..%.0f nameLine<=%.0f lift=%.1f saved=%.1f",
                                                CGRectIsNull(place) ? @"(not found)" : NSStringFromCGRect(place),
                                                top < CGFLOAT_MAX ? top : -1, bottom > -CGFLOAT_MAX ? bottom : -1,
                                                nameLine, lift, saved];
    }
    size.height = natural - saved;
    ((void (*)(id, SEL, CGSize))objc_msgSend)(layout, setter, size);
    objc_setAssociatedObject(layout, kCornerNoteKey,
                             thumb > 0 ? [NSValue valueWithCGRect:CGRectMake(thumb, saved, lift, 0)] : nil,
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

static const void* kPlacedKey = &kPlacedKey;       // on a view we moved: the frame we gave it
static const void* kNaturalKey = &kNaturalKey;     // on the photo's container: the frame X gave it
static const void* kPlacedForKey = &kPlacedForKey; // on the tweet: the row layout its views were moved for

static BOOL StillPlaced(UIView* view) {
    NSValue* note = objc_getAssociatedObject(view, kPlacedKey);
    if (!note) {
        return NO;
    }
    CGRect given = note.CGRectValue, now = view.frame;
    return fabs(CGRectGetMinX(given) - CGRectGetMinX(now)) < 0.5 && fabs(CGRectGetMinY(given) - CGRectGetMinY(now)) < 0.5 &&
           fabs(CGRectGetWidth(given) - CGRectGetWidth(now)) < 0.5 && fabs(CGRectGetHeight(given) - CGRectGetHeight(now)) < 0.5;
}

// Called right after X has laid a tweet out.
static void NFBPlaceCornerMedia(UIView* status) {
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
    CGRect noted = note.CGRectValue;
    CGFloat thumb = CGRectGetMinX(noted), saved = CGRectGetMinY(noted), lift = CGRectGetWidth(noted);
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
    // 7.3.105: whether a view is where we put it is no longer guessed from
    // where it is (7.3.102 took a photo for "moved up already" when it sat
    // higher than expected, and then left it and everything below it down).
    // Each view we move carries the frame we gave it; one that X has laid out
    // again has another frame and is moved again. A row's new layout starts
    // afresh.
    if (objc_getAssociatedObject(status, kPlacedForKey) != layout) {
        for (UIView* view in host.subviews) {
            objc_setAssociatedObject(view, kPlacedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(status, kPlacedForKey, layout, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL placed = StillPlaced(container);
    NSValue* was = placed ? objc_getAssociatedObject(container, kNaturalKey) : nil;
    // Where X put the photo.
    CGRect old = was ? was.CGRectValue : container.frame;
    CGRect name = [author.superview convertRect:author.frame toView:host];
    // The right end of the tweet's column: where the name line ends (X leaves
    // the name line its full width). Never past the row's own edge.
    CGFloat right = MIN(CGRectGetMaxX(name), CGRectGetWidth(host.bounds));
    CGFloat x = MAX(CGRectGetMinX(old), right - CGRectGetWidth(old));
    // Up beside the text, but never onto the name line.
    CGFloat y = MAX(CGRectGetMaxY(name) + 1, CGRectGetMinY(old) - lift);
    CGRect target = CGRectMake(x, y, CGRectGetWidth(old), CGRectGetHeight(old));
    BOOL moved = NO;
    if (saved > 0.5) {
        for (UIView* view in host.subviews) {
            if (view != container && !StillPlaced(view) && CGRectGetMinY(view.frame) >= CGRectGetMaxY(old) - 0.5) {
                CGRect lower = CGRectOffset(view.frame, 0, -saved);
                view.frame = lower;
                objc_setAssociatedObject(view, kPlacedKey, [NSValue valueWithCGRect:lower], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                moved = YES;
            }
        }
    }
    if (!placed) {
        objc_setAssociatedObject(container, kNaturalKey, [NSValue valueWithCGRect:old], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gPlacingCorner = YES;
        container.frame = target;
        gPlacingCorner = NO;
        objc_setAssociatedObject(container, kPlacedKey, [NSValue valueWithCGRect:target], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        moved = YES;
    }
    if (moved) {
        gCornerPlaced++;
    }
}

// MARK: The text beside the photo
// The photo needs room at the right of the text, so the text is laid out
// narrower by the photo and a gap.
//
// 7.3.99-7.3.104 did that with the row's layout metrics (more content inset on
// the right, where X makes the row's layout). A tweet on screen works its
// layout out again by itself, from the list's metrics; X keeps the text's old
// layout while it still holds (so the text stayed narrow) and lays the rest
// out anew, which is why the name line, the "..." button and the action row
// kept their full width. But whenever X did lay the text out again it went
// back to the full width, under the photo. 7.3.105 gave the tweet's own
// layout the row's narrower metrics as well: then everything was narrower,
// the "..." button and the action row too, and the photo, which sits at the
// right end of the name line, was that far from the edge.
//
// Now the metrics of the row and of the tweet are left alone. Each part of a
// tweet is laid out by an adapter of its own, and only the text's
// (T1StandardStatusBodyViewAdapter) gets narrower metrics, wherever a row's
// tweet is laid out: in +[T1StatusCell cellLayoutForViewModel:...] (the row
// and its height), in the tweet view's own update, and in the layout state
// generator both go through. A text layout carries how much narrower it was
// made, and one made for another width is no longer valid.

static UIEdgeInsets MetricInsets(id metrics, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    return [metrics respondsToSelector:selector] ? ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(metrics, selector)
                                                 : UIEdgeInsetsZero;
}

static CGFloat MetricNumber(id metrics, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    return [metrics respondsToSelector:selector] ? ((CGFloat (*)(id, SEL))objc_msgSend)(metrics, selector) : 0;
}

// X's metrics with `right` more room at the right of the content, or nil
// when X does not take it. The last answer is kept: rows are laid out in
// runs, and a copy of the metrics per tweet is slow.
static os_unfair_lock gNarrowLock = OS_UNFAIR_LOCK_INIT;
static id gNarrowSource = nil, gNarrowResult = nil;
static CGFloat gNarrowRight = -1;

static id NarrowedMetrics(id metrics, CGFloat right) {
    if (!metrics || right <= 0) {
        return nil;
    }
    id result = nil;
    os_unfair_lock_lock(&gNarrowLock);
    if (gNarrowResult && fabs(gNarrowRight - right) < 0.01 &&
        (gNarrowSource == metrics || [gNarrowSource isEqual:metrics])) {
        result = gNarrowResult;
    }
    os_unfair_lock_unlock(&gNarrowLock);
    if (result) {
        return result;
    }
    SEL selector = NSSelectorFromString(@"layoutMetricsWithContentEdgeInsets:");
    if (![metrics respondsToSelector:selector]) {
        return nil;
    }
    CGFloat before = MetricNumber(metrics, @"contentWidth");
    UIEdgeInsets content = MetricInsets(metrics, @"contentEdgeInsets");
    content.right += right;
    result = ((id (*)(id, SEL, UIEdgeInsets))objc_msgSend)(metrics, selector, content);
    if (!result || MetricNumber(result, @"contentWidth") > before - right / 2) {
        return nil;
    }
    os_unfair_lock_lock(&gNarrowLock);
    gNarrowSource = metrics;
    gNarrowResult = result;
    gNarrowRight = right;
    os_unfair_lock_unlock(&gNarrowLock);
    return result;
}

static const void* kTextRightKey = &kTextRightKey; // on a text layout: how much narrower it was made
static Class gGeneratorClass = Nil, gStatusViewClass = Nil;
static BOOL gRowHooked = NO, gStateHooked = NO;
static NSInteger gTweetLayouts = 0, gStateUpdates = 0, gTextNarrowed = 0, gTextMisses = 0, gTextStale = 0;
static NSInteger gAvatarShrinksKept = 0;

// What the text of this tweet is narrower by, for the time X lays the tweet
// out. `was` keeps what was set before (layouts can nest).
typedef struct {
    BOOL inTweet;
    CGFloat right;
} NFBTextScope;

static NFBTextScope EnterTweet(id viewModel) {
    NFBTextScope was = {tInTweet, tTextRight};
    CGFloat thumb = NFBCornerThumbFor(viewModel);
    tInTweet = YES;
    tTextRight = thumb > 0 ? thumb + kCornerGap : 0;
    return was;
}

static void LeaveTweet(NFBTextScope was) {
    tInTweet = was.inTweet;
    tTextRight = was.right;
}

%group CornerText

// Only a row's own tweet: quoted tweets, the tweet a conversation is about and
// tweets in messages have generators of their own.
%hook T1StandardStatusViewLayoutStateGenerator

- (id)layoutStateForViewModel:(id)viewModel
                      options:(NSUInteger)options
                      account:(id)account
                layoutMetrics:(id)layoutMetrics
      withPreviousLayoutState:(id)previousLayoutState {
    if (tNested > 0 || object_getClass(self) != gGeneratorClass) {
        return %orig;
    }
    gTweetLayouts++;
    NFBTextScope was = EnterTweet(viewModel);
    id state = %orig;
    LeaveTweet(was);
    return state;
}

%end

%hook T1StandardStatusBodyViewAdapter

- (id)layoutStateForViewModel:(id)viewModel layoutMetrics:(id)layoutMetrics {
    CGFloat right = (tInTweet && tNested == 0) ? tTextRight : 0;
    id narrowed = right > 0 ? NarrowedMetrics(layoutMetrics, right) : nil;
    if (right > 0 && !narrowed) {
        tTextMiss = YES;
        gTextMisses++;
    }
    id state = narrowed ? %orig(viewModel, narrowed) : %orig;
    if (state) {
        if (narrowed) {
            gTextNarrowed++;
            objc_setAssociatedObject(state, kTextRightKey, @(right), OBJC_ASSOCIATION_RETAIN);
        } else if (objc_getAssociatedObject(state, kTextRightKey)) {
            objc_setAssociatedObject(state, kTextRightKey, nil, OBJC_ASSOCIATION_RETAIN);
        }
    }
    return state;
}

// X asks this before it keeps a text layout it already has. Inside a row's
// tweet the layout must have been made for the width wanted now; anywhere
// else it is checked against the metrics it was made with.
- (BOOL)isLayoutState:(id)state validForViewModel:(id)viewModel layoutMetrics:(id)layoutMetrics {
    NSNumber* stamp = state ? objc_getAssociatedObject(state, kTextRightKey) : nil;
    CGFloat made = stamp ? stamp.doubleValue : 0;
    if (tInTweet && tNested == 0 && fabs(made - tTextRight) > 0.01) {
        gTextStale++;
        return NO;
    }
    id narrowed = made > 0 ? NarrowedMetrics(layoutMetrics, made) : nil;
    return narrowed ? %orig(state, viewModel, narrowed) : %orig;
}

%end

%end

// The row: its layout (and height) is made here, with the tweet's inside it.
%group CornerRow

%hook T1StatusCell

+ (id)cellLayoutForViewModel:(id)viewModel
                     options:(NSUInteger)options
                     account:(id)account
               layoutMetrics:(id)layoutMetrics
          withPreviousLayout:(id)previousLayout {
    CGFloat thumb = NFBCornerThumbFor(viewModel);
    BOOL missBefore = tTextMiss;
    tTextMiss = NO;
    NFBTextScope was = EnterTweet(viewModel);
    id layout = %orig;
    LeaveTweet(was);
    BOOL miss = tTextMiss;
    tTextMiss = missBefore;
    // The photo only goes up beside the text when the text made room for it.
    NFBCornerAdjustLayout(layout, miss ? 0 : thumb);
    return layout;
}

%end

%end

// A tweet on screen working its layout out again (a like count changed).
%group CornerState

%hook T1StandardStatusView

- (id)_t1_updateLayoutStateWithLayoutMetrics:(id)metrics {
    if (object_getClass(self) != gStatusViewClass) {
        return %orig;
    }
    gStateUpdates++;
    SEL modelSelector = NSSelectorFromString(@"viewModel");
    id viewModel = [(id)self respondsToSelector:modelSelector] ? ((id (*)(id, SEL))objc_msgSend)(self, modelSelector) : nil;
    NFBTextScope was = EnterTweet(viewModel);
    id state = %orig;
    LeaveTweet(was);
    return state;
}

%end

%end

// After X has laid a tweet out, its photo goes up beside the text. Quoted
// tweets and other kinds of tweet view keep X's layout.
%hook T1StandardStatusView

- (void)layoutSubviews {
    %orig;
    if (gStatusViewClass && object_getClass(self) == gStatusViewClass) {
        NFBPlaceCornerMedia((UIView*)self);
    }
}

%end

// X shrinks a tweet's avatar so a wide strip of photos can pass under it.
// With small media the strip is short and never reaches the avatar, so the
// avatar keeps its size.
%hook T1TappableStatusFleetLineItemView

- (void)setTransform:(CGAffineTransform)transform {
    if (!CGAffineTransformIsIdentity(transform) && NFBCompactMedia()) {
        gAvatarShrinksKept++;
        return;
    }
    %orig;
}

%end

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
    if ([view isKindOfClass:[UITableView class]]) {
        // X's lists are subclasses (TFNTableView). A plain table is one of
        // our settings pages: reloading it would take the slider out from
        // under the finger that is moving it.
        if (view.class != [UITableView class]) {
            [(UITableView*)view reloadData];
        }
        return;
    }
    for (UIView* sub in view.subviews) {
        NFBReloadTimelines(sub);
    }
}

// The lists that are not on screen: the photo's size is chosen on a settings
// page, with the timeline under it, out of the window. They measure their
// rows again too, so the timeline is right when the reader goes back.
static void NFBReloadHidden(UIViewController* controller, int depth) {
    if (!controller || depth > 12) {
        return;
    }
    UIView* view = controller.viewIfLoaded;
    if (view && !view.window) {
        NFBReloadTimelines(view);
    }
    for (UIViewController* child in controller.childViewControllers) {
        NFBReloadHidden(child, depth + 1);
    }
    NFBReloadHidden(controller.presentedViewController, depth + 1);
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
                    // A slider on the settings page changes the mode many
                    // times a second: the lists are told once it has settled.
                    static BOOL waiting = NO;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (waiting) {
                            return;
                        }
                        waiting = YES;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                                           waiting = NO;
                                           NSInteger mode = NFBMediaMode();
                                           if (mode == lastMode) {
                                               return;
                                           }
                                           lastMode = mode;
                                           for (UIWindow* window in UIApplication.sharedApplication.windows) {
                                               NFBReloadTimelines(window);
                                               NFBReloadHidden(window.rootViewController, 0);
                                           }
                                       });
                    });
                }];
}

// Read by Hooks/DebugDump.x.
NSString* NFBCompactMediaDebugText(void) {
    return [NSString stringWithFormat:@"active=%d switch=%d nsfwMode=%d sizeCalls=%ld squares=%ld "
                                      @"strips=%ld carouselCalls=%ld cardCalls=%ld adaptiveOff=%ld vertical=%ld "
                                      @"verticalVideo=%ld(hook=%d) rightContainers=%ld rightInner=%ld (%@) side=%.0f corner=%d "
                                      @"cornerPlaced=%ld cornerSkipped=%ld (%@) lastViewModel=%@\n"
                                      @"text: hooks=%d%d%d tweetLayouts=%ld stateUpdates=%ld narrowed=%ld misses=%ld stale=%ld "
                                      @"avatarShrinksKept=%ld",
                                      NFBCompactMedia(), [BHTSettings boolForKey:kCompactKey],
                                      [BHTSettings boolForKey:kSensitiveKey], (long)gSizeCalls,
                                      (long)gSquares, (long)gStrips, (long)gCarouselCalls,
                                      (long)gCardCalls, (long)gAdaptiveOff, (long)gVertical, (long)gVerticalVideos,
                                      gVerticalVideoHooked, (long)gRightContainers, (long)gRightAligned, gRightLog,
                                      ThumbSide(), [BHTSettings boolForKey:kCornerKey], (long)gCornerPlaced,
                                      (long)gCornerSkipped, gCornerLog, gLastViewModelClass ?: @"-", gTextHooked,
                                      gRowHooked, gStateHooked, (long)gTweetLayouts, (long)gStateUpdates,
                                      (long)gTextNarrowed, (long)gTextMisses, (long)gTextStale, (long)gAvatarShrinksKept];
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
    // One photo beside the text. The methods were read from X 12.44's class
    // list; each hook only goes in where its method exists. Without the first
    // two the text cannot be made narrower, and the photo stays under it.
    Class generator = objc_getClass("T1StandardStatusViewLayoutStateGenerator");
    Class body = objc_getClass("T1StandardStatusBodyViewAdapter");
    Class statusCell = objc_getClass("T1StatusCell");
    Class statusView = objc_getClass("T1StandardStatusView");
    gGeneratorClass = generator;
    gStatusViewClass = statusView;
    if (generator && body && statusCell &&
        class_getInstanceMethod(generator, NSSelectorFromString(@"layoutStateForViewModel:options:account:layoutMetrics:withPreviousLayoutState:")) &&
        class_getInstanceMethod(body, NSSelectorFromString(@"layoutStateForViewModel:layoutMetrics:")) &&
        class_getInstanceMethod(body, NSSelectorFromString(@"isLayoutState:validForViewModel:layoutMetrics:")) &&
        class_getClassMethod(statusCell, NSSelectorFromString(@"cellLayoutForViewModel:options:account:layoutMetrics:withPreviousLayout:"))) {
        %init(CornerText);
        %init(CornerRow);
        gTextHooked = YES;
        gRowHooked = YES;
        if (statusView && class_getInstanceMethod(statusView, NSSelectorFromString(@"_t1_updateLayoutStateWithLayoutMetrics:"))) {
            %init(CornerState);
            gStateHooked = YES;
        }
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
                       // 7.3.106: and the settings of the cards (7.3.86-7.3.105).
                       for (NSString* key in @[ @"nsfw_ai_blur", @"nsfw_ai_threshold",
                                                 @"nsfw_anime_threshold", @"nfb_nsfw_blur_before",
                                                 @"kemo_double_tap_like", @"kemo_timeline_cards",
                                                 @"kemo_notification_cards", @"kemo_card_look", @"kemo_card_radius",
                                                 @"kemo_card_gap", @"kemo_card_inner", @"kemo_card_inner_v",
                                                 @"kemo_card_page", @"kemo_card_body", @"kemo_card_name",
                                                 @"kemo_card_avatar", @"kemo_card_name_gap", @"kemo_card_paper",
                                                 @"kemo_card_paper_rgb", @"kemo_thread_indent_measured" ]) {
                           if ([defaults objectForKey:key]) {
                               [defaults removeObjectForKey:key];
                           }
                       }
                   });
}
