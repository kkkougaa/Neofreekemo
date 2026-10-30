//
//  MediaCountBadge.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - "1/4" badge on multi-image tweets
// A small dark pill in the top-right corner of a tweet's media showing which image
// is on screen and how many there are. Only multi-image carousels get one. The
// position comes from the carousel's own scroll position, so it follows swiping.

@interface T1StatusPhotoVideoForwardView : UIView
@end

static NSString* const kBadgeSettingKey = @"kemo_media_count_badge";
static const NSInteger kCountBadgeTag = 0x4e464237;

@interface NFBCountBadge : UILabel
@end

@implementation NFBCountBadge

- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(0, 8, 0, 8))];
}

@end

static BOOL IsCarouselScrollView(UIScrollView* view) {
    static Class cachedClass;
    static BOOL cachedResult;
    Class cls = view.class;
    if (cls != cachedClass) {
        cachedClass = cls;
        cachedResult = [NSStringFromClass(cls) hasSuffix:@"CarouselScrollView"];
    }
    return cachedResult;
}

static UIScrollView* FindCarousel(UIView* view, int depth) {
    if ([view isKindOfClass:[UIScrollView class]] && IsCarouselScrollView((UIScrollView*)view)) {
        return (UIScrollView*)view;
    }
    if (depth < 4) {
        for (UIView* sub in view.subviews) {
            UIScrollView* found = FindCarousel(sub, depth + 1);
            if (found) {
                return found;
            }
        }
    }
    return nil;
}

static void UpdateBadge(UIView* root) {
    UILabel* badge = (UILabel*)[root viewWithTag:kCountBadgeTag];
    UIScrollView* scroll = [BHTSettings boolForKey:kBadgeSettingKey] ? FindCarousel(root, 0) : nil;

    NSMutableArray<UIView*>* items = [NSMutableArray array];
    for (UIView* sub in scroll.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"MultiMediaViewImageView"]) {
            [items addObject:sub];
        }
    }
    if (items.count < 2) {
        badge.hidden = YES;
        return;
    }
    [items sortUsingComparator:^NSComparisonResult(UIView* a, UIView* b) {
        return [@(CGRectGetMinX(a.frame)) compare:@(CGRectGetMinX(b.frame))];
    }];

    // The image showing the most inside the media area is the current one.
    NSUInteger current = 0;
    CGFloat bestOverlap = -1;
    for (NSUInteger i = 0; i < items.count; i++) {
        CGRect rect = [scroll convertRect:items[i].frame toView:root];
        CGRect overlap = CGRectIntersection(rect, root.bounds);
        CGFloat width = CGRectIsNull(overlap) ? 0 : CGRectGetWidth(overlap);
        if (width > bestOverlap) {
            bestOverlap = width;
            current = i;
        }
    }

    if (!badge) {
        badge = [[NFBCountBadge alloc] initWithFrame:CGRectZero];
        badge.tag = kCountBadgeTag;
        badge.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        badge.textColor = [UIColor whiteColor];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        badge.layer.cornerRadius = 11;
        badge.clipsToBounds = YES;
        badge.userInteractionEnabled = NO;
        [root addSubview:badge];
    }
    badge.text = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)current + 1,
                                            (unsigned long)items.count];
    CGFloat textWidth = ceil([badge.text sizeWithAttributes:@{NSFontAttributeName : badge.font}].width);
    CGFloat width = textWidth + 16;
    badge.frame = CGRectMake(CGRectGetWidth(root.bounds) - width - 8, 8, width, 22);
    badge.hidden = NO;
    [root bringSubviewToFront:badge];
}

%hook T1StatusPhotoVideoForwardView

- (void)layoutSubviews {
    %orig;
    UpdateBadge((UIView*)self);
}

%end

// The carousel scrolls without laying its container out, so follow its offset.
%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    if (!IsCarouselScrollView(self)) {
        return;
    }
    Class rootClass = %c(T1StatusPhotoVideoForwardView);
    for (UIView* view = self.superview; view; view = view.superview) {
        if ([view isKindOfClass:rootClass]) {
            UpdateBadge(view);
            return;
        }
    }
}

%end
