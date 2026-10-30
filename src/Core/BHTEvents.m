//
//  BHTEvents.m
//  NeoFreeBird
//

#import "Core/BHTEvents.h"
#import "Core/BHTAliases.h"

static NSString* const kEventsKey = @"kemo_events";

@implementation BHTEvents

+ (NSArray<NSDictionary*>*)all {
    NSArray* stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kEventsKey] ?: @[];
    return [stored sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [a[@"time"] compare:b[@"time"]];
    }];
}

+ (NSInteger)daysUntil:(NSDate*)date {
    NSCalendar* calendar = [NSCalendar currentCalendar];
    NSDate* today = [calendar startOfDayForDate:[NSDate date]];
    NSDate* day = [calendar startOfDayForDate:date];
    return [calendar components:NSCalendarUnitDay fromDate:today toDate:day options:0].day;
}

+ (NSArray<NSDictionary*>*)upcoming:(NSUInteger)limit {
    NSMutableArray* result = [NSMutableArray array];
    for (NSDictionary* event in [self all]) {
        NSDate* date = [NSDate dateWithTimeIntervalSince1970:[event[@"time"] doubleValue]];
        if ([self daysUntil:date] >= 0) {
            [result addObject:event];
            if (result.count >= limit) {
                break;
            }
        }
    }
    return result;
}

+ (void)addName:(NSString*)name date:(NSDate*)date handle:(NSString*)handle {
    NSString* trimmed =
        [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || !date) {
        return;
    }
    NSMutableArray* events = [[[NSUserDefaults standardUserDefaults] arrayForKey:kEventsKey] mutableCopy]
                                 ?: [NSMutableArray array];
    [events addObject:@{
        @"name" : trimmed,
        @"time" : @(date.timeIntervalSince1970),
        @"handle" : [BHTAliases normalizedHandle:handle] ?: @"",
    }];
    [[NSUserDefaults standardUserDefaults] setObject:events forKey:kEventsKey];
}

+ (void)removeEvent:(NSDictionary*)event {
    NSMutableArray* events = [[[NSUserDefaults standardUserDefaults] arrayForKey:kEventsKey] mutableCopy];
    [events removeObject:event];
    [[NSUserDefaults standardUserDefaults] setObject:events ?: @[] forKey:kEventsKey];
}

@end
