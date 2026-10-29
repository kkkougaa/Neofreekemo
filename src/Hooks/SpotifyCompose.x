//
//  SpotifyCompose.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Core/BHTSpotify.h"

// MARK: - Now playing line in the compose screen
// One line above the keyboard showing the song that's playing on Spotify; tapping it
// types the track's share link into the tweet. Only shown once Spotify is connected
// in the kemo settings. Talks to Spotify only.

static const NSInteger kBarTag = 0x4e464233;
static const CGFloat kBarHeight = 34.0;
// The compose toolbar sits between the text and the keyboard; keep clear of it.
static const CGFloat kToolbarClearance = 56.0;
static const NSTimeInterval kRefreshInterval = 8.0;

static const void* kBarKey = &kBarKey;

// Top edge of the compose toolbar (reply setting, undo, media buttons) in the compose
// view's coordinates. It is found through its reply-setting button; when that isn't
// there, a fixed clearance above the keyboard stands in.
static CGFloat ComposeToolbarTop(UIView* host, CGFloat keyboardTop) {
    __block UIView* button = nil;
    EnumerateSubviewsRecursively(host, ^(UIView* view) {
        if (!button &&
            [NSStringFromClass(view.class) isEqualToString:@"T1TweetComposeConversationControlButton"]) {
            button = view;
        }
    });
    UIView* toolbar = button.superview.superview;
    if (toolbar && toolbar.superview) {
        return CGRectGetMinY([toolbar.superview convertRect:toolbar.frame toView:host]);
    }
    CGFloat bottom = keyboardTop > 0 ? keyboardTop
                                     : CGRectGetHeight(host.bounds) - host.safeAreaInsets.bottom;
    return bottom - kToolbarClearance;
}

// The view that is receiving typing, whatever kind of text view the editor is.
static UIView<UIKeyInput>* FocusedTextInput(UIView* root) {
    if (root.isFirstResponder && [root conformsToProtocol:@protocol(UIKeyInput)]) {
        return (UIView<UIKeyInput>*)root;
    }
    for (UIView* sub in root.subviews) {
        UIView<UIKeyInput>* found = FocusedTextInput(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

@interface NFBSpotifyBar : UIControl
@property (nonatomic, copy) NSString* shareURL;
@property (nonatomic, strong) UILabel* label;
@property (nonatomic, assign) CGFloat keyboardTop; // in the compose view's coordinates, or 0
@property (nonatomic, weak) UIViewController* composer;
@property (nonatomic, strong) NSTimer* timer;
- (void)refresh;
- (void)stop;
@end

@implementation NFBSpotifyBar

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.tag = kBarTag;
        self.hidden = YES;
        self.backgroundColor = [UIColor secondarySystemFillColor];
        self.layer.cornerRadius = kBarHeight / 2;
        self.clipsToBounds = YES;

        UILabel* note = [UILabel new];
        note.text = @"♪";
        note.textColor = [UIColor colorWithRed:0.12 green:0.84 blue:0.38 alpha:1];
        note.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        note.frame = CGRectMake(12, 0, 14, kBarHeight);
        [self addSubview:note];

        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor labelColor];
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.numberOfLines = 1;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        [self addTarget:self
                      action:@selector(insertLink)
            forControlEvents:UIControlEventTouchUpInside];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(keyboardChanged:)
                                                     name:UIKeyboardWillChangeFrameNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.timer invalidate];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)keyboardChanged:(NSNotification*)note {
    UIView* host = self.composer.view;
    if (!host) {
        return;
    }
    CGRect screenFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [host convertRect:screenFrame fromView:nil];
    self.keyboardTop = CGRectIntersectsRect(local, host.bounds) ? CGRectGetMinY(local) : 0;
    [self layoutInHost];
}

- (void)layoutInHost {
    UIView* host = self.composer.view;
    if (!host) {
        return;
    }
    CGFloat maxWidth = CGRectGetWidth(host.bounds) - 32;
    CGSize textSize = [self.label sizeThatFits:CGSizeMake(maxWidth, kBarHeight)];
    CGFloat width = MIN(textSize.width + 12 + 14 + 8 + 14, maxWidth);
    self.label.frame = CGRectMake(32, 0, width - 32 - 14, kBarHeight);

    CGFloat top = ComposeToolbarTop(host, self.keyboardTop);
    self.frame = CGRectMake(16, top - 8 - kBarHeight, width, kBarHeight);
    [host bringSubviewToFront:self];
}

- (void)refresh {
    __weak NFBSpotifyBar* weakSelf = self;
    [[BHTSpotify shared]
        fetchCurrentlyPlaying:^(NSString* title, NSString* artist, NSString* shareURL,
                                NSError* error) {
            NFBSpotifyBar* bar = weakSelf;
            if (!bar) {
                return;
            }
            if (title.length == 0 || shareURL.length == 0) {
                bar.hidden = YES;
                bar.shareURL = nil;
                return;
            }
            bar.label.text = artist.length ? [NSString stringWithFormat:@"%@ – %@", title, artist]
                                           : title;
            bar.shareURL = shareURL;
            bar.hidden = NO;
            [bar layoutInHost];
        }];
}

- (void)insertLink {
    UIView<UIKeyInput>* input = FocusedTextInput(self.composer.view);
    if (!input || self.shareURL.length == 0) {
        return;
    }

    // A space first unless the cursor already follows whitespace (or the text is empty).
    BOOL needsSpace = NO;
    if ([input conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> textInput = (id<UITextInput>)input;
        UITextRange* selection = textInput.selectedTextRange;
        UITextRange* before =
            selection ? [textInput textRangeFromPosition:textInput.beginningOfDocument
                                              toPosition:selection.start]
                      : nil;
        NSString* text = before ? [textInput textInRange:before] : nil;
        needsSpace = text.length > 0 &&
                     ![[NSCharacterSet whitespaceAndNewlineCharacterSet]
                         characterIsMember:[text characterAtIndex:text.length - 1]];
    }
    [input insertText:[(needsSpace ? @" " : @"") stringByAppendingString:self.shareURL]];
    [[[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

@end

static void AttachBar(UIViewController* composer) {
    if (![BHTSpotify shared].isConnected || !composer.isViewLoaded) {
        return;
    }
    NFBSpotifyBar* bar = objc_getAssociatedObject(composer, kBarKey);
    if (!bar) {
        bar = [[NFBSpotifyBar alloc] initWithFrame:CGRectZero];
        bar.composer = composer;
        objc_setAssociatedObject(composer, kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [composer.view addSubview:bar];
        [bar refresh];
        __weak NFBSpotifyBar* weakBar = bar;
        bar.timer = [NSTimer scheduledTimerWithTimeInterval:kRefreshInterval
                                                    repeats:YES
                                                      block:^(NSTimer* timer) {
                                                          [weakBar refresh];
                                                      }];
    }
    [bar layoutInHost];
}

static void DetachBar(UIViewController* composer) {
    NFBSpotifyBar* bar = objc_getAssociatedObject(composer, kBarKey);
    [bar stop];
    [bar removeFromSuperview];
    objc_setAssociatedObject(composer, kBarKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook T1TweetComposeViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    AttachBar((UIViewController*)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    NFBSpotifyBar* bar = objc_getAssociatedObject(self, kBarKey);
    [bar layoutInHost];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    DetachBar((UIViewController*)self);
}

%end
