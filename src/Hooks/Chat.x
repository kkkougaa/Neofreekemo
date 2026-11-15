//
//  Chat.x
//  NeoFreeBird
//
//  Hide typing indicator: XChat's own "me typing" call is skipped
//  (upstream e8159ed). Also the chat diagnostics for the shake dump, the
//  chat button tint and the screenshot protection switch.
//

#import <string.h>
#import "HookHelpers.h"

// MARK: - Diagnostics (shake dump "== CHAT ==")
//
// Records what goes over the chat socket and which DM / read / badge requests
// are made, to find out why the Chat tab can keep an unread badge. Repeated
// identical lines (the typing heartbeat, keep-alives) are collapsed with a
// count instead of filling the log.

static NSMutableArray<NSString*>* gChatLog;
static NSString* gChatLastKey;
static NSUInteger gChatLastRepeat;

void NFBChatNote(NSString* line) {
    static NSDateFormatter* formatter;
    @synchronized([NSObject class]) {
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.dateFormat = @"HH:mm:ss";
        }
        if (!gChatLog) {
            gChatLog = [NSMutableArray array];
        }
        if ([line isEqualToString:gChatLastKey] && gChatLog.count > 0) {
            gChatLastRepeat++;
            NSString* last = gChatLog.lastObject;
            NSRange mark = [last rangeOfString:@" (x" options:NSBackwardsSearch];
            if (mark.location != NSNotFound) {
                last = [last substringToIndex:mark.location];
            }
            gChatLog[gChatLog.count - 1] =
                [NSString stringWithFormat:@"%@ (x%lu)", last, (unsigned long)gChatLastRepeat + 1];
            return;
        }
        gChatLastKey = [line copy];
        gChatLastRepeat = 0;
        [gChatLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        if (gChatLog.count > 60) {
            [gChatLog removeObjectAtIndex:0];
        }
    }
}

NSString* NFBChatDebugText(void) {
    @synchronized([NSObject class]) {
        NSString* head = [NSString stringWithFormat:@"hide_typing_indicator=%d",
                                                    [BHTSettings boolForKey:@"hide_typing_indicator"]];
        return gChatLog.count ? [head stringByAppendingFormat:@"\n%@", [gChatLog componentsJoinedByString:@"\n"]]
                              : [head stringByAppendingString:@"\n(nothing recorded yet)"];
    }
}

static BOOL IsChatRelatedPath(NSString* path) {
    NSString* lower = path.lowercaseString;
    for (NSString* word in @[ @"/dm", @"dm_", @"chat", @"inbox", @"conversation", @"seen", @"unread", @"badge",
                              @"markread", @"mark_read", @"lastread", @"last_read" ]) {
        if ([lower containsString:word]) {
            return YES;
        }
    }
    return NO;
}

%hook TNLResponseInfo

- (instancetype)initWithFinalURLRequest:(NSURLRequest*)request
                            URLResponse:(NSURLResponse*)response
                                 source:(NSInteger)source
                                   data:(NSData*)data
                     temporarySavedFile:(id)temporarySavedFile {
    NSURL* url = request.URL;
    // Only kept for the shake dump: nothing to note while it is off.
    if (url && [BHTSettings boolForKey:@"kemo_shake_dump"] && IsChatRelatedPath(url.path)) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                               ? ((NSHTTPURLResponse*)response).statusCode
                               : -1;
        NSString* path = url.path.length > 90 ? [url.path substringFromIndex:url.path.length - 90] : url.path;
        NFBChatNote([NSString stringWithFormat:@"http %@ %@ -> %ld (%lu B)", request.HTTPMethod ?: @"GET", path,
                                               (long)status, (unsigned long)data.length]);
    }
    return %orig;
}

%end

// MARK: - Media request log (shake dump "== CHAT ==")
//
// Received chat pictures show "tap to retry". To see where they fail, every
// request that looks like chat media (ton.* hosts, chat / dm / attachment
// paths) is noted when it starts and when it ends, and any request at all
// that ends in an error or an HTTP error status is noted too.

static BOOL LooksLikeChatMedia(NSURL* url) {
    NSString* host = url.host.lowercaseString ?: @"";
    NSString* path = url.path.lowercaseString ?: @"";
    if ([host hasPrefix:@"ton."] || [host containsString:@"chat"]) {
        return YES;
    }
    for (NSString* word in @[ @"xchat", @"/dm", @"dm_", @"attachment", @"/ton/", @"blob", @"encrypted" ]) {
        if ([path containsString:word]) {
            return YES;
        }
    }
    return NO;
}

static NSString* ShortURL(NSURL* url) {
    NSString* path = url.path ?: @"";
    if (path.length > 70) {
        path = [@"…" stringByAppendingString:[path substringFromIndex:path.length - 70]];
    }
    return [NSString stringWithFormat:@"%@%@", url.host ?: @"?", path];
}

@interface NFBTaskWatcher : NSObject
@property (nonatomic, assign) BOOL media;
@property (nonatomic, copy) NSString* label;
@end

@implementation NFBTaskWatcher
- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
    NSURLSessionTask* task = object;
    if (task.state != NSURLSessionTaskStateCompleted) {
        return;
    }
    @try {
        [task removeObserver:self forKeyPath:@"state"];
    } @catch (__unused NSException* exception) {
    }
    NSInteger status = [task.response isKindOfClass:[NSHTTPURLResponse class]]
                           ? ((NSHTTPURLResponse*)task.response).statusCode
                           : -1;
    NSError* error = task.error;
    // Cancelled requests (scrolled away, replaced) are normal: only noted for media.
    BOOL cancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
    BOOL failed = (error && !cancelled) || status >= 400;
    if (!self.media && !failed) {
        return;
    }
    NSString* why = error ? [NSString stringWithFormat:@" err %@ %ld %@", error.domain, (long)error.code,
                                                       error.localizedDescription ?: @""]
                          : @"";
    NFBChatNote([NSString stringWithFormat:@"%@ done %@ -> %ld (%lld B)%@", self.media ? @"media" : @"req",
                                           self.label, (long)status, task.countOfBytesReceived, why]);
}
@end

static void* NFBTaskWatcherKey = &NFBTaskWatcherKey;

%hook NSURLSessionTask

- (void)resume {
    // Watching every request is only for the shake dump; with it off, requests
    // (pictures included) go out untouched.
    if ([BHTSettings boolForKey:@"kemo_shake_dump"] && self.state == NSURLSessionTaskStateSuspended &&
        !objc_getAssociatedObject(self, NFBTaskWatcherKey) &&
        ![self isKindOfClass:[NSURLSessionWebSocketTask class]]) {
        NSURL* url = (self.currentRequest ?: self.originalRequest).URL;
        if (url) {
            NFBTaskWatcher* watcher = [NFBTaskWatcher new];
            watcher.media = LooksLikeChatMedia(url);
            watcher.label = [NSString stringWithFormat:@"%@ %@", self.originalRequest.HTTPMethod ?: @"GET",
                                                       ShortURL(url)];
            if (watcher.media) {
                NFBChatNote([NSString stringWithFormat:@"media start %@ (%@)", watcher.label,
                                                       NSStringFromClass(object_getClass(self))]);
            }
            objc_setAssociatedObject(self, NFBTaskWatcherKey, watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try {
                [self addObserver:watcher forKeyPath:@"state" options:0 context:NULL];
            } @catch (__unused NSException* exception) {
            }
        }
    }
    %orig;
}

%end

// MARK: - Hide typing indicator (upstream e8159ed)

%hook Subsystem_ios_iosArm64_mainXChatConnectionManagerImpl
- (void)onMeTypingConversationId:(id)conversationID {
    if ([BHTSettings boolForKey:@"hide_typing_indicator"]) {
        NFBChatNote(@"typing indicator not sent");
        return;
    }
    %orig(conversationID);
}
%end

// MARK: - Tint chat buttons

static void nfb_applyChatScreenTint(UIView* view) {
    if ([BHTSettings boolForKey:@"tab_bar_theming"]) {
        view.tintColor = CurrentAccentColor();
    }
}

%hook TFNBarButtonItemButton
- (void)didMoveToWindow {
    %orig;
    nfb_applyChatScreenTint(self);
}
%end

// MARK: - Chat screenshot protection

static NSInteger nfb_secureEntrySuppression = 0;

static void* NFBNeutralizedCanvasKey = &NFBNeutralizedCanvasKey;

static void nfb_disableSecureCanvas(UIView* protectionView) {
    UIView* canvas = nfb_objectIvar(protectionView, "secureCanvasView");
    if (!canvas ||
        objc_getAssociatedObject(protectionView, NFBNeutralizedCanvasKey) == canvas) {
        return;
    }

    // The field is kept in a separate ivar (it has to be retained somewhere for
    // the canvas to keep working)
    UITextField* owner = nil;
    unsigned int count = 0;
    Ivar* ivars = class_copyIvarList(object_getClass(protectionView), &count);
    for (unsigned int i = 0; i < count && !owner; i++) {
        const char* type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@') {
            continue;
        }
        id value = object_getIvar(protectionView, ivars[i]);
        if ([value isKindOfClass:[UITextField class]]) {
            owner = value;
        }
    }
    free(ivars);

    if (!owner && [canvas.superview isKindOfClass:[UITextField class]]) {
        owner = (UITextField*)canvas.superview;
    }

    if (owner) {
        owner.secureTextEntry = NO;
    } else {
        for (UIView* content in [canvas.subviews copy]) {
            BOOL usesAutoLayout = !content.translatesAutoresizingMaskIntoConstraints;
            CGRect frame = [canvas convertRect:content.frame toView:protectionView];
            [protectionView addSubview:content];
            if (usesAutoLayout) {
                [NSLayoutConstraint activateConstraints:@[
                    [content.leadingAnchor constraintEqualToAnchor:protectionView.leadingAnchor],
                    [content.trailingAnchor constraintEqualToAnchor:protectionView.trailingAnchor],
                    [content.topAnchor constraintEqualToAnchor:protectionView.topAnchor],
                    [content.bottomAnchor constraintEqualToAnchor:protectionView.bottomAnchor],
                ]];
            } else {
                content.frame = frame;
                content.autoresizingMask =
                    UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            }
        }
        [canvas removeFromSuperview];
    }

    objc_setAssociatedObject(protectionView, NFBNeutralizedCanvasKey, canvas,
                             OBJC_ASSOCIATION_ASSIGN);
}

static BOOL nfb_shouldDropScreenshotProtection(UIView* protectionView) {
    if ([BHTSettings boolForKey:@"block_screenshot_detection"]) {
        return YES;
    }
    return !nfb_boolIvar(protectionView, "isProtectionEnabled", YES);
}

%hook UITextField
- (void)setSecureTextEntry:(BOOL)secure {
    if (secure && nfb_secureEntrySuppression > 0) {
        %orig(NO);
        return;
    }
    %orig;
}
%end

%hook _TtC16ChatConversation24ScreenshotProtectionView

- (void)didMoveToWindow {
    BOOL drop = nfb_shouldDropScreenshotProtection(self);
    if (drop) {
        if ([BHTSettings boolForKey:@"block_screenshot_detection"]) {
            nfb_setBoolIvar(self, "isProtectionEnabled", NO);
        }
        nfb_secureEntrySuppression++;
    }
    %orig;
    if (drop) {
        nfb_secureEntrySuppression--;
        nfb_disableSecureCanvas(self);
    }
}

- (void)layoutSubviews {
    BOOL drop = nfb_shouldDropScreenshotProtection(self);
    if (drop) {
        nfb_secureEntrySuppression++;
    }
    %orig;
    if (drop) {
        nfb_secureEntrySuppression--;
        nfb_disableSecureCanvas(self);
    }
}

%end
