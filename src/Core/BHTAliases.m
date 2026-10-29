//
//  BHTAliases.m
//  NeoFreeBird
//

#import "Core/BHTAliases.h"

static NSString* const kAliasesKey = @"kemo_account_aliases";

@implementation BHTAliases

+ (NSDictionary<NSString*, NSString*>*)all {
    NSDictionary* stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAliasesKey];
    return stored ?: @{};
}

+ (NSString*)aliasForHandle:(NSString*)handle {
    NSString* key = [self normalizedHandle:handle];
    return key ? [self all][key] : nil;
}

+ (void)setAlias:(NSString*)alias forHandle:(NSString*)handle {
    NSString* key = [self normalizedHandle:handle];
    if (!key) {
        return;
    }
    NSMutableDictionary* updated = [[self all] mutableCopy];
    NSString* trimmed =
        [alias stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 0) {
        updated[key] = trimmed;
    } else {
        [updated removeObjectForKey:key];
    }
    [[NSUserDefaults standardUserDefaults] setObject:updated forKey:kAliasesKey];
}

+ (NSString*)normalizedHandle:(NSString*)raw {
    NSString* handle = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([handle hasPrefix:@"@"] || [handle hasPrefix:@"＠"]) {
        handle = [handle substringFromIndex:1];
    }
    return handle.length > 0 ? handle.lowercaseString : nil;
}

@end
