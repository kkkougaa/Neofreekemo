//
//  BHTEvents.h
//  NeoFreeBird
//

#import <Foundation/Foundation.h>

// Event dates for the D-day lines in the side drawer. Stored locally in
// NSUserDefaults and edited in the kemo settings. Each event is a dictionary with
// "name", "time" (seconds since 1970) and an optional "handle" (account, no "@").
@interface BHTEvents : NSObject

// All events, soonest first.
+ (NSArray<NSDictionary*>*)all;

// Events that are today or later, soonest first, at most `limit`.
+ (NSArray<NSDictionary*>*)upcoming:(NSUInteger)limit;

+ (void)addName:(NSString*)name date:(NSDate*)date handle:(NSString*)handle;
+ (void)removeEvent:(NSDictionary*)event;

// Whole days from today to the date's day (0 = today, negative = past).
+ (NSInteger)daysUntil:(NSDate*)date;

@end
