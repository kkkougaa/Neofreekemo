//
//  LogoMenu.x
//  NeoFreeBird
//

#import "Headers/XHeaders.h"
#import "HookHelpers.h"

// MARK: - Recently viewed tweets, and the menu under the header logo

// Tweets that stay on screen for half a second are remembered (the last 30, on this
// device only); the list is opened from the kemo settings. Everything here reads what the
// app already shows; nothing goes to any server.

extern UIImageView* HeaderLogoInWindow(UIWindow* window);
extern UIWindow* NFBKeyWindow(void);

static NSString* const kRecentKey = @"nfb_recent_tweets";
static const NSUInteger kRecentLimit = 30;
static const NSTimeInterval kDwellSeconds = 0.5;

static NSString* Localized(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

// MARK: Store

// Kept in memory; the file is written a few seconds after the last change, so a tweet seen
// every half second does not mean a disk write every half second.
static NSMutableArray<NSDictionary*>* gRecent;
static BOOL gRecentSavePending;

static NSArray<NSDictionary*>* RecentTweets(void) {
    if (!gRecent) {
        NSArray* saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kRecentKey];
        gRecent = saved ? [saved mutableCopy] : [NSMutableArray array];
    }
    return gRecent;
}

static void SaveRecentSoon(void) {
    if (gRecentSavePending) {
        return;
    }
    gRecentSavePending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       gRecentSavePending = NO;
                       [[NSUserDefaults standardUserDefaults] setObject:[gRecent copy] forKey:kRecentKey];
                   });
}

// A small picture of the tweet's first image, kept as a tiny JPEG in Caches (about 5 KB each,
// 30 at most). It is made once, when the tweet is recorded; the list only reads the files.
static NSURL* ThumbnailURL(NSString* tweetID) {
    NSURL* caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                             inDomains:NSUserDomainMask] firstObject];
    NSURL* directory = [caches URLByAppendingPathComponent:@"nfb_recent" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return [directory URLByAppendingPathComponent:[tweetID stringByAppendingString:@".jpg"]];
}

// Returns whether a picture was saved; `sensitive` says the tweet's media was covered (by the
// app's own warning or by the AI cover), in which case no picture is kept at all.
static BOOL SaveThumbnail(UITableViewCell* cell, NSString* tweetID, BOOL* sensitive) {
    *sensitive = NO;
    __block UIImage* best = nil;
    __block CGFloat bestArea = 0;
    Class interstitial = NSClassFromString(@"HFSensitiveTweetBlurredInterstitialView");
    EnumerateSubviewsRecursively(cell, ^(UIView* view) {
        if ((interstitial && [view isKindOfClass:interstitial]) || view.tag == 0x4e464232) {
            *sensitive = YES;
            return;
        }
        if (![view isKindOfClass:[UIImageView class]]) {
            return;
        }
        UIImage* image = ((UIImageView*)view).image;
        // Tweet pictures are big; avatars and icons are not.
        if (!image.CGImage || image.size.width < 100 || image.size.height < 100) {
            return;
        }
        CGFloat area = image.size.width * image.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = image;
        }
    });
    if (*sensitive || !best) {
        return NO;
    }
    CGFloat edge = 112;
    CGFloat scale = MAX(edge / best.size.width, edge / best.size.height);
    CGSize target = CGSizeMake(best.size.width * scale, best.size.height * scale);
    UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer* renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(edge, edge) format:format];
    NSData* data = [renderer JPEGDataWithCompressionQuality:0.6
                                                    actions:^(UIGraphicsImageRendererContext* context) {
                                                        // Centre crop to a square.
                                                        [best drawInRect:CGRectMake((edge - target.width) / 2,
                                                                                    (edge - target.height) / 2,
                                                                                    target.width, target.height)];
                                                    }];
    return [data writeToURL:ThumbnailURL(tweetID) atomically:YES];
}

static void RemoveThumbnail(NSString* tweetID) {
    [[NSFileManager defaultManager] removeItemAtURL:ThumbnailURL(tweetID) error:nil];
}

static void RememberTweet(NSString* tweetID, NSString* label, BOOL hasThumbnail, BOOL sensitive) {
    RecentTweets();
    for (NSDictionary* entry in [gRecent copy]) {
        if ([entry[@"id"] isEqualToString:tweetID]) {
            [gRecent removeObject:entry];
        }
    }
    [gRecent insertObject:@{
        @"id" : tweetID,
        @"label" : label ?: @"",
        @"at" : @([[NSDate date] timeIntervalSince1970]),
        @"thumb" : @(hasThumbnail),
        @"sensitive" : @(sensitive),
    }
                  atIndex:0];
    while (gRecent.count > kRecentLimit) {
        RemoveThumbnail(gRecent.lastObject[@"id"]);
        [gRecent removeLastObject];
    }
    SaveRecentSoon();
}

// MARK: Watching the timeline

static __weak UITableView* gSeenTable;
static NSMutableDictionary<NSString*, NSDate*>* gDwell;

%hook TFNTableView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        gSeenTable = (UITableView*)self;
    }
}

%end

// Looked at twice a second: a tweet that is (mostly) in view and has stayed there for a couple
// of seconds counts as seen. While the list is moving nothing counts.
static void WatchTimeline(void) {
    UITableView* table = gSeenTable;
    if (!table || !table.window || table.isDragging || table.isDecelerating) {
        [gDwell removeAllObjects];
        return;
    }
    if (!gDwell) {
        gDwell = [NSMutableDictionary dictionary];
    }
    CGFloat top = table.contentOffset.y + table.adjustedContentInset.top;
    CGFloat bottom = table.contentOffset.y + CGRectGetHeight(table.bounds) - table.adjustedContentInset.bottom;
    CGFloat viewportHeight = MAX(bottom - top, 1);

    NSMutableSet<NSString*>* visibleNow = [NSMutableSet set];
    for (UITableViewCell* cell in table.visibleCells) {
        NSString* tweetID = cell.accessibilityIdentifier;
        if (tweetID.length <= 8) {
            continue;
        }
        CGFloat shown = MIN(CGRectGetMaxY(cell.frame), bottom) - MAX(CGRectGetMinY(cell.frame), top);
        // Mostly in view: most of a short tweet, or half the screen for a tall one.
        if (shown < MIN(CGRectGetHeight(cell.frame) * 0.6, viewportHeight * 0.5)) {
            continue;
        }
        [visibleNow addObject:tweetID];
        NSDate* since = gDwell[tweetID];
        if (!since) {
            gDwell[tweetID] = [NSDate date];
        } else if (-[since timeIntervalSinceNow] >= kDwellSeconds) {
            NSDictionary* first = RecentTweets().firstObject;
            NSString* label = [first[@"id"] isEqualToString:tweetID] ? nil : cell.accessibilityLabel;
            if (label.length > 0) {
                BOOL sensitive = NO;
                BOOL thumb = SaveThumbnail(cell, tweetID, &sensitive);
                RememberTweet(tweetID, label, thumb, sensitive);
            }
        }
    }
    for (NSString* gone in [gDwell.allKeys copy]) {
        if (![visibleNow containsObject:gone]) {
            [gDwell removeObjectForKey:gone];
        }
    }
}

// MARK: The list

@interface NFBRecentViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary*>* items;
@end

@implementation NFBRecentViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.items = RecentTweets();
        self.title = Localized(@"KEMO_MENU_RECENT");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.presentingViewController && !self.navigationController.presentingViewController) {
        return; // pushed inside the settings: the back button is enough
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                      primaryAction:[UIAction actionWithHandler:^(UIAction* action) {
                          [self dismissViewControllerAnimated:YES completion:nil];
                      }]];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(self.items.count, 1);
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"recent"]
                                ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                          reuseIdentifier:@"recent"];
    UIListContentConfiguration* content = [UIListContentConfiguration subtitleCellConfiguration];
    if (self.items.count == 0) {
        content.text = Localized(@"KEMO_RECENT_EMPTY");
        content.textProperties.color = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSString* label = self.items[indexPath.row][@"label"];
        // The accessibility sentence starts with the author, then the text.
        NSRange dot = [label rangeOfString:@". "];
        content.text = dot.location != NSNotFound ? [label substringToIndex:dot.location] : label;
        NSString* rest = dot.location != NSNotFound ? [label substringFromIndex:NSMaxRange(dot)] : @"";
        content.secondaryText = rest;
        content.secondaryTextProperties.numberOfLines = 2;
        content.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        content.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;

        NSDictionary* entry = self.items[indexPath.row];
        if ([entry[@"sensitive"] boolValue]) {
            // Covered media stays covered: no picture, just a mark.
            content.image = [UIImage systemImageNamed:@"eye.slash"];
            content.imageProperties.tintColor = [UIColor secondaryLabelColor];
            content.imageProperties.reservedLayoutSize = CGSizeMake(56, 56);
        } else if ([entry[@"thumb"] boolValue]) {
            UIImage* picture = [UIImage imageWithContentsOfFile:ThumbnailURL(entry[@"id"]).path];
            if (picture) {
                content.image = picture;
                content.imageProperties.maximumSize = CGSizeMake(56, 56);
                content.imageProperties.reservedLayoutSize = CGSizeMake(56, 56);
                content.imageProperties.cornerRadius = 8;
            }
        }
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.items.count == 0) {
        return;
    }
    NSString* tweetID = self.items[indexPath.row][@"id"];
    NSURL* url = [NSURL URLWithString:[@"twitter://status?id=" stringByAppendingString:tweetID]];
    [self dismissViewControllerAnimated:YES
                             completion:^{
                                 if (url) {
                                     [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                                 }
                             }];
}

@end

// MARK: Used by the kemo settings

UIViewController* NFBMakeRecentViewController(void) {
    return [NFBRecentViewController new];
}

NSUInteger NFBRecentCount(void) {
    return RecentTweets().count;
}

static NSTimer* gWatchTimer;

// Called twice a second from the bubble's timer.
void NFBRecentTick(void) {
    // The look at the timeline runs four times a second: it is a handful of cells and
    // a dictionary, with no layout and no drawing, so it costs next to nothing.
    if (!gWatchTimer) {
        gWatchTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                      repeats:YES
                                                        block:^(NSTimer* timer) {
                                                            if ([UIApplication sharedApplication].applicationState ==
                                                                    UIApplicationStateActive &&
                                                                [BHTSettings boolForKey:@"kemo_recent_tweets"]) {
                                                                WatchTimeline();
                                                            }
                                                        }];
    }
}
