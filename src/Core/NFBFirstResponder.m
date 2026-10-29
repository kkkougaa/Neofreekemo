//
//  NFBFirstResponder.m
//  NeoFreeBird
//

#import "Core/NFBFirstResponder.h"

static __weak UIResponder* gFoundResponder;

@interface UIResponder (NFBFirstResponder)
- (void)nfb_captureFirstResponder:(id)sender;
@end

@implementation UIResponder (NFBFirstResponder)

// Sent with a nil target, so only the first responder receives it.
- (void)nfb_captureFirstResponder:(id)sender {
    gFoundResponder = self;
}

@end

UIResponder* NFBCurrentFirstResponder(void) {
    gFoundResponder = nil;
    [[UIApplication sharedApplication] sendAction:@selector(nfb_captureFirstResponder:)
                                               to:nil
                                             from:nil
                                         forEvent:nil];
    return gFoundResponder;
}
