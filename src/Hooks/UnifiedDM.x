//
//  UnifiedDM.x
//  NeoFreeBird
//
//  7.3.151: "which account sends this DM?" for the A/B unified mode
//  (UnifiedTimeline.x has the timelines, UnifiedProfile.x the profile).
//
//  Entry point: the message (envelope) button on a profile. In X 12.44 it is
//  -[MessageButtonViewModel didTap:] (T1Twitter; Swift, @objc name, ivars
//  account / profileViewModel). While the mode is active, tapping it on a
//  profile in A's context shows the account sheet.
//
//  - A runs X's own path unchanged (%orig).
//  - B is shown disabled ("이 X 버전에서는 B로 열 수 없어요"). 12.44 has one DM
//    stack, XChat: +[T1XChatViewControllerFactory
//    createOneOnOneConversationWithAccount:userID:] does take an account and
//    _TtC14T1TwitterSwift19XChatViewController keeps it in an `account` ivar,
//    but everything under that screen hangs off one process-wide
//    +[XChatRootComponentProvider shared] with a single rootComponentHolder
//    (accountID / userID) and a single currentRootComponentUserID. Nothing in
//    the dump shows that a second account's screen gets its own chat session:
//    it either reuses A's (a message typed "as B" would go out as A) or
//    replaces A's with B's (A's Chat tab would then run on B's session).
//    Neither can be told apart or undone with API that is in the dump, so
//    nothing is opened as B.
//  - On a profile in B's context (opened from a tweet shown as B) X's own path
//    is not run either, for the same reason; a notice says so.
//  - If the screen's account cannot be told at all, nothing is opened.
//
//  Read only otherwise: the debug text lists the entry points found at
//  runtime, which user XChat's root component is for, and the account each
//  XChat screen on the stack holds, to decide later whether B can be opened.
//  The tweet share menu's "send via Direct Message" is not hooked: in 12.44 it
//  is the share tray (+[T1ShareSheetBuilder buildXChatShareSheetWithAccount:…],
//  Swift views) that sends in place over the same single XChat session.
//

#import "HookHelpers.h"

extern void NFBShowNotice(NSString* text);
extern void NFBPresentAccountSheet(NSString* title, NSString* message, NSArray<NSDictionary*>* rows);
extern UIColor* NFBUnifiedBColor(void);

// MARK: - Helpers (local copies; each Unified file keeps its own)

static id DMGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
}

static long long DMNumber(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return 0;
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* type = signature.methodReturnType;
    if (!type) return 0;
    @try {
        switch (type[0]) {
            case 'q':
            case 'l':
                return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
            case 'Q':
            case 'L':
                return (long long)((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector);
            case 'i':
                return ((int (*)(id, SEL))objc_msgSend)(object, selector);
            case '@': {
                id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
                if ([value respondsToSelector:@selector(longLongValue)]) return [value longLongValue];
                return 0;
            }
            default:
                return 0;
        }
    } @catch (__unused NSException* exception) {
        return 0;
    }
}

// An ObjC object ivar (type encoding '@' only).
static id DMIvar(id object, const char* name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return nil;
    const char* type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

// The first word stored in an ivar, as a bare address. For Swift ivars (no
// type encoding in the dump) holding a class reference this is the object's
// address. Only ever compared with known objects' addresses, never used.
static const void* DMRawIvar(id object, const char* name) {
    if (!object) return NULL;
    Class cls = object_getClass(object);
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar) return NULL;
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (offset <= 0 || (size_t)offset + sizeof(void*) > class_getInstanceSize(cls)) return NULL;
    const void* value = NULL;
    memcpy(&value, (const char*)(__bridge const void*)object + offset, sizeof(value));
    return value;
}

static id DMCurrentAccount(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) return nil;
    id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
    return DMGetter(host, @"currentAccount");
}

static NSArray* DMAccounts(void) {
    Class twitterClass = objc_getClass("TFNTwitter");
    if (!twitterClass || ![twitterClass respondsToSelector:@selector(sharedTwitter)]) return nil;
    id twitter = ((id (*)(id, SEL))objc_msgSend)(twitterClass, @selector(sharedTwitter));
    id accounts = DMGetter(twitter, @"accounts");
    return [accounts isKindOfClass:[NSArray class]] ? accounts : nil;
}

static NSString* DMAccountUserID(id account) {
    if (!account) return nil;
    id user = DMGetter(account, @"user");
    for (id source in @[ account, user ?: [NSNull null] ]) {
        if (source == [NSNull null]) continue;
        for (NSString* name in @[ @"userID", @"userId", @"userIDString" ]) {
            long long number = DMNumber(source, name);
            if (number > 0) return [NSString stringWithFormat:@"%lld", number];
            id value = DMGetter(source, name);
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
        }
    }
    return nil;
}

// The user ID of the account object at this address, if it is one of the
// signed-in accounts. The address is only compared.
static NSString* DMAccountIDAtAddress(const void* address) {
    if (!address) return nil;
    id current = DMCurrentAccount();
    if ((__bridge const void*)current == address) return DMAccountUserID(current);
    for (id account in DMAccounts()) {
        if ((__bridge const void*)account == address) return DMAccountUserID(account);
    }
    return nil;
}

static NSString* DMBID(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_id"];
}

static NSString* DMAID(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_a_id"];
}

static NSString* DMBName(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"kemo_unified_b_name"] ?: @"B";
}

static NSString* DMAName(void) {
    id account = DMCurrentAccount();
    NSString* name = DMGetter(DMGetter(account, @"user"), @"username") ?: DMGetter(account, @"username");
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return @"A";
    return [name hasPrefix:@"@"] ? name : [@"@" stringByAppendingString:name];
}

// Same rule as UnifiedTimeline.x: on, mode selected (unset = on), B set and
// not in use, and the account in use is A (or no A picked).
static BOOL DMActive(void) {
    if (![BHTSettings boolForKey:@"kemo_unified_exp"]) return NO;
    id mode = [[NSUserDefaults standardUserDefaults] objectForKey:@"kemo_unified_mode"];
    if (mode && ![mode boolValue]) return NO;
    NSString* bID = DMBID();
    NSString* currentID = DMAccountUserID(DMCurrentAccount());
    if (bID.length == 0 || currentID.length == 0 || [bID isEqualToString:currentID]) return NO;
    // 7.3.151: a saved A is required, as in UnifiedTimeline.x (UnifiedActive):
    // it used to take whoever was in use as A when none was saved.
    NSString* aID = DMAID();
    return aID.length > 0 && ![aID isEqualToString:bID] && [aID isEqualToString:currentID];
}

static NSMutableArray<NSString*>* gDMLog;

static void DMLog(NSString* line) {
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    @synchronized([NSObject class]) {
        if (!gDMLog) gDMLog = [NSMutableArray array];
        [gDMLog addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], line]];
        while (gDMLog.count > 30) [gDMLog removeObjectAtIndex:0];
    }
}

// An account's picture: AccountBubbles.x keeps them by user ID; a letter in a
// circle otherwise (as UnifiedProfile.x draws them).
static UIImage* DMAvatar(NSString* userID, NSString* letter, UIColor* color) {
    if (userID.length) {
        NSURL* base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
        NSString* path = [[base URLByAppendingPathComponent:@"NFBAccountAvatars"]
                             URLByAppendingPathComponent:[userID stringByAppendingString:@".img"]].path;
        NSData* data = [NSData dataWithContentsOfFile:path];
        UIImage* image = data.length ? [UIImage imageWithData:data] : nil;
        if (image) return image;
    }
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 28, 28)] fill];
        NSDictionary* attributes = @{
            NSFontAttributeName : [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName : UIColor.whiteColor
        };
        CGSize size = [letter sizeWithAttributes:attributes];
        [letter drawAtPoint:CGPointMake((28 - size.width) / 2, (28 - size.height) / 2) withAttributes:attributes];
    }];
}

// MARK: - The profile a message button belongs to

static BOOL DMIsProfile(UIViewController* controller) {
    return [NSStringFromClass([controller class]) isEqualToString:@"T1ProfileViewController"];
}

// Walks what is on screen (the top of each navigation stack, the selected
// tab, then anything presented) and keeps the last profile met: the frontmost.
static void DMFindVisibleProfile(UIViewController* controller, UIViewController* __strong* found, int depth) {
    if (!controller || depth > 24) return;
    if (DMIsProfile(controller) && controller.viewIfLoaded.window) *found = controller;
    if ([controller isKindOfClass:[UINavigationController class]]) {
        DMFindVisibleProfile(((UINavigationController*)controller).topViewController, found, depth + 1);
    } else if ([controller isKindOfClass:[UITabBarController class]]) {
        DMFindVisibleProfile(((UITabBarController*)controller).selectedViewController, found, depth + 1);
    } else {
        for (UIViewController* child in controller.childViewControllers) {
            if (child.viewIfLoaded.window) DMFindVisibleProfile(child, found, depth + 1);
        }
    }
    UIViewController* presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed) DMFindVisibleProfile(presented, found, depth + 1);
}

static UIWindow* DMKeyWindow(void) {
    UIWindow* window = nil;
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow* candidate in ((UIWindowScene*)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    return window;
}

// The sender's own profile when the sender is a view inside one (the button
// row under the header); the frontmost profile otherwise (the button can also
// sit in the navigation bar, outside the profile's views).
static UIViewController* DMProfileForSender(id sender, NSString** how) {
    if ([sender isKindOfClass:[UIView class]]) {
        for (UIResponder* responder = (UIView*)sender; responder; responder = responder.nextResponder) {
            if (![responder isKindOfClass:[UIViewController class]]) continue;
            for (UIViewController* controller = (UIViewController*)responder; controller; controller = controller.parentViewController) {
                if (DMIsProfile(controller)) {
                    if (how) *how = @"sender";
                    return controller;
                }
            }
            break;
        }
    }
    UIViewController* found = nil;
    DMFindVisibleProfile(DMKeyWindow().rootViewController, &found, 0);
    if (how) *how = found ? @"frontmost" : @"none";
    return found;
}

// As UnifiedProfile.x reads it: -[T1ProfileViewController
// profileViewControllerUserContext] (TUITwitterUserContext), then _viewModel.
static long long DMProfileUserID(UIViewController* profile) {
    if (!profile) return 0;
    long long userID = DMNumber(DMGetter(profile, @"profileViewControllerUserContext"), @"userID");
    if (userID > 0) return userID;
    id viewModel = DMIvar(profile, "_viewModel");
    userID = DMNumber(viewModel, @"userID");
    if (userID > 0) return userID;
    return DMNumber(DMGetter(viewModel, @"user"), @"userID");
}

// MARK: - XChat state (read only)

static NSString* const kXChatScreenClass = @"_TtC14T1TwitterSwift19XChatViewController";

// Which user XChat's one root component is for right now:
// -[XChatRootComponentProvider currentRootComponentUserID] (NSNumber).
static NSString* DMXChatRootUserID(void) {
    Class providerClass = objc_getClass("XChatRootComponentProvider");
    SEL shared = NSSelectorFromString(@"shared");
    if (!providerClass || ![providerClass respondsToSelector:shared]) return @"(no provider)";
    @try {
        id provider = ((id (*)(id, SEL))objc_msgSend)(providerClass, shared);
        id userID = DMGetter(provider, @"currentRootComponentUserID");
        return userID ? [NSString stringWithFormat:@"%@", userID] : @"(none)";
    } @catch (NSException* exception) {
        return [NSString stringWithFormat:@"(threw %@)", exception.name];
    }
}

static void DMCollectXChatScreens(UIViewController* controller, NSMutableArray<NSString*>* out, int depth) {
    if (!controller || depth > 24 || out.count >= 8) return;
    if ([NSStringFromClass([controller class]) isEqualToString:kXChatScreenClass]) {
        const void* address = DMRawIvar(controller, "account");
        [out addObject:[NSString stringWithFormat:@"account=%@%@", DMAccountIDAtAddress(address) ?: (address ? @"(not a signed-in account object)" : @"(no ivar)"),
                                                  controller.viewIfLoaded.window ? @" on screen" : @""]];
    }
    NSArray* children = [controller isKindOfClass:[UINavigationController class]] ? ((UINavigationController*)controller).viewControllers
                                                                                 : controller.childViewControllers;
    for (UIViewController* child in children) DMCollectXChatScreens(child, out, depth + 1);
    if (controller.presentedViewController) DMCollectXChatScreens(controller.presentedViewController, out, depth + 1);
}

// MARK: - Entry points found at runtime

static BOOL gDMButtonHooked;

static NSString* DMFound(NSString* className, NSString* selectorName, BOOL classMethod) {
    Class cls = objc_getClass(className.UTF8String);
    if (!cls) return [NSString stringWithFormat:@"%@: class missing", className];
    SEL selector = NSSelectorFromString(selectorName);
    BOOL found = classMethod ? class_getClassMethod(cls, selector) != NULL : class_getInstanceMethod(cls, selector) != NULL;
    return [NSString stringWithFormat:@"%@[%@ %@]: %@", classMethod ? @"+" : @"-", className, selectorName, found ? @"found" : @"MISSING"];
}

static NSString* DMEntryPointsText(void) {
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    [lines addObject:[DMFound(@"MessageButtonViewModel", @"didTap:", NO) stringByAppendingString:gDMButtonHooked ? @" (hooked)" : @" (not hooked)"]];
    Class model = objc_getClass("MessageButtonViewModel");
    [lines addObject:[NSString stringWithFormat:@"MessageButtonViewModel ivars: account=%d profileViewModel=%d",
                                                model && class_getInstanceVariable(model, "account") != NULL,
                                                model && class_getInstanceVariable(model, "profileViewModel") != NULL]];
    [lines addObject:DMFound(@"T1XChatViewControllerFactory", @"createOneOnOneConversationWithAccount:userID:", YES)];
    [lines addObject:DMFound(@"T1XChatViewControllerFactory", @"createWithAccount:conversationID:", YES)];
    [lines addObject:DMFound(@"T1XChatConversationIDFactory", @"oneOnOneConversationIDWithAccountUserID:recipientUserID:", YES)];
    [lines addObject:DMFound(@"T1TabbedAppNavigation", @"showXChatWithConversationID:account:source:completion:", NO)];
    [lines addObject:DMFound(@"_TtC14T1TwitterSwift20XTabbedAppNavigation", @"showXChatWithConversationID:account:source:completion:", NO)];
    [lines addObject:DMFound(@"T1TabbedAppNavigation",
                             @"showMessagesComposeWithRecipient:text:welcomeMessageID:navigationContext:source:completion:", NO)];
    [lines addObject:DMFound(@"T1ShareSheetBuilder",
                             @"buildXChatShareSheetWithAccount:link:shareable:status:actionItems:useAlternateBackgroundColor:didDismissBlock:", YES)];
    [lines addObject:DMFound(@"XChatRootComponentProvider", @"shared", YES)];
    [lines addObject:DMFound(@"XChatRootComponentProvider", @"currentRootComponentUserID", NO)];
    Class screen = objc_getClass(kXChatScreenClass.UTF8String);
    [lines addObject:[NSString stringWithFormat:@"XChatViewController: class=%d account ivar=%d", screen != Nil,
                                                screen && class_getInstanceVariable(screen, "account") != NULL]];
    return [lines componentsJoinedByString:@"\n"];
}

// MARK: - The question

static NSString* const kDMNoBReason = @"이 X 버전에서는 B로 열 수 없어요";

// asA runs X's own path, as the account in use.
static void DMAsk(long long userID, NSString* contextID, void (^asA)(void)) {
    NSString* aID = DMAccountUserID(DMCurrentAccount());
    NSString* bID = DMBID();
    // The answer holds only for the accounts in use when asked.
    BOOL (^same)(void) = ^BOOL {
        if (DMActive() && [DMAccountUserID(DMCurrentAccount()) isEqualToString:aID] && [DMBID() isEqualToString:bID]) return YES;
        DMLog(@"blocked: accounts changed while the sheet was up");
        NFBShowNotice(@"계정이 바뀌어서 열지 않았어요");
        return NO;
    };
    UIColor* purple = [UIColor colorWithRed:0.47 green:0.34 blue:1 alpha:1];
    NSArray<NSDictionary*>* rows = @[
        @{
            @"title" : DMAName(),
            @"detail" : @"A 계정",
            @"image" : DMAvatar(aID, @"A", purple),
            @"action" : ^{
                if (!same()) return;
                DMLog([NSString stringWithFormat:@"dm as A for %lld via X's own -[MessageButtonViewModel didTap:]", userID]);
                asA();
            }
        },
        // No provable way to open XChat as B in 12.44 (see the header): shown, not usable.
        @{
            @"title" : DMBName(),
            @"detail" : kDMNoBReason,
            @"image" : DMAvatar(bID, @"B", NFBUnifiedBColor()),
            @"disabled" : @YES
        },
    ];
    NFBPresentAccountSheet(@"어느 계정으로 DM을 보낼까요?", nil, rows);
    DMLog([NSString stringWithFormat:@"dm sheet for %lld (context %@)", userID, contextID ?: @"-"]);
    DMLog([NSString stringWithFormat:@"dm B row disabled: single XChat root component (now for %@)", DMXChatRootUserID()]);
}

// MARK: - Hook

%group UnifiedDMProfileButton

%hook MessageButtonViewModel

- (void)didTap:(id)sender {
    if (!DMActive()) {
        %orig;
        return;
    }
    NSString* aID = DMAccountUserID(DMCurrentAccount());
    NSString* bID = DMBID();
    NSString* how = nil;
    UIViewController* profile = DMProfileForSender(sender, &how);
    long long userID = DMProfileUserID(profile);
    NSString* targetID = userID > 0 ? [NSString stringWithFormat:@"%lld", userID] : nil;

    // Whose screen this is: the button's own account (the one X's path would
    // use), told by address; the profile's -account says the same on a profile.
    NSString* modelAccountID = DMAccountIDAtAddress(DMRawIvar(self, "account"));
    NSString* profileAccountID = DMAccountUserID(DMGetter(profile, @"account"));
    const void* modelProfile = DMRawIvar(self, "profileViewModel");
    BOOL sameViewModel = modelProfile && modelProfile == (__bridge const void*)DMIvar(profile, "_viewModel");
    DMLog([NSString stringWithFormat:@"dm tap: user %@ profile %@ (button's own view model: %@) button account %@ profile account %@ sender %@",
                                     targetID ?: @"?", how, sameViewModel ? @"yes" : @"no", modelAccountID ?: @"?", profileAccountID ?: @"?",
                                     sender ? NSStringFromClass([sender class]) : @"nil"]);

    if (modelAccountID.length && profileAccountID.length && ![modelAccountID isEqualToString:profileAccountID]) {
        DMLog(@"blocked: the button's account and the profile's account differ");
        NFBShowNotice(@"어느 계정 화면인지 확인하지 못해서 DM을 열지 않았어요");
        return;
    }
    NSString* contextID = modelAccountID.length ? modelAccountID : profileAccountID;
    if (contextID.length == 0) {
        DMLog(@"blocked: the screen's account is not known");
        NFBShowNotice(@"어느 계정 화면인지 확인하지 못해서 DM을 열지 않았어요");
        return;
    }
    if ([contextID isEqualToString:bID]) {
        // A B screen: the user means B. X's own path from here would go through
        // the one XChat session, which cannot be shown to be B's.
        DMLog([NSString stringWithFormat:@"blocked: B context for %@, no provable way to open XChat as B (root component now for %@)",
                                         targetID ?: @"?", DMXChatRootUserID()]);
        // Decided 7.3.151: in unified mode chat is A's only; B's is used after
        // switching to B.
        NFBShowNotice([NSString stringWithFormat:@"쪽지는 %@ 계정으로 전환해서 보내주세요", DMBName()]);
        return;
    }
    if (![contextID isEqualToString:aID]) {
        // A third account's screen: not this mode's business.
        DMLog([NSString stringWithFormat:@"dm tap in context %@: left to X", contextID]);
        %orig;
        return;
    }
    if (!targetID || [targetID isEqualToString:aID] || [targetID isEqualToString:bID]) {
        // No one to choose for (the target is not known, or is A or B itself):
        // A's own screen, A's own path.
        DMLog([NSString stringWithFormat:@"dm tap for %@ in A context: no question, left to X", targetID ?: @"?"]);
        %orig;
        return;
    }
    // No question while B cannot be opened: a sheet whose B row is always off
    // only adds a tap. DMAsk stays for the day XChat can be opened as B.
    DMLog([NSString stringWithFormat:@"dm as A for %lld via X's own -[MessageButtonViewModel didTap:] (no sheet: B not openable; root component now for %@)",
                                     userID, DMXChatRootUserID()]);
    %orig;
}

%end

%end

// MARK: - Debug

NSString* NFBUnifiedDMDebugText(void) {
    NSMutableString* out = [NSMutableString string];
    NSString* aID = DMAccountUserID(DMCurrentAccount());
    [out appendFormat:@"active=%d inUse=%@ B=%@\n", DMActive(), aID ?: @"-", DMBID() ?: @"-"];
    [out appendFormat:@"entry points:\n%@\n", DMEntryPointsText()];
    [out appendFormat:@"XChat root component user: %@\n", DMXChatRootUserID()];
    NSMutableArray<NSString*>* screens = [NSMutableArray array];
    @try {
        DMCollectXChatScreens(DMKeyWindow().rootViewController, screens, 0);
    } @catch (__unused NSException* exception) {
    }
    [out appendFormat:@"XChat screens: %@\n", screens.count ? [screens componentsJoinedByString:@"; "] : @"(none)"];
    @synchronized([NSObject class]) {
        [out appendFormat:@"%@\n", gDMLog.count ? [gDMLog componentsJoinedByString:@"\n"] : @"(no events)"];
    }
    return out;
}

%ctor {
    // Installed only when 12.44's class and method are there.
    Class model = objc_getClass("MessageButtonViewModel");
    gDMButtonHooked = model && class_getInstanceMethod(model, NSSelectorFromString(@"didTap:")) != NULL;
    if (gDMButtonHooked) {
        %init(UnifiedDMProfileButton);
    }
    DMLog([NSString stringWithFormat:@"profile message button -[MessageButtonViewModel didTap:]: %@", gDMButtonHooked ? @"hooked" : @"not found"]);
}
