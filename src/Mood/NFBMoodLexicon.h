#import <Foundation/Foundation.h>

// On-device word lists for the mood thermometer. Conflict (level 6) is
// checked before profanity (level 5). Anger hits only feed levels 1–4.
BOOL NFBMoodContainsConflict(NSString *_Nullable text);
BOOL NFBMoodContainsProfanity(NSString *_Nullable text);
NSInteger NFBMoodAngerHits(NSString *_Nullable text);
