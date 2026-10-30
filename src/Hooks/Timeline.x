//
//  Timeline.x
//  NeoFreeBird
//

#import <string.h>
#import "HookHelpers.h"

// MARK: - Hide "Discover more", who-to-follow and prompts

// The home feed (For You / Following); the Swift class is looked up by its mangled name
// first, then by the dotted one.
static BOOL IsHomeTimeline(UIViewController* viewController);

// Resolves the class by name so mangled Swift names work; NSStringFromClass
// would only ever produce the demangled dotted form.
static BOOL IsInHierarchyOfClass(UIViewController* viewController, NSString* className) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass) {
        return NO;
    }

    UIViewController* currentVC = viewController;

    while (currentVC) {
        if ([currentVC isKindOfClass:targetClass]) {
            return YES;
        }

        if (currentVC.parentViewController) {
            currentVC = currentVC.parentViewController;
        } else if (currentVC.navigationController) {
            currentVC = currentVC.navigationController;
        } else if (currentVC.presentingViewController) {
            currentVC = currentVC.presentingViewController;
        } else {
            break;
        }
    }

    return NO;
}

static BOOL IsHomeTimeline(UIViewController* viewController) {
    return IsInHierarchyOfClass(
               viewController,
               @"_TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController") ||
           IsInHierarchyOfClass(
               viewController,
               @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
}

// Need to tag edit history since it reuses a generic class
static const void* EditHistoryViewControllerKey = &EditHistoryViewControllerKey;

static BOOL IsInEditHistory(UIViewController* viewController) {
    UIViewController* currentVC = viewController;

    while (currentVC) {
        if (objc_getAssociatedObject(currentVC, EditHistoryViewControllerKey)) {
            return YES;
        }

        currentVC = currentVC.parentViewController;
    }

    return NO;
}

static const void* ConversationOpenedFromProfileKey = &ConversationOpenedFromProfileKey;

static BOOL StringSuggestsProfile(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }

    return [[(NSString*)value lowercaseString] containsString:@"profile"];
}

static id ObjectForSelector(id object, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL NavigationMetadataIsFromProfile(id metadata) {
    if (!metadata) {
        return NO;
    }

    if ([metadata respondsToSelector:@selector(name)] &&
        StringSuggestsProfile(ObjectForSelector(metadata, @selector(name)))) {
        return YES;
    }

    id scribeContext = nil;
    if ([metadata respondsToSelector:@selector(sourceScribeContext)]) {
        scribeContext = ObjectForSelector(metadata, @selector(sourceScribeContext));
    }

    for (NSUInteger depth = 0; scribeContext && depth < 8; depth++) {
        NSArray<NSString*>* selectors = @[@"page", @"section", @"component", @"element"];
        for (NSString* selectorName in selectors) {
            SEL selector = NSSelectorFromString(selectorName);
            if ([scribeContext respondsToSelector:selector] &&
                StringSuggestsProfile(ObjectForSelector(scribeContext, selector))) {
                return YES;
            }
        }

        if (![scribeContext respondsToSelector:@selector(sourceContext)]) {
            break;
        }
        scribeContext = ObjectForSelector(scribeContext, @selector(sourceContext));
    }

    return NO;
}

static BOOL IsInProfileOriginConversation(UIViewController* viewController) {
    UIViewController* currentVC = viewController;

    while (currentVC) {
        if (objc_getAssociatedObject(currentVC, ConversationOpenedFromProfileKey)) {
            return YES;
        }

        if (currentVC.parentViewController) {
            currentVC = currentVC.parentViewController;
        } else if (currentVC.navigationController) {
            currentVC = currentVC.navigationController;
        } else if (currentVC.presentingViewController) {
            currentVC = currentVC.presentingViewController;
        } else {
            break;
        }
    }

    return NO;
}

%hook T1ConversationContainerViewController

- (id)initWithAccount:(id)account
                         statusID:(long long)statusID
          statusNavigationContext:(id)statusNavigationContext
                    scribeContext:(id)scribeContext
         sourceNavigationMetadata:(id)sourceNavigationMetadata
       overrideNavigationMetadata:(id)overrideNavigationMetadata
      shouldIncludeReferrerParams:(BOOL)shouldIncludeReferrerParams
    shouldStartQuickPromoteOnOpen:(BOOL)shouldStartQuickPromoteOnOpen
                excludedStatusIDs:(id)excludedStatusIDs {
    id conversation = %orig(account, statusID, statusNavigationContext, scribeContext,
                                sourceNavigationMetadata, overrideNavigationMetadata,
                                shouldIncludeReferrerParams, shouldStartQuickPromoteOnOpen,
                                excludedStatusIDs);
    if (conversation && NavigationMetadataIsFromProfile(sourceNavigationMetadata)) {
        objc_setAssociatedObject(conversation, ConversationOpenedFromProfileKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return conversation;
}

- (id)initWithAccount:(id)account
                        viewModel:(id)viewModel
          statusNavigationContext:(id)statusNavigationContext
                    scribeContext:(id)scribeContext
         sourceNavigationMetadata:(id)sourceNavigationMetadata
       overrideNavigationMetadata:(id)overrideNavigationMetadata
      shouldIncludeReferrerParams:(BOOL)shouldIncludeReferrerParams
    shouldNotifyDisplayLatestEdit:(BOOL)shouldNotifyDisplayLatestEdit
    shouldStartQuickPromoteOnOpen:(BOOL)shouldStartQuickPromoteOnOpen
                excludedStatusIDs:(id)excludedStatusIDs {
    id conversation = %orig(account, viewModel, statusNavigationContext, scribeContext,
                                sourceNavigationMetadata, overrideNavigationMetadata,
                                shouldIncludeReferrerParams, shouldNotifyDisplayLatestEdit,
                                shouldStartQuickPromoteOnOpen, excludedStatusIDs);
    if (conversation && NavigationMetadataIsFromProfile(sourceNavigationMetadata)) {
        objc_setAssociatedObject(conversation, ConversationOpenedFromProfileKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return conversation;
}

%end

%hook T1EditHistoryViewControllerFactory

+ (id)viewControllerWithAccount:(id)account
                        tweetID:(unsigned long long)tweetID
                  scribeContext:(id)scribeContext {
    id viewController = %orig;
    if (viewController) {
        objc_setAssociatedObject(viewController, EditHistoryViewControllerKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return viewController;
}

%end

static NSString* ItemEntryID(id viewModel) {
    if (![viewModel respondsToSelector:@selector(entryID)]) {
        return nil;
    }

    NSString* entryID = [viewModel performSelector:@selector(entryID)];
    return [entryID isKindOfClass:[NSString class]] ? entryID : nil;
}

static NSString* ItemScribeComponent(id viewModel) {
    if (![viewModel respondsToSelector:@selector(scribeComponent)]) {
        return nil;
    }

    NSString* component = [viewModel performSelector:@selector(scribeComponent)];
    return [component isKindOfClass:[NSString class]] ? component : nil;
}

static BOOL ItemRespondsAndInvokesBOOL(id viewModel, SEL selector) {
    if (![viewModel respondsToSelector:selector]) {
        return NO;
    }

    return ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

// Set when a reply is only on the feed because a followed account replied to
// someone else's tweet
static BOOL ItemIsReplyWithSocialContext(id viewModel) {
    return ItemRespondsAndInvokesBOOL(viewModel, @selector(isReplyAndShouldShowSocialContext));
}

static BOOL ItemIsConversationThreadReply(id viewModel) {
    return [ItemEntryID(viewModel) containsString:@"conversationthread"];
}

// The tweet's author and who it's directly replying to, for recognizing an
// exchange between the thread's own author and a verified user. Real user
// IDs are never 0, so that doubles as "unknown/unsupported".
static long long ItemRepresentedFromUserID(id viewModel) {
    SEL selector = @selector(representedFromUserID);
    if (![viewModel respondsToSelector:selector]) {
        return 0;
    }

    return ((long long (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

static long long AdditionalItemRepresentedFromUserID(id viewModel) {
    SEL selector = @selector(fromUser);
    if (![viewModel respondsToSelector:selector]) {
        return 0;
    }

    // Get the userID NSInteger from the viewModel if the selector exists
    id fromUser = ((id (*)(id, SEL))objc_msgSend)(viewModel, selector);
    if (![fromUser respondsToSelector:@selector(userID)]) {
        return 0;
    }
    return ((long long (*)(id, SEL))objc_msgSend)(fromUser, @selector(userID));
}

static long long ItemInReplyToUserID(id viewModel) {
    SEL selector = @selector(inReplyToUserID);
    if (![viewModel respondsToSelector:selector]) {
        return 0;
    }

    return ((long long (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

static long long CurrentAccountUserID(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass) {
        return 0;
    }

    id host = ((id (*)(id, SEL))objc_msgSend)(
        (id)hostClass, @selector(sharedHostViewController));
    if (![host respondsToSelector:@selector(currentAccount)]) {
        return 0;
    }

    id account = ((id (*)(id, SEL))objc_msgSend)(host, @selector(currentAccount));
    if (![account respondsToSelector:@selector(userID)]) {
        return 0;
    }

    return ((long long (*)(id, SEL))objc_msgSend)(account, @selector(userID));
}

// Twitter's *ByCurrentAccountState fields are a tri-state (0 unknown, 1 yes,
// 2 no); if follows still get hidden, flip this to the value logged for a
// known-followed account.
static const NSInteger kFollowedByCurrentAccountStateFollowing = 1;
static const NSInteger kBlockingCurrentAccountStateBlocking = 1;

static BOOL UserBlocksCurrentAccount(id user) {
    SEL relationshipSelector = @selector(relationship);
    if (![user respondsToSelector:relationshipSelector]) {
        return NO;
    }

    id relationship = ((id (*)(id, SEL))objc_msgSend)(user, relationshipSelector);
    SEL blockingSelector = @selector(blockingCurrentAccountState);
    if (![relationship respondsToSelector:blockingSelector]) {
        return NO;
    }

    NSInteger blockingState =
        ((NSInteger (*)(id, SEL))objc_msgSend)(relationship, blockingSelector);
    return blockingState == kBlockingCurrentAccountStateBlocking;
}

static BOOL ItemIsRetweetOfBlockingUser(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(isRetweet))) {
        return NO;
    }

    SEL authorSelector = @selector(representedFromUser);
    if (![viewModel respondsToSelector:authorSelector]) {
        return NO;
    }

    return UserBlocksCurrentAccount(
        ((id (*)(id, SEL))objc_msgSend)(viewModel, authorSelector));
}

static BOOL ItemIsQuoteTweet(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(isQuoteStatus))) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    long long representedFromUserID = AdditionalItemRepresentedFromUserID(viewModel);
    if (currentAccountUserID != 0 && representedFromUserID == currentAccountUserID) {
        return NO;
    }
    return YES;
}

static BOOL ItemIsRetweet(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(isRetweet))) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    long long representedFromUserID = AdditionalItemRepresentedFromUserID(viewModel);
    if (currentAccountUserID != 0 && representedFromUserID == currentAccountUserID) {
        return NO;
    }

    return YES;
}

// Everything the per-item filters need to know about one section update: which
// hide toggles are on, which screen the timeline is being shown on, and the
// conversation lookups those two imply. Adding a filter or a surface means
// adding a property here, a line in +contextForDataViewController: and a line
// in -isEqualToContext:, instead of another argument threaded through every
// function in this section.
@interface BHTimelineFilterContext : NSObject

// Hide toggles, already resolved against the surface — hideVerified stays off
// in profiles and search, where seeing the account that was looked up is the
// whole point of being there.
@property (nonatomic) BOOL hideWhoToFollow;
@property (nonatomic) BOOL hidePrompts;
@property (nonatomic) BOOL hideVerified;
@property (nonatomic) BOOL hideQuoteTweets;
@property (nonatomic) BOOL hideRetweets;
@property (nonatomic) BOOL hideBlockedRetweets;
@property (nonatomic) BOOL mediaOnly;

// Surfaces.
@property (nonatomic) BOOL inConversation;
@property (nonatomic) BOOL inProfile;
@property (nonatomic) BOOL openedFromProfile;
@property (nonatomic) BOOL inSearch;
@property (nonatomic) BOOL inEditHistory;

// Conversation lookups, filled in by -resolveConversationLookupsInSections:
// once per section update and only when hiding verified replies needs them.
@property (nonatomic) long long conversationRootUserID;
@property (nonatomic, copy) NSSet<NSNumber*>* authorRepliedToUserIDs;

// NO when nothing in this context can hide anything, so the sections can be
// handed back untouched.
@property (nonatomic, readonly) BOOL shouldFilter;

+ (instancetype)contextForDataViewController:(TFNItemsDataViewController*)dataViewController;
- (void)resolveConversationLookupsInSections:(NSArray*)sections;
- (BOOL)isEqualToContext:(BHTimelineFilterContext*)other;

@end

static BOOL BHShouldHideVerifiedItem(id viewModel, BHTimelineFilterContext* context) {
    SEL verifiedSelector = @selector(isFromUserVerified);
    if (![viewModel respondsToSelector:verifiedSelector]) {
        return NO;
    }

    BOOL verified = ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, verifiedSelector);
    if (!verified) {
        return NO;
    }

    SEL bookmarkedSelector = @selector(displayAsBookmarked);
    if ([viewModel respondsToSelector:bookmarkedSelector]) {
        BOOL bookmarked = ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, bookmarkedSelector);
        if (bookmarked) {
            return NO;
        }
    }

    if (context.inConversation) {
        if (!ItemIsConversationThreadReply(viewModel)) {
            return NO;
        }

        if (context.conversationRootUserID != 0) {
            long long repliedUserID = ItemRepresentedFromUserID(viewModel);

            BOOL isAuthorsOwnReply = repliedUserID == context.conversationRootUserID;
            BOOL authorRepliedToThisUser =
                [context.authorRepliedToUserIDs containsObject:@(repliedUserID)];
            if (isAuthorsOwnReply || authorRepliedToThisUser) {
                return NO;
            }
        }
    }

    if (!context.inConversation && ItemIsReplyWithSocialContext(viewModel)) {
        return NO;
    }

    SEL followStateSelector = @selector(representedFromUserFollowedByCurrentAccountState);
    if ([viewModel respondsToSelector:followStateSelector]) {
        NSInteger followState =
            ((NSInteger (*)(id, SEL))objc_msgSend)(viewModel, followStateSelector);
        if (followState == kFollowedByCurrentAccountStateFollowing) {
            return NO;
        }
    }

    return YES;
}

// MARK: Media-only filter
// Whether a tweet view model carries photos or video. The view model's API isn't
// documented, so a few likely selectors are tried in turn; 1 = has media, 0 = none,
// -1 = no selector answered (the item is then left alone). What each view model
// answered is kept for the shake dump, so the right selector can be pinned down.

static NSMutableString* gMediaProbeLog;

NSString* BHTMediaProbeSummary(void) {
    return gMediaProbeLog.length ? [gMediaProbeLog copy] : @"(no timeline items probed)";
}

// An object answer as a count when it is a collection, else whether it exists.
static NSInteger ProbeCount(id value) {
    if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
        return [value count];
    }
    return value ? 1 : 0;
}

// Calls a zero-argument selector and reports its result as a number, or -1 when the
// object doesn't answer it or returns something that isn't a scalar/object.
static NSInteger ProbeSelector(id object, NSString* name, id* objectResult) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) {
        return -1;
    }

    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method) {
        return -1;
    }
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));

    switch (type[0]) {
    case 'B':
    case 'c':
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) ? 1 : 0;
    case 'q':
    case 'Q':
    case 'l':
    case 'i':
        return ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector) > 0 ? 1 : 0;
    case '@': {
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if (objectResult) {
            *objectResult = value;
        }
        return ProbeCount(value) > 0 ? 1 : 0;
    }
    default:
        return -1;
    }
}

static NSInteger ItemMediaState(id viewModel) {
    NSMutableString* log = nil;
    static NSMutableSet<NSString*>* loggedClasses;
    NSString* className = NSStringFromClass([viewModel class]);
    if (!gMediaProbeLog) {
        gMediaProbeLog = [NSMutableString string];
        loggedClasses = [NSMutableSet set];
    }
    if (![loggedClasses containsObject:className] && loggedClasses.count < 6) {
        [loggedClasses addObject:className];
        log = [NSMutableString stringWithFormat:@"%@:", className];
    }

    NSInteger result = -1;

    // Flags and collections on the view model itself.
    for (NSString* name in @[
             @"hasMedia", @"hasInlineMedia", @"hasMediaEntities", @"hasPhoto", @"hasVideo",
             @"inlineMediaInfos", @"mediaInfos", @"media", @"mediaEntities"
         ]) {
        NSInteger answer = ProbeSelector(viewModel, name, nil);
        if (answer >= 0) {
            [log appendFormat:@" %@=%ld", name, (long)answer];
            if (result < 0) {
                result = answer;
            }
        }
    }

    // The underlying status and its entity set.
    for (NSString* statusName in @[ @"status", @"displayStatus", @"primaryStatus" ]) {
        id status = nil;
        if (ProbeSelector(viewModel, statusName, &status) < 0 || !status) {
            continue;
        }
        [log appendFormat:@" %@:%@", statusName, NSStringFromClass([status class])];
        for (NSString* name in @[ @"hasMedia", @"hasPhoto", @"hasVideo", @"mediaEntities" ]) {
            NSInteger answer = ProbeSelector(status, name, nil);
            if (answer >= 0) {
                [log appendFormat:@" %@=%ld", name, (long)answer];
                if (result < 0) {
                    result = answer;
                }
            }
        }
        id entities = nil;
        if (ProbeSelector(status, @"entities", &entities) >= 0 && entities) {
            id media = nil;
            NSInteger answer = ProbeSelector(entities, @"media", &media);
            if (answer >= 0) {
                [log appendFormat:@" entities.media=%ld", (long)answer];
                if (result < 0) {
                    result = answer;
                }
            }
        }
    }

    if (log) {
        [log appendFormat:@" => %ld%c", (long)result, 10];
        [gMediaProbeLog appendString:log];
    }
    return result;
}

// A plain tweet entry (not a prompt, module or cursor) that is known to have no media.
static BOOL ItemIsTweetWithoutMedia(id viewModel) {
    if (![ItemEntryID(viewModel) hasPrefix:@"tweet-"]) {
        return NO;
    }
    return ItemMediaState(viewModel) == 0;
}

static BOOL ShouldHideTimelineItem(id item, BHTimelineFilterContext* context) {
    id viewModel = unwrapDataViewItem(item);
    NSString* className = NSStringFromClass([viewModel classForCoder]);

    if (context.mediaOnly && ItemIsTweetWithoutMedia(viewModel)) {
        return YES;
    }

    if (context.hideVerified && BHShouldHideVerifiedItem(viewModel, context)) {
        return YES;
    }

    if (context.hideBlockedRetweets && ItemIsRetweetOfBlockingUser(viewModel)) {
        return YES;
    }

    if (context.hidePrompts && [className isEqualToString:@"TwitterURT.URTTimelinePromptViewModel"]) {
        return YES;
    }

    if (context.hideWhoToFollow && [ItemScribeComponent(viewModel)
                                       isEqualToString:@"suggest_who_to_follow"]) {
        return YES;
    }

    if (context.hideWhoToFollow && context.inProfile &&
        [className isEqualToString:@"T1TwitterSwift.URTTimelineCarouselViewModel"]) {
        return YES;
    }

    if (!context.inProfile && context.hideQuoteTweets && ItemIsQuoteTweet(viewModel) &&
        !ItemIsReplyWithSocialContext(viewModel)) {
        return YES;
    }

    if (!context.inProfile && context.hideRetweets && ItemIsRetweet(viewModel)) {
        return YES;
    }

    NSString* entryID = ItemEntryID(viewModel);

    if (!entryID) {
        return NO;
    }

    if (context.inConversation && [entryID hasPrefix:@"tweetdetailrelatedtweets"]) {
        return YES;
    }

    if (context.hideWhoToFollow && [entryID containsString:@"who-to-follow"]) {
        return YES;
    }

    return NO;
}

// Calling ShouldHideTimelineItem() for every item on every section update slows
// the app down a LOT, so verdicts are memoized by entry ID. They only hold for
// the context that produced them; a different context drops the whole cache.
static NSCache<NSString*, NSNumber*>* TimelineVerdictCacheForContext(
    BHTimelineFilterContext* context) {
    static NSCache<NSString*, NSNumber*>* cache;
    static BHTimelineFilterContext* cachedContext;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 4000;
    });

    if (![context isEqualToContext:cachedContext]) {
        [cache removeAllObjects];
        cachedContext = context;
    }

    return cache;
}

static BOOL MemoizedShouldHideTimelineItem(id item, NSCache<NSString*, NSNumber*>* cache,
                                           BHTimelineFilterContext* context) {
    NSString* entryID = ItemEntryID(unwrapDataViewItem(item));
    if (!entryID) {
        return ShouldHideTimelineItem(item, context);
    }

    NSNumber* cached = [cache objectForKey:entryID];
    if (cached) {
        return cached.boolValue;
    }

    BOOL hide = ShouldHideTimelineItem(item, context);
    [cache setObject:@(hide) forKey:entryID];
    return hide;
}

static long long ConversationRootUserID(NSArray* sections) {
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (id item in (NSArray*)section) {
            id viewModel = unwrapDataViewItem(item);
            if (ItemIsConversationThreadReply(viewModel)) {
                continue;
            }

            long long userID = ItemRepresentedFromUserID(viewModel);
            if (userID != 0) {
                return userID;
            }
        }
    }

    return 0;
}

static NSSet<NSNumber*>* ConversationAuthorRepliedToUserIDs(NSArray* sections,
                                                            long long rootUserID) {
    NSMutableSet<NSNumber*>* repliedToUserIDs = [NSMutableSet set];
    if (rootUserID == 0) {
        return repliedToUserIDs;
    }

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (id item in (NSArray*)section) {
            id viewModel = unwrapDataViewItem(item);
            if (!ItemIsConversationThreadReply(viewModel)) {
                continue;
            }

            if (ItemRepresentedFromUserID(viewModel) != rootUserID) {
                continue;
            }

            long long repliedToUserID = ItemInReplyToUserID(viewModel);
            if (repliedToUserID != 0) {
                [repliedToUserIDs addObject:@(repliedToUserID)];
            }
        }
    }

    return repliedToUserIDs;
}

@implementation BHTimelineFilterContext

+ (instancetype)contextForDataViewController:(TFNItemsDataViewController*)dataViewController {
    BHTimelineFilterContext* context = [self new];

    context.inConversation =
        IsInHierarchyOfClass(dataViewController, @"T1ConversationContainerViewController");
    context.inProfile = IsInHierarchyOfClass(dataViewController, @"T1ProfileViewController");
    context.openedFromProfile = IsInProfileOriginConversation(dataViewController);
    context.inSearch = IsInHierarchyOfClass(dataViewController, @"TTSSearchContainerViewControllerV2");
    context.inEditHistory = IsInEditHistory(dataViewController);

    context.hideWhoToFollow = [BHTSettings boolForKey:@"hide_who_to_follow"];
    context.hidePrompts = [BHTSettings boolForKey:@"hide_timeline_prompts"];
    context.hideVerified = [BHTSettings boolForKey:@"hide_verified_tweets"] &&
                           !context.inProfile && !context.inSearch && !context.inEditHistory;
    context.hideBlockedRetweets = [BHTSettings boolForKey:@"hide_blocked_retweets"];
    context.mediaOnly = [BHTSettings boolForKey:@"kemo_media_only"] && IsHomeTimeline(dataViewController);
    BOOL inPostInteractions =
        IsInHierarchyOfClass(dataViewController, @"T1PostInteractionsViewController");
    BOOL openedTweetFromProfile = context.inProfile || context.openedFromProfile;
    context.hideQuoteTweets = [BHTSettings boolForKey:@"hide_quote_tweets"] &&
                              !inPostInteractions && !openedTweetFromProfile;
    context.hideRetweets = [BHTSettings boolForKey:@"hide_retweets"] &&
                           !inPostInteractions && !openedTweetFromProfile;

    return context;
}

- (BOOL)shouldFilter {
    return self.hideWhoToFollow || self.hidePrompts || self.hideVerified ||
           self.hideQuoteTweets || self.hideRetweets || self.hideBlockedRetweets || self.mediaOnly ||
           self.inConversation;
}

- (void)resolveConversationLookupsInSections:(NSArray*)sections {
    if (!self.hideVerified || !self.inConversation) {
        self.conversationRootUserID = 0;
        self.authorRepliedToUserIDs = nil;
        return;
    }

    self.conversationRootUserID = ConversationRootUserID(sections);
    self.authorRepliedToUserIDs =
        ConversationAuthorRepliedToUserIDs(sections, self.conversationRootUserID);
}

- (BOOL)isEqualToContext:(BHTimelineFilterContext*)other {
    if (!other) {
        return NO;
    }

    return self.hideWhoToFollow == other.hideWhoToFollow &&
           self.hidePrompts == other.hidePrompts && self.hideVerified == other.hideVerified &&
           self.hideBlockedRetweets == other.hideBlockedRetweets &&
           self.mediaOnly == other.mediaOnly &&
           self.inConversation == other.inConversation && self.inProfile == other.inProfile &&
           self.openedFromProfile == other.openedFromProfile &&
           self.inSearch == other.inSearch &&
           self.hideQuoteTweets == other.hideQuoteTweets &&
           self.hideRetweets == other.hideRetweets &&
           self.conversationRootUserID == other.conversationRootUserID &&
           self.inEditHistory == other.inEditHistory &&
           (self.authorRepliedToUserIDs == other.authorRepliedToUserIDs ||
            [self.authorRepliedToUserIDs isEqualToSet:other.authorRepliedToUserIDs]);
}

@end

static NSArray* FilteredTimelineSections(TFNItemsDataViewController* dataViewController,
                                         NSArray* sections) {
    BHTimelineFilterContext* context =
        [BHTimelineFilterContext contextForDataViewController:dataViewController];
    if (!context.shouldFilter) {
        return sections;
    }

    [context resolveConversationLookupsInSections:sections];
    NSCache<NSString*, NSNumber*>* verdicts = TimelineVerdictCacheForContext(context);

    // Modules can share a section with unrelated items, so filtering is per item;
    // a purely filtered section (like the Discover More one) empties and is dropped.
    BOOL modified = NO;
    NSMutableArray* filteredSections = [NSMutableArray arrayWithCapacity:sections.count];

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            [filteredSections addObject:section];
            continue;
        }

        NSArray* items = section;
        NSMutableIndexSet* removed = [NSMutableIndexSet indexSet];

        for (NSUInteger i = 0; i < items.count; i++) {
            if (MemoizedShouldHideTimelineItem(items[i], verdicts, context)) {
                [removed addIndex:i];
            }
        }

        if (removed.count == 0) {
            [filteredSections addObject:section];
            continue;
        }

        MarkEmptiedModuleChrome(items, removed);

        modified = YES;
        NSMutableArray* keptItems = [items mutableCopy];
        [keptItems removeObjectsAtIndexes:removed];
        if (keptItems.count > 0) {
            [filteredSections addObject:keptItems];
        }
    }

    return modified ? [filteredSections copy] : sections;
}

// MARK: - Videos for you module

// The server sends the carousel as one timeline entry, but the app expands it
// into separate header/content/footer view models. Drop the entry from the
// GraphQL response so the whole module never reaches that expansion.
static BOOL IsGraphQLResponse(NSURL* url) {
    return [url.path.pathComponents containsObject:@"graphql"];
}

static id RemoveVideoCarouselEntries(id node, BOOL* removed) {
    if ([node isKindOfClass:[NSArray class]]) {
        NSMutableArray* kept = [NSMutableArray array];
        for (id value in (NSArray*)node) {
            id entryID = [value isKindOfClass:[NSDictionary class]] ? value[@"entry_id"] : nil;
            if ([entryID isKindOfClass:[NSString class]] &&
                [entryID hasPrefix:@"video-carousel-"]) {
                *removed = YES;
                continue;
            }

            [kept addObject:RemoveVideoCarouselEntries(value, removed)];
        }
        return kept;
    }

    if ([node isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary* copy = [node mutableCopy];
        for (NSString* key in node) {
            copy[key] = RemoveVideoCarouselEntries(node[key], removed);
        }
        return copy;
    }

    return node;
}

%hook TNLResponseInfo

- (instancetype)initWithFinalURLRequest:(NSURLRequest*)request
                            URLResponse:(NSURLResponse*)response
                                 source:(NSInteger)source
                                   data:(NSData*)data
                     temporarySavedFile:(id)temporarySavedFile {
    if ([BHTSettings boolForKey:@"hide_videos_for_you"] && data &&
        IsGraphQLResponse(request.URL)) {
        NSData* marker = [@"video-carousel-" dataUsingEncoding:NSUTF8StringEncoding];
        if ([data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)].location !=
            NSNotFound) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            BOOL removed = NO;
            id filtered = json ? RemoveVideoCarouselEntries(json, &removed) : nil;
            if (removed) {
                data = [NSJSONSerialization dataWithJSONObject:filtered options:0 error:nil] ?: data;
            }
        }
    }

    return %orig(request, response, source, data, temporarySavedFile);
}

%end

// "New tweets N" for the header bubble: on the home timeline, how many tweets arrived
// that this list had not shown before.
extern void NFBSetNewTweets(id controller, NSArray<NSString*>* entryIDs, NSUInteger count);
extern BOOL NFBRefreshWasRecent(void);

static const void* kSeenTweetsKey = &kSeenTweetsKey;

static void NoteNewTweets(TFNItemsDataViewController* controller, NSArray* sections) {
    NSMutableArray<NSString*>* ids = [NSMutableArray array];
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }
        for (id item in (NSArray*)section) {
            NSString* entryID = ItemEntryID(unwrapDataViewItem(item));
            if ([entryID hasPrefix:@"tweet-"]) {
                [ids addObject:entryID];
            }
        }
    }

    NSSet<NSString*>* seen = objc_getAssociatedObject(controller, kSeenTweetsKey);
    NSMutableSet<NSString*>* all = [NSMutableSet setWithArray:ids];
    if (seen && seen.count < 3000) {
        [all unionSet:seen];
    }
    objc_setAssociatedObject(controller, kSeenTweetsKey, all, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (seen.count == 0 || ids.count == 0) {
        return;
    }

    NSUInteger fresh = 0;
    if (NFBRefreshWasRecent()) {
        for (NSString* entryID in ids) {
            if (![seen containsObject:entryID]) {
                fresh++;
            }
        }
    } else {
        // Not a pull: only count what arrived above the tweets already shown.
        BOOL overlap = NO;
        for (NSString* entryID in ids) {
            if ([seen containsObject:entryID]) {
                overlap = YES;
                break;
            }
            fresh++;
        }
        if (!overlap) {
            return;
        }
    }
    if (fresh > 0) {
        NFBSetNewTweets(controller, ids, fresh);
    }
}

// For You refreshes ignore the restore flag, so the first status in view is remembered by
// its id and put back where it was once the new sections have been laid out.
static void KeepPositionAround(TFNItemsDataViewController* controller, NSArray* sections,
                               void (^apply)(void)) {
    UITableView* table = (UITableView*)controller.tableView;
    NSString* anchorID = nil;
    CGFloat anchorOffset = 0;
    CGFloat topEdge = table.contentOffset.y + table.adjustedContentInset.top;
    if (table.window && topEdge > 40) {
        for (UITableViewCell* cell in table.visibleCells) {
            NSString* cellID = cell.accessibilityIdentifier;
            if (cellID.length > 8 && CGRectGetMaxY(cell.frame) > topEdge &&
                (!anchorID || CGRectGetMinY(cell.frame) < anchorOffset + topEdge)) {
                anchorID = cellID;
                anchorOffset = CGRectGetMinY(cell.frame) - topEdge;
            }
        }
    }
    apply();
    if (!anchorID) {
        return;
    }

    __weak UITableView* weakTable = table;
    void (^restore)(void) = ^{
        UITableView* current = weakTable;
        if (!current) {
            return;
        }
        [current layoutIfNeeded];
        CGFloat top = current.contentOffset.y + current.adjustedContentInset.top;
        for (UITableViewCell* cell in current.visibleCells) {
            if ([cell.accessibilityIdentifier isEqualToString:anchorID]) {
                CGFloat delta = (CGRectGetMinY(cell.frame) - top) - anchorOffset;
                if (fabs(delta) > 1.0) {
                    current.contentOffset = CGPointMake(current.contentOffset.x,
                                                        current.contentOffset.y + delta);
                }
                return;
            }
        }
        // Not on screen any more: find it in the new data and scroll there.
        for (NSUInteger section = 0; section < sections.count; section++) {
            id items = sections[section];
            if (![items isKindOfClass:[NSArray class]]) {
                continue;
            }
            for (NSUInteger row = 0; row < [items count]; row++) {
                if ([[items[row] description] containsString:anchorID] &&
                    section < (NSUInteger)current.numberOfSections &&
                    row < (NSUInteger)[current numberOfRowsInSection:section]) {
                    [current scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]
                                   atScrollPosition:UITableViewScrollPositionTop
                                           animated:NO];
                    return;
                }
            }
        }
    };
    dispatch_async(dispatch_get_main_queue(), restore);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), restore);
}

%hook TFNItemsDataViewController

- (void)setSections:(NSArray*)sections restoreScrollPosition:(BOOL)restoreScrollPosition {
    // Home timeline only: ask for the scroll position to be restored, so a refresh
    // leaves you where you were instead of jumping to the newest tweets.
    NSArray* filtered = FilteredTimelineSections(self, sections);
    if (IsHomeTimeline(self) && [BHTSettings boolForKey:@"kemo_header_bubble"] &&
        [BHTSettings boolForKey:@"kemo_bubble_new_tweets"]) {
        NoteNewTweets(self, filtered);
    }
    if ([BHTSettings boolForKey:@"kemo_keep_position"] && IsHomeTimeline(self)) {
        KeepPositionAround(self, filtered, ^{
            %orig(filtered, YES);
        });
        return;
    }
    %orig(filtered, restoreScrollPosition);
}

- (void)updateSections:(NSArray*)sections
    reconfigureItemIdentifiers:(NSArray*)identifiers
              withRowAnimation:(long long)animation
                    completion:(id)completion {
    %orig(FilteredTimelineSections(self, sections), identifiers, animation, completion);
}

%end
