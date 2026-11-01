//
//  ConflictCat.x
//  NeoFreeBird
//
//  An angry-cat badge under the author avatar when a tweet reads as divisive
//  bait. Nothing is blurred or hidden. The huff is a repeating Core Animation
//  on the badge layer, so scrolling does not tick a timer.
//
//  Hooked class: T1StandardStatusView. Quote cards are scored from inside that
//  layout pass. The quoted class is not hooked on its own: hooking a method it
//  does not override would replace the superclass implementation.

#import <QuartzCore/QuartzCore.h>
#import <stdlib.h>
#import <string.h>
#import "HookHelpers.h"
#import "Conflict/NFBConflict.h"

static const void* kBadgeKey = &kBadgeKey;
static const void* kAppliedKey = &kAppliedKey;
static const void* kPendingKey = &kPendingKey;
static const void* kNestedKey = &kNestedKey;
static const void* kInApply = &kInApply;

static NSString* const kHuffAnim = @"nfb.huff";
static NSString* const kPuffAnim = @"nfb.puff";
static const CGFloat kBadgeWidth = 20.0;
static const CGFloat kBadgeGap = 4.0;
static const CFTimeInterval kHuffDuration = 2.1;

static UIImage* ConflictCatImage(void) {
    static UIImage* image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle* bundle = [BHTBundle sharedBundle].mainBundle;
        UIImage* named = [UIImage imageNamed:@"nfb_conflict_cat"
                                    inBundle:bundle
               compatibleWithTraitCollection:nil];
        if (named.CGImage) {
            image = named;
            return;
        }
        BOOL use3x = UIScreen.mainScreen.scale >= 2.5;
        NSURL* url = [[BHTBundle sharedBundle]
            pathForFile:use3x ? @"nfb_conflict_cat@3x.png" : @"nfb_conflict_cat@2x.png"];
        UIImage* loaded = url ? [UIImage imageWithContentsOfFile:url.path] : nil;
        if (loaded.CGImage) {
            image = [UIImage imageWithCGImage:loaded.CGImage
                                        scale:use3x ? 3.0 : 2.0
                                  orientation:UIImageOrientationUp];
        }
    });
    return image;
}

static CATransform3D HuffTransform(CGFloat scaleX, CGFloat scaleY, CGFloat degrees) {
    CATransform3D transform = CATransform3DMakeScale(scaleX, scaleY, 1);
    return CATransform3DRotate(transform, degrees * (CGFloat)M_PI / 180.0, 0, 0, 1);
}

static CAAnimationGroup* HuffGroup(void) {
    CAKeyframeAnimation* huff = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    huff.values = @[
        [NSValue valueWithCATransform3D:HuffTransform(1, 1, 0)],
        [NSValue valueWithCATransform3D:HuffTransform(1.045, 1.02, -4)],
        [NSValue valueWithCATransform3D:HuffTransform(1.08, 1.045, 4)],
        [NSValue valueWithCATransform3D:HuffTransform(1, 1, 0)],
        [NSValue valueWithCATransform3D:HuffTransform(1, 1, 0)]
    ];
    // Motion occupies the first ~0.9s. The rest of the 2.1s group is a pause.
    huff.keyTimes = @[ @0, @0.14, @0.28, @0.429, @1 ];
    CAMediaTimingFunction* ease =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    huff.timingFunctions = @[ ease, ease, ease, ease ];
    huff.duration = kHuffDuration;

    CAAnimationGroup* group = [CAAnimationGroup animation];
    group.animations = @[ huff ];
    group.duration = kHuffDuration;
    group.repeatCount = HUGE_VALF;
    return group;
}

static CAAnimationGroup* PuffGroup(CGFloat driftX) {
    CAMediaTimingFunction* ease =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    CAKeyframeAnimation* fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[ @0, @0.5, @0.22, @0, @0 ];
    fade.keyTimes = @[ @0, @0.08, @0.2, @0.429, @1 ];
    fade.timingFunctions = @[ ease, ease, ease, ease ];
    fade.duration = kHuffDuration;

    CAKeyframeAnimation* rise = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
    rise.values = @[ @0, @(-3), @(-6), @(-6) ];
    rise.keyTimes = @[ @0, @0.14, @0.429, @1 ];
    rise.timingFunctions = @[ ease, ease, ease ];
    rise.duration = kHuffDuration;

    CAKeyframeAnimation* slide = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.values = @[ @0, @(driftX), @(driftX) ];
    slide.keyTimes = @[ @0, @0.429, @1 ];
    slide.timingFunctions = @[ ease, ease ];
    slide.duration = kHuffDuration;

    CAAnimationGroup* group = [CAAnimationGroup animation];
    group.animations = @[ fade, rise, slide ];
    group.duration = kHuffDuration;
    group.repeatCount = HUGE_VALF;
    return group;
}

@interface NFBConflictBadge : UIView
@property (nonatomic, strong) UIImageView* cat;
@property (nonatomic, strong) CALayer* puffA;
@property (nonatomic, strong) CALayer* puffB;
@property (nonatomic, assign) CFTimeInterval phase;
@property (nonatomic, assign) BOOL hasPhase;
- (void)applyHuff;
- (void)stopHuff;
@end

@implementation NFBConflictBadge

- (instancetype)initWithImage:(UIImage*)image {
    CGFloat height = kBadgeWidth;
    if (image.size.width > 0) {
        height = kBadgeWidth * image.size.height / image.size.width;
    }
    if ((self = [super initWithFrame:CGRectMake(0, 0, kBadgeWidth, height)])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = NO;
        self.isAccessibilityElement = NO;
        _cat = [[UIImageView alloc] initWithImage:image];
        _cat.contentMode = UIViewContentModeScaleAspectFit;
        _cat.userInteractionEnabled = NO;
        _cat.frame = self.bounds;
        _cat.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_cat];

        _puffA = [self puffWithDiameter:3.2 color:[UIColor whiteColor]];
        _puffB = [self puffWithDiameter:2.6
                                 color:[UIColor colorWithRed:0xE8 / 255.0
                                                       green:0x20 / 255.0
                                                        blue:0x30 / 255.0
                                                       alpha:1]];
        [self.layer addSublayer:_puffA];
        [self.layer addSublayer:_puffB];
    }
    return self;
}

- (CALayer*)puffWithDiameter:(CGFloat)diameter color:(UIColor*)color {
    CALayer* layer = [CALayer layer];
    layer.bounds = CGRectMake(0, 0, diameter, diameter);
    layer.cornerRadius = diameter / 2.0;
    layer.backgroundColor = color.CGColor;
    layer.opacity = 0;
    return layer;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    self.puffA.position = CGPointMake(width - 1.0, 1.5);
    self.puffB.position = CGPointMake(width - 5.0, 4.0);
}

- (void)stopHuff {
    [self.cat.layer removeAnimationForKey:kHuffAnim];
    [self.puffA removeAnimationForKey:kPuffAnim];
    [self.puffB removeAnimationForKey:kPuffAnim];
    self.puffA.opacity = 0;
    self.puffB.opacity = 0;
}

- (void)applyHuff {
    BOOL animate = [BHTSettings boolForKey:@"kemo_conflict_huff"] &&
                   !UIAccessibilityIsReduceMotionEnabled();
    if (!animate) {
        [self stopHuff];
        return;
    }
    if (!self.hasPhase) {
        self.phase = (CFTimeInterval)arc4random_uniform(2100) / 1000.0;
        self.hasPhase = YES;
    }
    if ([self.cat.layer animationForKey:kHuffAnim] == nil) {
        CAAnimationGroup* group = HuffGroup();
        group.timeOffset = self.phase;
        [self.cat.layer addAnimation:group forKey:kHuffAnim];
    }
    if ([self.puffA animationForKey:kPuffAnim] == nil) {
        CAAnimationGroup* leading = PuffGroup(1.5);
        leading.timeOffset = self.phase;
        [self.puffA addAnimation:leading forKey:kPuffAnim];
        CAAnimationGroup* trailing = PuffGroup(3.0);
        trailing.timeOffset = fmod(self.phase + 0.16, kHuffDuration);
        [self.puffB addAnimation:trailing forKey:kPuffAnim];
    }
}

@end

static NSCache<NSString*, NSNumber*>* ConflictCache(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 400;
    });
    return cache;
}

static void ConflictRemove(UIView* root) {
    NFBConflictBadge* badge = objc_getAssociatedObject(root, kBadgeKey);
    [badge stopHuff];
    [badge removeFromSuperview];
    objc_setAssociatedObject(root, kBadgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(root, kAppliedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(root, kPendingKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static BOOL ConflictSkip(NSString* name) {
    if ([name hasPrefix:@"NFBConflict"] || [name hasPrefix:@"NFBMood"]) {
        return YES;
    }
    if ([name containsString:@"QuotedStandardStatus"] || [name containsString:@"QuotedStatus"]) {
        return YES;
    }
    if ([name containsString:@"InlineAction"] || [name containsString:@"Media"]) {
        return YES;
    }
    return NO;
}

static UIView* ConflictAvatar(UIView* root) {
    UIView* stack[64];
    NSInteger count = 1;
    stack[0] = root;
    UIView* best = nil;
    CGFloat bestArea = 0;
    NSInteger seen = 0;
    while (count > 0 && seen < 80) {
        UIView* view = stack[--count];
        seen++;
        for (UIView* sub in view.subviews) {
            NSString* name = NSStringFromClass(sub.class);
            if (ConflictSkip(name)) {
                continue;
            }
            if ([name containsString:@"AvatarImageView"]) {
                CGRect frame = [sub convertRect:sub.bounds toView:root];
                CGFloat area = CGRectGetWidth(frame) * CGRectGetHeight(frame);
                if (area > bestArea && area >= 16.0 * 16.0) {
                    bestArea = area;
                    best = sub;
                }
                continue;
            }
            if ([name containsString:@"BodyText"]) {
                continue;
            }
            if (count < 64) {
                stack[count++] = sub;
            }
        }
    }
    return best;
}

static NSString* ConflictAccessibility(UIView* view) {
    if (view.accessibilityLabel.length > 0) {
        return view.accessibilityLabel;
    }
    for (UIView* sub in view.subviews) {
        if (sub.accessibilityLabel.length > 0) {
            return sub.accessibilityLabel;
        }
        for (UIView* deeper in sub.subviews) {
            if (deeper.accessibilityLabel.length > 0) {
                return deeper.accessibilityLabel;
            }
        }
    }
    return nil;
}

static NSString* ConflictBodyText(UIView* root) {
    UIView* stack[64];
    NSInteger count = 1;
    stack[0] = root;
    NSInteger seen = 0;
    while (count > 0 && seen < 80) {
        UIView* view = stack[--count];
        seen++;
        for (UIView* sub in view.subviews) {
            NSString* name = NSStringFromClass(sub.class);
            if (ConflictSkip(name)) {
                continue;
            }
            if ([name containsString:@"BodyText"]) {
                NSString* label = ConflictAccessibility(sub);
                if (label.length > 0) {
                    return label;
                }
                continue;
            }
            if ([name containsString:@"Avatar"]) {
                continue;
            }
            if (count < 64) {
                stack[count++] = sub;
            }
        }
    }
    return nil;
}

static NSString* ConflictObjectString(id object, NSString* selectorName) {
    if (!object) {
        return nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* returnType = signature.methodReturnType;
    if (!returnType || strcmp(returnType, @encode(id)) != 0) {
        return nil;
    }
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    if ([value isKindOfClass:[NSString class]] && [(NSString*)value length] > 0) {
        return value;
    }
    return nil;
}

static NSString* ConflictTweetText(UIView* root) {
    NSString* body = ConflictBodyText(root);
    if (body.length > 0) {
        return body;
    }
    if (![root respondsToSelector:@selector(viewModel)]) {
        return nil;
    }
    id viewModel = ((id (*)(id, SEL))objc_msgSend)(root, @selector(viewModel));
    for (NSString* name in @[ @"text", @"statusText", @"displayText", @"fullText", @"bodyText" ]) {
        NSString* value = ConflictObjectString(viewModel, name);
        if (value.length > 0) {
            return value;
        }
        NSString* status = ConflictObjectString(viewModel, @"status");
        value = ConflictObjectString(status, name);
        if (value.length > 0) {
            return value;
        }
    }
    return nil;
}

static void ConflictPlace(UIView* root, BOOL divisive) {
    if (!divisive || CGRectIsEmpty(root.bounds)) {
        NFBConflictBadge* existing = objc_getAssociatedObject(root, kBadgeKey);
        existing.hidden = YES;
        [existing stopHuff];
        return;
    }
    UIView* avatar = ConflictAvatar(root);
    UIImage* image = ConflictCatImage();
    if (!avatar || !image) {
        NFBConflictBadge* existing = objc_getAssociatedObject(root, kBadgeKey);
        existing.hidden = YES;
        [existing stopHuff];
        return;
    }
    NFBConflictBadge* badge = objc_getAssociatedObject(root, kBadgeKey);
    if (!badge) {
        badge = [[NFBConflictBadge alloc] initWithImage:image];
        objc_setAssociatedObject(root, kBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [root addSubview:badge];
    }
    CGRect avatarFrame = [avatar convertRect:avatar.bounds toView:root];
    CGSize size = badge.bounds.size;
    if (size.width < 1) {
        size = CGSizeMake(kBadgeWidth, kBadgeWidth);
    }
    CGRect frame = CGRectMake(CGRectGetMidX(avatarFrame) - size.width / 2.0,
                              CGRectGetMaxY(avatarFrame) + kBadgeGap, size.width, size.height);
    if (!CGRectEqualToRect(badge.frame, frame)) {
        badge.frame = frame;
    }
    badge.hidden = NO;
    [badge applyHuff];
    [root bringSubviewToFront:badge];
}

static void ConflictApply(UIView* root);

static void ConflictApplyQuotes(UIView* root, BOOL record) {
    UIView* stack[48];
    NSInteger count = 0;
    for (UIView* sub in root.subviews) {
        if (count < 48) {
            stack[count++] = sub;
        }
    }
    BOOL found = NO;
    NSInteger seen = 0;
    while (count > 0 && seen < 48) {
        UIView* view = stack[--count];
        seen++;
        NSString* name = NSStringFromClass(view.class);
        if ([name hasPrefix:@"NFBConflict"] || [name hasPrefix:@"NFBMood"]) {
            continue;
        }
        if ([name containsString:@"QuotedStandardStatus"] || [name containsString:@"QuotedStatus"]) {
            found = YES;
            ConflictApply(view);
            continue;
        }
        if ([name containsString:@"BodyText"] || [name containsString:@"Media"] ||
            [name containsString:@"InlineAction"] || [name containsString:@"Avatar"]) {
            continue;
        }
        for (UIView* sub in view.subviews) {
            if (count < 48) {
                stack[count++] = sub;
            }
        }
    }
    if (record) {
        objc_setAssociatedObject(root, kNestedKey, found ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ConflictApply(UIView* root) {
    if (![NSThread isMainThread]) {
        return;
    }
    if (![BHTSettings boolForKey:@"kemo_conflict"]) {
        if (!objc_getAssociatedObject(root, kBadgeKey) && !objc_getAssociatedObject(root, kNestedKey)) {
            return;
        }
    }
    if (objc_getAssociatedObject(root, kInApply)) {
        return;
    }
    objc_setAssociatedObject(root, kInApply, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        if (![BHTSettings boolForKey:@"kemo_conflict"]) {
            BOOL nested = objc_getAssociatedObject(root, kNestedKey) != nil;
            ConflictRemove(root);
            if (nested) {
                ConflictApplyQuotes(root, NO);
                objc_setAssociatedObject(root, kNestedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return;
        }
        NSString* text = nil;
        @try {
            text = ConflictTweetText(root);
        } @catch (__unused NSException* exception) {
            text = nil;
        }
        if (text.length == 0) {
            ConflictPlace(root, NO);
            objc_setAssociatedObject(root, kAppliedKey, @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
            ConflictApplyQuotes(root, YES);
            return;
        }
        NSString* cacheKey =
            [NSString stringWithFormat:@"%lu:%lu", (unsigned long)text.length, (unsigned long)text.hash];
        NSString* applied = objc_getAssociatedObject(root, kAppliedKey);
        BOOL sameTweet = [applied isEqualToString:cacheKey];
        NSNumber* cached = [ConflictCache() objectForKey:cacheKey];
        if (cached) {
            objc_setAssociatedObject(root, kPendingKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(root, kAppliedKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
            ConflictPlace(root, cached.boolValue);
            ConflictApplyQuotes(root, YES);
            return;
        }
        NSString* pending = objc_getAssociatedObject(root, kPendingKey);
        if ([pending isEqualToString:cacheKey]) {
            ConflictApplyQuotes(root, YES);
            return;
        }
        // A new tweet must not keep the previous cat. The same tweet keeps its
        // badge while a dropped cache entry is scored again.
        if (!sameTweet) {
            ConflictPlace(root, NO);
        }
        objc_setAssociatedObject(root, kPendingKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        __weak UIView* weakRoot = root;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BOOL divisive = NFBConflictIsDivisive(text);
            [ConflictCache() setObject:@(divisive) forKey:cacheKey];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIView* strongRoot = weakRoot;
                if (!strongRoot) {
                    return;
                }
                NSString* stillPending = objc_getAssociatedObject(strongRoot, kPendingKey);
                if (![stillPending isEqualToString:cacheKey]) {
                    return;
                }
                objc_setAssociatedObject(strongRoot, kPendingKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
                if (![BHTSettings boolForKey:@"kemo_conflict"]) {
                    ConflictRemove(strongRoot);
                    return;
                }
                objc_setAssociatedObject(strongRoot, kAppliedKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
                ConflictPlace(strongRoot, divisive);
            });
        });
        ConflictApplyQuotes(root, YES);
    } @catch (__unused NSException* exception) {
        ConflictRemove(root);
    } @finally {
        objc_setAssociatedObject(root, kInApply, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%hook T1StandardStatusView

- (void)layoutSubviews {
    %orig;
    ConflictApply((UIView*)self);
}

%end
