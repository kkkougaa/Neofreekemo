#import "Core/NFBKemoHaptics.h"
#import "Core/BHTSettings.h"
#import <CoreHaptics/CoreHaptics.h>
#import <UIKit/UIKit.h>

static CHHapticEngine* NFBHapticEngine(void) {
    static CHHapticEngine* engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics) {
            return;
        }
        NSError* error = nil;
        engine = [[CHHapticEngine alloc] initAndReturnError:&error];
        if (!engine) {
            return;
        }
        engine.playsHapticsOnly = YES;
        engine.resetHandler = ^{
            [engine startAndReturnError:nil];
        };
        [engine startAndReturnError:nil];
    });
    return engine;
}

static BOOL NFBPlayCoreBurst(void) {
    CHHapticEngine* engine = NFBHapticEngine();
    if (!engine) {
        return NO;
    }
    CHHapticEventParameter* sharp = [[CHHapticEventParameter alloc]
        initWithParameterID:CHHapticEventParameterIDHapticSharpness
                      value:0.7];
    CHHapticEventParameter* hit = [[CHHapticEventParameter alloc]
        initWithParameterID:CHHapticEventParameterIDHapticIntensity
                      value:0.8];
    CHHapticEvent* tap = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                       parameters:@[ hit, sharp ]
                                                     relativeTime:0];

    CHHapticEventParameter* body = [[CHHapticEventParameter alloc]
        initWithParameterID:CHHapticEventParameterIDHapticIntensity
                      value:0.4];
    CHHapticEventParameter* soft = [[CHHapticEventParameter alloc]
        initWithParameterID:CHHapticEventParameterIDHapticSharpness
                      value:0.25];
    CHHapticEvent* decay = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                         parameters:@[ body, soft ]
                                                       relativeTime:0
                                                           duration:0.2];
    CHHapticParameterCurve* curve = [[CHHapticParameterCurve alloc]
        initWithParameterID:CHHapticEventParameterIDHapticIntensity
              controlPoints:@[
                  [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:0 value:0.4],
                  [[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:0.2 value:0]
              ]];
    NSError* error = nil;
    CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:@[ tap, decay ]
                                                      parameterCurves:@[ curve ]
                                                                error:&error];
    if (!pattern) {
        return NO;
    }
    id<CHHapticPatternPlayer> player = [engine createPlayerWithPattern:pattern error:&error];
    if (!player) {
        return NO;
    }
    [engine startAndReturnError:nil];
    return [player startAtTime:0 error:nil];
}

static void NFBPlayImpactFallback(void) {
    UIImpactFeedbackGenerator* impact =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [impact impactOccurred];
}

void NFBKemoPlayBurstHaptic(void) {
    if (![BHTSettings boolForKey:@"kemo_effect_haptics"]) {
        return;
    }
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NFBKemoPlayBurstHaptic();
        });
        return;
    }
    if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics || !NFBPlayCoreBurst()) {
        NFBPlayImpactFallback();
    }
}
