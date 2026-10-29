//
//  BHTHashtags.m
//  NeoFreeBird
//

#import "Core/BHTHashtags.h"

static NSString* const kFavoritesKey = @"kemo_favorite_hashtags";

@implementation BHTHashtags

+ (NSArray<NSString*>*)favorites {
    NSArray* stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kFavoritesKey];
    if (stored) {
        return stored;
    }
    return @[ @"#FursuitFriday", @"#FursuitEveryday" ];
}

+ (void)setFavorites:(NSArray<NSString*>*)favorites {
    [[NSUserDefaults standardUserDefaults] setObject:favorites ?: @[] forKey:kFavoritesKey];
}

+ (NSString*)normalized:(NSString*)raw {
    NSString* tag = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([tag hasPrefix:@"#"] || [tag hasPrefix:@"＃"]) {
        tag = [tag substringFromIndex:1];
    }
    tag = [[tag componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        componentsJoinedByString:@""];
    tag = [tag stringByReplacingOccurrencesOfString:@"#" withString:@""];
    return tag.length > 0 ? [@"#" stringByAppendingString:tag] : nil;
}

@end
