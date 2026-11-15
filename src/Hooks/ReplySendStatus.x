//
//  ReplySendStatus.x
//  NeoFreeBird
//

#import "Core/TwitterChirpFont.h"
#import "HookHelpers.h"

// MARK: - Reply bar send status

// A reply sent straight from the reply bar (T1PersistentComposeViewController:
// under a post, and wherever X shows the same bar) says how it is going inside
// the bar itself, like the "Prompt box" motion study: a status line slides in
// over the text row ("Sending reply" with a shine and a pulsing dot), then a
// green dot and "Reply sent" (or a red one and "Couldn't send"), and closes.
// The send button's arrow turns into three dots while it sends. The bar keeps
// X's own Liquid Glass look; only its contents change. X's own "sent" toast is
// hidden for these replies, since the bar already said it.
//
// The study's springs, stepped the same way (semi-implicit Euler, four
// substeps a frame, frames capped at 1/30 s): status line 380 / 30, button
// 520 / 30.

@interface TNLResponseInfo : NSObject
@end

static BOOL StatusOn(void) {
    return [BHTSettings boolForKey:@"kemo_reply_status"];
}

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

typedef NS_ENUM(NSInteger, NFBSendState) {
    NFBSendWaiting,  // the send was tapped; X may still be asking to confirm
    NFBSendSending,
    NFBSendSent,
    NFBSendFailed
};

typedef struct {
    CGFloat x, v, t, k, c;
} NFBReplySpring;

static NFBReplySpring ReplySpring(CGFloat k, CGFloat c) {
    NFBReplySpring s = {0, 0, 0, k, UIAccessibilityIsReduceMotionEnabled() ? 2 * sqrt(k) : c};
    return s;
}

static void ReplySpringStep(NFBReplySpring* s, CGFloat dt) {
    CGFloat a = -s->k * (s->x - s->t) - s->c * s->v;
    s->v += a * dt;
    s->x += s->v * dt;
}

static UITextView* FindTextView(UIView* root) {
    __block UITextView* found = nil;
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if (!found && [view isKindOfClass:[UITextView class]] && !view.hidden) {
            found = (UITextView*)view;
        }
    });
    return found;
}

// The send button: the visible button furthest to the trailing side of the bar.
static UIButton* FindSendButton(UIView* root) {
    __block UIButton* best = nil;
    __block CGFloat bestX = -CGFLOAT_MAX;
    BOOL rtl = root.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if (![view isKindOfClass:[UIButton class]] || view.hidden || view.alpha < 0.05 || !view.window) {
            return;
        }
        CGRect frame = [view convertRect:view.bounds toView:root];
        if (CGRectGetWidth(frame) > 80 || CGRectGetHeight(frame) > 80) {
            return;
        }
        CGFloat x = rtl ? -CGRectGetMinX(frame) : CGRectGetMaxX(frame);
        if (x > bestX) {
            bestX = x;
            best = (UIButton*)view;
        }
    });
    return best;
}

// MARK: Status line

@interface NFBReplyStatus : NSObject
@property (nonatomic, weak) UIView* host;  // the reply bar or the quick composer
@property (nonatomic, weak) UITextView* textView;
@property (nonatomic, weak) UIButton* sendButton;
@property (nonatomic, strong) UIView* line;
@property (nonatomic, strong) UIView* dot;
@property (nonatomic, strong) UILabel* label;
@property (nonatomic, strong) CAGradientLayer* shine;
@property (nonatomic, strong) UIView* dots;
@property (nonatomic, strong) CADisplayLink* link;
@property (nonatomic, assign) CFTimeInterval lastTime;
@property (nonatomic, assign) NFBSendState state;
@property (nonatomic, strong) NSDate* tappedAt;
@property (nonatomic, assign) NSInteger generation;
@end

@interface NFBReplyTicker : NSObject
@property (nonatomic, copy) void (^block)(CADisplayLink* link);
@end

@implementation NFBReplyTicker
- (void)fire:(CADisplayLink*)link {
    if (self.block) {
        self.block(link);
    }
}
@end

static NFBReplyStatus* gReplyStatus;
static NSDate* gHideToastUntil;

@implementation NFBReplyStatus {
    NFBReplySpring _open;    // status line, 0 closed, 1 open
    NFBReplySpring _button;  // 0 arrow, 1 dots
}

- (instancetype)initWithHost:(UIView*)host {
    if ((self = [super init])) {
        _host = host;
        _open = ReplySpring(380, 30);
        _button = ReplySpring(520, 30);
        _state = NFBSendWaiting;
        _tappedAt = [NSDate date];
    }
    return self;
}

- (void)buildIfNeeded {
    UITextView* textView = self.textView;
    if (self.line || !textView.superview) {
        return;
    }
    self.line = [[UIView alloc] initWithFrame:textView.frame];
    self.line.userInteractionEnabled = NO;
    self.line.clipsToBounds = YES;
    self.line.alpha = 0;
    [textView.superview insertSubview:self.line aboveSubview:textView];

    self.dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
    self.dot.layer.cornerRadius = 4;
    [self.line addSubview:self.dot];

    self.label = [UILabel new];
    self.label.font = TwitterChirpFont(TwitterFontStyleSemibold);
    self.label.textColor = textView.textColor ?: UIColor.labelColor;
    self.label.adjustsFontForContentSizeCategory = NO;
    [self.line addSubview:self.label];

    // The shine running across "Sending reply".
    self.shine = [CAGradientLayer layer];
    self.shine.startPoint = CGPointMake(0, 0.5);
    self.shine.endPoint = CGPointMake(1, 0.5);
    self.shine.colors = @[
        (id)[UIColor colorWithWhite:1 alpha:0.45].CGColor, (id)UIColor.whiteColor.CGColor,
        (id)[UIColor colorWithWhite:1 alpha:0.45].CGColor
    ];
    self.shine.locations = @[ @0.2, @0.5, @0.8 ];

    UIButton* send = self.sendButton;
    if (send) {
        self.dots = [[UIView alloc] initWithFrame:send.bounds];
        self.dots.userInteractionEnabled = NO;
        UIColor* color = send.tintColor ?: UIColor.whiteColor;
        for (NSInteger i = 0; i < 3; i++) {
            UIView* d = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4, 4)];
            d.layer.cornerRadius = 2;
            d.backgroundColor = color;
            d.center = CGPointMake(CGRectGetMidX(send.bounds) + (i - 1) * 7, CGRectGetMidY(send.bounds));
            [self.dots addSubview:d];
        }
        self.dots.transform = CGAffineTransformMakeScale(0.001, 0.001);
        [send addSubview:self.dots];
    }
}

- (void)layoutLine {
    UITextView* textView = self.textView;
    if (!textView) {
        return;
    }
    self.line.frame = textView.frame;
    CGFloat height = CGRectGetHeight(self.line.bounds);
    CGFloat inset = textView.textContainerInset.left + textView.textContainer.lineFragmentPadding;
    BOOL rtl = textView.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    [self.label sizeToFit];
    CGFloat width = CGRectGetWidth(self.line.bounds);
    CGFloat labelWidth = MIN(CGRectGetWidth(self.label.bounds), width - inset - 16);
    CGFloat dotX = rtl ? width - inset - 8 : inset;
    CGFloat labelX = rtl ? dotX - 8 - labelWidth : dotX + 16;
    // Slides up into place as it opens.
    CGFloat slide = (1 - MIN(1, MAX(0, _open.x))) * 10;
    self.dot.center = CGPointMake(dotX + 4, height / 2 + slide);
    self.label.frame = CGRectMake(labelX, (height - CGRectGetHeight(self.label.bounds)) / 2 + slide, labelWidth,
                                  CGRectGetHeight(self.label.bounds));
    self.shine.frame = self.label.bounds;
}

- (void)say:(NFBSendState)state {
    self.state = state;
    [self buildIfNeeded];
    [self.dot.layer removeAllAnimations];
    [self.shine removeAllAnimations];
    self.label.layer.mask = nil;
    switch (state) {
        case NFBSendWaiting:
            return;
        case NFBSendSending: {
            self.label.text = L(@"KEMO_REPLY_SENDING");
            self.dot.backgroundColor = CurrentAccentColor();
            CABasicAnimation* pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            pulse.fromValue = @1;
            pulse.toValue = @0.55;
            pulse.duration = 0.5;
            pulse.autoreverses = YES;
            pulse.repeatCount = HUGE_VALF;
            pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            if (!UIAccessibilityIsReduceMotionEnabled()) {
                [self.dot.layer addAnimation:pulse forKey:@"pulse"];
                CABasicAnimation* run = [CABasicAnimation animationWithKeyPath:@"locations"];
                run.fromValue = @[ @-0.6, @-0.3, @0.0 ];
                run.toValue = @[ @1.0, @1.3, @1.6 ];
                run.duration = 1.4;
                run.repeatCount = HUGE_VALF;
                [self.shine addAnimation:run forKey:@"shine"];
                self.label.layer.mask = self.shine;
            }
            _open.t = 1;
            _button.t = 1;
            // No answer from X (an undo-send that was undone, say): close quietly.
            NSInteger generation = ++self.generation;
            CGFloat wait = 12 + MAX(0, [BHTSettings integerForKey:@"undo_tweet_timeout"]);
            __weak NFBReplyStatus* weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NFBReplyStatus* status = weakSelf;
                if (status && status.generation == generation && status.state == NFBSendSending) {
                    status->_open.t = 0;
                    status->_button.t = 0;
                    [status wake];
                }
            });
            break;
        }
        case NFBSendSent:
        case NFBSendFailed: {
            BOOL sent = state == NFBSendSent;
            self.label.text = L(sent ? @"KEMO_REPLY_SENT" : @"KEMO_REPLY_FAILED");
            self.dot.backgroundColor = sent ? [UIColor colorWithRed:0 green:0.729 blue:0.486 alpha:1]
                                             : [UIColor colorWithRed:0.957 green:0.129 blue:0.18 alpha:1];
            _open.t = 1;
            _button.t = 0;
            NSInteger generation = ++self.generation;
            __weak NFBReplyStatus* weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((sent ? 1.6 : 2.4) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               NFBReplyStatus* status = weakSelf;
                               if (status && status.generation == generation) {
                                   status->_open.t = 0;
                                   [status wake];
                               }
                           });
            break;
        }
    }
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.label.text);
    [self wake];
}

- (void)wake {
    if (!self.link) {
        __weak NFBReplyStatus* weakSelf = self;
        NFBReplyTicker* ticker = [NFBReplyTicker new];
        ticker.block = ^(CADisplayLink* link) {
            [weakSelf tick:link];
        };
        self.link = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(fire:)];
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        self.lastTime = 0;
    }
    self.link.paused = NO;
}

- (void)tick:(CADisplayLink*)link {
    // The bar went away (or was rebuilt): put everything back at once.
    if (!self.textView.window || !self.host.window) {
        [self finish];
        return;
    }
    CFTimeInterval now = link.timestamp;
    CGFloat dt = self.lastTime > 0 ? MIN(now - self.lastTime, 1.0 / 30) : 1.0 / 60;
    self.lastTime = now;
    for (int i = 0; i < 4; i++) {
        ReplySpringStep(&_open, dt / 4);
        ReplySpringStep(&_button, dt / 4);
    }

    CGFloat open = MIN(1, MAX(0, _open.x));
    CGFloat m = MIN(1.2, MAX(0, _button.x));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self layoutLine];
    self.line.alpha = open;
    self.textView.alpha = 1 - open;
    UIButton* send = self.sendButton;
    send.imageView.transform =
        CGAffineTransformRotate(CGAffineTransformMakeScale(MAX(0.001, 1 - m), MAX(0.001, 1 - m)), m * M_PI_2);
    self.dots.transform = CGAffineTransformMakeScale(MAX(0.001, m), MAX(0.001, m));
    [CATransaction commit];

    BOOL settled = fabs(_open.x - _open.t) < 0.002 && fabs(_open.v) < 0.01 && fabs(_button.x - _button.t) < 0.002 &&
                   fabs(_button.v) < 0.01;
    if (settled) {
        link.paused = YES;
        self.lastTime = 0;
        if (_open.t == 0 && _button.t == 0) {
            [self finish];
        }
    }
}

- (void)finish {
    [self.link invalidate];
    self.link = nil;
    self.textView.alpha = 1;
    self.sendButton.imageView.transform = CGAffineTransformIdentity;
    [self.dots removeFromSuperview];
    [self.line removeFromSuperview];
    if (gReplyStatus == self) {
        gReplyStatus = nil;
    }
}

- (void)dealloc {
    [_link invalidate];
    _textView.alpha = 1;
    _sendButton.imageView.transform = CGAffineTransformIdentity;
    [_dots removeFromSuperview];
    [_line removeFromSuperview];
}

@end

// MARK: Hiding X's own "sent" toast

static BOOL IsSentToastText(NSString* text) {
    if (text.length == 0) {
        return NO;
    }
    static NSArray<NSString*>* known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray* list = [NSMutableArray array];
        NSString* key = @"COMPOSITION_COMPLETE_SENDING_TWEET_TOAST_NOTIFICATION_MESSAGE";
        NSString* x = [[NSBundle mainBundle] localizedStringForKey:key value:@"" table:nil];
        if (x.length > 0 && ![x isEqualToString:key]) {
            [list addObject:x];
        }
        NSString* ours = L(key);
        if (ours.length > 0 && ![ours isEqualToString:key]) {
            [list addObject:ours];
        }
        known = list;
    });
    return [known containsObject:text];
}

static void HideSentToasts(void) {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            EnumerateSubviewsRecursively(window, ^(UIView* view) {
                if (![view isKindOfClass:[UILabel class]] || view.hidden ||
                    !IsSentToastText(((UILabel*)view).text)) {
                    return;
                }
                // The toast: the largest ancestor that is still toast-sized.
                UIView* toast = view;
                while (toast.superview && toast.superview != window &&
                       CGRectGetHeight(toast.superview.bounds) < 160) {
                    toast = toast.superview;
                }
                // Only faded out for a moment: X may reuse the same view for its next toast.
                if (toast.alpha > 0.01) {
                    CGFloat alpha = toast.alpha;
                    toast.alpha = 0;
                    __weak UIView* weakToast = toast;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                       if (weakToast.alpha < 0.01) {
                                           weakToast.alpha = alpha;
                                       }
                                   });
                }
            });
        }
    }
}

static void HideSentToastsSoon(void) {
    gHideToastUntil = [NSDate dateWithTimeIntervalSinceNow:4];
    for (NSNumber* delay in @[ @0.0, @0.15, @0.4, @0.8, @1.5, @2.5 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (gHideToastUntil && [gHideToastUntil timeIntervalSinceNow] > 0) {
                               HideSentToasts();
                           }
                       });
    }
}

// MARK: Hooks

// The bar is waiting on X (maybe a confirmation, or undo-send); once its text
// empties the reply is on its way.
static void WatchForSending(NFBReplyStatus* status) {
    if (status != gReplyStatus || status.state != NFBSendWaiting) {
        return;
    }
    if ([status.tappedAt timeIntervalSinceNow] < -60) {
        gReplyStatus = nil;
        return;
    }
    UITextView* textView = status.textView;
    if (textView && textView.text.length == 0) {
        [status say:NFBSendSending];
        return;
    }
    __weak NFBReplyStatus* weakStatus = status;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NFBReplyStatus* again = weakStatus;
        if (again) {
            WatchForSending(again);
        }
    });
}

%hook T1PersistentComposeViewController

- (void)_t1_sendReply {
    UIViewController* bar = (UIViewController*)self;
    UITextView* textView = StatusOn() ? FindTextView(bar.view) : nil;
    if (!textView || textView.text.length == 0) {
        return %orig;
    }
    [gReplyStatus finish];
    NFBReplyStatus* status = [[NFBReplyStatus alloc] initWithHost:bar.view];
    status.textView = textView;
    status.sendButton = FindSendButton(bar.view);
    gReplyStatus = status;
    %orig;
    WatchForSending(status);
}

%end

static BOOL IsCreateTweet(NSURLRequest* request) {
    NSString* path = request.URL.path;
    return [path hasSuffix:@"/CreateTweet"] || [path hasSuffix:@"/CreateNoteTweet"] ||
           [path hasSuffix:@"/statuses/update.json"];
}

static BOOL ResponseSucceeded(NSURLResponse* response, NSData* data) {
    NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse*)response).statusCode : -1;
    if (code < 200 || code >= 300 || data.length == 0) {
        return NO;
    }
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return YES;  // 2xx without a body we can read: X took it
    }
    NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [text containsString:@"\"rest_id\""] || json[@"id_str"] != nil || json[@"errors"] == nil;
}

%hook TNLResponseInfo

- (instancetype)initWithFinalURLRequest:(NSURLRequest*)request
                            URLResponse:(NSURLResponse*)response
                                 source:(NSInteger)source
                                   data:(NSData*)data
                     temporarySavedFile:(id)temporarySavedFile {
    if (gReplyStatus && request && IsCreateTweet(request)) {
        BOOL ok = ResponseSucceeded(response, data);
        dispatch_async(dispatch_get_main_queue(), ^{
            NFBReplyStatus* status = gReplyStatus;
            if (!status || status.state == NFBSendSent || status.state == NFBSendFailed) {
                return;
            }
            [status say:ok ? NFBSendSent : NFBSendFailed];
            if (ok) {
                HideSentToastsSoon();
            }
        });
    }
    return %orig;
}

%end

// X's toast may only get its text after it is on screen.
%hook UILabel

- (void)setText:(NSString*)text {
    %orig;
    if (gHideToastUntil && [gHideToastUntil timeIntervalSinceNow] > 0 && IsSentToastText(text)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            HideSentToasts();
        });
    }
}

%end

// MARK: Quick composer (the post box next to the + button)

// X clears the box itself when it sends, which posts no text-change
// notification, so a send is recognised as: a post request starts while the
// box that was just typed in is now empty.

@interface _TtC13QuickComposer21QuickComposerSlotView : UIView
@end

static __weak UIView* gQuickSlot;
static __weak UITextView* gQuickTextView;
static NSDate* gQuickTypedAt;

static void BeginQuickSend(void) {
    UIView* slot = gQuickSlot;
    UITextView* textView = gQuickTextView;
    if (!StatusOn() || !slot.window || !textView.window || textView.text.length > 0) {
        return;
    }
    if (!gQuickTypedAt || [gQuickTypedAt timeIntervalSinceNow] < -120) {
        return;
    }
    if (gReplyStatus && gReplyStatus.state != NFBSendSent && gReplyStatus.state != NFBSendFailed) {
        return;  // the reply bar already owns this send
    }
    gQuickTypedAt = nil;
    [gReplyStatus finish];
    NFBReplyStatus* status = [[NFBReplyStatus alloc] initWithHost:slot];
    status.textView = textView;
    status.sendButton = FindSendButton(slot);
    gReplyStatus = status;
    [status say:NFBSendSending];
}

%hook _TtC13QuickComposer21QuickComposerSlotView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        gQuickSlot = self;
    }
}

%end

%hook NSURLSessionTask

- (void)resume {
    NSURLRequest* request = self.currentRequest ?: self.originalRequest;
    if (self.state == NSURLSessionTaskStateSuspended && request && IsCreateTweet(request) && gQuickTypedAt) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BeginQuickSend();
            // X may empty the box a moment after the request starts.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               BeginQuickSend();
                           });
        });
    }
    %orig;
}

%end

%ctor {
    %init;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UITextViewTextDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
                    UITextView* textView = note.object;
                    UIView* slot = gQuickSlot;
                    if (!slot || ![textView isKindOfClass:[UITextView class]] || ![textView isDescendantOfView:slot]) {
                        return;
                    }
                    gQuickTextView = textView;
                    gQuickTypedAt = textView.text.length > 0 ? [NSDate date] : nil;
                }];
}
