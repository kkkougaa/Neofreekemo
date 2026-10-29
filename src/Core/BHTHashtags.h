//
//  BHTHashtags.h
//  NeoFreeBird
//

#import <Foundation/Foundation.h>

// The favorite hashtags offered first while typing "#" in the compose screen. Stored
// locally in NSUserDefaults and edited in the kemo settings.
@interface BHTHashtags : NSObject

+ (NSArray<NSString*>*)favorites;
+ (void)setFavorites:(NSArray<NSString*>*)favorites;

// "  #Tag " / "Tag" -> "#Tag"; nil when nothing usable is left.
+ (NSString*)normalized:(NSString*)raw;

@end
