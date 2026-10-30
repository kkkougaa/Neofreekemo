//
//  DraftSave.x
//  NeoFreeBird
//

#import "Core/NFBFirstResponder.h"
#import "HookHelpers.h"

// MARK: - Draft autosave

// While the compose screen is open, what has been typed is saved every couple of seconds.
// If the app is closed or crashes before the tweet goes out, the next empty compose screen
// offers to bring the text back. Nothing is inserted on its own.

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

// MARK: Restore banner

@interface NFBDraftBanner : UIView
@property (nonatomic, weak) UIViewController* composer;
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

- (void)dismiss {
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
    banner.layer.cornerRadius = 18;

    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIButton* restore = BannerButton([bundle localizedStringForKey:@"KEMO_DRAFT_RESTORE"],
                                     @selector(restore), banner, YES);
    UIButton* discard = BannerButton([bundle localizedStringForKey:@"KEMO_DRAFT_DISCARD"],
                                     @selector(discard), banner, NO);
    CGFloat gap = 14;
    CGFloat width = 16 + CGRectGetWidth(restore.bounds) + gap + CGRectGetWidth(discard.bounds) + 16;
    restore.frame = CGRectMake(16, 0, CGRectGetWidth(restore.bounds), 36);
    discard.frame = CGRectMake(CGRectGetMaxX(restore.frame) + gap, 0, CGRectGetWidth(discard.bounds), 36);
    [banner addSubview:restore];
    [banner addSubview:discard];

    CGFloat top = composer.view.safeAreaInsets.top + 8;
    banner.frame = CGRectMake((CGRectGetWidth(composer.view.bounds) - width) / 2, top, width, 36);
    banner.alpha = 0;
    [composer.view addSubview:banner];
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

- (void)viewWillDisappear:(BOOL)animated {
    StopDrafts((UIViewController*)self);
    %orig;
}

%end
