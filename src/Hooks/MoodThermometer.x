//
//  MoodThermometer.x
//  NeoFreeBird
//
//  A small face under the author avatar. Scoring stays off the main thread
//  and the result is cached per text, so scrolling only repositions a view
//  that is already attached. Master switch off leaves the cell untouched.
//
//  Hooked class: T1StandardStatusView (quote cards included). A quoted view
//  that inherits layoutSubviews runs the same hook. One that overrides it is
//  found from the outer tweet, so this file does not hook the subclass itself
//  (hooking a missing override would replace UIView's method).
//  The avatar is the largest view whose class contains AvatarImageView and
//  that is not inside a nested quote. Quote cards score their own text.

#import <string.h>
#import "HookHelpers.h"
#import "Core/BHTBundle.h"
#import "Mood/NFBMoodFaceView.h"
#import "Mood/NFBMoodScore.h"

static const void* kFaceKey = &kFaceKey;
static const void* kCoverKey = &kCoverKey;
static const void* kAppliedKey = &kAppliedKey;
static const void* kPendingKey = &kPendingKey;
static const void* kRevealKey = &kRevealKey;
static const void* kNestedKey = &kNestedKey;
static const void* kInApply = &kInApply;

static const CGFloat kFaceSize = 17.0;
static const CGFloat kFaceGap = 4.0;

@interface NFBMoodCoverView : UIView
@property (nonatomic, strong) UIVisualEffectView* blur;
@property (nonatomic, strong) UIView* dim;
@property (nonatomic, strong) UILabel* label;
@property (nonatomic, copy) void (^onTap)(void);
- (void)applyLevel:(NSInteger)level mode:(NSInteger)mode;
@end

static NSString* MoodText(NSString* key, NSString* fallback) {
    NSString* value = [[BHTBundle sharedBundle] localizedStringForKey:key];
    if (value.length == 0 || [value isEqualToString:key]) {
        return fallback;
    }
    return value;
}

@implementation NFBMoodCoverView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        _blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        _blur.frame = self.bounds;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blur.userInteractionEnabled = NO;
        [self addSubview:_blur];

        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dim.userInteractionEnabled = NO;
        _dim.backgroundColor = [UIColor systemBackgroundColor];
        _dim.hidden = YES;
        [self addSubview:_dim];

        UIView* chip = [UIView new];
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        chip.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
        chip.layer.cornerRadius = 14;
        chip.layer.masksToBounds = YES;
        chip.userInteractionEnabled = NO;
        [self addSubview:chip];

        _label = [UILabel new];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor whiteColor];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 2;
        [chip addSubview:_label];

        [NSLayoutConstraint activateConstraints:@[
            [chip.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [chip.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [chip.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:8],
            [chip.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-8],
            [_label.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:12],
            [_label.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-12],
            [_label.topAnchor constraintEqualToAnchor:chip.topAnchor constant:7],
            [_label.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-7]
        ]];

        UITapGestureRecognizer* tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (void)tapped {
    if (self.onTap) {
        self.onTap();
    }
}

- (void)applyLevel:(NSInteger)level mode:(NSInteger)mode {
    BOOL hide = mode >= 2;
    self.blur.hidden = hide;
    self.dim.hidden = !hide;
    self.label.text = level >= 6 ? MoodText(@"KEMO_MOOD_PILL_CONFLICT", @"분쟁을 부르는 트윗 · 탭해서 보기")
                                 : MoodText(@"KEMO_MOOD_PILL_RAGE", @"욕설이 많은 트윗 · 탭해서 보기");
    self.accessibilityLabel = self.label.text;
}

@end

static NSCache<NSString*, NSNumber*>* MoodCache(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 400;
    });
    return cache;
}

static void MoodHide(UIView* root) {
    NFBMoodFaceView* face = objc_getAssociatedObject(root, kFaceKey);
    NFBMoodCoverView* cover = objc_getAssociatedObject(root, kCoverKey);
    face.hidden = YES;
    cover.hidden = YES;
    cover.userInteractionEnabled = NO;
}

static BOOL MoodSkipBranch(NSString* name) {
    if ([name hasPrefix:@"NFBMood"]) {
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

static UIView* MoodAvatar(UIView* root) {
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
            if (MoodSkipBranch(name)) {
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

static NSString* MoodAccessibility(UIView* view) {
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

static NSString* MoodBodyText(UIView* root) {
    UIView* stack[64];
    NSInteger count = 1;
    stack[0] = root;
    NSInteger seen = 0;
    while (count > 0 && seen < 80) {
        UIView* view = stack[--count];
        seen++;
        for (UIView* sub in view.subviews) {
            NSString* name = NSStringFromClass(sub.class);
            if (MoodSkipBranch(name)) {
                continue;
            }
            if ([name containsString:@"BodyText"]) {
                NSString* label = MoodAccessibility(sub);
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

static NSString* MoodObjectString(id object, NSString* selectorName) {
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

static NSString* MoodTweetText(UIView* root) {
    NSString* body = MoodBodyText(root);
    if (body.length > 0) {
        return body;
    }
    if (![root respondsToSelector:@selector(viewModel)]) {
        return nil;
    }
    id viewModel = ((id (*)(id, SEL))objc_msgSend)(root, @selector(viewModel));
    for (NSString* name in @[ @"text", @"statusText", @"displayText", @"fullText", @"bodyText" ]) {
        NSString* value = MoodObjectString(viewModel, name);
        if (value.length > 0) {
            return value;
        }
        NSString* status = MoodObjectString(viewModel, @"status");
        value = MoodObjectString(status, name);
        if (value.length > 0) {
            return value;
        }
    }
    return nil;
}

static BOOL MoodLevelVisible(NSInteger level) {
    if (level < 1 || level > 6) {
        return NO;
    }
    return [BHTSettings boolForKey:[NSString stringWithFormat:@"kemo_mood_level_%ld", (long)level]];
}

static void MoodPlace(UIView* root, NSInteger level, NSString* cacheKey) {
    if (CGRectIsEmpty(root.bounds)) {
        return;
    }
    UIView* avatar = MoodAvatar(root);
    NFBMoodFaceView* face = objc_getAssociatedObject(root, kFaceKey);
    BOOL showFace = level >= 1 && MoodLevelVisible(level) && avatar;
    if (showFace) {
        if (!face) {
            face = [[NFBMoodFaceView alloc] initWithFrame:CGRectMake(0, 0, kFaceSize, kFaceSize)];
            objc_setAssociatedObject(root, kFaceKey, face, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [root addSubview:face];
        }
        CGRect avatarFrame = [avatar convertRect:avatar.bounds toView:root];
        CGRect frame = CGRectMake(CGRectGetMidX(avatarFrame) - kFaceSize / 2.0,
                                  CGRectGetMaxY(avatarFrame) + kFaceGap, kFaceSize, kFaceSize);
        if (!CGRectEqualToRect(face.frame, frame)) {
            face.frame = frame;
        }
        face.level = level;
        face.hidden = NO;
    } else {
        face.hidden = YES;
    }

    NSInteger mode = [BHTSettings integerForKey:@"kemo_mood_rage"];
    NSString* revealed = objc_getAssociatedObject(root, kRevealKey);
    BOOL coverIt = level >= 5 && mode > 0 && ![revealed isEqualToString:cacheKey];
    NFBMoodCoverView* cover = objc_getAssociatedObject(root, kCoverKey);
    if (!coverIt) {
        cover.hidden = YES;
        cover.userInteractionEnabled = NO;
    } else {
        if (!cover) {
            cover = [[NFBMoodCoverView alloc] initWithFrame:CGRectZero];
            objc_setAssociatedObject(root, kCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [root addSubview:cover];
        }
        CGFloat left = 0;
        if (avatar) {
            CGRect avatarFrame = [avatar convertRect:avatar.bounds toView:root];
            left = CGRectGetMaxX(avatarFrame) + 6.0;
            if (left > CGRectGetWidth(root.bounds) - 24.0) {
                left = 0;
            }
        }
        CGRect frame = CGRectMake(left, 0, CGRectGetWidth(root.bounds) - left, CGRectGetHeight(root.bounds));
        if (!CGRectEqualToRect(cover.frame, frame)) {
            cover.frame = frame;
        }
        [cover applyLevel:level mode:mode];
        __weak UIView* weakRoot = root;
        NSString* key = cacheKey;
        cover.onTap = ^{
            UIView* strongRoot = weakRoot;
            if (!strongRoot) {
                return;
            }
            objc_setAssociatedObject(strongRoot, kRevealKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
            NFBMoodCoverView* live = objc_getAssociatedObject(strongRoot, kCoverKey);
            live.hidden = YES;
            live.userInteractionEnabled = NO;
        };
        cover.hidden = NO;
        cover.userInteractionEnabled = YES;
        [root bringSubviewToFront:cover];
    }
    if (face && !face.hidden) {
        [root bringSubviewToFront:face];
    }
    objc_setAssociatedObject(root, kAppliedKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void MoodApply(UIView* root);

// Quote cards nested in this tweet. record=NO while tearing the feature down,
// so the marker that forced the walk is cleared and later layouts stay cheap.
static void MoodApplyNestedQuotes(UIView* root, BOOL record) {
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
        if ([name hasPrefix:@"NFBMood"]) {
            continue;
        }
        if ([name containsString:@"QuotedStandardStatus"] || [name containsString:@"QuotedStatus"]) {
            found = YES;
            MoodApply(view);
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

static void MoodTearDown(UIView* root) {
    NFBMoodFaceView* face = objc_getAssociatedObject(root, kFaceKey);
    NFBMoodCoverView* cover = objc_getAssociatedObject(root, kCoverKey);
    [face removeFromSuperview];
    [cover removeFromSuperview];
    objc_setAssociatedObject(root, kFaceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(root, kCoverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(root, kAppliedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(root, kPendingKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(root, kRevealKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void MoodApply(UIView* root) {
    if (![NSThread isMainThread]) {
        return;
    }
    if (![BHTSettings boolForKey:@"kemo_mood"]) {
        BOOL decorated = objc_getAssociatedObject(root, kFaceKey) ||
                         objc_getAssociatedObject(root, kCoverKey) ||
                         objc_getAssociatedObject(root, kNestedKey);
        if (!decorated) {
            return;
        }
    }
    // Adding the face during layout can re-enter layoutSubviews. The second
    // pass would walk the same tree again.
    if (objc_getAssociatedObject(root, kInApply)) {
        return;
    }
    objc_setAssociatedObject(root, kInApply, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
    if (![BHTSettings boolForKey:@"kemo_mood"]) {
        BOOL nested = objc_getAssociatedObject(root, kNestedKey) != nil;
        MoodTearDown(root);
        if (nested) {
            MoodApplyNestedQuotes(root, NO);
            objc_setAssociatedObject(root, kNestedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    @try {
        NSString* text = MoodTweetText(root);
        if (text.length == 0) {
            MoodHide(root);
            objc_setAssociatedObject(root, kAppliedKey, @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
            MoodApplyNestedQuotes(root, YES);
            return;
        }
        NSInteger sensitivity = [BHTSettings integerForKey:@"kemo_mood_sensitivity"];
        NSString* cacheKey = [NSString stringWithFormat:@"%lu:%lu:%ld", (unsigned long)text.length,
                                                        (unsigned long)text.hash, (long)sensitivity];
        NSString* applied = objc_getAssociatedObject(root, kAppliedKey);
        if ([applied isEqualToString:cacheKey]) {
            NSNumber* cached = [MoodCache() objectForKey:cacheKey];
            if (cached) {
                MoodPlace(root, cached.integerValue, cacheKey);
                MoodApplyNestedQuotes(root, YES);
                return;
            }
        }
        NSNumber* cached = [MoodCache() objectForKey:cacheKey];
        if (cached) {
            objc_setAssociatedObject(root, kPendingKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            MoodPlace(root, cached.integerValue, cacheKey);
            MoodApplyNestedQuotes(root, YES);
            return;
        }
        NSString* pending = objc_getAssociatedObject(root, kPendingKey);
        if ([pending isEqualToString:cacheKey]) {
            MoodApplyNestedQuotes(root, YES);
            return;
        }
        MoodHide(root);
        objc_setAssociatedObject(root, kPendingKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        __weak UIView* weakRoot = root;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSInteger level = NFBMoodScore(text, sensitivity);
            [MoodCache() setObject:@(level) forKey:cacheKey];
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
                if (![BHTSettings boolForKey:@"kemo_mood"]) {
                    MoodHide(strongRoot);
                    return;
                }
                MoodPlace(strongRoot, level, cacheKey);
            });
        });
        MoodApplyNestedQuotes(root, YES);
    } @catch (__unused NSException* exception) {
        MoodHide(root);
    }
    } @finally {
        objc_setAssociatedObject(root, kInApply, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%hook T1StandardStatusView

- (void)layoutSubviews {
    %orig;
    MoodApply((UIView*)self);
}

%end
