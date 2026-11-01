#import <Foundation/Foundation.h>

// YES when the text has a slur-style divisive term, or at least two weaker
// baiting signals. Profanity by itself does not count. Empty text is NO.
BOOL NFBConflictIsDivisive(NSString *_Nullable text);
