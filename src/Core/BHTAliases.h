//
//  BHTAliases.h
//  NeoFreeBird
//

#import <Foundation/Foundation.h>

// Personal nicknames for accounts, shown in the timeline next to the name. Stored
// locally in NSUserDefaults, keyed by the account's lowercase handle.
@interface BHTAliases : NSObject

+ (NSDictionary<NSString*, NSString*>*)all;
+ (NSString*)aliasForHandle:(NSString*)handle;

// An empty alias removes the entry.
+ (void)setAlias:(NSString*)alias forHandle:(NSString*)handle;

// "@Handle " -> "handle"; nil when nothing usable is left.
+ (NSString*)normalizedHandle:(NSString*)raw;

@end
