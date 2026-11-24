#import "Timeline.h"

static BOOL StringSuggestsProfile(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }

    return [[(NSString*)value lowercaseString] containsString:@"profile"];
}

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

static BOOL ItemIsAITweet(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(hasAIGeneratedDisclosure))) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    long long representedFromUserID = AdditionalItemRepresentedFromUserID(viewModel);
    if (currentAccountUserID != 0 && representedFromUserID == currentAccountUserID) {
        return NO;
    }

    return YES;
}

static BOOL ItemIsPaidTweet(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(hasPaidPromotionDisclosure))) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    long long representedFromUserID = AdditionalItemRepresentedFromUserID(viewModel);
    if (currentAccountUserID != 0 && representedFromUserID == currentAccountUserID) {
        return NO;
    }

    return YES;
}

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

    if (context.inNotifications) {
        return NO;
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

    if (!context.inProfile && context.hideAITweets && ItemIsAITweet(viewModel)) {
        return YES;
    }

    if (!context.inProfile && context.hidePaidTweets && ItemIsPaidTweet(viewModel)) {
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

// The server sends the carousel as one timeline entry, but the app expands it
// into separate header/content/footer view models. Drop the entry from the
// GraphQL response so the whole module never reaches that expansion.
BOOL IsGraphQLResponse(NSURL* url) {
    return [url.path.pathComponents containsObject:@"graphql"];
}

id RemoveVideoCarouselEntries(id node, BOOL* removed) {
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

// Resolves the class by name so mangled Swift names work; NSStringFromClass
// would only ever produce the demangled dotted form.
BOOL IsInHierarchyOfClass(UIViewController* viewController, NSString* className) {
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

// Need to tag edit history since it reuses a generic class

BOOL IsHomeTimeline(UIViewController* viewController) {
    return IsInHierarchyOfClass(
               viewController,
               @"_TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController") ||
           IsInHierarchyOfClass(
               viewController,
               @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
}

BOOL IsInEditHistory(UIViewController* viewController) {
    UIViewController* currentVC = viewController;

    while (currentVC) {
        if (objc_getAssociatedObject(currentVC, EditHistoryViewControllerKey)) {
            return YES;
        }

        currentVC = currentVC.parentViewController;
    }

    return NO;
}

BOOL NavigationMetadataIsFromProfile(id metadata) {
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

BOOL IsInProfileOriginConversation(UIViewController* viewController) {
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

long long ConversationRootUserID(NSArray* sections) {
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

NSSet<NSNumber*>* ConversationAuthorRepliedToUserIDs(NSArray* sections,
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

// What the filter did outside the home timeline, for the shake dump.
static NSMutableArray<NSString*>* gFilterLog;

static void FilterNote(NSString* line) {
    if (!gFilterLog) {
        gFilterLog = [NSMutableArray array];
    }
    [gFilterLog addObject:line];
    if (gFilterLog.count > 12) {
        [gFilterLog removeObjectAtIndex:0];
    }
}

NSString* NFBTimelineFilterDebugText(void) {
    return gFilterLog.count ? [gFilterLog componentsJoinedByString:@"\n"] : @"(no filtering outside home yet)";
}

static NSUInteger SectionItemCount(NSArray* sections) {
    NSUInteger count = 0;
    for (id section in sections) {
        if ([section isKindOfClass:[NSArray class]]) {
            count += [(NSArray*)section count];
        }
    }
    return count;
}

static NSArray* FilteredTimelineSectionsUnguarded(TFNItemsDataViewController* dataViewController,
                                                  NSArray* sections);

// Outside the home timeline (notifications, profiles, lists, search...), a
// filter that would leave a non-empty list with nothing at all shows a blank
// screen. Then the list is kept as X sent it.
NSArray* FilteredTimelineSections(TFNItemsDataViewController* dataViewController,
                                  NSArray* sections) {
    NSArray* filtered = FilteredTimelineSectionsUnguarded(dataViewController, sections);
    if (filtered == sections || IsHomeTimeline(dataViewController)) {
        return filtered;
    }
    NSUInteger before = SectionItemCount(sections);
    NSUInteger after = SectionItemCount(filtered);
    NSString* name = NSStringFromClass(dataViewController.class);
    if (before > 0 && after == 0) {
        FilterNote([NSString stringWithFormat:@"%@: would remove all %lu items, kept them", name,
                                              (unsigned long)before]);
        return sections;
    }
    FilterNote([NSString stringWithFormat:@"%@: %lu -> %lu items", name, (unsigned long)before,
                                          (unsigned long)after]);
    return filtered;
}

static NSArray* FilteredTimelineSectionsUnguarded(TFNItemsDataViewController* dataViewController,
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
