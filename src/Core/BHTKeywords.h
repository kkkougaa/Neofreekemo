//
//  BHTKeywords.h
//  NeoFreeBird
//

#import <Foundation/Foundation.h>

// Words that make a tweet stand out in the timeline. Stored locally in
// NSUserDefaults and edited in the kemo settings.
@interface BHTKeywords : NSObject

+ (NSArray<NSString*>*)all;
+ (void)setAll:(NSArray<NSString*>*)keywords;

// Whether the text contains any keyword (case-insensitive).
+ (BOOL)textMatches:(NSString*)text;

@end
