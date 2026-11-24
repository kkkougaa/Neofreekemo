//
//  NFBClickerRemind.h
//  NeoFreeBird
//

#import <Foundation/Foundation.h>

// Time reminders for the clicker character, as in the desktop app (remind.js): alarms on
// chosen weekdays, medicine times and drinking water every so often between two times. When
// one is due the character shows it (pet.js showRemind) with the character's own lines for
// it (sp_alarm_before / sp_pill_before / sp_water_before, then *_after when tapped).
//
// Stored in kemo_clicker_remind in the desktop's shape:
//   alarms: [{id, on, days: [0-6, 0 = Sunday], time: "HH:MM", memo}]
//   pill:   {on, days, times: ["HH:MM"], memo}
//   water:  {on, days, every (minutes), from: "HH:MM", to: "HH:MM"}
@interface NFBClickerRemind : NSObject

+ (NSMutableDictionary*)settings;
+ (void)save:(NSDictionary*)settings;
// Checks twice a minute while the app is open; reminders that came due while the character
// was not on screen wait (up to 30 minutes) and show when it is.
+ (void)start;
// Shows one now (the settings page's test button).
+ (void)test:(NSString*)kind;
+ (NSString*)debugText;

@end
