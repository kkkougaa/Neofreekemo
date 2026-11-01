#import <Foundation/Foundation.h>

// Sharp tap, then a short decay, for Kemo particle bursts. No-ops when the
// toggle is off, in Low Power Mode, or when the device cannot play haptics.
void NFBKemoPlayBurstHaptic(void);
