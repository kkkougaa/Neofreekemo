//
//  DraftSave.x
//  NeoFreeBird
//

#import "Core/NFBFirstResponder.h"
#import "HookHelpers.h"

// MARK: - Draft autosave

// While the compose screen is open, what has been typed is saved every couple of seconds.
// If the app is closed or crashes before the tweet goes out, the next empty compose screen
// offers to bring the text back. Nothing is inserted on its own. The offer sits at the
// bottom right, just above the composer's undo icon, so it does not cover the text.

static NSString* const kDraftTextKey = @"nfb_draft_text";
static NSString* const kDraftTimeKey = @"nfb_draft_time";
static const NSTimeInterval kDraftLifetime = 48 * 3600;

static const void* kDraftTimerKey = &kDraftTimerKey;
static const void* kDraftTouchedKey = &kDraftTouchedKey;
static const void* kDraftSentKey = &kDraftSentKey;
static const void* kDraftBannerKey = &kDraftBannerKey;
static const NSInteger kDraftBannerTag = 0x4E464452;

static BOOL DraftEnabled(void) {
    return [BHTSettings boolForKey:@"kemo_draft_autosave"];
}

// The main text field of the compose screen: the one in focus, otherwise the biggest.
static UIView<UIKeyInput>* ComposeInput(UIViewController* composer) {
    UIResponder* responder = NFBCurrentFirstResponder();
    if ([responder isKindOfClass:[UIView class]] &&
        [responder conformsToProtocol:@protocol(UIKeyInput)] &&
        [responder respondsToSelector:@selector(text)] &&
        ((UIView*)responder).window == composer.view.window) {
        return (UIView<UIKeyInput>*)responder;
    }

    UIView<UIKeyInput>* best = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:composer.view];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 3000) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (!view.hidden && [view conformsToProtocol:@protocol(UIKeyInput)] &&
            [view respondsToSelector:@selector(text)]) {
            CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
            if (area > bestArea) {
                bestArea = area;
                best = (UIView<UIKeyInput>*)view;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return best;
}

static NSString* TextOf(UIView<UIKeyInput>* input) {
    id text = [input performSelector:@selector(text)];
    return [text isKindOfClass:[NSString class]] ? text : nil;
}

static BOOL IsBlank(NSString* text) {
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
               .length == 0;
}

static NSString* SavedDraft(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* text = [defaults stringForKey:kDraftTextKey];
    NSDate* when = [defaults objectForKey:kDraftTimeKey];
    if (IsBlank(text) || !when || -[when timeIntervalSinceNow] > kDraftLifetime) {
        return nil;
    }
    return text;
}

static void ClearDraft(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kDraftTextKey];
    [defaults removeObjectForKey:kDraftTimeKey];
}

static void SaveNow(UIViewController* composer) {
    if (!DraftEnabled() || [objc_getAssociatedObject(composer, kDraftSentKey) boolValue]) {
        return;
    }
    UIView<UIKeyInput>* input = ComposeInput(composer);
    NSString* text = input ? TextOf(input) : nil;
    if (!text) {
        return;
    }
    if (!IsBlank(text)) {
        objc_setAssociatedObject(composer, kDraftTouchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        if (![[defaults stringForKey:kDraftTextKey] isEqualToString:text]) {
            [defaults setObject:text forKey:kDraftTextKey];
            [defaults setObject:[NSDate date] forKey:kDraftTimeKey];
        }
    } else if ([objc_getAssociatedObject(composer, kDraftTouchedKey) boolValue]) {
        // Typed something and then emptied the box on purpose: the old draft goes too.
        ClearDraft();
    }
}

// Called from the real send path: whatever was saved has been posted.
void NFBDraftNoteSent(UIViewController* composer) {
    objc_setAssociatedObject(composer, kDraftSentKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ClearDraft();
}

// MARK: Restore offer

static const CGFloat kBannerHeight = 34.0;

// The composer's undo control. Matched by name first (class, accessibility, icon);
// otherwise the rightmost icon button on the compose toolbar, which is where that
// undo icon sits.
static BOOL TextMentionsUndo(NSString* text) {
    if (text.length == 0) {
        return NO;
    }
    if ([text rangeOfString:@"undo" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    return [text containsString:@"되돌리"] || [text containsString:@"실행 취소"];
}

static NSString* VectorImageName(UIImage* image) {
    if (!image) {
        return nil;
    }
    for (NSString* key in @[ @"name", @"imageName" ]) {
        SEL selector = NSSelectorFromString(key);
        if (![image respondsToSelector:selector]) {
            continue;
        }
        id value = ((id (*)(id, SEL))objc_msgSend)(image, selector);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return value;
        }
    }
    return nil;
}

static BOOL IsIconSized(CGRect frame) {
    return frame.size.width >= 16 && frame.size.width <= 64 && frame.size.height >= 16 &&
           frame.size.height <= 64;
}

static BOOL ViewIsUndoControl(UIView* view) {
    if (TextMentionsUndo(NSStringFromClass(view.class)) ||
        TextMentionsUndo(view.accessibilityIdentifier) ||
        TextMentionsUndo(view.accessibilityLabel)) {
        return YES;
    }
    if (![view isKindOfClass:[UIButton class]]) {
        return NO;
    }
    UIButton* button = (UIButton*)view;
    if (TextMentionsUndo([button titleForState:UIControlStateNormal]) ||
        TextMentionsUndo(button.imageView.accessibilityLabel)) {
        return YES;
    }
    UIImage* image = [button imageForState:UIControlStateNormal] ?: button.imageView.image;
    return TextMentionsUndo(VectorImageName(image));
}

// Top edge of the compose toolbar, in the compose view's coordinates.
static CGFloat ComposeToolbarTop(UIView* host) {
    __block UIView* replyButton = nil;
    EnumerateSubviewsRecursively(host, ^(UIView* view) {
        if (!replyButton && [NSStringFromClass(view.class)
                                isEqualToString:@"T1TweetComposeConversationControlButton"]) {
            replyButton = view;
        }
    });
    UIView* toolbar = replyButton.superview.superview;
    if (toolbar && toolbar.superview) {
        return CGRectGetMinY([toolbar.superview convertRect:toolbar.frame toView:host]);
    }
    return CGRectGetHeight(host.bounds) - host.safeAreaInsets.bottom - 56.0;
}

static UIView* ComposeUndoButton(UIView* host, UIView* banner) {
    __block UIView* named = nil;
    __block CGFloat namedScore = -1;
    __block UIView* toolbar = nil;

    EnumerateSubviewsRecursively(host, ^(UIView* view) {
        if (view == banner || [view isDescendantOfView:banner]) {
            return;
        }
        if (!toolbar && [NSStringFromClass(view.class)
                            isEqualToString:@"T1TweetComposeConversationControlButton"]) {
            toolbar = view.superview.superview;
        }
        if (view.hidden || view.alpha < 0.01) {
            return;
        }
        CGRect frame = [view convertRect:view.bounds toView:host];
        if (!IsIconSized(frame) || !ViewIsUndoControl(view)) {
            return;
        }
        CGFloat score = CGRectGetMaxX(frame) + CGRectGetMaxY(frame);
        if (score > namedScore) {
            namedScore = score;
            named = view;
        }
    });
    if (named) {
        return named;
    }
    if (!toolbar) {
        return nil;
    }

    // No labelled undo control: the undo icon is the rightmost icon on that toolbar.
    __block UIView* rightmost = nil;
    __block CGFloat rightmostX = -1;
    EnumerateSubviewsRecursively(toolbar, ^(UIView* view) {
        if (view.hidden || view.alpha < 0.01 || ![view isKindOfClass:[UIControl class]]) {
            return;
        }
        CGRect frame = [view convertRect:view.bounds toView:host];
        if (!IsIconSized(frame)) {
            return;
        }
        CGFloat edge = CGRectGetMaxX(frame);
        if (edge > rightmostX) {
            rightmostX = edge;
            rightmost = view;
        }
    });
    return rightmost;
}

@interface NFBDraftBanner : UIView
@property (nonatomic, weak) UIViewController* composer;
- (void)placeAboveUndo;
@end

@implementation NFBDraftBanner

- (void)restore {
    UIViewController* composer = self.composer;
    UIView<UIKeyInput>* input = composer ? ComposeInput(composer) : nil;
    NSString* draft = SavedDraft();
    if (input && draft) {
        [input becomeFirstResponder];
        [input insertText:draft];
        objc_setAssociatedObject(composer, kDraftTouchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
    [self dismiss];
}

- (void)discard {
    ClearDraft();
    [self dismiss];
}

- (void)placeAboveUndo {
    UIView* host = self.composer.view;
    if (!host) {
        return;
    }
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width < 1 || height < 1) {
        return;
    }

    UIView* undo = ComposeUndoButton(host, self);
    CGFloat right;
    CGFloat bottom;
    if (undo) {
        CGRect frame = [undo convertRect:undo.bounds toView:host];
        right = CGRectGetMaxX(frame);
        bottom = CGRectGetMinY(frame) - 6.0;
    } else {
        right = CGRectGetWidth(host.bounds) - host.safeAreaInsets.right - 12.0;
        bottom = ComposeToolbarTop(host) - 6.0;
    }

    CGFloat minX = host.safeAreaInsets.left + 8.0;
    CGFloat x = MAX(right - width, minX);
    CGFloat maxX = CGRectGetWidth(host.bounds) - host.safeAreaInsets.right - 8.0 - width;
    if (x > maxX) {
        x = MAX(minX, maxX);
    }
    CGFloat y = MAX(bottom - height, host.safeAreaInsets.top + 4.0);
    CGRect next = CGRectMake(x, y, width, height);
    if (!CGRectEqualToRect(self.frame, next)) {
        self.frame = next;
    }
    if (host.subviews.lastObject != self) {
        [host bringSubviewToFront:self];
    }
}

- (void)keyboardMoved:(NSNotification*)note {
    (void)note;
    [self placeAboveUndo];
}

- (void)dismiss {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [UIView animateWithDuration:0.2
        animations:^{
            self.alpha = 0;
        }
        completion:^(BOOL finished) {
            [self removeFromSuperview];
        }];
}

@end

static UIButton* BannerButton(NSString* title, SEL action, id target, BOOL bold) {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:bold ? UIFontWeightBold : UIFontWeightMedium];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button sizeToFit];
    return button;
}

static void ShowBanner(UIViewController* composer) {
    if (!composer.isViewLoaded || [composer.view viewWithTag:kDraftBannerTag] || !SavedDraft()) {
        return;
    }
    UIView<UIKeyInput>* input = ComposeInput(composer);
    NSString* text = input ? TextOf(input) : nil;
    // Only on a blank box; a reply that starts with "@name " is not blank and gets no offer.
    if (!input || !IsBlank(text)) {
        return;
    }

    NFBDraftBanner* banner = [NFBDraftBanner new];
    banner.composer = composer;
    banner.tag = kDraftBannerTag;
    banner.backgroundColor = CurrentAccentColor();
    banner.layer.cornerRadius = kBannerHeight / 2;

    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIButton* restore = BannerButton([bundle localizedStringForKey:@"KEMO_DRAFT_RESTORE"],
                                     @selector(restore), banner, YES);
    UIButton* discard = BannerButton([bundle localizedStringForKey:@"KEMO_DRAFT_DISCARD"],
                                     @selector(discard), banner, NO);
    CGFloat gap = 14;
    CGFloat width = 16 + CGRectGetWidth(restore.bounds) + gap + CGRectGetWidth(discard.bounds) + 16;
    restore.frame = CGRectMake(16, 0, CGRectGetWidth(restore.bounds), kBannerHeight);
    discard.frame =
        CGRectMake(CGRectGetMaxX(restore.frame) + gap, 0, CGRectGetWidth(discard.bounds), kBannerHeight);
    [banner addSubview:restore];
    [banner addSubview:discard];
    banner.bounds = CGRectMake(0, 0, width, kBannerHeight);

    [[NSNotificationCenter defaultCenter] addObserver:banner
                                             selector:@selector(keyboardMoved:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [composer.view addSubview:banner];
    [banner placeAboveUndo];
    banner.alpha = 0;
    [UIView animateWithDuration:0.25
                     animations:^{
                         banner.alpha = 1;
                     }];
}

static void StartDrafts(UIViewController* composer) {
    if (!DraftEnabled()) {
        return;
    }
    // After the screen has settled: the text field does not exist right away.
    __weak UIViewController* weakComposer = composer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       if (weakComposer) {
                           ShowBanner(weakComposer);
                       }
                   });

    NSTimer* old = objc_getAssociatedObject(composer, kDraftTimerKey);
    [old invalidate];
    NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     repeats:YES
                                                       block:^(NSTimer* t) {
                                                           UIViewController* strong = weakComposer;
                                                           if (!strong) {
                                                               [t invalidate];
                                                               return;
                                                           }
                                                           SaveNow(strong);
                                                       }];
    objc_setAssociatedObject(composer, kDraftTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void StopDrafts(UIViewController* composer) {
    NSTimer* timer = objc_getAssociatedObject(composer, kDraftTimerKey);
    [timer invalidate];
    objc_setAssociatedObject(composer, kDraftTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SaveNow(composer);
    [[composer.view viewWithTag:kDraftBannerTag] removeFromSuperview];
}

%hook T1TweetComposeViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    StartDrafts((UIViewController*)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIView* banner = [self.view viewWithTag:kDraftBannerTag];
    if ([banner isKindOfClass:[NFBDraftBanner class]]) {
        [(NFBDraftBanner*)banner placeAboveUndo];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    StopDrafts((UIViewController*)self);
    %orig;
}

%end
