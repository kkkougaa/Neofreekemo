//
//  NFBChirpFonts.h
//  NeoFreeBird
//
//  The user's own fonts in Chirp's place. A picked font is copied into the app
//  and, at the next launch, registered under Chirp's PostScript names before X
//  registers its own, so X draws with it through its usual font code. Nothing
//  is swapped while X makes fonts.
//

#import <Foundation/Foundation.h>

// Slots, by weight. Regular is needed; a missing slot uses the nearest one.
extern NSString* const NFBChirpSlotLight;
extern NSString* const NFBChirpSlotRegular;
extern NSString* const NFBChirpSlotMedium;
extern NSString* const NFBChirpSlotBold;
extern NSString* const NFBChirpSlotHeavy;

// The NSUserDefaults key that holds the picked font's name for a slot (shown
// as the row's subtitle).
NSString* NFBChirpSlotNameKey(NSString* slot);

// Copies the font at `url` into the slot and builds its Chirp-named copies.
// Returns NO with a message the user can read when the file is not a font
// this can use (a collection, WOFF, or a file CoreGraphics can't open).
BOOL NFBChirpImportFont(NSURL* url, NSString* slot, NSString** message);

// Removes every picked font. Takes effect at the next launch.
void NFBChirpResetFonts(void);

// For the dump.
NSString* NFBChirpFontsDebugText(void);
