//
//  BHTSpotify.h
//  NeoFreeBird
//

#import <Foundation/Foundation.h>

// Spotify login (authorization code + PKCE, so no client secret is stored) and the
// currently playing track. Talks to Spotify only; nothing here touches X.
@interface BHTSpotify : NSObject

+ (instancetype)shared;

// The app's Client ID from the Spotify developer dashboard, kept in the kemo settings.
@property (nonatomic, copy, readonly) NSString* clientID;
@property (nonatomic, readonly) BOOL isConnected;
// How the last now-playing check went, in a few words (shown in the kemo settings).
@property (nonatomic, copy, readonly) NSString* lastStatus;

// Opens Spotify's login page; the completion runs on the main queue.
- (void)loginWithCompletion:(void (^)(NSError* error))completion;
- (void)logout;

// Calls back on the main queue. A nil title with no error means nothing is playing.
- (void)fetchCurrentlyPlaying:(void (^)(NSString* title, NSString* artist, NSString* shareURL,
                                        NSError* error))completion;

@end
