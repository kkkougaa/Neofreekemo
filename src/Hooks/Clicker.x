//
//  Clicker.x
//  NeoFreeBird
//

#import <UIKit/UIGestureRecognizerSubclass.h>
#import "HookHelpers.h"
#import "Core/NFBClickerStore.h"

// MARK: - Clicker
//
// A BUG Clicker character sitting on the home timeline. The character page is the desktop
// app's own pet.html with its scripts (BHTwitter.bundle/Clicker), shown in a transparent
// WKWebView; ios-bridge.js stands in for the Electron preload and talks to this file the way
// the desktop main process would. Only the parts of the character window that make sense in X
// are answered: data, the hit mask, dragging and line sounds. Menus, capture, reminders and the
// desktop music and typing listeners are left out.
//
// The character rides on X's quick composer bar ("What's happening?" above the tab bar). The
// host view lives in the bar's window, just above the window subview that holds the bar, so
// modals still cover it. A display link copies the bar's on-screen frame and visibility every
// frame: when the bar slides, fades or shrinks away on scroll the character goes with it.
// In free mode the character stands at a fixed spot instead, still only while the bar is up.
//
// While a post is being written the character moves onto the composer's toolbar (the row with
// the photo, camera and GIF buttons, TCRComposerToolbarView) the same way, and nods along with
// typing there, as the desktop app does with the keyboard.
//
// Characters brought in from a .cvclk (NFBClickerStore) are opened in the page by the desktop
// importer itself (ios-import.js); this side only hands over the original, still locked file.

static NSString* const kClickerOn = @"kemo_clicker";
static NSString* const kClickerFree = @"kemo_clicker_free";
static NSString* const kClickerSize = @"kemo_clicker_size";
static NSString* const kClickerBarX = @"kemo_clicker_bar_x";
static NSString* const kClickerBarY = @"kemo_clicker_bar_y";
static NSString* const kClickerFreeX = @"kemo_clicker_free_x";
static NSString* const kClickerFreeY = @"kemo_clicker_free_y";
static NSString* const kClickerFlip = @"kemo_clicker_flip";
static NSString* const kClickerLock = @"kemo_clicker_lock";
static NSString* const kClickerSound = @"kemo_clicker_sound";
static NSString* const kClickerCompose = @"kemo_clicker_compose";
static NSString* const kClickerComposeX = @"kemo_clicker_compose_x";
static NSString* const kClickerComposeY = @"kemo_clicker_compose_y";
static NSString* const kClickerTyping = @"kemo_clicker_typing";

typedef struct {
    BOOL on, free, flip, lock, sound, compose, typing;
    NSInteger size, barX, barY, freeX, freeY, composeX, composeY, charIndex;
} ClickerPrefs;

static ClickerPrefs gPrefs;
// The chosen .cvclk (NFBClickerStore), "" for the built-in character. Kept out of the struct.
static NSString* gCharEntry = @"";
// Whether the character is on the composer toolbar right now (else on the home bar).
static BOOL gOnCompose;

static ClickerPrefs ReadClickerPrefs(void) {
    ClickerPrefs p;
    p.on = [BHTSettings boolForKey:kClickerOn];
    p.free = [BHTSettings boolForKey:kClickerFree];
    p.flip = [BHTSettings boolForKey:kClickerFlip];
    p.lock = [BHTSettings boolForKey:kClickerLock];
    p.sound = [BHTSettings boolForKey:kClickerSound];
    p.size = MAX(48, MIN(320, [BHTSettings integerForKey:kClickerSize]));
    p.barX = [BHTSettings integerForKey:kClickerBarX];
    p.barY = [BHTSettings integerForKey:kClickerBarY];
    p.freeX = [BHTSettings integerForKey:kClickerFreeX];
    p.freeY = [BHTSettings integerForKey:kClickerFreeY];
    p.compose = [BHTSettings boolForKey:kClickerCompose];
    p.typing = [BHTSettings boolForKey:kClickerTyping];
    p.composeX = [BHTSettings integerForKey:kClickerComposeX];
    p.composeY = [BHTSettings integerForKey:kClickerComposeY];
    p.charIndex = [NFBClickerStore selectedIndex];
    return p;
}

// MARK: - Geometry

// The desktop window is the character square with room around it for the speech bubble
// (above), ears and tails (sides) and the drag shadow (below). Same shape, phone-sized pads.
typedef struct {
    CGFloat size, side, zone, bottom, width, height;
} ClickerGeom;

static ClickerGeom ClickerGeometry(NSInteger size) {
    ClickerGeom g;
    g.size = size;
    g.side = MAX(100, round(size * 0.9));
    g.zone = MAX(140, round(size * 0.8));
    g.bottom = MAX(40, round(size * 0.3));
    g.width = g.size + g.side * 2;
    g.height = g.size + g.zone + g.bottom;
    return g;
}

// MARK: - Files

static NSURL* ClickerDir(void) {
    static NSURL* dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [[BHTBundle sharedBundle] pathForFile:@"Clicker"];
    });
    return dir;
}

static NSString* SniffMime(NSData* d, NSString* ext) {
    const uint8_t* b = d.bytes;
    NSUInteger n = d.length;
    if (n >= 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') {
        return @"image/png";
    }
    if (n >= 3 && b[0] == 0xFF && b[1] == 0xD8) {
        return @"image/jpeg";
    }
    if (n >= 12 && memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "WEBP", 4) == 0) {
        return @"image/webp";
    }
    if (n >= 6 && memcmp(b, "GIF8", 4) == 0) {
        return @"image/gif";
    }
    NSDictionary* byExt = @{
        @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"webp": @"image/webp",
        @"gif": @"image/gif", @"wav": @"audio/wav", @"mp3": @"audio/mpeg", @"ogg": @"audio/ogg",
        @"m4a": @"audio/mp4", @"ttf": @"font/ttf", @"otf": @"font/otf", @"woff": @"font/woff",
        @"woff2": @"font/woff2"
    };
    return byExt[ext.lowercaseString];
}

// A file next to character.json as a data: URL, as the desktop characters.js does. Names
// with a path in them are refused; web and data URLs pass through.
static NSString* ClickerFileURL(NSURL* charDir, id name, NSUInteger maxBytes) {
    if (![name isKindOfClass:[NSString class]] || [name length] == 0) {
        return @"";
    }
    NSString* s = name;
    if ([s hasPrefix:@"data:"] || [s hasPrefix:@"https:"] || [s hasPrefix:@"http:"]) {
        return s;
    }
    if ([s containsString:@"/"] || [s containsString:@"\\"] || [s hasPrefix:@"."]) {
        return @"";
    }
    // .bcp is the desktop app's lock for one PC; it never opens here.
    if ([s.pathExtension.lowercaseString isEqualToString:@"bcp"]) {
        return @"";
    }
    NSData* d = [NSData dataWithContentsOfURL:[charDir URLByAppendingPathComponent:s]];
    if (d.length == 0 || d.length > maxBytes) {
        return @"";
    }
    NSString* mime = SniffMime(d, s.pathExtension);
    if (!mime) {
        return @"";
    }
    return [NSString stringWithFormat:@"data:%@;base64,%@", mime, [d base64EncodedStringWithOptions:0]];
}

static NSArray<NSString*>* ClickerSlots(void) {
    static NSArray* slots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray* a = [@[
            @"back1", @"back2", @"head1", @"head2", @"head3", @"head4", @"head5", @"body", @"body2", @"side1",
            @"side2"
        ] mutableCopy];
        for (int i = 1; i <= 4; i++) {
            [a addObject:[NSString stringWithFormat:@"ex%d", i]];
            [a addObject:[NSString stringWithFormat:@"ex%dp", i]];
        }
        for (NSString* top in @[@"partTop", @"partTop2", @"partTop3"]) {
            [a addObjectsFromArray:@[top, [top stringByAppendingString:@"Blink"], [top stringByAppendingString:@"Sh"]]];
        }
        [a addObjectsFromArray:@[@"bbTL", @"bbTR", @"bbBL", @"bbBR", @"bbSkin", @"petImg1", @"petImg2", @"petImg3"]];
        slots = [a copy];
    });
    return slots;
}

static NSURL* ClickerCharDir(NSString* charId) {
    return [ClickerDir() URLByAppendingPathComponent:[@"assets/characters" stringByAppendingPathComponent:charId]];
}

// characters.js resolve(): the character plus a <slot>Url for every picture.
static NSDictionary* ClickerCharacter(NSString* charId) {
    NSURL* dir = ClickerCharDir(charId);
    NSData* json = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"character.json"]];
    NSDictionary* c = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    if (![c isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSUInteger maxImage = 8 * 1024 * 1024;
    NSMutableDictionary* out = [c mutableCopy];
    out[@"id"] = charId;
    for (NSString* slot in ClickerSlots()) {
        out[[slot stringByAppendingString:@"Url"]] = ClickerFileURL(dir, c[slot], maxImage);
    }
    out[@"soundUrl"] = ClickerFileURL(dir, c[@"soundFile"], 2 * 1024 * 1024);
    out[@"fontUrl"] = ClickerFileURL(dir, c[@"fontFile"], 12 * 1024 * 1024);
    NSMutableArray* rig = [NSMutableArray array];
    BOOL ear = NO;
    if ([c[@"rig"] isKindOfClass:[NSArray class]]) {
        for (id part in c[@"rig"]) {
            if (![part isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSMutableDictionary* p = [part mutableCopy];
            p[@"url"] = ClickerFileURL(dir, part[@"img"], maxImage);
            [rig addObject:p];
            ear = ear || [part[@"kind"] isEqual:@"ear"];
        }
    }
    out[@"rig"] = rig;
    out[@"head1EdgeUrl"] = ear ? out[@"head1Url"] : @"";
    return out;
}

static NSString* ClickerJSON(id obj) {
    if (!obj || obj == [NSNull null]) {
        return @"null";
    }
    NSData* d = [NSJSONSerialization dataWithJSONObject:@[obj] options:0 error:nil];
    NSString* s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    // Wrapped in an array so plain strings and numbers serialize too; strip the brackets.
    return s.length >= 2 ? [s substringWithRange:NSMakeRange(1, s.length - 2)] : @"null";
}

// MARK: - Touch tracker

// Watches the finger in window coordinates without taking part: it never recognizes, so the
// page still gets every touch. The desktop main process reads the cursor the same way while
// pet.js drags.
@interface NFBClickerTouchTracker : UIGestureRecognizer
@property (nonatomic) CGPoint last;
@property (nonatomic) BOOL down;
@end

@implementation NFBClickerTouchTracker
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesBegan:touches withEvent:event];
    self.down = YES;
    self.last = [touches.anyObject locationInView:nil];
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesMoved:touches withEvent:event];
    self.last = [touches.anyObject locationInView:nil];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesEnded:touches withEvent:event];
    self.last = [touches.anyObject locationInView:nil];
    self.down = NO;
    self.state = UIGestureRecognizerStateFailed;
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [super touchesCancelled:touches withEvent:event];
    self.down = NO;
    self.state = UIGestureRecognizerStateFailed;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer*)other {
    return NO;
}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer*)other {
    return NO;
}
@end

// WKUserContentController keeps its handler; this keeps the host view from leaking.
@interface NFBClickerScriptProxy : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation NFBClickerScriptProxy
- (void)userContentController:(WKUserContentController*)controller didReceiveScriptMessage:(WKScriptMessage*)message {
    [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end

// MARK: - Host view

@interface NFBClickerView : UIView <WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) WKWebView* web;
@property (nonatomic, strong) NFBClickerTouchTracker* tracker;
@property (nonatomic, strong) NSData* maskBits;
@property (nonatomic) NSInteger maskW, maskH;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSValue*>* hots;
@property (nonatomic) BOOL dragging;
@property (nonatomic) CGPoint dragTouch;
@property (nonatomic) CGPoint dragFrom;
@property (nonatomic) CGRect sentArea;
@property (nonatomic) BOOL ready;
// .cvclk files the page has already opened (it keeps them), so they are not sent again.
@property (nonatomic, strong) NSMutableSet<NSString*>* sentFiles;
- (void)pushData;
- (void)typed;
- (void)sendArea;
@end

static void ClickerTick(void);

@implementation NFBClickerView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.hots = [NSMutableDictionary dictionary];
        self.sentFiles = [NSMutableSet set];
        self.sentArea = CGRectNull;

        WKWebViewConfiguration* config = [WKWebViewConfiguration new];
        config.allowsInlineMediaPlayback = YES;
        config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
        WKUserContentController* content = [WKUserContentController new];
        NSString* lang = [NSLocale preferredLanguages].firstObject ?: @"ko";
        NSString* code = [lang hasPrefix:@"ko"]   ? @"ko"
                         : [lang hasPrefix:@"ja"] ? @"ja"
                         : [lang hasPrefix:@"zh-Hans"] ? @"zhcn"
                         : [lang hasPrefix:@"zh"] ? @"zh"
                                                  : @"en";
        NSString* bridge =
            [NSString stringWithContentsOfURL:[ClickerDir() URLByAppendingPathComponent:@"ios-bridge.js"]
                                     encoding:NSUTF8StringEncoding
                                        error:nil] ?: @"";
        NSString* source = [NSString stringWithFormat:@"window.__clkLang=%@;\n%@", ClickerJSON(code), bridge];
        [content addUserScript:[[WKUserScript alloc] initWithSource:source
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:YES]];
        // The desktop importer, bundled (tools/clicker): opens .cvclk files in the page.
        NSString* importer =
            [NSString stringWithContentsOfURL:[ClickerDir() URLByAppendingPathComponent:@"ios-import.js"]
                                     encoding:NSUTF8StringEncoding
                                        error:nil];
        if (importer.length) {
            [content addUserScript:[[WKUserScript alloc] initWithSource:importer
                                                          injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                       forMainFrameOnly:YES]];
        }
        NFBClickerScriptProxy* proxy = [NFBClickerScriptProxy new];
        proxy.target = self;
        [content addScriptMessageHandler:proxy name:@"clicker"];
        config.userContentController = content;

        WKWebView* web = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
        web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        web.opaque = NO;
        web.backgroundColor = UIColor.clearColor;
        web.scrollView.backgroundColor = UIColor.clearColor;
        web.scrollView.scrollEnabled = NO;
        web.scrollView.bounces = NO;
        web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        if (@available(iOS 16.4, *)) {
            web.inspectable = YES;
        }
        web.navigationDelegate = self;
        [self addSubview:web];
        self.web = web;

        NFBClickerTouchTracker* tracker = [[NFBClickerTouchTracker alloc] initWithTarget:nil action:nil];
        tracker.cancelsTouchesInView = NO;
        tracker.delaysTouchesBegan = NO;
        tracker.delaysTouchesEnded = NO;
        tracker.delegate = self;
        [self addGestureRecognizer:tracker];
        self.tracker = tracker;

        NSURL* dir = ClickerDir();
        NSURLComponents* page = [NSURLComponents
            componentsWithURL:[dir URLByAppendingPathComponent:@"src/pet/pet.html"]
            resolvingAgainstBaseURL:NO];
        page.query = @"id=home";
        if (dir && page.URL) {
            [web loadFileURL:page.URL allowingReadAccessToURL:dir];
        }
    }
    return self;
}

// iOS can kill the page's process in the background; start it again from scratch.
- (void)webViewWebContentProcessDidTerminate:(WKWebView*)webView {
    self.ready = NO;
    self.maskBits = nil;
    [self.hots removeAllObjects];
    [self.sentFiles removeAllObjects];
    self.sentArea = CGRectNull;
    [webView reload];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return YES;
}

// Only the drawn character (and pet.js's extra hot spots) take touches; everything else
// falls through to X underneath, like the desktop window's click-through.
- (BOOL)wantsPoint:(CGPoint)p {
    CGSize s = self.bounds.size;
    if (s.width <= 0 || s.height <= 0 || !CGRectContainsPoint(self.bounds, p)) {
        return NO;
    }
    for (NSValue* v in self.hots.allValues) {
        if (CGRectContainsPoint(v.CGRectValue, p)) {
            return YES;
        }
    }
    NSData* bits = self.maskBits;
    if (!bits || self.maskW <= 0 || self.maskH <= 0) {
        return NO;
    }
    NSInteger gx = MIN(self.maskW - 1, (NSInteger)floor(p.x / s.width * self.maskW));
    NSInteger gy = MIN(self.maskH - 1, (NSInteger)floor(p.y / s.height * self.maskH));
    NSUInteger i = (NSUInteger)(gy * self.maskW + gx);
    return i < bits.length && ((const uint8_t*)bits.bytes)[i] == 1;
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    if (self.hidden || self.alpha < 0.05 || !self.ready) {
        return nil;
    }
    if (!self.dragging && ![self wantsPoint:point]) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

- (void)js:(NSString*)script {
    [self.web evaluateJavaScript:script completionHandler:nil];
}

- (void)resolve:(NSInteger)cb value:(id)value {
    if (cb <= 0) {
        return;
    }
    [self js:[NSString stringWithFormat:@"window.__clk&&__clk.resolve(%ld,%@)", (long)cb, ClickerJSON(value)]];
}

- (void)emit:(NSString*)channel value:(id)value {
    [self js:[NSString stringWithFormat:@"window.__clk&&__clk.emit(%@,%@)", ClickerJSON(channel), ClickerJSON(value)]];
}

- (NSDictionary*)areaDict {
    CGRect a = self.sentArea;
    if (CGRectIsNull(a)) {
        a = self.bounds;
    }
    return @{
        @"left": @(round(CGRectGetMinX(a))),
        @"top": @(round(CGRectGetMinY(a))),
        @"right": @(round(CGRectGetMaxX(a))),
        @"bottom": @(round(CGRectGetMaxY(a)))
    };
}

// main.js petPayload(): what one character window needs. A character from a .cvclk goes
// as the file itself (charFile, base64) the first time; the page opens it with the desktop
// importer and keeps it, and later payloads only name it (charKey).
- (NSDictionary*)payload {
    static NSDictionary* builtIn;
    if (!builtIn) {
        builtIn = ClickerCharacter(@"default");
    }
    if (!builtIn) {
        return nil;
    }
    ClickerGeom g = ClickerGeometry(gPrefs.size);
    NSMutableDictionary* p = [@{
        @"pet": @{
            @"id": @"home",
            @"charId": @"default",
            @"size": @(gPrefs.size),
            @"flip": @(gPrefs.flip),
            @"lock": @(gPrefs.lock),
            @"mute": @(!gPrefs.sound),
            @"music": @NO,
            @"typing": @((BOOL)(gOnCompose && gPrefs.typing)),
            @"keyBg": @"",
            @"alwaysOnTop": @YES,
            @"clickThrough": @YES
        },
        @"geom": @{
            @"size": @(g.size),
            @"side": @(g.side),
            @"bubbleZone": @(g.zone),
            @"bottom": @(g.bottom),
            @"width": @(g.width),
            @"height": @(g.height)
        },
        @"lift": @0,
        @"area": [self areaDict],
        @"prefs": @{
            @"react": @{@"sense": @5, @"keyEvery": @1, @"beatOffset": @0, @"sound": @"music"},
            @"ui": @{
                @"bubbleTheme": @"dark",
                @"bubbleFont": @14,
                @"lite": @NO,
                @"menuStyle": @"native",
                @"reduceMotion": @(UIAccessibilityIsReduceMotionEnabled()),
                @"restIdle": @NO,
                @"motionOs": @YES
            },
            @"update": @{@"auto": @NO}
        }
    } mutableCopy];
    NSString* entry = gCharEntry;
    if (entry.length) {
        p[@"charKey"] = entry;
        p[@"charIndex"] = @(gPrefs.charIndex);
        p[@"charDefault"] = builtIn;
        if (![self.sentFiles containsObject:entry]) {
            NSData* file = [NFBClickerStore fileForEntry:entry];
            if (file.length) {
                p[@"charFile"] = [file base64EncodedStringWithOptions:0];
            }
        }
    } else {
        p[@"char"] = builtIn;
    }
    return p;
}

- (void)pushData {
    if (self.ready) {
        [self emit:@"data" value:[self payload]];
    }
}

// The part of the page that is on screen, so pet.js keeps the speech bubble inside it.
- (void)sendArea {
    UIWindow* w = self.window;
    if (!w) {
        return;
    }
    CGRect screen = UIEdgeInsetsInsetRect(w.bounds, UIEdgeInsetsMake(w.safeAreaInsets.top, 4, 0, 4));
    CGRect visible = CGRectIntersection([self convertRect:screen fromView:w], self.bounds);
    if (CGRectIsNull(visible)) {
        visible = CGRectZero;
    }
    CGRect old = self.sentArea;
    if (!CGRectIsNull(old) && fabs(old.origin.x - visible.origin.x) < 1 && fabs(old.origin.y - visible.origin.y) < 1 &&
        fabs(old.size.width - visible.size.width) < 1 && fabs(old.size.height - visible.size.height) < 1) {
        return;
    }
    self.sentArea = visible;
    if (self.ready) {
        [self emit:@"area" value:[self areaDict]];
    }
}

- (void)userContentController:(WKUserContentController*)controller didReceiveScriptMessage:(WKScriptMessage*)message {
    NSDictionary* m = message.body;
    if (![m isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString* op = m[@"op"];
    NSArray* args = [m[@"args"] isKindOfClass:[NSArray class]] ? m[@"args"] : @[];
    NSInteger cb = [m[@"cb"] integerValue];

    if ([op isEqualToString:@"ready"]) {
        self.ready = YES;
        [self resolve:cb value:[self payload]];
    } else if ([op isEqualToString:@"mask"]) {
        NSDictionary* mask = args.firstObject;
        if (![mask isKindOfClass:[NSDictionary class]] || ![mask[@"bits"] isKindOfClass:[NSArray class]]) {
            return;
        }
        NSArray* list = mask[@"bits"];
        NSMutableData* bits = [NSMutableData dataWithLength:list.count];
        uint8_t* b = bits.mutableBytes;
        for (NSUInteger i = 0; i < list.count; i++) {
            b[i] = [list[i] integerValue] == 1 ? 1 : 0;
        }
        self.maskW = [mask[@"gw"] integerValue];
        self.maskH = [mask[@"gh"] integerValue];
        self.maskBits = bits;
    } else if ([op isEqualToString:@"hot"]) {
        NSDictionary* r = args.count > 0 ? args[0] : nil;
        NSString* key = args.count > 1 && [args[1] isKindOfClass:[NSString class]] ? args[1] : @"remind";
        if ([r isKindOfClass:[NSDictionary class]] && r[@"l"]) {
            CGFloat l = [r[@"l"] doubleValue], t = [r[@"t"] doubleValue];
            self.hots[key] =
                [NSValue valueWithCGRect:CGRectMake(l, t, [r[@"r"] doubleValue] - l, [r[@"b"] doubleValue] - t)];
        } else {
            [self.hots removeObjectForKey:key];
        }
    } else if ([op isEqualToString:@"dragStart"]) {
        if (gPrefs.lock || !self.tracker.down) {
            [self resolve:cb value:@NO];
            return;
        }
        self.dragging = YES;
        self.dragTouch = self.tracker.last;
        self.dragFrom = gOnCompose     ? CGPointMake(gPrefs.composeX, gPrefs.composeY)
                        : gPrefs.free ? CGPointMake(gPrefs.freeX, gPrefs.freeY)
                                      : CGPointMake(gPrefs.barX, gPrefs.barY);
        [self resolve:cb value:@YES];
    } else if ([op isEqualToString:@"dragMove"]) {
        if (!self.dragging) {
            return;
        }
        CGPoint now = self.tracker.last;
        CGFloat dx = now.x - self.dragTouch.x, dy = now.y - self.dragTouch.y;
        if (gOnCompose) {
            gPrefs.composeX = MAX(-200, MIN(200, lround(self.dragFrom.x + dx)));
        } else if (gPrefs.free) {
            // Free spot: x from the left edge, y from the bottom edge.
            gPrefs.freeX = MAX(0, MIN(500, lround(self.dragFrom.x + dx)));
            gPrefs.freeY = MAX(0, MIN(1000, lround(self.dragFrom.y - dy)));
        } else {
            // On the bar it only slides sideways.
            gPrefs.barX = MAX(-200, MIN(200, lround(self.dragFrom.x + dx)));
        }
        ClickerTick();
    } else if ([op isEqualToString:@"dragEnd"]) {
        if (!self.dragging) {
            return;
        }
        self.dragging = NO;
        NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
        if (gOnCompose) {
            [d setInteger:gPrefs.composeX forKey:kClickerComposeX];
        } else if (gPrefs.free) {
            [d setInteger:gPrefs.freeX forKey:kClickerFreeX];
            [d setInteger:gPrefs.freeY forKey:kClickerFreeY];
        } else {
            [d setInteger:gPrefs.barX forKey:kClickerBarX];
        }
    } else if ([op isEqualToString:@"charInfo"]) {
        NSString* key = args.count > 0 && [args[0] isKindOfClass:[NSString class]] ? args[0] : nil;
        if (!key) {
            return;
        }
        NSArray* names = args.count > 1 && [args[1] isKindOfClass:[NSArray class]] ? args[1] : @[];
        BOOL locked = args.count > 2 && [args[2] respondsToSelector:@selector(boolValue)] && [args[2] boolValue];
        NSString* error = args.count > 3 && [args[3] isKindOfClass:[NSString class]] ? args[3] : @"";
        // Opened or not, the page has the file; a broken one is not sent again either.
        [self.sentFiles addObject:key];
        [NFBClickerStore noteEntry:key names:names locked:locked error:error];
    } else if ([op isEqualToString:@"charNeed"]) {
        NSString* key = args.count > 0 && [args[0] isKindOfClass:[NSString class]] ? args[0] : nil;
        NSDictionary* entry = nil;
        for (NSDictionary* e in [NFBClickerStore entries]) {
            if ([e[@"id"] isEqual:key]) {
                entry = e;
            }
        }
        // The page lost it (it reloaded); send it again unless it failed to open.
        if (key && [entry[@"error"] length] == 0 && [self.sentFiles containsObject:key]) {
            [self.sentFiles removeObject:key];
            [self pushData];
        }
    } else if ([op isEqualToString:@"lineSound"]) {
        NSString* charId = args.count > 0 && [args[0] isKindOfClass:[NSString class]] ? args[0] : @"default";
        if ([charId containsString:@"/"] || [charId hasPrefix:@"."]) {
            [self resolve:cb value:@""];
            return;
        }
        [self resolve:cb value:ClickerFileURL(ClickerCharDir(charId), args.count > 1 ? args[1] : nil, 2 * 1024 * 1024)];
    } else if (cb > 0) {
        [self resolve:cb value:nil];
    }
}

// main.js reactTo('typing', {kind: 'key'}): one nod per keystroke.
- (void)typed {
    if (self.ready && !self.hidden) {
        [self js:@"window.__clk&&__clk.emit('react',{kind:'key'})"];
    }
}

@end

// MARK: - Placement

static NSHashTable<UIView*>* gHomeBars;
static NSHashTable<UIView*>* gComposeBars;
static NFBClickerView* gHost;
static CADisplayLink* gLink;
static __weak UIView* gLastAnchor;
static CGFloat gAnchorMaxWidth;
static NSInteger gHostSize;
static BOOL gHostOnCompose;

@interface NFBClickerTicker : NSObject
@end

@implementation NFBClickerTicker
- (void)tick:(CADisplayLink*)link {
    ClickerTick();
}
@end

static void ClickerHide(void) {
    if (gHost && !gHost.hidden) {
        gHost.hidden = YES;
        gHost.dragging = NO;
    }
}

static void ClickerStopLink(void) {
    [gLink invalidate];
    gLink = nil;
}

static void ClickerStartLink(void) {
    if (gLink) {
        return;
    }
    gLink = [CADisplayLink displayLinkWithTarget:[NFBClickerTicker new] selector:@selector(tick:)];
    [gLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// A bar that is in a window; a hidden one still counts, its visibility just reads 0.
static UIView* ClickerBarIn(NSHashTable<UIView*>* bars) {
    UIView* best = nil;
    for (UIView* v in bars.allObjects) {
        if (v.window && (!best || (best.hidden && !v.hidden))) {
            best = v;
        }
    }
    return best;
}

// The composer's toolbar wins while a post is being written; the home bar is still in its
// window underneath then, covered.
static UIView* ClickerCurrentAnchor(BOOL* compose) {
    UIView* bar = gPrefs.compose ? ClickerBarIn(gComposeBars) : nil;
    if (bar) {
        *compose = YES;
        return bar;
    }
    *compose = NO;
    return ClickerBarIn(gHomeBars);
}

// How much of the bar is really showing: hidden or faded ancestors, clipping ancestors, the
// screen edge, and the bar shrinking (the tab bar minimizing on scroll) all count.
static CGFloat ClickerAnchorVisibility(UIView* anchor, UIWindow* window, CGRect frame) {
    CGFloat alpha = 1;
    CGRect visible = frame;
    CALayer* wp = window.layer.presentationLayer ?: window.layer;
    for (UIView* v = anchor; v && v != window; v = v.superview) {
        if (v.hidden) {
            return 0;
        }
        CALayer* layer = v.layer.presentationLayer ?: v.layer;
        alpha *= layer.opacity;
        if (v != anchor && v.clipsToBounds) {
            visible = CGRectIntersection(visible, [layer convertRect:layer.bounds toLayer:wp]);
        }
    }
    visible = CGRectIntersection(visible, window.bounds);
    if (CGRectIsNull(visible) || frame.size.height <= 0) {
        return 0;
    }
    CGFloat shown = visible.size.height / frame.size.height;
    CGFloat wide = gAnchorMaxWidth > 0 ? frame.size.width / gAnchorMaxWidth : 1;
    CGFloat widthFade = MAX(0, MIN(1, (wide - 0.75) / 0.2));
    return MAX(0, MIN(1, alpha * shown * widthFade));
}

static void ClickerTick(void) {
    BOOL compose = NO;
    UIView* anchor = gPrefs.on ? ClickerCurrentAnchor(&compose) : nil;
    if (!anchor) {
        // Nothing to follow: stop ticking until a bar comes back into a window
        // (didMoveToWindow) or the setting is turned on.
        ClickerHide();
        ClickerStopLink();
        return;
    }
    UIWindow* window = anchor.window;
    UIView* top = anchor;
    while (top.superview && top.superview != window) {
        top = top.superview;
    }
    if (top.superview != window) {
        ClickerHide();
        return;
    }

    if (!gHost) {
        gHost = [[NFBClickerView alloc] initWithFrame:CGRectZero];
    }
    NSArray* subviews = window.subviews;
    NSUInteger topIndex = [subviews indexOfObjectIdenticalTo:top];
    NSUInteger hostIndex = gHost.superview == window ? [subviews indexOfObjectIdenticalTo:gHost] : NSNotFound;
    if (hostIndex == NSNotFound || hostIndex != topIndex + 1) {
        [window insertSubview:gHost aboveSubview:top];
    }

    if (anchor != gLastAnchor) {
        gLastAnchor = anchor;
        gAnchorMaxWidth = 0;
        gHost.dragging = NO;
    }
    gOnCompose = compose;
    CALayer* al = anchor.layer.presentationLayer ?: anchor.layer;
    CALayer* wl = window.layer.presentationLayer ?: window.layer;
    CGRect bar = [al convertRect:al.bounds toLayer:wl];
    gAnchorMaxWidth = MAX(gAnchorMaxWidth, bar.size.width);
    CGFloat visibility = ClickerAnchorVisibility(anchor, window, bar);

    CGPoint feet;
    if (compose) {
        feet = CGPointMake(CGRectGetMidX(bar) + gPrefs.composeX, CGRectGetMinY(bar) - gPrefs.composeY);
    } else if (gPrefs.free) {
        feet = CGPointMake(gPrefs.freeX, window.bounds.size.height - gPrefs.freeY);
    } else {
        feet = CGPointMake(CGRectGetMidX(bar) + gPrefs.barX, CGRectGetMinY(bar) - gPrefs.barY);
    }
    ClickerGeom g = ClickerGeometry(gPrefs.size);
    CGRect frame = CGRectMake(round(feet.x - g.width / 2), round(feet.y - g.zone - g.size), g.width, g.height);
    if (!CGRectEqualToRect(gHost.frame, frame)) {
        gHost.frame = frame;
    }
    if (gHostSize != gPrefs.size || gHostOnCompose != compose) {
        // Size changes the page layout; the compose flag turns typing on in the payload.
        gHostSize = gPrefs.size;
        gHostOnCompose = compose;
        [gHost pushData];
    }
    // A drag in progress keeps the character visible even if the bar moves under it.
    CGFloat alpha = gHost.dragging ? 1 : visibility;
    gHost.hidden = alpha < 0.02;
    gHost.alpha = alpha;
    [gHost sendArea];
}

static void ClickerAddBar(NSHashTable<UIView*>* __strong* table, UIView* bar) {
    if (!*table) {
        *table = [NSHashTable weakObjectsHashTable];
    }
    if (bar.window) {
        [*table addObject:bar];
    }
    if (gPrefs.on) {
        ClickerStartLink();
    }
}

static void ClickerPrefsChanged(void) {
    ClickerPrefs now = ReadClickerPrefs();
    ClickerPrefs old = gPrefs;
    if (gHost.dragging) {
        // The drag owns the position until it ends.
        now.barX = old.barX;
        now.barY = old.barY;
        now.freeX = old.freeX;
        now.freeY = old.freeY;
        now.composeX = old.composeX;
        now.composeY = old.composeY;
    }
    NSString* entry = [NFBClickerStore selectedEntry];
    BOOL charChanged = ![entry isEqualToString:gCharEntry] || now.charIndex != old.charIndex;
    gCharEntry = entry;
    gPrefs = now;
    if (charChanged || now.flip != old.flip || now.lock != old.lock || now.sound != old.sound ||
        now.typing != old.typing) {
        [gHost pushData];
    }
    if (now.on) {
        ClickerStartLink();
    }
    ClickerTick();
}

// Typing in X while the character is on the composer toolbar.
static void ClickerTextChanged(NSNotification* note) {
    if (!gPrefs.on || !gPrefs.typing || !gOnCompose || !gHost || gHost.hidden) {
        return;
    }
    UIView* field = note.object;
    if (![field isKindOfClass:[UIView class]] || field.window != gHost.window) {
        return;
    }
    [gHost typed];
}

%hook _TtC13QuickComposer21QuickComposerSlotView

- (void)didMoveToWindow {
    %orig;
    ClickerAddBar(&gHomeBars, self);
}

%end

%hook TCRComposerToolbarView

- (void)didMoveToWindow {
    %orig;
    ClickerAddBar(&gComposeBars, self);
}

%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        ClickerPrefsChanged();
    });
    // queue:nil, never the main queue (7.3.79, 7.3.86); the work hops to main itself.
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:NSUserDefaultsDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification* note) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ClickerPrefsChanged();
                        });
                    }];
    for (NSNotificationName name in @[UITextViewTextDidChangeNotification, UITextFieldTextDidChangeNotification]) {
        [center addObserverForName:name
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification* note) {
                            if ([NSThread isMainThread]) {
                                ClickerTextChanged(note);
                            } else {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    ClickerTextChanged(note);
                                });
                            }
                        }];
    }
    %init;
}
