#import <Foundation/Foundation.h>

// 0 means "no text". 6 is conflict and wins over 5. Sensitivity (0 relaxed
// … 100 sharp) only moves the thresholds between levels 1 and 4.
NSInteger NFBMoodScore(NSString *_Nullable text, NSInteger sensitivity);
