//
//  NFBFirstResponder.h
//  NeoFreeBird
//

#import <UIKit/UIKit.h>

// The responder that is currently receiving keyboard input, wherever it lives in the
// view hierarchy (nil when nothing is focused).
UIResponder* NFBCurrentFirstResponder(void);
