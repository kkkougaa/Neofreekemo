//
//  BHTKeywords.m
//  NeoFreeBird
//

#import "Core/BHTKeywords.h"

static NSString* const kKeywordsKey = @"kemo_highlight_keywords";

@implementation BHTKeywords

+ (NSArray<NSString*>*)all {
    return [[NSUserDefaults standardUserDefaults] arrayForKey:kKeywordsKey] ?: @[];
}

+ (void)setAll:(NSArray<NSString*>*)keywords {
    [[NSUserDefaults standardUserDefaults] setObject:keywords ?: @[] forKey:kKeywordsKey];
}

+ (BOOL)textMatches:(NSString*)text {
    if (text.length == 0) {
        return NO;
    }
    NSArray<NSString*>* keywords = [self all];
    if (keywords.count == 0) {
        return NO;
    }
    for (NSString* keyword in keywords) {
        if (keyword.length > 0 &&
            [text rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

@end
