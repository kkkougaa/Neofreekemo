//
//  AccountBubbles.x
//  NeoFreeBird
//
//  Long-pressing the Home dash button normally opens X's account list. When this
//  is on, the accounts pop out as circles instead. Releasing on one calls X's
//  own viewAccount:animated:. Any failure leaves the stock sheet in place.

#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import "HookHelpers.h"

static const NSInteger kBubbleLimit = 8;
static const CGFloat kBubbleSize = 56.0;

static BOOL BubblesOn(void) {
    return [BHTSettings boolForKey:@"kemo_account_bubbles"];
}

static id ObjectProp(id object, NSString* selectorName) {
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
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString* StringProp(id object, NSString* selectorName) {
    id value = ObjectProp(object, selectorName);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSArray* TwitterAccounts(void) {
    Class twitterClass = objc_getClass("TFNTwitter");
    if (!twitterClass || ![twitterClass respondsToSelector:@selector(sharedTwitter)]) {
        return nil;
    }
    id twitter = ((id (*)(id, SEL))objc_msgSend)(twitterClass, @selector(sharedTwitter));
    id accounts = ObjectProp(twitter, @"accounts");
    if (![accounts isKindOfClass:[NSArray class]] || [accounts count] == 0) {
        return nil;
    }
    return accounts;
}

static BOOL SwitchToAccount(id account, id tabController) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (hostClass && [hostClass respondsToSelector:@selector(sharedHostViewController)]) {
        id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
        SEL selector = @selector(viewAccount:animated:);
        if (host && [host respondsToSelector:selector]) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(host, selector, account, YES);
            return YES;
        }
    }
    id presenter = ObjectProp(tabController, @"dashPresenter");
    SEL fallback = NSSelectorFromString(@"switchAccountTo:");
    if (presenter && [presenter respondsToSelector:fallback]) {
        ((void (*)(id, SEL, id))objc_msgSend)(presenter, fallback, account);
        return YES;
    }
    return NO;
}

static NSString* AccountTitle(id account) {
    id user = ObjectProp(account, @"user");
    id source = user ?: account;
    for (NSString* name in @[ @"displayUsername", @"username", @"fullName", @"displayFullName" ]) {
        NSString* value = StringProp(source, name);
        if (value.length > 0) {
            return value;
        }
    }
    return @"";
}

static NSURL* AccountImageURL(id account) {
    id user = ObjectProp(account, @"user");
    for (id source in @[ user ?: [NSNull null], account ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in @[ @"profileImageURL", @"profileImageUrl", @"profileImageURLString" ]) {
            id value = ObjectProp(source, name);
            if ([value isKindOfClass:[NSURL class]]) {
                return value;
            }
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                return [NSURL URLWithString:value];
            }
        }
    }
    return nil;
}

static UIVisualEffect* BubbleEffect(void) {
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    if (glassClass) {
        id effect = nil;
        SEL styled = NSSelectorFromString(@"effectWithStyle:");
        if ([glassClass respondsToSelector:styled]) {
            effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, styled, 0);
        }
        if (!effect) {
            effect = [[glassClass alloc] init];
        }
        if ([effect isKindOfClass:[UIVisualEffect class]]) {
            return effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

@interface NFBAccountBubble : UIView
@property (nonatomic, strong) id account;
@property (nonatomic, assign) CGPoint slot;
@property (nonatomic, assign) BOOL settled;
@property (nonatomic, strong) UIImageView* avatar;
@end

@implementation NFBAccountBubble

- (instancetype)initWithAccount:(id)account {
    if ((self = [super initWithFrame:CGRectMake(0, 0, kBubbleSize, kBubbleSize)])) {
        _account = account;
        self.userInteractionEnabled = NO;
        UIVisualEffectView* glass =
            [[UIVisualEffectView alloc] initWithEffect:BubbleEffect()];
        glass.frame = self.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerRadius = kBubbleSize / 2.0;
        glass.clipsToBounds = YES;
        glass.layer.borderWidth = 1.0;
        glass.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        [self addSubview:glass];

        _avatar = [[UIImageView alloc] initWithFrame:CGRectInset(self.bounds, 3, 3)];
        _avatar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _avatar.layer.cornerRadius = CGRectGetWidth(_avatar.bounds) / 2.0;
        _avatar.clipsToBounds = YES;
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        _avatar.backgroundColor = [UIColor colorWithWhite:0.75 alpha:0.45];
        [self addSubview:_avatar];
        self.accessibilityLabel = AccountTitle(account);
    }
    return self;
}

@end

@interface NFBAccountFan : UIView
@property (nonatomic, copy) void (^onSwitch)(id account);
@property (nonatomic, strong) NSArray<NFBAccountBubble*>* bubbles;
@property (nonatomic, weak) NFBAccountBubble* hovered;
@end

@implementation NFBAccountFan

- (instancetype)initWithAccounts:(NSArray*)accounts origin:(CGPoint)origin {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        NSInteger count = MIN((NSInteger)accounts.count, kBubbleLimit);
        NSMutableArray* bubbles = [NSMutableArray array];
        CGFloat start = (CGFloat)M_PI * 1.08;
        CGFloat end = (CGFloat)M_PI * 1.92;
        for (NSInteger i = 0; i < count; i++) {
            NFBAccountBubble* bubble = [[NFBAccountBubble alloc] initWithAccount:accounts[i]];
            CGFloat t = count == 1 ? 0.5 : (CGFloat)i / (CGFloat)(count - 1);
            CGFloat angle = start + (end - start) * t;
            bubble.slot = CGPointMake(origin.x + cos(angle) * 112.0, origin.y + sin(angle) * 112.0);
            bubble.center = origin;
            bubble.transform = CGAffineTransformMakeScale(0.15, 0.15);
            [self addSubview:bubble];
            [bubbles addObject:bubble];
            [UIView animateWithDuration:0.48
                                  delay:i * 0.055
                 usingSpringWithDamping:0.62
                  initialSpringVelocity:0.7
                                options:UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                                 bubble.center = bubble.slot;
                                 bubble.transform = CGAffineTransformIdentity;
                             }
                             completion:^(BOOL finished) {
                                 bubble.settled = YES;
                             }];
            [self loadImageForBubble:bubble];
        }
        _bubbles = bubbles;
    }
    return self;
}

- (void)loadImageForBubble:(NFBAccountBubble*)bubble {
    NSURL* url = AccountImageURL(bubble.account);
    if (!url) {
        return;
    }
    __weak NFBAccountBubble* weakBubble = bubble;
    [[[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
          if (error || data.length == 0) {
              return;
          }
          UIImage* image = [UIImage imageWithData:data];
          if (!image) {
              return;
          }
          dispatch_async(dispatch_get_main_queue(), ^{
              weakBubble.avatar.image = image;
          });
      }] resume];
}

- (NFBAccountBubble*)bubbleNear:(CGPoint)point {
    NFBAccountBubble* best = nil;
    CGFloat bestDistance = 40;
    for (NFBAccountBubble* bubble in self.bubbles) {
        CGFloat distance = hypot(point.x - bubble.center.x, point.y - bubble.center.y);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = bubble;
        }
    }
    return best;
}

- (void)hoverAt:(CGPoint)point {
    NFBAccountBubble* next = [self bubbleNear:point];
    if (next == self.hovered) {
        return;
    }
    for (NFBAccountBubble* bubble in self.bubbles) {
        if (!bubble.settled) {
            continue;
        }
        [UIView animateWithDuration:0.12
                         animations:^{
                             bubble.transform = bubble == next ? CGAffineTransformMakeScale(1.18, 1.18)
                                                               : CGAffineTransformIdentity;
                         }];
    }
    self.hovered = next;
    if (next && !NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        UISelectionFeedbackGenerator* tap = [UISelectionFeedbackGenerator new];
        [tap selectionChanged];
    }
}

- (void)dismissSwitching:(BOOL)switching {
    NFBAccountBubble* chosen = self.hovered;
    [UIView animateWithDuration:0.18
        animations:^{
            self.alpha = 0;
            if (!switching) {
                for (NFBAccountBubble* bubble in self.bubbles) {
                    bubble.transform = CGAffineTransformMakeScale(0.2, 0.2);
                }
            }
        }
        completion:^(BOOL finished) {
            if (switching && chosen && self.onSwitch) {
                self.onSwitch(chosen.account);
            }
            [self removeFromSuperview];
        }];
}

@end

static const void* kFanKey = &kFanKey;
static const void* kPassKey = &kPassKey;

static void FanUpdate(id owner, UIGestureRecognizer* gesture) {
    UIWindow* window = gesture.view.window;
    NFBAccountFan* fan = objc_getAssociatedObject(owner, kFanKey);
    UIGestureRecognizerState state = gesture.state;
    if (state == UIGestureRecognizerStateBegan) {
        if (!window) {
            return;
        }
        NSArray* accounts = TwitterAccounts();
        if (accounts.count == 0) {
            objc_setAssociatedObject(owner, kPassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        CGPoint origin = [gesture locationInView:window];
        NFBAccountFan* created = [[NFBAccountFan alloc] initWithAccounts:accounts origin:origin];
        created.frame = window.bounds;
        created.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        __weak id weakOwner = owner;
        created.onSwitch = ^(id account) {
            if (!SwitchToAccount(account, weakOwner)) {
                return;
            }
        };
        [window addSubview:created];
        objc_setAssociatedObject(owner, kFanKey, created, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!fan) {
        return;
    }
    if (state == UIGestureRecognizerStateChanged) {
        [fan hoverAt:[gesture locationInView:fan.superview ?: window]];
        return;
    }
    if (state == UIGestureRecognizerStateEnded) {
        [fan dismissSwitching:fan.hovered != nil];
        objc_setAssociatedObject(owner, kFanKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (state == UIGestureRecognizerStateCancelled || state == UIGestureRecognizerStateFailed) {
        [fan dismissSwitching:NO];
        objc_setAssociatedObject(owner, kFanKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%hook T1TabNavigationController

- (void)_t1_action_didLongPressDashButton:(id)sender {
    if (!BubblesOn() || ![sender isKindOfClass:[UIGestureRecognizer class]]) {
        %orig;
        return;
    }
    UIGestureRecognizer* gesture = sender;
    if (objc_getAssociatedObject(self, kPassKey)) {
        if (gesture.state == UIGestureRecognizerStateEnded ||
            gesture.state == UIGestureRecognizerStateCancelled ||
            gesture.state == UIGestureRecognizerStateFailed) {
            objc_setAssociatedObject(self, kPassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        %orig;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        NSArray* accounts = TwitterAccounts();
        if (accounts.count == 0 || !gesture.view.window) {
            objc_setAssociatedObject(self, kPassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            %orig;
            return;
        }
        FanUpdate(self, gesture);
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        NFBAccountFan* fan = objc_getAssociatedObject(self, kFanKey);
        BOOL failedSwitch = fan.hovered && !SwitchToAccount(fan.hovered.account, self);
        [fan dismissSwitching:NO];
        objc_setAssociatedObject(self, kFanKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (failedSwitch) {
            %orig;
        }
        return;
    }
    FanUpdate(self, gesture);
}

%end
