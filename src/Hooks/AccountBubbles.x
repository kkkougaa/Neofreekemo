//
//  AccountBubbles.x
//  NeoFreeBird
//
//  Long-pressing the profile picture at the top left normally opens X's account
//  list. When this is on, the accounts pop out as circles instead: drag onto one
//  and let go to switch, or let go first and tap one. Switching uses X's own
//  -[T1HostViewController viewAccount:animated:].
//
//  7.3.20 hooked -[T1TabNavigationController _t1_action_didLongPressDashButton:],
//  which this X build never calls, and fanned the circles upward from the top
//  left corner, off screen. This version puts its own long press on the avatar
//  button in the navigation bar, makes X's own long press wait for it, and fans
//  the circles toward the middle of the screen. With fewer than two accounts the
//  press stands aside and X's sheet opens as before.
//
//  7.3.22: on iOS 26 the avatar sits in a SwiftUI platter and X's sheet still
//  won. Now X's sheet itself is caught when it is presented after a held
//  finger, and the circles open in its place, following that finger.
//
//  7.3.23: profile pictures (from X's on-screen avatars, or any getter giving a
//  profile_images address), an unread badge per account, and circles pushed
//  apart so five or more never overlap near a corner.
//
//  7.3.24: one even arc (quarter circle from a corner) that slides as a whole
//  to stay on screen; unread badges read off X's own account list rows; the
//  name tag sits above the arc, away from the thumb.
//
//  7.3.25: a Liquid Glass gear at the far end of the arc opens a list where
//  the accounts can be dragged into the order the circles use.
//
//  7.3.27: profile pictures are kept on disk (Application Support) and only
//  downloaded again when an account's picture address changes.
//
//  7.3.38: long-pressing the Home tab lifts the whole screen up like a card and
//  shows the accounts in a row on a black dock underneath; tap one to switch.
//  Tapping or pulling down the lifted screen puts it back.
//
//  7.3.39: opening the notifications tab clears that account's remembered
//  unread number, so its badge no longer comes back after switching away.
//
//  7.3.40: the dock no longer switches by sliding the held finger onto an
//  account; the press only lifts the screen and accounts are picked by tap.
//
//  7.3.41: the circles and the dock have their own switches, so either one,
//  both or neither can be used.
//
//  7.3.42: dock circles show the picture edge to edge under a clear Liquid
//  Glass pane, instead of a small picture inside a glass ring.
//
//  7.3.43: the glass covers only a thin band at the edge (it lensed whole
//  faces out of shape), with a faint sheen over the picture.
//
//  7.3.44: bigger dock circles, five to a screen with the gear a scroll away;
//  unread numbers read off X's list are kept on disk across relaunches.
//
//  7.3.45: the glass covers the whole picture again, but as a larger pane cut
//  back to the circle, so only the gentle middle of it bends the face.
//
//  7.3.46: 22% overhang cut away all of the visible glass (the clear pane's
//  calm middle shows nothing over a photo); 8% keeps part of the edge bend.
//
//  7.3.47: with the bigger 7.3.44 circles the glass bends less for its size,
//  so the pane is the circle's own size again (no overhang).
//
//  7.3.48: dock circles squash under the finger and spring back when let go.
//
//  7.3.49: the dock no longer uses UIKit's Liquid Glass (no way to soften its
//  bending); the glass look is drawn: a magnified rim band, a sheen and a
//  rim light, each with its own strength.

#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import "HookHelpers.h"

static const NSInteger kBubbleLimit = 8;
static const CGFloat kBubbleSize = 56.0;
static const CGFloat kHitRadius = 44.0;

@class NFBAccountDock;
static __weak NFBAccountDock* gLiveDock = nil;

// The circles from the top left avatar.
static BOOL BubblesOn(void) {
    return [BHTSettings boolForKey:@"kemo_account_bubbles"];
}

// The dock from a long press on the Home tab.
static BOOL DockOn(void) {
    return [BHTSettings boolForKey:@"kemo_account_dock"];
}

// MARK: - Account data

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
    if (!returnType || returnType[0] != '@') {
        return nil;
    }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException* exception) {
        return nil;
    }
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

static id HostController(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass || ![hostClass respondsToSelector:@selector(sharedHostViewController)]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
}

static id CurrentAccount(void) {
    return ObjectProp(HostController(), @"currentAccount");
}

static NSString* AccountKey(id account) {
    id user = ObjectProp(account, @"user");
    for (id source in @[ account ?: [NSNull null], user ?: [NSNull null] ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in @[ @"userID", @"userId", @"userIDString", @"username", @"screenName" ]) {
            SEL selector = NSSelectorFromString(name);
            if (![source respondsToSelector:selector]) {
                continue;
            }
            NSMethodSignature* signature = [source methodSignatureForSelector:selector];
            const char* type = signature.methodReturnType;
            if (!type) {
                continue;
            }
            if (type[0] == '@') {
                id value = ObjectProp(source, name);
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                    return [value lowercaseString];
                }
                if ([value isKindOfClass:[NSNumber class]]) {
                    return [value stringValue];
                }
            } else if (type[0] == 'q' || type[0] == 'Q' || type[0] == 'l' || type[0] == 'L') {
                long long value = ((long long (*)(id, SEL))objc_msgSend)(source, selector);
                if (value != 0) {
                    return [NSString stringWithFormat:@"%lld", value];
                }
            }
        }
    }
    return nil;
}

static BOOL SameAccount(id a, id b) {
    if (!a || !b) {
        return NO;
    }
    if (a == b) {
        return YES;
    }
    NSString* keyA = AccountKey(a);
    NSString* keyB = AccountKey(b);
    return keyA && keyB && [keyA isEqualToString:keyB];
}

static BOOL SwitchToAccount(id account) {
    id host = HostController();
    SEL selector = @selector(viewAccount:animated:);
    if (!account || !host || ![host respondsToSelector:selector]) {
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(host, selector, account, YES);
        return YES;
    } @catch (__unused NSException* exception) {
        return NO;
    }
}

static NSString* AccountTitle(id account) {
    if (!account) {
        return @"";
    }
    id user = ObjectProp(account, @"user");
    for (id source in @[ user ?: [NSNull null], account ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in @[ @"username", @"screenName", @"displayUsername" ]) {
            NSString* value = StringProp(source, name);
            if (value.length > 0) {
                return [value hasPrefix:@"@"] ? value : [@"@" stringByAppendingString:value];
            }
        }
        for (NSString* name in @[ @"fullName", @"displayFullName", @"name" ]) {
            NSString* value = StringProp(source, name);
            if (value.length > 0) {
                return value;
            }
        }
    }
    return @"";
}

static NSString* ProbedImageString(id account);

static NSURL* AccountImageURL(id account) {
    if (!account) {
        return nil;
    }
    id user = ObjectProp(account, @"user");
    for (id source in @[ user ?: [NSNull null], account ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in @[ @"profileImageURL", @"profileImageUrl", @"profileImageURLString",
                                  @"profileImageURLHTTPS", @"avatarURL", @"avatarImageURL" ]) {
            id value = ObjectProp(source, name);
            NSString* string = nil;
            if ([value isKindOfClass:[NSURL class]]) {
                string = [value absoluteString];
            } else if ([value isKindOfClass:[NSString class]]) {
                string = value;
            }
            if (string.length == 0) {
                continue;
            }
            // The stored URL is usually the 48px "_normal" size.
            string = [string stringByReplacingOccurrencesOfString:@"_normal." withString:@"_bigger."];
            if ([string hasPrefix:@"http://"]) {
                string = [@"https://" stringByAppendingString:[string substringFromIndex:7]];
            }
            NSURL* url = [NSURL URLWithString:string];
            if (url) {
                return url;
            }
        }
    }
    // Names differ between X builds: look for any getter giving a profile_images address.
    NSString* probed = ProbedImageString(account);
    if (probed.length > 0) {
        probed = [probed stringByReplacingOccurrencesOfString:@"_normal." withString:@"_bigger."];
        if ([probed hasPrefix:@"http://"]) {
            probed = [@"https://" stringByAppendingString:[probed substringFromIndex:7]];
        }
        return [NSURL URLWithString:probed];
    }
    return nil;
}

// What the last probe found, for the shake dump.
static NSMutableArray<NSString*>* gProbeLog = nil;

static void ProbeNote(NSString* line) {
    if (!gProbeLog) {
        gProbeLog = [NSMutableArray array];
    }
    if (![gProbeLog containsObject:line]) {
        [gProbeLog addObject:line];
        if (gProbeLog.count > 24) {
            [gProbeLog removeObjectAtIndex:0];
        }
    }
}

// Zero-argument getters on the class chain (stopping at NSObject) whose name
// contains one of the words.
static NSArray<NSString*>* GettersMatching(id object, NSArray<NSString*>* words) {
    NSMutableArray* names = [NSMutableArray array];
    for (Class cls = object_getClass(object); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method* methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString* name = NSStringFromSelector(method_getName(methods[i]));
            if ([name containsString:@":"] || [name hasPrefix:@"set"] || [name hasPrefix:@"_"] ||
                [names containsObject:name]) {
                continue;
            }
            NSString* lower = name.lowercaseString;
            for (NSString* word in words) {
                if ([lower containsString:word]) {
                    [names addObject:name];
                    break;
                }
            }
        }
        free(methods);
    }
    return names;
}

static NSString* ProfileImageString(id value) {
    NSString* string = nil;
    if ([value isKindOfClass:[NSURL class]]) {
        string = [value absoluteString];
    } else if ([value isKindOfClass:[NSString class]]) {
        string = value;
    }
    return [string containsString:@"profile_images"] ? string : nil;
}

// Any getter on the user or account that hands back a pbs.twimg.com
// profile_images address.
static NSString* ProbedImageString(id account) {
    if (!account) {
        return nil;
    }
    id user = ObjectProp(account, @"user");
    for (id source in @[ user ?: [NSNull null], account ]) {
        if (source == [NSNull null]) {
            continue;
        }
        for (NSString* name in GettersMatching(source, @[ @"image", @"avatar" ])) {
            NSString* string = ProfileImageString(ObjectProp(source, name));
            if (string) {
                ProbeNote([NSString stringWithFormat:@"image: -[%@ %@]", NSStringFromClass([source class]), name]);
                return string;
            }
        }
    }
    ProbeNote([NSString stringWithFormat:@"image: none on %@ / %@", NSStringFromClass([user class]),
                                         NSStringFromClass([account class])]);
    return nil;
}

// X's own avatar views carry the user ID: "TUIAvatarImageView.<id>".
static UIImage* OnScreenAvatar(NSString* key) {
    if (key.length == 0) {
        return nil;
    }
    NSString* wanted = [@"TUIAvatarImageView." stringByAppendingString:key];
    for (UIWindow* window in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
        NSInteger budget = 6000;
        while (queue.count > 0 && budget-- > 0) {
            UIView* view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([view isKindOfClass:[UIImageView class]] && [view.accessibilityIdentifier isEqualToString:wanted]) {
                UIImage* image = ((UIImageView*)view).image;
                if (image) {
                    return image;
                }
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
    return nil;
}

static NSInteger NumberFromGetter(id object, NSString* name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) {
        return -1;
    }
    NSMethodSignature* signature = [object methodSignatureForSelector:selector];
    const char* type = signature.methodReturnType;
    if (!type) {
        return -1;
    }
    @try {
        switch (type[0]) {
            case 'q':
                return (NSInteger)((long long (*)(id, SEL))objc_msgSend)(object, selector);
            case 'Q':
                return (NSInteger)((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector);
            case 'i': case 'l':
                return (NSInteger)((int (*)(id, SEL))objc_msgSend)(object, selector);
            case 'I': case 'L':
                return (NSInteger)((unsigned int (*)(id, SEL))objc_msgSend)(object, selector);
            case '@': {
                id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
                return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : -1;
            }
            default:
                return -1;
        }
    } @catch (__unused NSException* exception) {
        return -1;
    }
}

// Unread notifications for an account, from whatever count getter it has.
// Prefers notification counts over other unread counts; -1 when none found.
static NSInteger AccountUnreadCount(id account) {
    for (NSArray<NSString*>* words in @[ @[ @"unreadnotification", @"notificationsunread", @"notificationbadge",
                                            @"notificationcount", @"notificationscount" ],
                                         @[ @"unread", @"badge" ] ]) {
        for (NSString* name in GettersMatching(account, words)) {
            NSString* lower = name.lowercaseString;
            if ([lower containsString:@"dm"] || [lower containsString:@"message"] ||
                [lower containsString:@"enabled"] || [lower containsString:@"should"] ||
                [lower hasPrefix:@"is"] || [lower hasPrefix:@"has"]) {
                continue;
            }
            NSInteger value = NumberFromGetter(account, name);
            if (value >= 0) {
                ProbeNote([NSString stringWithFormat:@"badge: -[%@ %@]", NSStringFromClass([account class]), name]);
                return value;
            }
        }
    }
    ProbeNote([NSString stringWithFormat:@"badge: none on %@", NSStringFromClass([account class])]);
    return -1;
}

// Unread counts read off X's own account list (T1PickableAccountEntryCell:
// a TUIAvatarImageView.<user id> plus a TFNBadgeView with the number).
static NSMutableDictionary<NSString*, NSNumber*>* gSheetCounts = nil;
static NSString* const kSheetCountsKey = @"kemo_account_unread_counts";

// The numbers last read off X's list, kept on disk so a relaunch (or an
// update) does not leave the circles and the dock without badges until X's
// list is opened again.
static NSMutableDictionary<NSString*, NSNumber*>* SheetCounts(void) {
    if (!gSheetCounts) {
        NSDictionary* saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSheetCountsKey];
        gSheetCounts = [saved isKindOfClass:[NSDictionary class]] ? [saved mutableCopy]
                                                                   : [NSMutableDictionary dictionary];
    }
    return gSheetCounts;
}

static void SaveSheetCounts(void) {
    [[NSUserDefaults standardUserDefaults] setObject:[SheetCounts() copy] forKey:kSheetCountsKey];
}

static NSInteger HarvestSheetCounts(UIView* root) {
    if (!root) {
        return 0;
    }
    NSInteger cells = 0;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:root];
    NSInteger budget = 3000;
    while (queue.count > 0 && budget-- > 0) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (![view isKindOfClass:[UITableViewCell class]] ||
            ![NSStringFromClass(view.class) containsString:@"AccountEntryCell"]) {
            [queue addObjectsFromArray:view.subviews];
            continue;
        }
        NSString* key = nil;
        NSInteger count = 0;
        NSMutableArray<UIView*>* inner = [NSMutableArray arrayWithObject:view];
        while (inner.count > 0) {
            UIView* sub = inner.firstObject;
            [inner removeObjectAtIndex:0];
            NSString* identifier = sub.accessibilityIdentifier;
            if (!key && [identifier hasPrefix:@"TUIAvatarImageView."]) {
                key = [identifier substringFromIndex:@"TUIAvatarImageView.".length];
            }
            if (!sub.hidden && sub.alpha > 0.01 && [NSStringFromClass(sub.class) containsString:@"BadgeView"]) {
                NSMutableArray<UIView*>* labels = [NSMutableArray arrayWithObject:sub];
                while (labels.count > 0) {
                    UIView* label = labels.firstObject;
                    [labels removeObjectAtIndex:0];
                    if ([label isKindOfClass:[UILabel class]] && ((UILabel*)label).text.integerValue > 0) {
                        count = ((UILabel*)label).text.integerValue;
                        break;
                    }
                    [labels addObjectsFromArray:label.subviews];
                }
            }
            [inner addObjectsFromArray:sub.subviews];
        }
        if (key.length > 0) {
            SheetCounts()[key] = @(count);
            cells++;
        }
    }
    if (cells > 0) {
        SaveSheetCounts();
        ProbeNote([NSString stringWithFormat:@"badge: read %ld rows of X's account list", (long)cells]);
    }
    return cells;
}

// The notifications tab was looked at: the account in use has nothing unread
// any more, whatever X's list said the last time it was read.
static void MarkCurrentAccountSeen(void) {
    NSString* key = AccountKey(CurrentAccount());
    if (key.length == 0) {
        return;
    }
    SheetCounts()[key] = @0;
    SaveSheetCounts();
}

static NSInteger BadgeCountFor(id account) {
    NSString* key = AccountKey(account);
    NSNumber* seen = key ? SheetCounts()[key] : nil;
    if (seen) {
        return seen.integerValue;
    }
    return AccountUnreadCount(account);
}

// MARK: - Account order

static NSString* const kOrderKey = @"kemo_account_bubble_order";

static NSString* OrderTitle(void) {
    NSString* language = NSLocale.preferredLanguages.firstObject ?: @"en";
    if ([language hasPrefix:@"ko"]) {
        return @"계정 순서";
    }
    if ([language hasPrefix:@"ja"]) {
        return @"アカウントの順番";
    }
    return @"Account order";
}

// X's accounts sorted by the saved order; accounts not in it keep X's order
// and go last.
static NSArray* OrderedAccounts(NSArray* accounts) {
    NSArray* saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kOrderKey];
    if (saved.count == 0 || accounts.count < 2) {
        return accounts;
    }
    NSMutableArray* placed = [NSMutableArray array];
    NSMutableArray* rest = [NSMutableArray arrayWithArray:accounts];
    for (id key in saved) {
        for (id account in rest) {
            if ([AccountKey(account) isEqual:key]) {
                [placed addObject:account];
                [rest removeObject:account];
                break;
            }
        }
    }
    [placed addObjectsFromArray:rest];
    return placed;
}

static void SaveOrder(NSArray* accounts) {
    NSMutableArray* keys = [NSMutableArray array];
    for (id account in accounts) {
        NSString* key = AccountKey(account);
        if (key.length > 0) {
            [keys addObject:key];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:keys forKey:kOrderKey];
}

static NSCache<NSString*, UIImage*>* AvatarCache(void) {
    static NSCache* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 40;
    });
    return cache;
}

// MARK: - Avatars kept on disk
//
// Library/Application Support/NFBAccountAvatars/<user id>.img, plus index.plist
// mapping each user id to the profile_images address the file came from.
// Application Support is never purged by iOS (unlike Caches), so a picture
// stays until the account's address changes, which only happens when the
// profile picture itself is changed. Index reads and writes stay on the main
// thread; file writes go to a background queue.

static NSString* AvatarDirectory(void) {
    static NSString* directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL* base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
        NSURL* folder = [base URLByAppendingPathComponent:@"NFBAccountAvatars" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:folder
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
        [folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        directory = [folder.path copy];
    });
    return directory;
}

static NSString* AvatarFileKey(NSString* key) {
    NSCharacterSet* bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    return [[key componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
}

static NSString* AvatarPath(NSString* key) {
    return [AvatarDirectory() stringByAppendingPathComponent:[AvatarFileKey(key) stringByAppendingString:@".img"]];
}

static NSMutableDictionary<NSString*, NSString*>* AvatarIndex(void) {
    static NSMutableDictionary* index;
    if (!index) {
        NSString* path = [AvatarDirectory() stringByAppendingPathComponent:@"index.plist"];
        NSDictionary* saved = [NSDictionary dictionaryWithContentsOfFile:path];
        index = [NSMutableDictionary dictionaryWithDictionary:saved ?: @{}];
    }
    return index;
}

static void SaveAvatarIndex(void) {
    NSDictionary* snapshot = [AvatarIndex() copy];
    NSString* path = [AvatarDirectory() stringByAppendingPathComponent:@"index.plist"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [snapshot writeToFile:path atomically:YES];
    });
}

// Memory first, then the file on disk.
static UIImage* StoredAvatar(NSString* key) {
    if (key.length == 0) {
        return nil;
    }
    UIImage* image = [AvatarCache() objectForKey:key];
    if (image) {
        return image;
    }
    NSData* data = [NSData dataWithContentsOfFile:AvatarPath(key)];
    image = data.length > 0 ? [UIImage imageWithData:data] : nil;
    if (image) {
        [AvatarCache() setObject:image forKey:key];
    }
    return image;
}

// Main thread. `source` is the profile_images address, or @"" when the picture
// was taken from X's on-screen avatar and its address is not known yet.
static void StoreAvatar(NSString* key, NSData* data, UIImage* image, NSString* source) {
    if (key.length == 0 || !image) {
        return;
    }
    [AvatarCache() setObject:image forKey:key];
    NSData* bytes = data.length > 0 ? data : UIImagePNGRepresentation(image);
    if (bytes.length == 0) {
        return;
    }
    NSString* path = AvatarPath(key);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [bytes writeToFile:path atomically:YES];
    });
    AvatarIndex()[key] = source ?: @"";
    SaveAvatarIndex();
}

// Hands back the stored picture right away, then a fresh one only if the
// account's picture address differs from the one the stored file came from.
// `done` runs on the main thread, once or twice.
static void LoadAvatar(id account, void (^done)(UIImage* image)) {
    NSString* key = AccountKey(account);
    UIImage* stored = StoredAvatar(key);
    if (!stored) {
        stored = OnScreenAvatar(key);
        if (stored) {
            StoreAvatar(key, nil, stored, @"");
        }
    }
    if (stored) {
        done(stored);
    }
    NSURL* url = AccountImageURL(account);
    if (!url || key.length == 0) {
        return;
    }
    NSString* source = url.absoluteString;
    if (stored && [AvatarIndex()[key] isEqualToString:source]) {
        return;
    }
    [[[NSURLSession sharedSession]
          dataTaskWithURL:url
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            UIImage* image = data.length > 0 && !error ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!image) {
                    ProbeNote([NSString stringWithFormat:@"download failed %@: %@", url.host,
                                                         error.localizedDescription ?: @"no image data"]);
                    return;
                }
                StoreAvatar(key, data, image, source);
                done(image);
            });
        }] resume];
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

static UIColor* AccentColor(void) {
    UIWindow* window = UIApplication.sharedApplication.windows.firstObject;
    return window.tintColor ?: [UIColor systemBlueColor];
}

static void Tick(void) {
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        return;
    }
    UISelectionFeedbackGenerator* tap = [UISelectionFeedbackGenerator new];
    [tap selectionChanged];
}

// MARK: - Bubble views

@interface NFBAccountBubble : UIView
@property (nonatomic, strong) id account;
@property (nonatomic, assign) CGPoint slot;
@property (nonatomic, assign) BOOL settled;
@property (nonatomic, assign) BOOL current;
@property (nonatomic, assign) BOOL settings;
@property (nonatomic, strong) UIImageView* avatar;
@property (nonatomic, strong) UILabel* initial;
@property (nonatomic, strong) UILabel* badge;
// The dock's magnified copy of the picture along the rim (see PutGlassOverBubble).
@property (nonatomic, weak) UIImageView* lens;
- (void)setCount:(NSInteger)count;
@end

@implementation NFBAccountBubble

- (instancetype)initWithAccount:(id)account current:(BOOL)current {
    if ((self = [super initWithFrame:CGRectMake(0, 0, kBubbleSize, kBubbleSize)])) {
        _account = account;
        _current = current;
        self.userInteractionEnabled = NO;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.22;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        UIVisualEffectView* glass = [[UIVisualEffectView alloc] initWithEffect:BubbleEffect()];
        glass.frame = self.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerRadius = kBubbleSize / 2.0;
        glass.clipsToBounds = YES;
        glass.layer.borderWidth = current ? 2.5 : 1.0;
        glass.layer.borderColor =
            current ? AccentColor().CGColor : [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        [self addSubview:glass];

        NSString* title = AccountTitle(account);
        _initial = [[UILabel alloc] initWithFrame:self.bounds];
        _initial.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _initial.textAlignment = NSTextAlignmentCenter;
        _initial.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
        _initial.textColor = [UIColor labelColor];
        NSString* letters = [title stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"@"]];
        _initial.text = letters.length > 0 ? [[letters substringToIndex:1] uppercaseString] : @"?";
        [self addSubview:_initial];

        _avatar = [[UIImageView alloc] initWithFrame:CGRectInset(self.bounds, 4, 4)];
        _avatar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _avatar.layer.cornerRadius = CGRectGetWidth(_avatar.bounds) / 2.0;
        _avatar.clipsToBounds = YES;
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        [self addSubview:_avatar];

        // Unread notifications, top right, like X's own badge.
        _badge = [UILabel new];
        _badge.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        _badge.textColor = [UIColor whiteColor];
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.backgroundColor = AccentColor();
        _badge.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
        _badge.layer.borderWidth = 2;
        _badge.clipsToBounds = YES;
        _badge.hidden = YES;
        [self addSubview:_badge];

        self.isAccessibilityElement = YES;
        self.accessibilityLabel = title;
    }
    return self;
}

- (void)setCount:(NSInteger)count {
    if (count <= 0 || self.settings) {
        self.badge.hidden = YES;
        return;
    }
    self.badge.text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    CGFloat height = 22;
    CGFloat width = MAX(height, [self.badge.text sizeWithAttributes:@{NSFontAttributeName : self.badge.font}].width + 12);
    self.badge.frame = CGRectMake(CGRectGetWidth(self.bounds) - width + 6, -4, width, height);
    self.badge.layer.cornerRadius = height / 2.0;
    self.badge.hidden = NO;
    self.accessibilityValue = self.badge.text;
}

// The gear at the end of the arc that opens the order editor.
- (instancetype)initSettings {
    if ((self = [self initWithAccount:nil current:NO])) {
        _settings = YES;
        UIImageSymbolConfiguration* config =
            [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
        self.avatar.image = [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:config];
        self.avatar.contentMode = UIViewContentModeCenter;
        self.avatar.tintColor = [UIColor labelColor];
        self.initial.hidden = YES;
        self.accessibilityLabel = OrderTitle();
    }
    return self;
}

- (void)setImage:(UIImage*)image {
    self.avatar.image = image;
    self.lens.image = image;
    self.initial.hidden = image != nil;
}

@end

// MARK: - Order editor

// A plain reorderable list: drag the handles, the order is saved on every move.
@interface NFBAccountOrderController : UITableViewController
@property (nonatomic, strong) NSMutableArray* accounts;
@end

@implementation NFBAccountOrderController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _accounts = [NSMutableArray arrayWithArray:OrderedAccounts(TwitterAccounts() ?: @[])];
        self.title = OrderTitle();
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 60;
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = NO;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(done)];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return self.accounts.count;
}

- (UIImage*)roundImage:(UIImage*)image {
    CGFloat side = 36;
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, side, side)] addClip];
        [image drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"account"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"account"];
    }
    id account = self.accounts[indexPath.row];
    id user = ObjectProp(account, @"user");
    NSString* name = nil;
    for (NSString* selector in @[ @"fullName", @"displayFullName", @"name" ]) {
        name = StringProp(user, selector) ?: StringProp(account, selector);
        if (name.length > 0) {
            break;
        }
    }
    NSString* handle = AccountTitle(account);
    cell.textLabel.text = name.length > 0 ? name : handle;
    cell.detailTextLabel.text = name.length > 0 ? handle : nil;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    cell.imageView.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
    cell.imageView.tintColor = [UIColor tertiaryLabelColor];
    __weak UITableViewCell* weakCell = cell;
    __weak typeof(self) weakSelf = self;
    LoadAvatar(account, ^(UIImage* image) {
        UITableViewCell* shown = weakCell;
        NSIndexPath* path = shown ? [weakSelf.tableView indexPathForCell:shown] : nil;
        if (!shown || (path && weakSelf.accounts[path.row] != account)) {
            return;
        }
        shown.imageView.image = [weakSelf roundImage:image];
        [shown setNeedsLayout];
    });
    return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView*)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath*)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView*)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath*)indexPath {
    return NO;
}

- (BOOL)tableView:(UITableView*)tableView canMoveRowAtIndexPath:(NSIndexPath*)indexPath {
    return YES;
}

- (void)tableView:(UITableView*)tableView
    moveRowAtIndexPath:(NSIndexPath*)from
           toIndexPath:(NSIndexPath*)to {
    id account = self.accounts[from.row];
    [self.accounts removeObjectAtIndex:from.row];
    [self.accounts insertObject:account atIndex:to.row];
    SaveOrder(self.accounts);
    Tick();
}

@end

static void ShowOrderEditor(void) {
    UIWindow* window = nil;
    for (UIWindow* candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) {
            window = candidate;
            break;
        }
    }
    UIViewController* top = (window ?: UIApplication.sharedApplication.windows.firstObject).rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    if (!top) {
        return;
    }
    UINavigationController* nav =
        [[UINavigationController alloc] initWithRootViewController:[NFBAccountOrderController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController* sheet = nav.sheetPresentationController;
        sheet.detents = @[ [UISheetPresentationControllerDetent mediumDetent],
                           [UISheetPresentationControllerDetent largeDetent] ];
        sheet.prefersGrabberVisible = YES;
    }
    [top presentViewController:nav animated:YES completion:nil];
}

@interface NFBAccountFan : UIView
@property (nonatomic, strong) NSArray<NFBAccountBubble*>* bubbles;
@property (nonatomic, weak) NFBAccountBubble* hovered;
@property (nonatomic, strong) UIView* dim;
@property (nonatomic, strong) UILabel* nameTag;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, assign) CGPoint tagAnchor;
- (void)refreshCounts;
@end

static __weak NFBAccountFan* gLiveFan = nil;

@implementation NFBAccountFan

- (instancetype)initWithFrame:(CGRect)frame
                     accounts:(NSArray*)accounts
                       origin:(CGPoint)origin
                         safe:(UIEdgeInsets)safe {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
        _dim.alpha = 0;
        [self addSubview:_dim];
        [UIView animateWithDuration:0.2 animations:^{
            self.dim.alpha = 1;
        }];

        id current = CurrentAccount();
        accounts = OrderedAccounts(accounts);
        NSInteger accountCount = MIN((NSInteger)accounts.count, kBubbleLimit);
        // One more slot at the far end of the arc for the settings gear.
        NSInteger count = accountCount + 1;

        // One even arc around the finger. From a corner it is a quarter circle
        // pointing into the screen; elsewhere it opens toward the middle. The
        // radius grows until neighbours are a full circle apart, then the whole
        // arc slides (never squashes) to stay on screen.
        CGFloat pad = kBubbleSize / 2.0 + 8.0;
        CGRect allowed = UIEdgeInsetsInsetRect(frame, UIEdgeInsetsMake(safe.top + pad, safe.left + pad,
                                                                        safe.bottom + pad, safe.right + pad));
        CGFloat width = CGRectGetWidth(frame);
        CGFloat height = CGRectGetHeight(frame);
        BOOL nearLeft = origin.x < width * 0.3, nearRight = origin.x > width * 0.7;
        BOOL nearTop = origin.y < height * 0.3, nearBottom = origin.y > height * 0.7;
        BOOL corner = (nearLeft || nearRight) && (nearTop || nearBottom);
        CGPoint pivot = CGPointMake(MAX(CGRectGetMinX(allowed) + 8, MIN(origin.x, CGRectGetMaxX(allowed) - 8)),
                                    MAX(CGRectGetMinY(allowed) + 8, MIN(origin.y, CGRectGetMaxY(allowed) - 8)));
        CGFloat aim, spread;
        if (corner) {
            aim = atan2(nearTop ? 1.0 : -1.0, nearLeft ? 1.0 : -1.0);
            spread = MIN((CGFloat)M_PI_2, (CGFloat)(count - 1) * (CGFloat)(M_PI / 6.0));
        } else {
            aim = atan2(CGRectGetMidY(frame) - pivot.y, CGRectGetMidX(frame) - pivot.x);
            spread = MIN((CGFloat)(M_PI * 5.0 / 6.0), (CGFloat)(count - 1) * (CGFloat)(M_PI * 35.0 / 180.0));
        }
        CGFloat gap = kBubbleSize + 16.0;
        CGFloat step = count > 1 ? spread / (CGFloat)(count - 1) : 0;
        CGFloat radius = count > 1 ? MAX(120.0, gap / (2.0 * sin(step / 2.0))) : 120.0;

        CGPoint slots[kBubbleLimit + 1];
        CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, minY = CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
        for (NSInteger i = 0; i < count; i++) {
            CGFloat angle = aim - spread / 2.0 + step * (CGFloat)i;
            slots[i] = CGPointMake(pivot.x + cos(angle) * radius, pivot.y + sin(angle) * radius);
            minX = MIN(minX, slots[i].x);
            maxX = MAX(maxX, slots[i].x);
            minY = MIN(minY, slots[i].y);
            maxY = MAX(maxY, slots[i].y);
        }
        CGFloat shiftX = MAX(0, CGRectGetMinX(allowed) - minX) - MAX(0, maxX - CGRectGetMaxX(allowed));
        CGFloat shiftY = MAX(0, CGRectGetMinY(allowed) - minY) - MAX(0, maxY - CGRectGetMaxY(allowed));
        for (NSInteger i = 0; i < count; i++) {
            slots[i].x += shiftX;
            slots[i].y += shiftY;
        }
        // The name tag sits above the whole arc: clear of the circles, and of
        // the thumb, which always comes from below.
        _tagAnchor = CGPointMake((minX + maxX) / 2.0 + shiftX, minY + shiftY - kBubbleSize / 2.0 - 26);

        NSMutableArray* bubbles = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) {
            BOOL gear = i == accountCount;
            id account = gear ? nil : accounts[i];
            NFBAccountBubble* bubble = gear ? [[NFBAccountBubble alloc] initSettings]
                                            : [[NFBAccountBubble alloc] initWithAccount:account
                                                                                current:SameAccount(account, current)];
            CGPoint slot = slots[i];
            bubble.slot = slot;
            bubble.center = origin;
            bubble.transform = CGAffineTransformMakeScale(0.15, 0.15);
            bubble.alpha = 0;
            [self addSubview:bubble];
            [bubbles addObject:bubble];
            [UIView animateWithDuration:0.46
                delay:i * 0.04
                usingSpringWithDamping:0.64
                initialSpringVelocity:0.7
                options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                animations:^{
                    bubble.center = bubble.slot;
                    bubble.alpha = 1;
                    bubble.transform = CGAffineTransformIdentity;
                }
                completion:^(BOOL finished) {
                    bubble.settled = YES;
                }];
            if (!gear) {
                [self loadImageForBubble:bubble];
                [bubble setCount:bubble.current ? 0 : BadgeCountFor(account)];
            }
        }
        _bubbles = bubbles;

        gLiveFan = self;

        _nameTag = [UILabel new];
        _nameTag.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _nameTag.textColor = [UIColor whiteColor];
        _nameTag.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
        _nameTag.textAlignment = NSTextAlignmentCenter;
        _nameTag.layer.cornerRadius = 14;
        _nameTag.clipsToBounds = YES;
        _nameTag.alpha = 0;
        [self addSubview:_nameTag];
    }
    return self;
}

- (void)refreshCounts {
    for (NFBAccountBubble* bubble in self.bubbles) {
        if (!bubble.settings) {
            [bubble setCount:bubble.current ? 0 : BadgeCountFor(bubble.account)];
        }
    }
}

- (void)loadImageForBubble:(NFBAccountBubble*)bubble {
    __weak NFBAccountBubble* weakBubble = bubble;
    LoadAvatar(bubble.account, ^(UIImage* image) {
        [weakBubble setImage:image];
    });
}

- (NFBAccountBubble*)bubbleNear:(CGPoint)point {
    NFBAccountBubble* best = nil;
    CGFloat bestDistance = kHitRadius;
    for (NFBAccountBubble* bubble in self.bubbles) {
        CGFloat distance = hypot(point.x - bubble.slot.x, point.y - bubble.slot.y);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = bubble;
        }
    }
    return best;
}

- (void)showName:(NFBAccountBubble*)bubble {
    if (!bubble) {
        [UIView animateWithDuration:0.12 animations:^{
            self.nameTag.alpha = 0;
        }];
        return;
    }
    self.nameTag.text = bubble.accessibilityLabel;
    [self.nameTag sizeToFit];
    CGRect frame = self.nameTag.frame;
    frame.size.width = MIN(frame.size.width + 24, CGRectGetWidth(self.bounds) - 32);
    frame.size.height = 28;
    self.nameTag.frame = frame;
    // Above the arc (see tagAnchor). If that is off the top, above the circle.
    CGPoint center = self.tagAnchor;
    if (center.y - 14 < self.safeAreaInsets.top + 8) {
        center = CGPointMake(bubble.slot.x, bubble.slot.y - kBubbleSize / 2.0 - 30);
        if (center.y - 14 < self.safeAreaInsets.top + 8) {
            center.y = bubble.slot.y + kBubbleSize / 2.0 + 30;
        }
    }
    CGFloat half = frame.size.width / 2.0;
    center.x = MAX(16 + half, MIN(center.x, CGRectGetWidth(self.bounds) - 16 - half));
    self.nameTag.center = center;
    [UIView animateWithDuration:0.12 animations:^{
        self.nameTag.alpha = 1;
    }];
}

- (void)hoverAt:(CGPoint)point {
    NFBAccountBubble* next = [self bubbleNear:point];
    if (next == self.hovered) {
        return;
    }
    self.hovered = next;
    for (NFBAccountBubble* bubble in self.bubbles) {
        if (!bubble.settled) {
            continue;
        }
        [UIView animateWithDuration:0.14
                         animations:^{
                             bubble.transform = bubble == next ? CGAffineTransformMakeScale(1.2, 1.2)
                                                               : CGAffineTransformIdentity;
                         }];
    }
    [self showName:next];
    if (next) {
        Tick();
    }
}

// Released without picking: keep the circles up and let the user tap one.
- (void)waitForTap {
    self.userInteractionEnabled = YES;
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(tapped:)];
    [self addGestureRecognizer:tap];
}

- (void)tapped:(UITapGestureRecognizer*)tap {
    NFBAccountBubble* bubble = [self bubbleNear:[tap locationInView:self]];
    if (bubble) {
        self.hovered = bubble;
        Tick();
        [self finishWith:bubble];
    } else {
        [self finishWith:nil];
    }
}

- (void)finishWith:(NFBAccountBubble*)chosen {
    if (self.closing) {
        return;
    }
    self.closing = YES;
    self.userInteractionEnabled = NO;
    id account = chosen && !chosen.current && !chosen.settings ? chosen.account : nil;
    BOOL openOrder = chosen.settings;
    [UIView animateWithDuration:0.2
        animations:^{
            self.alpha = 0;
            for (NFBAccountBubble* bubble in self.bubbles) {
                bubble.transform = bubble == chosen ? CGAffineTransformMakeScale(1.35, 1.35)
                                                    : CGAffineTransformMakeScale(0.3, 0.3);
            }
        }
        completion:^(BOOL finished) {
            [self removeFromSuperview];
            if (account) {
                SwitchToAccount(account);
            } else if (openOrder) {
                ShowOrderEditor();
            }
        }];
}

@end

// MARK: - Long press on the avatar button

@interface NFBAccountPress : UILongPressGestureRecognizer
@end

@implementation NFBAccountPress
@end

@interface NFBAccountPressHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NFBAccountFan* fan;
@property (nonatomic, assign) BOOL moved;
@property (nonatomic, assign) CGPoint start;
+ (instancetype)shared;
@end

@implementation NFBAccountPressHandler

+ (instancetype)shared {
    static NFBAccountPressHandler* handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handler = [NFBAccountPressHandler new];
    });
    return handler;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    if (!BubblesOn() || !gesture.view.window || self.fan.superview) {
        return NO;
    }
    // With one account there is nothing to switch to; X's sheet can add one.
    return TwitterAccounts().count >= 2;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return NO;
}

// X's own long press (the account sheet) and the bar-wide settings long press
// wait for this one, so they do not fire when the circles open.
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer*)other {
    if (other == gesture || [other isKindOfClass:[NFBAccountPress class]]) {
        return NO;
    }
    NSString* name = NSStringFromClass(other.class);
    BOOL pressLike = [other isKindOfClass:[UILongPressGestureRecognizer class]] ||
                     [name containsString:@"LongPress"] || [name containsString:@"ContextMenu"] ||
                     [name containsString:@"Preview"];
    if (!pressLike || !other.view || !gesture.view) {
        return NO;
    }
    return [other.view isDescendantOfView:gesture.view] || [gesture.view isDescendantOfView:other.view];
}

- (void)pressed:(NFBAccountPress*)press {
    UIWindow* window = press.view.window;
    switch (press.state) {
        case UIGestureRecognizerStateBegan: {
            NSArray* accounts = TwitterAccounts();
            if (!window || accounts.count < 2) {
                return;
            }
            UIView* avatar = press.view;
            CGPoint origin = [avatar convertPoint:CGPointMake(CGRectGetMidX(avatar.bounds),
                                                              CGRectGetMidY(avatar.bounds))
                                           toView:window];
            if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
                UIImpactFeedbackGenerator* thump =
                    [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [thump impactOccurred];
            }
            self.fan = [[NFBAccountFan alloc] initWithFrame:window.bounds
                                                   accounts:accounts
                                                     origin:origin
                                                       safe:window.safeAreaInsets];
            [window addSubview:self.fan];
            self.start = [press locationInView:window];
            self.moved = NO;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint point = [press locationInView:window];
            if (hypot(point.x - self.start.x, point.y - self.start.y) > 12) {
                self.moved = YES;
            }
            [self.fan hoverAt:point];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            NFBAccountFan* fan = self.fan;
            self.fan = nil;
            if (fan.hovered) {
                [fan finishWith:fan.hovered];
            } else if (!self.moved) {
                [fan waitForTap];
            } else {
                [fan finishWith:nil];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self.fan finishWith:nil];
            self.fan = nil;
            break;
        }
        default:
            break;
    }
}

@end

static BOOL LooksLikeAvatar(UIView* view) {
    NSString* name = NSStringFromClass(view.class);
    if ([name rangeOfString:@"Avatar" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return NO;
    }
    CGSize size = view.bounds.size;
    return !view.hidden && view.alpha > 0.01 && size.width >= 20 && size.width <= 64 && size.height >= 20 &&
           size.height <= 64;
}

// The view that should carry the press: the avatar's biggest small ancestor
// below the bar, preferring a control, that takes touches.
static UIView* PressHost(UIView* avatar, UINavigationBar* bar) {
    UIView* host = nil;
    UIView* control = nil;
    for (UIView* view = avatar; view && view != bar; view = view.superview) {
        CGSize size = view.bounds.size;
        if (size.width > 80 || size.height > 80) {
            break;
        }
        if (view.userInteractionEnabled) {
            host = view;
            if ([view isKindOfClass:[UIControl class]]) {
                control = view;
            }
        } else {
            host = nil;
        }
    }
    return control ?: host;
}

@interface NFBWeakView : NSObject
@property (nonatomic, weak) UIView* view;
@end

@implementation NFBWeakView
@end

static const void* kPressHostKey = &kPressHostKey;

static BOOL HasAccountPress(UIView* host) {
    for (UIGestureRecognizer* existing in host.gestureRecognizers) {
        if ([existing isKindOfClass:[NFBAccountPress class]]) {
            return YES;
        }
    }
    return NO;
}

static void AttachAccountPress(UINavigationBar* bar) {
    NFBWeakView* known = objc_getAssociatedObject(bar, kPressHostKey);
    if (known.view && [known.view isDescendantOfView:bar] && HasAccountPress(known.view)) {
        return;
    }
    UIView* found = nil;
    BOOL rtl = bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithArray:bar.subviews];
    NSInteger budget = 300;
    while (queue.count > 0 && budget-- > 0) {
        UIView* view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (view.hidden) {
            continue;
        }
        if (LooksLikeAvatar(view)) {
            CGRect frame = [view convertRect:view.bounds toView:bar];
            BOOL leading = rtl ? CGRectGetMaxX(frame) > CGRectGetWidth(bar.bounds) - 96
                               : CGRectGetMinX(frame) < 96;
            if (leading) {
                found = view;
                break;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    UIView* host = found ? PressHost(found, bar) : nil;
    if (!host) {
        return;
    }
    if (!HasAccountPress(host)) {
        NFBAccountPressHandler* handler = [NFBAccountPressHandler shared];
        NFBAccountPress* press = [[NFBAccountPress alloc] initWithTarget:handler action:@selector(pressed:)];
        press.minimumPressDuration = 0.35;
        press.cancelsTouchesInView = YES;
        press.delegate = handler;
        [host addGestureRecognizer:press];
    }
    NFBWeakView* box = known ?: [NFBWeakView new];
    box.view = host;
    objc_setAssociatedObject(bar, kPressHostKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// MARK: - Catching X's account sheet
//
// On iOS 26 the avatar button lives in a SwiftUI platter, and the press above
// may never get the touch. So also watch for X presenting its account sheet
// (AccountSwitcherTrayContentViewController) while a finger has been held: skip
// the sheet and open the circles there instead, following the same finger.

static NSTimeInterval gTouchStart = 0;
static NSTimeInterval gTouchEnd = 0;
static CGPoint gTouchStartPoint;
static BOOL gTouchDown = NO;
static __weak UITouch* gTrackedTouch = nil;
static NFBAccountFan* gCaughtFan = nil;
static BOOL gCaughtMoved = NO;
static NSString* gBubbleLog = @"(no account sheet seen)";

NSString* NFBAccountBubblesDebugText(void) {
    NFBWeakView* known = nil;
    for (UIWindow* window in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:window];
        NSInteger budget = 4000;
        while (queue.count > 0 && budget-- > 0 && !known) {
            UIView* view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([view isKindOfClass:[UINavigationBar class]]) {
                NFBWeakView* box = objc_getAssociatedObject(view, kPressHostKey);
                if (box.view) {
                    known = box;
                }
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
    return [NSString stringWithFormat:@"on=%d accounts=%lu pressHost=%@ last=%@%c%@", BubblesOn(),
                                      (unsigned long)TwitterAccounts().count,
                                      known.view ? NSStringFromClass(known.view.class) : @"(none)", gBubbleLog, 10,
                                      gProbeLog.count ? [gProbeLog componentsJoinedByString:@"\n"] : @"(no probes yet)"];
}

static BOOL IsAccountSheet(UIViewController* controller, NSInteger depth) {
    if (!controller || depth > 6) {
        return NO;
    }
    if ([NSStringFromClass(controller.class) containsString:@"AccountSwitcherTray"]) {
        return YES;
    }
    for (UIViewController* child in controller.childViewControllers) {
        if (IsAccountSheet(child, depth + 1)) {
            return YES;
        }
    }
    for (NSString* name in @[ @"viewControllers" ]) {
        id list = ObjectProp(controller, name);
        if ([list isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray*)list) {
                if ([item isKindOfClass:[UIViewController class]] && IsAccountSheet(item, depth + 1)) {
                    return YES;
                }
            }
        }
    }
    for (NSString* name in @[ @"rootViewController", @"contentViewController", @"topViewController" ]) {
        id item = ObjectProp(controller, name);
        if (item != controller && [item isKindOfClass:[UIViewController class]] && IsAccountSheet(item, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

// A held finger (not a quick tap) that is still down or only just lifted.
static BOOL FingerHeld(NSTimeInterval grace) {
    if (gTouchStart <= 0) {
        return NO;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!gTouchDown && now - gTouchEnd > grace) {
        return NO;
    }
    return (gTouchDown ? now : gTouchEnd) - gTouchStart >= 0.25;
}

static BOOL FanIsUp(void) {
    return [NFBAccountPressHandler shared].fan.superview != nil || gCaughtFan.superview != nil ||
           gLiveDock != nil;
}

static BOOL OpenCaughtFan(UIWindow* window) {
    NSArray* accounts = TwitterAccounts();
    if (!window || accounts.count < 2) {
        return NO;
    }
    if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        UIImpactFeedbackGenerator* thump =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [thump impactOccurred];
    }
    NFBAccountFan* fan = [[NFBAccountFan alloc] initWithFrame:window.bounds
                                                     accounts:accounts
                                                       origin:gTouchStartPoint
                                                         safe:window.safeAreaInsets];
    [window addSubview:fan];
    if (gTouchDown) {
        gCaughtFan = fan;
        gCaughtMoved = NO;
    } else {
        [fan waitForTap];
    }
    return YES;
}

// The sheet X wanted to show is never presented, but its view can still be
// built off screen so its rows (and their unread badges) can be read.
static UIViewController* gOffscreenSheet = nil;

static void LayoutTree(UIView* view, NSInteger depth) {
    if (depth > 30) {
        return;
    }
    [view layoutIfNeeded];
    for (UIView* sub in view.subviews) {
        LayoutTree(sub, depth + 1);
    }
}

static void ReadCountsOffscreen(UIViewController* sheet, CGRect bounds) {
    if (!sheet || gOffscreenSheet) {
        return;
    }
    gOffscreenSheet = sheet;
    @try {
        sheet.view.frame = bounds;
        LayoutTree(sheet.view, 0);
        HarvestSheetCounts(sheet.view);
    } @catch (__unused NSException* exception) {
        ProbeNote(@"badge: building X's list off screen threw");
    }
    [gLiveFan refreshCounts];
    // Rows may fill in a moment later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            LayoutTree(sheet.view, 0);
            if (HarvestSheetCounts(sheet.view) == 0) {
                ProbeNote(@"badge: X's list had no rows off screen");
            }
        } @catch (__unused NSException* exception) {
        }
        [gLiveFan refreshCounts];
        gOffscreenSheet = nil;
    });
}

static void TrackTouches(UIWindow* window, UIEvent* event) {
    for (UITouch* touch in event.allTouches) {
        if (touch.phase == UITouchPhaseBegan && !gTouchDown) {
            gTrackedTouch = touch;
            gTouchDown = YES;
            gTouchStart = touch.timestamp;
            gTouchStartPoint = [touch locationInView:nil];
            continue;
        }
        if (touch != gTrackedTouch) {
            continue;
        }
        NFBAccountFan* fan = gCaughtFan;
        if (touch.phase == UITouchPhaseMoved && fan) {
            CGPoint point = [touch locationInView:fan];
            if (hypot(point.x - gTouchStartPoint.x, point.y - gTouchStartPoint.y) > 12) {
                gCaughtMoved = YES;
            }
            [fan hoverAt:point];
        } else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
            gTouchDown = NO;
            gTouchEnd = NSProcessInfo.processInfo.systemUptime;
            gTrackedTouch = nil;
            gCaughtFan = nil;
            if (fan) {
                if (fan.hovered) {
                    [fan finishWith:fan.hovered];
                } else if (!gCaughtMoved && touch.phase == UITouchPhaseEnded) {
                    [fan waitForTap];
                } else {
                    [fan finishWith:nil];
                }
            }
        }
    }
}

// MARK: - Account dock (long press on the Home tab)

// The whole screen slides up like a card, its bottom corners rounded, and a
// black dock underneath shows every account in a row. Every window subview
// moves together so overlays stay lined up with the screen they belong to.

static const CGFloat kDockGap = 10.0;
static const CGFloat kDockSide = 12.0;
static const NSInteger kDockVisible = 5;

// Gives a circle (built at kBubbleSize) a new size, keeping every round part round.
static void ResizeBubble(NFBAccountBubble* bubble, CGRect frame) {
    bubble.frame = frame;
    CGRect bounds = bubble.bounds;
    CGFloat radius = CGRectGetWidth(bounds) / 2.0;
    for (UIView* view in bubble.subviews) {
        if ([view isKindOfClass:[UIVisualEffectView class]]) {
            view.frame = bounds;
            view.layer.cornerRadius = radius;
        }
    }
    bubble.initial.frame = bounds;
    bubble.initial.font = [UIFont systemFontOfSize:round(CGRectGetWidth(bounds) * 0.4) weight:UIFontWeightBold];
    bubble.avatar.frame = CGRectInset(bounds, 4, 4);
    bubble.avatar.layer.cornerRadius = CGRectGetWidth(bubble.avatar.bounds) / 2.0;
}
static const CGFloat kDockCardRadius = 34.0;

@interface NFBAccountDock : UIView
@property (nonatomic, weak) UIWindow* hostWindow;
@property (nonatomic, strong) UIScrollView* strip;
@property (nonatomic, strong) NSArray<NFBAccountBubble*>* bubbles;
@property (nonatomic, strong) UIView* catcher;
@property (nonatomic, strong) NSArray<UIView*>* lifted;
@property (nonatomic, strong) NSArray<NSValue*>* liftedTransforms;
@property (nonatomic, weak) UIView* rounded;
@property (nonatomic, assign) CGFloat oldRadius;
@property (nonatomic, assign) BOOL oldClips;
@property (nonatomic, assign) CACornerMask oldCorners;
@property (nonatomic, copy) NSString* oldCurve;
@property (nonatomic, assign) CGFloat lift;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, weak) NFBAccountBubble* pressed;
@property (nonatomic, assign) CGPoint pressStart;
+ (BOOL)openInWindow:(UIWindow*)window;
- (void)closeWith:(NFBAccountBubble*)chosen;
@end

// Dock circles: a glass bead drawn by hand. UIKit's Liquid Glass has no
// setting for how hard it bends light, and over a 60-odd point picture it
// bent faces out of shape, so the bead is built from parts whose strength is
// set here:
//  - the picture, sharp, filling the circle;
//  - along the rim, a slightly magnified copy of it (the lens bulge real
//    glass gives an edge), only kDockLensBand wide;
//  - a faint sheen from the top and a light rim that is bright at the top
//    left, fades along the sides and catches again at the bottom right.
static const CGFloat kDockLensBand = 7.0;     // points of rim that bulge
static const CGFloat kDockLensScale = 1.08;   // how much the rim magnifies

static UIView* RingMask(CGRect bounds, CGFloat band) {
    UIView* ring = [[UIView alloc] initWithFrame:bounds];
    CAShapeLayer* shape = [CAShapeLayer layer];
    UIBezierPath* path = [UIBezierPath bezierPathWithOvalInRect:bounds];
    [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectInset(bounds, band, band)]];
    shape.path = path.CGPath;
    shape.fillRule = kCAFillRuleEvenOdd;
    shape.fillColor = [UIColor blackColor].CGColor;
    [ring.layer addSublayer:shape];
    return ring;
}

// Clear in the middle, fading in over the outer `band` points, so the
// magnified rim blends into the face instead of meeting it at a seam.
static UIView* SoftRingMask(CGRect bounds, CGFloat band) {
    UIView* ring = [[UIView alloc] initWithFrame:bounds];
    CAGradientLayer* fade = [CAGradientLayer layer];
    fade.type = kCAGradientLayerRadial;
    fade.frame = ring.bounds;
    fade.startPoint = CGPointMake(0.5, 0.5);
    fade.endPoint = CGPointMake(1.0, 1.0);
    CGFloat radius = CGRectGetWidth(bounds) / 2.0;
    CGFloat inner = MAX(0.0, (radius - band) / radius);
    fade.colors = @[ (id)[UIColor clearColor].CGColor, (id)[UIColor clearColor].CGColor,
                     (id)[UIColor blackColor].CGColor, (id)[UIColor blackColor].CGColor ];
    fade.locations = @[ @0, @(inner), @(inner + (1.0 - inner) * 0.6), @1 ];
    [ring.layer addSublayer:fade];
    return ring;
}

static void PutGlassOverBubble(NFBAccountBubble* bubble) {
    CGRect bounds = bubble.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat radius = width / 2.0;
    for (UIView* view in bubble.subviews) {
        if ([view isKindOfClass:[UIVisualEffectView class]]) {
            view.layer.borderWidth = 0;
        }
    }
    bubble.avatar.frame = bounds;
    bubble.avatar.layer.cornerRadius = radius;

    // The bulging rim: the same picture a little larger, seen only in a band.
    UIView* lensWindow = [[UIView alloc] initWithFrame:bounds];
    lensWindow.userInteractionEnabled = NO;
    lensWindow.layer.cornerRadius = radius;
    lensWindow.clipsToBounds = YES;
    lensWindow.maskView = SoftRingMask(bounds, kDockLensBand);
    CGFloat grow = width * (kDockLensScale - 1.0) / 2.0;
    UIImageView* lens = [[UIImageView alloc] initWithFrame:CGRectInset(bounds, -grow, -grow)];
    lens.contentMode = UIViewContentModeScaleAspectFill;
    lens.image = bubble.avatar.image;
    [lensWindow addSubview:lens];
    // The bulge reads as glass only if it is a touch softer than the face.
    lens.layer.shouldRasterize = YES;
    lens.layer.rasterizationScale = UIScreen.mainScreen.scale * 0.6;
    bubble.lens = lens;
    [bubble insertSubview:lensWindow aboveSubview:bubble.avatar];

    // Light from above, across the whole face but faint.
    UIView* sheenView = [[UIView alloc] initWithFrame:bounds];
    sheenView.userInteractionEnabled = NO;
    sheenView.layer.cornerRadius = radius;
    sheenView.clipsToBounds = YES;
    CAGradientLayer* sheen = [CAGradientLayer layer];
    sheen.frame = bounds;
    sheen.colors = @[ (id)[UIColor colorWithWhite:1 alpha:0.26].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0.05].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0].CGColor ];
    sheen.locations = @[ @0, @0.3, @0.55 ];
    [sheenView.layer addSublayer:sheen];
    [bubble insertSubview:sheenView aboveSubview:lensWindow];

    // The rim light, a thin ring lit from the top left.
    UIView* rimLight = [[UIView alloc] initWithFrame:bounds];
    rimLight.userInteractionEnabled = NO;
    CAGradientLayer* rim = [CAGradientLayer layer];
    rim.frame = bounds;
    rim.startPoint = CGPointMake(0.15, 0.0);
    rim.endPoint = CGPointMake(0.85, 1.0);
    rim.colors = @[ (id)[UIColor colorWithWhite:1 alpha:0.95].CGColor,
                    (id)[UIColor colorWithWhite:1 alpha:0.15].CGColor,
                    (id)[UIColor colorWithWhite:1 alpha:0.05].CGColor,
                    (id)[UIColor colorWithWhite:1 alpha:0.55].CGColor ];
    rim.locations = @[ @0, @0.4, @0.65, @1 ];
    [rimLight.layer addSublayer:rim];
    rimLight.maskView = RingMask(CGRectInset(bounds, 0.5, 0.5), 1.6);
    [bubble insertSubview:rimLight aboveSubview:sheenView];
    UIView* band = rimLight;

    // The edge line sits on its own view so the glass mask cannot clip it.
    UIView* edge = [[UIView alloc] initWithFrame:bounds];
    edge.userInteractionEnabled = NO;
    edge.layer.cornerRadius = radius;
    edge.layer.borderWidth = bubble.current ? 2.5 : 0.0;
    edge.layer.borderColor =
        bubble.current ? AccentColor().CGColor : [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [bubble insertSubview:edge aboveSubview:band];
    [bubble bringSubviewToFront:bubble.badge];
}

@implementation NFBAccountDock

+ (BOOL)openInWindow:(UIWindow*)window {
    if (!window || gLiveDock || FanIsUp()) {
        return NO;
    }
    NSArray* accounts = TwitterAccounts();
    if (accounts.count < 2) {
        return NO;
    }
    UIViewController* root = window.rootViewController;
    // A presented sheet lives beside the root view; lifting only one of them
    // would tear the screen apart, so leave X alone then.
    if (!root.isViewLoaded || root.presentedViewController) {
        gBubbleLog = @"dock skipped: something is presented";
        return NO;
    }
    NFBAccountDock* dock = [[NFBAccountDock alloc] initWithWindow:window accounts:accounts];
    [dock open];
    NSMutableArray* counts = [NSMutableArray array];
    for (id account in accounts) {
        NSString* key = AccountKey(account);
        NSNumber* seen = key ? SheetCounts()[key] : nil;
        [counts addObject:[NSString stringWithFormat:@"%@=%@", AccountTitle(account),
                                                     seen ? (id)seen
                                                          : (id)[NSString stringWithFormat:@"getter %ld",
                                                                     (long)AccountUnreadCount(account)]]];
    }
    gBubbleLog = [NSString stringWithFormat:@"dock opened (%lu accounts) badges: %@", (unsigned long)accounts.count,
                                            [counts componentsJoinedByString:@", "]];
    return YES;
}

- (instancetype)initWithWindow:(UIWindow*)window accounts:(NSArray*)accounts {
    if ((self = [super initWithFrame:window.bounds])) {
        _hostWindow = window;
        self.backgroundColor = [UIColor blackColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        CGFloat width = CGRectGetWidth(self.bounds);
        CGFloat height = CGRectGetHeight(self.bounds);
        // Five circles fill the row edge to edge; the gear (and any more
        // accounts) are a scroll away.
        CGFloat size = floor((width - kDockSide * 2.0 - kDockGap * (kDockVisible - 1)) / kDockVisible);
        CGFloat stripHeight = size + 32.0;
        _lift = stripHeight + 20.0 + MAX(window.safeAreaInsets.bottom, 12.0);

        _strip = [[UIScrollView alloc] initWithFrame:CGRectMake(0, height - _lift + 12.0, width, stripHeight)];
        _strip.showsHorizontalScrollIndicator = NO;
        _strip.alwaysBounceHorizontal = YES;
        _strip.clipsToBounds = NO;
        [self addSubview:_strip];

        id current = CurrentAccount();
        NSArray* ordered = OrderedAccounts(accounts);
        // One more place at the end for the gear that opens the order editor.
        NSInteger count = (NSInteger)ordered.count + 1;
        CGFloat total = count * size + (count - 1) * kDockGap;
        CGFloat side = MAX(kDockSide, (width - total) / 2.0);
        _strip.contentSize = CGSizeMake(total + side * 2.0, stripHeight);

        NSMutableArray* bubbles = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) {
            BOOL gear = i == count - 1;
            id account = gear ? nil : ordered[i];
            NFBAccountBubble* bubble = gear ? [[NFBAccountBubble alloc] initSettings]
                                            : [[NFBAccountBubble alloc] initWithAccount:account
                                                                                current:SameAccount(account, current)];
            CGFloat x = side + i * (size + kDockGap);
            ResizeBubble(bubble, CGRectMake(x, 6.0, size, size));
            bubble.slot = bubble.center;
            bubble.initial.textColor = [UIColor whiteColor];
            bubble.avatar.tintColor = gear ? [UIColor whiteColor] : bubble.avatar.tintColor;
            bubble.badge.layer.borderColor = [UIColor blackColor].CGColor;
            if (!gear) {
                PutGlassOverBubble(bubble);
            }
            [_strip addSubview:bubble];
            [bubbles addObject:bubble];

            if (!gear) {
                UILabel* name = [[UILabel alloc]
                    initWithFrame:CGRectMake(x - kDockGap / 2.0, 6.0 + size + 6.0, size + kDockGap, 15.0)];
                name.text = AccountTitle(account);
                name.font = [UIFont systemFontOfSize:11 weight:bubble.current ? UIFontWeightBold : UIFontWeightMedium];
                name.textColor = [UIColor colorWithWhite:1 alpha:bubble.current ? 0.95 : 0.6];
                name.textAlignment = NSTextAlignmentCenter;
                name.lineBreakMode = NSLineBreakByTruncatingTail;
                name.isAccessibilityElement = NO;
                [_strip addSubview:name];

                __weak NFBAccountBubble* weakBubble = bubble;
                LoadAvatar(account, ^(UIImage* image) {
                    [weakBubble setImage:image];
                });
                [bubble setCount:bubble.current ? 0 : BadgeCountFor(account)];
            }
        }
        _bubbles = bubbles;

        // Start the row on the account in use when it would be off screen.
        for (NFBAccountBubble* bubble in bubbles) {
            if (bubble.current) {
                CGFloat maxOffset = MAX(0, _strip.contentSize.width - width);
                _strip.contentOffset = CGPointMake(MIN(maxOffset, MAX(0, bubble.center.x - width / 2.0)), 0);
            }
        }

        // Follows the finger from the moment it lands, so a circle can squash
        // under it and spring back; the row still scrolls alongside.
        UILongPressGestureRecognizer* touch =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(dockTouched:)];
        touch.minimumPressDuration = 0;
        touch.cancelsTouchesInView = NO;
        touch.delegate = (id<UIGestureRecognizerDelegate>)self;
        [self addGestureRecognizer:touch];
    }
    return self;
}

- (void)open {
    UIWindow* window = self.hostWindow;
    UIView* rootView = window.rootViewController.view;

    NSMutableArray* lifted = [NSMutableArray array];
    NSMutableArray* transforms = [NSMutableArray array];
    for (UIView* view in window.subviews) {
        [lifted addObject:view];
        [transforms addObject:[NSValue valueWithCGAffineTransform:view.transform]];
    }
    self.lifted = lifted;
    self.liftedTransforms = transforms;
    [window insertSubview:self atIndex:0];

    self.rounded = rootView;
    self.oldRadius = rootView.layer.cornerRadius;
    self.oldClips = rootView.clipsToBounds;
    self.oldCorners = rootView.layer.maskedCorners;
    self.oldCurve = rootView.layer.cornerCurve;
    rootView.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    rootView.layer.cornerCurve = kCACornerCurveContinuous;
    rootView.clipsToBounds = YES;

    // Covers the lifted screen: tap it or pull it down to put it back.
    self.catcher = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(window.bounds),
                                                            CGRectGetHeight(window.bounds) - self.lift)];
    self.catcher.backgroundColor = [UIColor clearColor];
    self.catcher.accessibilityLabel = @"Close";
    [self.catcher addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(catcherTapped:)]];
    [self.catcher addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(catcherPanned:)]];
    [window addSubview:self.catcher];

    gLiveDock = self;
    if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        UIImpactFeedbackGenerator* thump =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [thump impactOccurred];
    }

    [UIView animateWithDuration:0.42
        delay:0
        usingSpringWithDamping:0.86
        initialSpringVelocity:0.4
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:^{
            [self applyLift:self.lift];
            rootView.layer.cornerRadius = kDockCardRadius;
        }
        completion:nil];

    NSInteger index = 0;
    for (NFBAccountBubble* bubble in self.bubbles) {
        bubble.alpha = 0;
        bubble.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.6, 0.6),
                                                   CGAffineTransformMakeTranslation(0, 24));
        [UIView animateWithDuration:0.46
            delay:0.06 + index * 0.035
            usingSpringWithDamping:0.7
            initialSpringVelocity:0.6
            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
            animations:^{
                bubble.alpha = 1;
                bubble.transform = CGAffineTransformIdentity;
            }
            completion:^(BOOL finished) {
                bubble.settled = YES;
            }];
        index++;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillResign:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// lift 0 is the screen where it was; self.lift is fully up.
- (void)applyLift:(CGFloat)lift {
    for (NSUInteger i = 0; i < self.lifted.count; i++) {
        CGAffineTransform base = self.liftedTransforms[i].CGAffineTransformValue;
        self.lifted[i].transform = CGAffineTransformConcat(base, CGAffineTransformMakeTranslation(0, -lift));
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Rotated or resized: the row no longer fits, so just put things back.
    if (self.hostWindow && !self.closing &&
        fabs(CGRectGetHeight(self.bounds) - CGRectGetHeight(self.hostWindow.bounds)) > 1) {
        [self closeWith:nil];
    }
}

- (void)appWillResign:(NSNotification*)note {
    [self closeWith:nil];
}

- (NFBAccountBubble*)bubbleAt:(CGPoint)point {
    NFBAccountBubble* best = nil;
    CGFloat bestDistance = kHitRadius;
    for (NFBAccountBubble* bubble in self.bubbles) {
        CGPoint center = [self.strip convertPoint:bubble.slot toView:self];
        CGFloat distance = hypot(point.x - center.x, point.y - center.y);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = bubble;
        }
    }
    return best;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return YES;
}

// Squashes a circle like a soft sweet under the finger, or lets it spring
// back up (wobbling past its size before settling).
- (void)squash:(NFBAccountBubble*)bubble down:(BOOL)down {
    if (!bubble) {
        return;
    }
    [UIView animateWithDuration:down ? 0.28 : 0.5
                          delay:0
         usingSpringWithDamping:down ? 0.62 : 0.38
          initialSpringVelocity:down ? 0.4 : 1.2
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         // A little wider than tall, as if pressed flat.
                         bubble.transform = down ? CGAffineTransformMakeScale(0.9, 0.84) : CGAffineTransformIdentity;
                     }
                     completion:nil];
}

- (void)dockTouched:(UILongPressGestureRecognizer*)touch {
    if (self.closing) {
        return;
    }
    CGPoint point = [touch locationInView:self];
    switch (touch.state) {
        case UIGestureRecognizerStateBegan: {
            NFBAccountBubble* bubble = [self bubbleAt:point];
            self.pressed = bubble;
            self.pressStart = point;
            if (bubble) {
                if (!NSProcessInfo.processInfo.isLowPowerModeEnabled) {
                    UIImpactFeedbackGenerator* soft =
                        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
                    [soft impactOccurred];
                }
                [self squash:bubble down:YES];
            }
            break;
        }
        case UIGestureRecognizerStateChanged:
            // Moving the finger (scrolling the row) lets go without choosing.
            if (self.pressed && (self.strip.isDragging ||
                                 hypot(point.x - self.pressStart.x, point.y - self.pressStart.y) > 12)) {
                [self squash:self.pressed down:NO];
                self.pressed = nil;
            }
            break;
        case UIGestureRecognizerStateEnded: {
            NFBAccountBubble* bubble = self.pressed;
            self.pressed = nil;
            if (bubble && [self bubbleAt:point] == bubble) {
                Tick();
                // Pop back up first, then go.
                [self squash:bubble down:NO];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                   [self closeWith:bubble];
                               });
            } else {
                [self squash:bubble down:NO];
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self squash:self.pressed down:NO];
            self.pressed = nil;
            break;
        default:
            break;
    }
}

- (void)catcherTapped:(UITapGestureRecognizer*)tap {
    [self closeWith:nil];
}

- (void)catcherPanned:(UIPanGestureRecognizer*)pan {
    if (self.closing) {
        return;
    }
    CGFloat down = MAX(0, [pan translationInView:self].y);
    switch (pan.state) {
        case UIGestureRecognizerStateChanged:
            [self applyLift:MAX(0, self.lift - down)];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            if (down > self.lift * 0.3 || [pan velocityInView:self].y > 300) {
                [self closeWith:nil];
            } else {
                [UIView animateWithDuration:0.3
                    delay:0
                    usingSpringWithDamping:0.86
                    initialSpringVelocity:0.3
                    options:UIViewAnimationOptionBeginFromCurrentState
                    animations:^{
                        [self applyLift:self.lift];
                    }
                    completion:nil];
            }
            break;
        default:
            break;
    }
}

- (void)closeWith:(NFBAccountBubble*)chosen {
    if (self.closing) {
        return;
    }
    self.closing = YES;
    self.userInteractionEnabled = NO;
    [self.catcher removeFromSuperview];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    id account = chosen && !chosen.current && !chosen.settings ? chosen.account : nil;
    BOOL openOrder = chosen.settings;
    UIView* rootView = self.rounded;

    [UIView animateWithDuration:0.34
        delay:0
        usingSpringWithDamping:0.9
        initialSpringVelocity:0.2
        options:UIViewAnimationOptionBeginFromCurrentState
        animations:^{
            [self applyLift:0];
            rootView.layer.cornerRadius = self.oldRadius;
            for (NFBAccountBubble* bubble in self.bubbles) {
                bubble.alpha = bubble == chosen ? 1 : 0;
                bubble.transform = bubble == chosen ? CGAffineTransformMakeScale(1.25, 1.25)
                                                    : CGAffineTransformMakeScale(0.6, 0.6);
            }
        }
        completion:^(BOOL finished) {
            for (NSUInteger i = 0; i < self.lifted.count; i++) {
                self.lifted[i].transform = self.liftedTransforms[i].CGAffineTransformValue;
            }
            rootView.layer.cornerRadius = self.oldRadius;
            rootView.layer.maskedCorners = self.oldCorners;
            if (self.oldCurve) {
                rootView.layer.cornerCurve = self.oldCurve;
            }
            rootView.clipsToBounds = self.oldClips;
            [self removeFromSuperview];
            if (gLiveDock == self) {
                gLiveDock = nil;
            }
            if (account) {
                gBubbleLog = @"dock: switched account";
                SwitchToAccount(account);
            } else if (openOrder) {
                ShowOrderEditor();
            }
        }];
}

@end

// MARK: - Long press on the Home tab

// Sits on the tab bar (not the Home button itself, whose touches X may route
// elsewhere) and only starts when the finger is on the Home button.
@interface NFBDockPress : UILongPressGestureRecognizer
@property (nonatomic, weak) UIView* home;
@end

@implementation NFBDockPress
@end

@interface NFBDockPressHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

@implementation NFBDockPressHandler

+ (instancetype)shared {
    static NFBDockPressHandler* handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handler = [NFBDockPressHandler new];
    });
    return handler;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    if (![gesture isKindOfClass:[NFBDockPress class]] || !DockOn() || gLiveDock || FanIsUp()) {
        return NO;
    }
    UIView* home = ((NFBDockPress*)gesture).home;
    if (!home.window || home.hidden || home.alpha < 0.01) {
        return NO;
    }
    CGPoint point = [gesture locationInView:home];
    if (!CGRectContainsPoint(CGRectInset(home.bounds, -6, -6), point)) {
        return NO;
    }
    return TwitterAccounts().count >= 2;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
    return YES;
}

// Once the dock is up, X's own tap on Home must not also fire when the finger
// lifts: switching the others off and on again cancels them.
static void CancelOtherGestures(UIGestureRecognizer* mine) {
    UIView* view = mine.view;
    for (NSInteger depth = 0; view && depth < 8 && ![view isKindOfClass:[UIWindow class]]; depth++) {
        for (UIGestureRecognizer* other in view.gestureRecognizers) {
            if (other != mine && other.enabled) {
                other.enabled = NO;
                other.enabled = YES;
            }
        }
        view = view.superview;
    }
    UIView* home = [mine isKindOfClass:[NFBDockPress class]] ? ((NFBDockPress*)mine).home : nil;
    for (UIGestureRecognizer* other in home.gestureRecognizers) {
        if (other.enabled) {
            other.enabled = NO;
            other.enabled = YES;
        }
    }
}

- (void)pressed:(NFBDockPress*)press {
    // The press only lifts the screen; an account is always picked with a tap.
    if (press.state == UIGestureRecognizerStateBegan && [NFBAccountDock openInWindow:press.view.window]) {
        CancelOtherGestures(press);
    }
}

@end

static const void* kDockPressKey = &kDockPressKey;

static void AttachDockPress(UIView* host, UIView* home) {
    if (!host || !home) {
        return;
    }
    NFBDockPress* press = objc_getAssociatedObject(host, kDockPressKey);
    if (!press) {
        press = [[NFBDockPress alloc] initWithTarget:[NFBDockPressHandler shared] action:@selector(pressed:)];
        press.minimumPressDuration = 0.35;
        press.allowableMovement = 16;
        press.cancelsTouchesInView = YES;
        press.delegate = [NFBDockPressHandler shared];
        [host addGestureRecognizer:press];
        objc_setAssociatedObject(host, kDockPressKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    press.home = home;
}

static void CollectViews(UIView* view, Class itemClass, NSMutableArray<UIView*>* items, NSInteger depth) {
    if (depth > 12) {
        return;
    }
    for (UIView* subview in view.subviews) {
        if ([subview isKindOfClass:itemClass]) {
            [items addObject:subview];
        } else {
            CollectViews(subview, itemClass, items, depth + 1);
        }
    }
}

// The newer tab bar: Home is pinned first, so it is the leading button.
static void AttachDockPressToGlassBar(UIView* bar) {
    Class itemClass = NSClassFromString(@"_TtC11XNavigation14TabBarItemView");
    if (!itemClass || !bar.window) {
        return;
    }
    NSMutableArray<UIView*>* items = [NSMutableArray array];
    CollectViews(bar, itemClass, items, 0);
    if (items.count == 0) {
        return;
    }
    BOOL rtl = bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    UIView* home = nil;
    CGFloat edge = 0;
    for (UIView* item in items) {
        if (item.hidden || CGRectGetWidth(item.bounds) < 1) {
            continue;
        }
        CGFloat x = CGRectGetMidX([item convertRect:item.bounds toView:bar]);
        if (!home || (rtl ? x > edge : x < edge)) {
            home = item;
            edge = x;
        }
    }
    AttachDockPress(bar, home);
}

%hook T1TabView

- (void)layoutSubviews {
    %orig;
    if (DockOn() && [self.scribePage isEqualToString:CustomTabBarHomePageID]) {
        AttachDockPress(self.superview, (UIView*)self);
    }
}

%end

%hook _TtC11XNavigation10TabBarView

- (void)layoutSubviews {
    %orig;
    if (DockOn()) {
        AttachDockPressToGlassBar((UIView*)self);
    }
}

%end

%hook T1NotificationsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (BubblesOn() || DockOn()) {
        MarkCurrentAccountSeen();
    }
}

%end

%hook UINavigationBar

- (void)layoutSubviews {
    %orig;
    if (BubblesOn()) {
        AttachAccountPress(self);
    }
}

%end

%hook UIWindow

- (void)sendEvent:(UIEvent*)event {
    if (event.type == UIEventTypeTouches && BubblesOn()) {
        TrackTouches(self, event);
    }
    %orig;
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController*)controller
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    if (BubblesOn() && IsAccountSheet(controller, 0)) {
        BOOL held = FingerHeld(0.6);
        if (FanIsUp()) {
            gBubbleLog = @"sheet skipped, circles already up";
            return;
        }
        if (held) {
            UIWindow* window = self.view.window ?: UIApplication.sharedApplication.keyWindow;
            if (OpenCaughtFan(window)) {
                ReadCountsOffscreen(controller, window.bounds);
                gBubbleLog = [NSString stringWithFormat:@"sheet replaced by circles (from %@)",
                                                        NSStringFromClass(self.class)];
                return;
            }
        }
        gBubbleLog = [NSString stringWithFormat:@"sheet shown: held=%d accounts=%lu", held,
                                                (unsigned long)TwitterAccounts().count];
    }
    %orig;
}

// Fallback for a sheet that came up some other way than presentViewController.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!(BubblesOn() || DockOn()) ||
        ![NSStringFromClass(self.class) containsString:@"AccountSwitcherTrayContent"]) {
        return;
    }
    // Whenever X's list is on screen, remember its unread numbers (the dock
    // shows them too).
    HarvestSheetCounts(self.view);
    if (!BubblesOn() || FanIsUp() || !FingerHeld(1.0) || TwitterAccounts().count < 2) {
        __weak UIView* weakView = self.view;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HarvestSheetCounts(weakView);
            [gLiveFan refreshCounts];
        });
        return;
    }
    UIViewController* top = self;
    while (top.parentViewController) {
        top = top.parentViewController;
    }
    UIWindow* window = top.presentingViewController.view.window ?: self.view.window;
    if (top.presentingViewController) {
        [top dismissViewControllerAnimated:NO completion:nil];
    }
    if (OpenCaughtFan(window)) {
        gBubbleLog = @"sheet closed after appearing, circles opened";
    }
}

%end
