//
//  NFBClickerRemind.m
//  NeoFreeBird
//

#import "Core/NFBClickerRemind.h"
#import <UIKit/UIKit.h>

extern BOOL NFBClickerRemindShow(NSDictionary* reminder);

static NSString* const kRemindKey = @"kemo_clicker_remind";

static NSTimer* gTimer;
static NSDate* gChecked;
static NSMutableArray<NSDictionary*>* gWaiting;
static NSMutableString* gLog;

static void RemindLog(NSString* line) {
    if (!gLog) {
        gLog = [NSMutableString string];
    }
    NSString* when = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                    dateStyle:NSDateFormatterNoStyle
                                                    timeStyle:NSDateFormatterMediumStyle];
    [gLog appendFormat:@"  %@ %@\n", when, line];
    if (gLog.length > 1500) {
        [gLog deleteCharactersInRange:NSMakeRange(0, gLog.length - 1500)];
    }
}

static NSArray<NSNumber*>* Days(id v) {
    NSMutableOrderedSet* set = [NSMutableOrderedSet orderedSet];
    if ([v isKindOfClass:[NSArray class]]) {
        for (id d in v) {
            NSInteger n = [d respondsToSelector:@selector(integerValue)] ? [d integerValue] : -1;
            if (n >= 0 && n <= 6) {
                [set addObject:@(n)];
            }
        }
        return [set.array sortedArrayUsingSelector:@selector(compare:)];
    }
    return @[@0, @1, @2, @3, @4, @5, @6];
}

static NSString* HHMM(id v, NSString* fallback) {
    NSString* s = [v isKindOfClass:[NSString class]] ? v : @"";
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"^([01]\\d|2[0-3]):[0-5]\\d$" options:0 error:nil];
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] ? s : fallback;
}

@implementation NFBClickerRemind

// remind.js norm(): the same defaults and limits.
+ (NSMutableDictionary*)settings {
    NSDictionary* r = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kRemindKey] ?: @{};
    NSMutableArray* alarms = [NSMutableArray array];
    NSArray* list = [r[@"alarms"] isKindOfClass:[NSArray class]] ? r[@"alarms"] : @[];
    for (NSDictionary* a in list) {
        if (![a isKindOfClass:[NSDictionary class]] || alarms.count >= 20) {
            continue;
        }
        [alarms addObject:[@{
            @"id": [a[@"id"] isKindOfClass:[NSString class]] ? a[@"id"] : [NSString stringWithFormat:@"a%.0f", NSDate.date.timeIntervalSince1970 * 1000 + alarms.count],
            @"on": @(a[@"on"] == nil || [a[@"on"] boolValue]),
            @"days": Days(a[@"days"]),
            @"time": HHMM(a[@"time"], @"09:00"),
            @"memo": [a[@"memo"] isKindOfClass:[NSString class]] ? [a[@"memo"] substringToIndex:MIN([a[@"memo"] length], 40)] : @""
        } mutableCopy]];
    }
    NSDictionary* p = [r[@"pill"] isKindOfClass:[NSDictionary class]] ? r[@"pill"] : @{};
    NSMutableOrderedSet* times = [NSMutableOrderedSet orderedSet];
    for (id t in [p[@"times"] isKindOfClass:[NSArray class]] ? p[@"times"] : @[@"08:00"]) {
        NSString* h = HHMM(t, nil);
        if (h) {
            [times addObject:h];
        }
    }
    NSArray* sortedTimes = [times.array sortedArrayUsingSelector:@selector(compare:)];
    NSDictionary* w = [r[@"water"] isKindOfClass:[NSDictionary class]] ? r[@"water"] : @{};
    NSInteger every = [w[@"every"] respondsToSelector:@selector(integerValue)] ? [w[@"every"] integerValue] : 60;
    return [@{
        @"alarms": alarms,
        @"pill": [@{
            @"on": @([p[@"on"] boolValue]),
            @"days": Days(p[@"days"]),
            @"times": sortedTimes.count ? [sortedTimes subarrayWithRange:NSMakeRange(0, MIN(sortedTimes.count, (NSUInteger)8))] : @[@"08:00"],
            @"memo": [p[@"memo"] isKindOfClass:[NSString class]] ? p[@"memo"] : @""
        } mutableCopy],
        @"water": [@{
            @"on": @([w[@"on"] boolValue]),
            @"days": Days(w[@"days"]),
            @"every": @(MAX(10, MIN(12 * 60, every))),
            @"from": HHMM(w[@"from"], @"09:00"),
            @"to": HHMM(w[@"to"], @"22:00")
        } mutableCopy]
    } mutableCopy];
}

+ (void)save:(NSDictionary*)settings {
    [[NSUserDefaults standardUserDefaults] setObject:settings forKey:kRemindKey];
}

static NSTimeInterval At(NSDate* day, NSString* hhmm) {
    NSArray* parts = [hhmm componentsSeparatedByString:@":"];
    NSDate* d = [[NSCalendar currentCalendar] dateBySettingHour:[parts[0] integerValue]
                                                         minute:[parts[1] integerValue]
                                                         second:0
                                                         ofDate:day
                                                        options:0];
    return d.timeIntervalSince1970;
}

static NSString* Label(NSTimeInterval t) {
    NSDateComponents* c = [[NSCalendar currentCalendar] components:NSCalendarUnitHour | NSCalendarUnitMinute
                                                          fromDate:[NSDate dateWithTimeIntervalSince1970:t]];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)c.hour, (long)c.minute];
}

// remind.js due(): every reminder with from < time <= to, in time order.
+ (NSArray<NSDictionary*>*)dueIn:(NSDictionary*)r from:(NSTimeInterval)from to:(NSTimeInterval)to {
    NSMutableArray* out = [NSMutableArray array];
    NSCalendar* cal = [NSCalendar currentCalendar];
    NSDate* day = [cal startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:from]];
    void (^push)(NSString*, NSString*, NSTimeInterval, NSString*, NSDictionary*) =
        ^(NSString* kind, NSString* key, NSTimeInterval t, NSString* memo, NSDictionary* extra) {
            if (t > from && t <= to) {
                NSMutableDictionary* item = [@{@"kind": kind, @"key": key, @"at": @(t * 1000), @"time": Label(t), @"memo": memo ?: @""} mutableCopy];
                [item addEntriesFromDictionary:extra ?: @{}];
                [out addObject:item];
            }
        };
    for (int i = 0; i < 400 && day.timeIntervalSince1970 <= to; i++) {
        NSInteger wd = [cal component:NSCalendarUnitWeekday fromDate:day] - 1; // 0 = Sunday, as in JS
        for (NSDictionary* a in r[@"alarms"]) {
            if ([a[@"on"] boolValue] && [a[@"days"] containsObject:@(wd)]) {
                NSTimeInterval t = At(day, a[@"time"]);
                push(@"alarm", [NSString stringWithFormat:@"%@@%.0f", a[@"id"], t * 1000], t, a[@"memo"], @{@"id": a[@"id"]});
            }
        }
        NSDictionary* p = r[@"pill"];
        if ([p[@"on"] boolValue] && [p[@"days"] containsObject:@(wd)]) {
            for (NSString* hm in p[@"times"]) {
                NSTimeInterval t = At(day, hm);
                push(@"pill", [NSString stringWithFormat:@"pill@%.0f", t * 1000], t, p[@"memo"], @{@"slot": hm});
            }
        }
        NSDictionary* w = r[@"water"];
        if ([w[@"on"] boolValue] && [w[@"days"] containsObject:@(wd)]) {
            NSTimeInterval step = [w[@"every"] doubleValue] * 60;
            NSTimeInterval end = At(day, w[@"to"]);
            for (NSTimeInterval t = At(day, w[@"from"]) + step; t <= end; t += step) {
                push(@"water", [NSString stringWithFormat:@"water@%.0f", t * 1000], t, @"", nil);
            }
        }
        day = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary* x, NSDictionary* y) {
        return [x[@"at"] compare:y[@"at"]];
    }];
    return out;
}

+ (void)check {
    NSDate* now = [NSDate date];
    if (!gWaiting) {
        gWaiting = [NSMutableArray array];
    }
    if (gChecked) {
        // After a long sleep only the last half hour counts.
        NSTimeInterval from = MAX(gChecked.timeIntervalSince1970, now.timeIntervalSince1970 - 30 * 60);
        NSArray* due = [self dueIn:[self settings] from:from to:now.timeIntervalSince1970];
        for (NSDictionary* r in due) {
            RemindLog([NSString stringWithFormat:@"due %@ %@", r[@"kind"], r[@"time"]]);
            [gWaiting addObject:r];
        }
    }
    gChecked = now;
    // Show what is waiting, oldest first; drop what waited over half an hour.
    while (gWaiting.count) {
        NSDictionary* r = gWaiting.firstObject;
        if (now.timeIntervalSince1970 * 1000 - [r[@"at"] doubleValue] > 30 * 60 * 1000) {
            RemindLog([NSString stringWithFormat:@"dropped %@ %@ (not on screen)", r[@"kind"], r[@"time"]]);
            [gWaiting removeObjectAtIndex:0];
            continue;
        }
        if (!NFBClickerRemindShow(r)) {
            break; // the character is not on screen; try again next check
        }
        RemindLog([NSString stringWithFormat:@"shown %@ %@", r[@"kind"], r[@"time"]]);
        [gWaiting removeObjectAtIndex:0];
    }
}

+ (void)start {
    if (gTimer) {
        return;
    }
    gChecked = [NSDate date];
    gTimer = [NSTimer scheduledTimerWithTimeInterval:20
                                             repeats:YES
                                               block:^(NSTimer* timer) {
                                                   [NFBClickerRemind check];
                                               }];
    gTimer.tolerance = 5;
}

+ (void)test:(NSString*)kind {
    NSDate* now = [NSDate date];
    NSDictionary* r = @{
        @"kind": kind ?: @"alarm",
        @"key": [NSString stringWithFormat:@"test@%.0f", now.timeIntervalSince1970 * 1000],
        @"at": @(now.timeIntervalSince1970 * 1000),
        @"time": Label(now.timeIntervalSince1970),
        @"memo": @"",
        @"test": @YES
    };
    if (!gWaiting) {
        gWaiting = [NSMutableArray array];
    }
    [gWaiting addObject:r];
    RemindLog([@"test " stringByAppendingString:kind ?: @"alarm"]);
    [self check];
}

+ (NSString*)debugText {
    NSDictionary* r = [self settings];
    NSUInteger alarms = 0;
    for (NSDictionary* a in r[@"alarms"]) {
        alarms += [a[@"on"] boolValue] ? 1 : 0;
    }
    NSArray* next = [self dueIn:r from:NSDate.date.timeIntervalSince1970 to:NSDate.date.timeIntervalSince1970 + 2 * 86400];
    return [NSString stringWithFormat:@"remind: alarms=%lu pill=%d water=%d waiting=%lu next=%@\n%@", (unsigned long)alarms,
                                      [r[@"pill"][@"on"] boolValue], [r[@"water"][@"on"] boolValue],
                                      (unsigned long)gWaiting.count,
                                      next.count ? [NSString stringWithFormat:@"%@ %@", next[0][@"kind"], next[0][@"time"]] : @"-",
                                      gLog ?: @""];
}

@end
