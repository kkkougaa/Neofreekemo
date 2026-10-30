//
//  BHTAvatars.h
//  NeoFreeBird
//

#import <UIKit/UIKit.h>

// Profile pictures for the accounts attached to D-day events. Fetched once from
// unavatar.io (a public avatar service, not X) and kept on disk; the handle is the only
// thing sent.
@interface BHTAvatars : NSObject

// The cached picture, or nil. When it isn't cached yet a download starts and the
// completion runs on the main queue once it has arrived.
+ (UIImage*)imageForHandle:(NSString*)handle completion:(void (^)(void))completion;

@end
