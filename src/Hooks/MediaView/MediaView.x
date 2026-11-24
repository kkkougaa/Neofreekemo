#import "MediaView.h"

// MARK: - Force tweet images to full frame

%hook T1StandardStatusAttachmentViewAdapter

// attachmentType 2 = photos, displayType 1 = full frame
- (NSUInteger)displayType {
    if (self.attachmentType == 2) {
        return [BHTSettings boolForKey:@"force_tweet_full_frame"] ? 1 : %orig;
    }

    return %orig;
}

%end

%hook T1AccountAutoplayPolicy

- (id)initWithCurrentSettings:(id)settings
           currentNetworkReachabilityStatus:(id)status
                         notificationCenter:(id)center
    ignoreCurrentSettingsWhenAutoplayingGif:(_Bool)ignore {
    return %orig(settings, status, center, NO);
}

- (id)initWithIgnoreCurrentSettingsWhenAutoplayingGif:(_Bool)ignore {
    return %orig(NO);
}

%end
