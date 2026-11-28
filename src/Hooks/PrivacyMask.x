//
//  PrivacyMask.x
//  NeoFreeBird
//
//  7.3.165: "개인정보 가리기" (kemo_privacy_mask), for showing the tweak off in
//  screenshots. While it is on:
//  - a tweet's display name and @handle (the labels X marks StatusFullname /
//    StatusUsername, the identifiers UnifiedTimeline.x and
//    ProfileAliasButton.x already rely on; any "Status…Fullname" /
//    "Status…Username" too) show a made-up name and handle instead, the same
//    made-up one for the same person;
//  - every profile picture is covered by a grey circle with a person glyph:
//    X's avatar views (TUIAvatarImageView, TFNAvatarImageView) and any round
//    picture view of ours (the unified pair, the dock).
//  Only what is drawn changes; nothing is sent, and X's own data is untouched.
//  Off again: the real names come back and the covers go.
//

#import "HookHelpers.h"

static NSString* const kPrivacyMaskKey = @"kemo_privacy_mask";
static BOOL gMaskOn = NO;
static BOOL gMaskSetting = NO;  // inside our own setText: calls
static NSHashTable<UILabel*>* gMaskedLabels;
static NSHashTable<UIView*>* gCovers;
static const void* kMaskOriginalKey = &kMaskOriginalKey;  // UILabel: X's own text (NSString or NSAttributedString)
static const void* kMaskFakeKey = &kMaskFakeKey;          // UILabel: the text we put there
static const NSInteger kCoverTag = 0x4E4650;              // "NFP"

BOOL NFBPrivacyMaskOn(void) {
    return gMaskOn;
}

// 0: not a name label, 1: display name, 2: @handle.
static int MaskKind(UILabel* label) {
    NSString* identifier = label.accessibilityIdentifier;
    if (identifier.length < 10 || ![identifier hasPrefix:@"Status"]) return 0;
    if ([identifier hasSuffix:@"Fullname"]) return 1;
    if ([identifier hasSuffix:@"Username"]) return 2;
    return 0;
}

static NSString* FakeFor(NSString* original, int kind) {
    static NSArray<NSString*>* names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[
            @"익명의 고양이", @"익명의 펭귄", @"익명의 여우", @"익명의 수달", @"익명의 토끼", @"익명의 판다", @"익명의 햄스터",
            @"익명의 고래", @"익명의 부엉이", @"익명의 다람쥐", @"익명의 사슴", @"익명의 오리", @"익명의 너구리", @"익명의 코알라"
        ];
    });
    NSString* key = [[original stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (kind == 2 && [key hasPrefix:@"@"]) key = [key substringFromIndex:1];
    // A stable number per name (FNV-1a), the same on every run.
    uint32_t hash = 2166136261u;
    for (NSUInteger i = 0; i < key.length; i++) {
        hash ^= [key characterAtIndex:i];
        hash *= 16777619u;
    }
    if (kind == 2) return [NSString stringWithFormat:@"@user_%04x", hash & 0xFFFF];
    return [NSString stringWithFormat:@"%@ %02u", names[hash % names.count], (hash >> 8) % 100];
}

static NSString* PlainOf(id text) {
    if ([text isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString*)text string];
    return [text isKindOfClass:[NSString class]] ? text : nil;
}

// A name label of a tweet gets the made-up name; any other label is left to X.
static void MaskLabel(UILabel* label) {
    if (!gMaskOn || gMaskSetting || ![NSThread isMainThread]) return;
    int kind = MaskKind(label);
    if (!kind) return;
    NSString* shown = label.text;
    NSString* fake = objc_getAssociatedObject(label, kMaskFakeKey);
    if (shown.length == 0 || (fake && [shown isEqualToString:fake])) return;
    id original = label.attributedText.length ? label.attributedText : shown;
    NSString* replacement = FakeFor(PlainOf(original) ?: shown, kind);
    objc_setAssociatedObject(label, kMaskOriginalKey, [original copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(label, kMaskFakeKey, replacement, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gMaskedLabels) gMaskedLabels = [NSHashTable weakObjectsHashTable];
    [gMaskedLabels addObject:label];
    gMaskSetting = YES;
    if ([original isKindOfClass:[NSAttributedString class]] && [(NSAttributedString*)original length]) {
        // X's look (font, colour) from its first character; no verified badge or emoji images.
        NSDictionary* attributes = [(NSAttributedString*)original attributesAtIndex:0 effectiveRange:NULL];
        NSMutableDictionary* kept = [attributes mutableCopy];
        [kept removeObjectForKey:NSAttachmentAttributeName];
        [kept removeObjectForKey:NSLinkAttributeName];
        label.attributedText = [[NSAttributedString alloc] initWithString:replacement attributes:kept];
    } else {
        label.text = replacement;
    }
    gMaskSetting = NO;
}

static void UnmaskLabel(UILabel* label) {
    id original = objc_getAssociatedObject(label, kMaskOriginalKey);
    NSString* fake = objc_getAssociatedObject(label, kMaskFakeKey);
    objc_setAssociatedObject(label, kMaskOriginalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(label, kMaskFakeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!original || !fake || ![label.text isEqualToString:fake]) return;  // X has put something else there since
    gMaskSetting = YES;
    if ([original isKindOfClass:[NSAttributedString class]]) label.attributedText = original;
    else label.text = original;
    gMaskSetting = NO;
}

// MARK: - Covers on profile pictures

static UIView* CoverFor(UIView* picture, BOOL create) {
    UIView* cover = [picture viewWithTag:kCoverTag];
    if (cover && cover.superview == picture) return cover;
    if (!create) return nil;
    cover = [[UIView alloc] initWithFrame:picture.bounds];
    cover.tag = kCoverTag;
    cover.userInteractionEnabled = NO;
    cover.isAccessibilityElement = NO;
    cover.clipsToBounds = YES;
    cover.backgroundColor = [UIColor systemGray3Color];
    UIImageView* glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"person.fill"]];
    glyph.tintColor = [UIColor whiteColor];
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    glyph.tag = 1;
    [cover addSubview:glyph];
    [picture addSubview:cover];
    if (!gCovers) gCovers = [NSHashTable weakObjectsHashTable];
    [gCovers addObject:cover];
    return cover;
}

static void UpdateCover(UIView* picture) {
    if (![NSThread isMainThread]) return;
    UIView* cover = CoverFor(picture, gMaskOn);
    if (!cover) return;
    cover.hidden = !gMaskOn;
    if (!gMaskOn) return;
    CGRect bounds = picture.bounds;
    if (!CGRectEqualToRect(cover.frame, bounds)) cover.frame = bounds;
    CGFloat side = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat radius = picture.layer.cornerRadius > 0 ? picture.layer.cornerRadius : side / 2;
    if (cover.layer.cornerRadius != radius) cover.layer.cornerRadius = radius;
    UIView* glyph = [cover viewWithTag:1];
    CGRect glyphFrame = CGRectInset(bounds, side * 0.24, side * 0.24);
    if (!CGRectEqualToRect(glyph.frame, glyphFrame)) glyph.frame = glyphFrame;
    if (picture.subviews.lastObject != cover) [picture bringSubviewToFront:cover];
}

// A plain image view that looks like a profile picture: round, 14...90pt, a
// real (not template) image.
static BOOL LooksLikeProfilePicture(UIImageView* view) {
    CGSize size = view.bounds.size;
    if (size.width < 14 || size.width > 90 || fabs(size.width - size.height) > 1) return NO;
    if (view.layer.cornerRadius < size.width * 0.45 || !view.clipsToBounds) return NO;
    UIImage* image = view.image;
    if (!image || image.images || image.renderingMode == UIImageRenderingModeAlwaysTemplate || image.isSymbolImage) return NO;
    return YES;
}

static void MaskEverything(BOOL on) {
    if (on) {
        // What is on screen now is covered at its next layout; nudge the windows.
        for (UIWindow* window in UIApplication.sharedApplication.windows) {
            NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
            NSUInteger seen = 0;
            while (queue.count && seen < 6000) {
                UIView* view = queue.firstObject;
                [queue removeObjectAtIndex:0];
                seen++;
                if ([view isKindOfClass:[UILabel class]]) MaskLabel((UILabel*)view);
                [view setNeedsLayout];
                [queue addObjectsFromArray:view.subviews];
            }
        }
        return;
    }
    for (UILabel* label in [gMaskedLabels allObjects]) UnmaskLabel(label);
    [gMaskedLabels removeAllObjects];
    for (UIView* cover in [gCovers allObjects]) cover.hidden = YES;
}

// MARK: - Hooks

%hook UILabel

- (void)setText:(NSString*)text {
    if (gMaskOn && !gMaskSetting) {
        objc_setAssociatedObject(self, kMaskFakeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
    if (gMaskOn && !gMaskSetting) MaskLabel(self);
}

- (void)setAttributedText:(NSAttributedString*)text {
    if (gMaskOn && !gMaskSetting) {
        objc_setAssociatedObject(self, kMaskFakeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
    if (gMaskOn && !gMaskSetting) MaskLabel(self);
}

- (void)setAccessibilityIdentifier:(NSString*)identifier {
    %orig;
    if (gMaskOn) MaskLabel(self);
}

%end

%hook UIImageView

- (void)layoutSubviews {
    %orig;
    if (gMaskOn ? LooksLikeProfilePicture(self) : ([self viewWithTag:kCoverTag] != nil)) UpdateCover(self);
}

%end

%hook TUIAvatarImageView

- (void)layoutSubviews {
    %orig;
    if (gMaskOn || [(UIView*)self viewWithTag:kCoverTag]) UpdateCover((UIView*)self);
}

%end

%hook TFNAvatarImageView

- (void)layoutSubviews {
    %orig;
    if (gMaskOn || [(UIView*)self viewWithTag:kCoverTag]) UpdateCover((UIView*)self);
}

%end

%ctor {
    gMaskOn = [[NSUserDefaults standardUserDefaults] boolForKey:kPrivacyMaskKey];
    // queue:nil, then main (a main-queue observer stalls the launch, see CLAUDE.md).
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification* note) {
                                                      BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:kPrivacyMaskKey];
                                                      if (on == gMaskOn) return;
                                                      dispatch_async(dispatch_get_main_queue(), ^{
                                                          BOOL now = [[NSUserDefaults standardUserDefaults] boolForKey:kPrivacyMaskKey];
                                                          if (now == gMaskOn) return;
                                                          gMaskOn = now;
                                                          MaskEverything(now);
                                                      });
                                                  }];
}
