//
//  HashtagCompose.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Core/BHTHashtags.h"
#import "Core/BHTSpotify.h"

// MARK: - Favorite hashtags in the compose screen
// While a "#tag" is being typed, a strip above the compose toolbar offers the favorite
// hashtags (kemo settings) that match it, first in the list. Tapping one finishes the
// tag. The editor is polled through the UITextInput protocol, so it doesn't matter
// what kind of text view X uses. Nothing is sent anywhere.

static const CGFloat kStripHeight = 34.0;
static const CGFloat kToolbarClearance = 56.0; // fallback when the toolbar can't be found
static const CGFloat kSpotifyLift = 42.0;      // room for the Spotify line, when shown
static const NSUInteger kMaxChips = 6;

static const void* kStripKey = &kStripKey;

// Top edge of the compose toolbar in the compose view's coordinates.
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

static UIView<UITextInput>* FocusedTextInput(UIView* root) {
    if (root.isFirstResponder && [root conformsToProtocol:@protocol(UITextInput)]) {
        return (UIView<UITextInput>*)root;
    }
    for (UIView* sub in root.subviews) {
        UIView<UITextInput>* found = FocusedTextInput(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

// The "#tag" being typed right at the cursor, if there is one.
static NSString* TagBeingTyped(id<UITextInput> input) {
    UITextRange* selection = input.selectedTextRange;
    if (!selection || !selection.isEmpty) {
        return nil;
    }
    UITextRange* beforeCursor = [input textRangeFromPosition:input.beginningOfDocument
                                                  toPosition:selection.start];
    NSString* text = beforeCursor ? [input textInRange:beforeCursor] : nil;
    if (text.length == 0) {
        return nil;
    }

    NSCharacterSet* spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSInteger start = -1;
    for (NSInteger i = (NSInteger)text.length; i > 0; i--) {
        unichar c = [text characterAtIndex:i - 1];
        if (c == '#' || c == 0xFF03) { // # or ＃
            start = i - 1;
            break;
        }
        if ([spaces characterIsMember:c]) {
            return nil;
        }
    }
    if (start < 0) {
        return nil;
    }
    if (start > 0 && ![spaces characterIsMember:[text characterAtIndex:start - 1]]) {
        return nil; // "abc#x" isn't a hashtag
    }

    NSString* typed = [text substringFromIndex:start];
    return [[typed substringFromIndex:1] containsString:@"#"] ? nil : typed;
}

@interface NFBHashtagStrip : UIView
@property (nonatomic, weak) UIViewController* composer;
@property (nonatomic, strong) UIScrollView* scroll;
@property (nonatomic, assign) CGFloat keyboardTop; // compose view coordinates, or 0
@property (nonatomic, strong) NSTimer* timer;
@property (nonatomic, copy) NSString* shownKey; // what the chips were last built for
- (void)update;
- (void)stop;
- (void)layoutInHost;
@end

@implementation NFBHashtagStrip

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.hidden = YES;
        _scroll = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scroll.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scroll.showsHorizontalScrollIndicator = NO;
        [self addSubview:_scroll];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(keyboardChanged:)
                                                     name:UIKeyboardWillChangeFrameNotification
                                                   object:nil];
        __weak NFBHashtagStrip* weakSelf = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                 repeats:YES
                                                   block:^(NSTimer* timer) {
                                                       [weakSelf update];
                                                   }];
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
    CGFloat top = ComposeToolbarTop(host, self.keyboardTop);
    CGFloat lift = [BHTSpotify shared].isConnected ? kSpotifyLift : 0;
    self.frame = CGRectMake(16, top - 8 - lift - kStripHeight, CGRectGetWidth(host.bounds) - 32,
                            kStripHeight);
    [host bringSubviewToFront:self];
}

- (void)update {
    UIView* host = self.composer.view;
    UIView<UITextInput>* input = host ? FocusedTextInput(host) : nil;
    NSString* typed = input ? TagBeingTyped(input) : nil;
    if (!typed) {
        self.hidden = YES;
        self.shownKey = nil;
        return;
    }

    NSString* prefix = [typed substringFromIndex:1].lowercaseString;
    NSMutableArray<NSString*>* matches = [NSMutableArray array];
    for (NSString* tag in [BHTHashtags favorites]) {
        NSString* body = [tag substringFromIndex:1].lowercaseString;
        if ([body hasPrefix:prefix] && ![body isEqualToString:prefix]) {
            [matches addObject:tag];
        }
    }
    if (matches.count == 0) {
        self.hidden = YES;
        self.shownKey = nil;
        return;
    }
    if (matches.count > kMaxChips) {
        [matches removeObjectsInRange:NSMakeRange(kMaxChips, matches.count - kMaxChips)];
    }

    // Rebuilding the chips every tick would eat taps in flight; only do it on change.
    NSString* key = [[matches componentsJoinedByString:@","] stringByAppendingString:typed];
    if (![key isEqualToString:self.shownKey]) {
        self.shownKey = key;
        for (UIView* old in [self.scroll.subviews copy]) {
            [old removeFromSuperview];
        }
        CGFloat x = 0;
        for (NSString* tag in matches) {
            UIButton* chip = [UIButton buttonWithType:UIButtonTypeSystem];
            [chip setTitle:tag forState:UIControlStateNormal];
            [chip setTitleColor:CurrentAccentColor() forState:UIControlStateNormal];
            chip.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            chip.backgroundColor = [UIColor secondarySystemFillColor];
            chip.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
            chip.layer.cornerRadius = kStripHeight / 2;
            [chip sizeToFit];
            chip.frame = CGRectMake(x, 0, CGRectGetWidth(chip.frame), kStripHeight);
            [chip addTarget:self
                          action:@selector(chipTapped:)
                forControlEvents:UIControlEventTouchUpInside];
            [self.scroll addSubview:chip];
            x += CGRectGetWidth(chip.frame) + 8;
        }
        self.scroll.contentSize = CGSizeMake(MAX(x - 8, 0), kStripHeight);
    }
    self.hidden = NO;
    [self layoutInHost];
}

- (void)chipTapped:(UIButton*)chip {
    NSString* tag = [chip titleForState:UIControlStateNormal];
    UIView<UITextInput>* input = FocusedTextInput(self.composer.view);
    NSString* typed = input ? TagBeingTyped(input) : nil;
    if (tag.length == 0 || !typed) {
        return;
    }

    UITextRange* selection = input.selectedTextRange;
    UITextPosition* tokenStart = [input positionFromPosition:selection.start
                                                      offset:-(NSInteger)typed.length];
    UITextRange* tokenRange = tokenStart ? [input textRangeFromPosition:tokenStart
                                                             toPosition:selection.start]
                                         : nil;
    if (!tokenRange) {
        return;
    }
    [input replaceRange:tokenRange withText:[tag stringByAppendingString:@" "]];
    [[[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    self.hidden = YES;
    self.shownKey = nil;
}

@end

static void AttachStrip(UIViewController* composer) {
    if (!composer.isViewLoaded || objc_getAssociatedObject(composer, kStripKey)) {
        return;
    }
    NFBHashtagStrip* strip = [[NFBHashtagStrip alloc] initWithFrame:CGRectZero];
    strip.composer = composer;
    objc_setAssociatedObject(composer, kStripKey, strip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [composer.view addSubview:strip];
}

static void DetachStrip(UIViewController* composer) {
    NFBHashtagStrip* strip = objc_getAssociatedObject(composer, kStripKey);
    [strip stop];
    [strip removeFromSuperview];
    objc_setAssociatedObject(composer, kStripKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook T1TweetComposeViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    AttachStrip((UIViewController*)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    NFBHashtagStrip* strip = objc_getAssociatedObject(self, kStripKey);
    if (!strip.hidden) {
        [strip layoutInHost];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    DetachStrip((UIViewController*)self);
}

%end
