//
//  CompactMedia.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Small media thumbnails in timeline tweets
// With "kemo_compact_media" on, a tweet's photos and videos are laid out as one small
// square at the right end of the tweet instead of the full-width media block. Tapping
// it still opens X's own viewer. This replaces the on-device AI blur (removed in 7.3.76).
//
// X sizes the media block in -[T1StandardStatusAttachmentViewAdapter
// _t1_photoVideoForwardViewSizeForViewModel:layoutMetrics:width:attachmentType:], and
// the row height is computed from that layout state, so returning a small size there
// shrinks the row as well; nothing is covered and no blank space is left. The carousel
// path sizes itself separately, so it is turned off while this is on (several pictures
// then show as X's own small grid inside the square).
//
// The block is laid out from the left edge of the text column; once the status view
// has laid out, the block is moved to the right end of that column.

@interface T1StatusPhotoVideoForwardView : UIView
@end

static NSString* const kCompactKey = @"kemo_compact_media";
static const CGFloat kThumbSide = 92.0;

static const void* kLayoutModeKey = &kLayoutModeKey;

static BOOL NFBCompactMedia(void) {
    return [BHTSettings boolForKey:kCompactKey];
}

%hook T1StandardStatusAttachmentViewAdapter

- (CGSize)_t1_photoVideoForwardViewSizeForViewModel:(id)viewModel
                                      layoutMetrics:(id)layoutMetrics
                                              width:(CGFloat)width
                                     attachmentType:(NSUInteger)attachmentType {
    CGSize size = %orig;
    if (!NFBCompactMedia() || size.width <= 0 || size.height <= 0) {
        return size;
    }
    CGFloat side = MIN(kThumbSide, MIN(size.width, width));
    return CGSizeMake(side, side);
}

- (BOOL)_t1_shouldUseCarouselForViewModel:(id)viewModel anatomyFeatures:(id)features {
    return NFBCompactMedia() ? NO : %orig;
}

- (BOOL)_t1_usesCarouselForAttachmentType:(NSUInteger)type viewModel:(id)viewModel {
    return NFBCompactMedia() ? NO : %orig;
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
    if (mode && mode.boolValue != NFBCompactMedia()) {
        return NO;
    }
    return %orig;
}

%end

// The right end of the text column, in the status view's coordinates.
static CGFloat NFBTextColumnMaxX(UIView* statusView) {
    static Class bodyClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bodyClass = NSClassFromString(@"T1StatusBodyTextView");
    });
    __block CGFloat maxX = 0;
    if (bodyClass) {
        EnumerateSubviewsRecursively(statusView, ^(UIView* view) {
            if (maxX == 0 && [view isKindOfClass:bodyClass] && !view.hidden &&
                CGRectGetWidth(view.bounds) > 0) {
                maxX = CGRectGetMaxX([view convertRect:view.bounds toView:statusView]);
            }
        });
    }
    return maxX > 0 ? maxX : CGRectGetWidth(statusView.bounds) - 16;
}

static void NFBAlignThumbnail(UIView* statusView) {
    static Class mediaClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mediaClass = NSClassFromString(@"T1StatusPhotoVideoForwardView");
    });
    if (!mediaClass) {
        return;
    }

    __block UIView* media = nil;
    EnumerateSubviewsRecursively(statusView, ^(UIView* view) {
        if (!media && [view isKindOfClass:mediaClass]) {
            media = view;
        }
    });
    if (!media || media.hidden || CGRectGetWidth(media.bounds) > kThumbSide + 1) {
        return;
    }

    // Climb past wrappers that are exactly the thumbnail's size, so the whole block moves.
    UIView* block = media;
    while (block.superview && block.superview != statusView &&
           CGRectGetWidth(block.superview.bounds) <= CGRectGetWidth(block.frame) + 1) {
        block = block.superview;
    }
    UIView* container = block.superview;
    if (!container) {
        return;
    }

    CGFloat rightEdge = CGRectGetWidth(container.bounds);
    if (container == statusView) {
        rightEdge = NFBTextColumnMaxX(statusView);
    }
    CGRect frame = block.frame;
    CGFloat x = MAX(0, rightEdge - CGRectGetWidth(frame));
    if (fabs(frame.origin.x - x) > 0.5) {
        frame.origin.x = x;
        block.frame = frame;
    }
}

%hook T1StandardStatusView

- (void)layoutSubviews {
    %orig;
    if (NFBCompactMedia()) {
        NFBAlignThumbnail((UIView*)self);
    }
}

%end
