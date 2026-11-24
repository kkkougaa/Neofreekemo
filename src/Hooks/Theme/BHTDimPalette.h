#import <UIKit/UIKit.h>

BOOL BHTDimThemeEnabled(void);

// The colors picked under "kemo_custom_theme" (nil when unset or the theme is off).
// A custom background turns the Dim machinery on with that color in place of navy.
UIColor* _Nullable BHTCustomThemeBackgroundColor(void);
UIColor* _Nullable BHTCustomThemeTextColor(void);
UIColor* _Nullable BHTCustomThemeSecondaryTextColor(void);
UIColor* _Nullable BHTColorFromHexString(NSString* _Nullable hex);
NSString* _Nullable BHTHexStringFromColor(UIColor* color);

// YES when the color is one of the three current background shades (Dim or custom).
BOOL BHTColorIsDimShade(UIColor* _Nullable color);

// 4 dim shades
UIColor* BHTDimBackgroundColor(void);
UIColor* BHTDimElevatedBackgroundColor(void);
UIColor* BHTDimHighlightBackgroundColor(void);
UIColor* BHTDimSearchPillColor(void);

// Which Dim shade an opaque color is, if any
typedef NS_ENUM(NSInteger, BHTDimShadeKind) {
    BHTDimShadeNone,
    BHTDimShadeBackground,
    BHTDimShadeElevated,
    BHTDimShadeHighlight,
};

BHTDimShadeKind BHTDimShadeOfColor(UIColor* _Nullable color);

UIColor* _Nullable BHTDimReplacementForResolvedColor(UIColor* resolved);
BOOL BHTColorIsCloseToWhite(UIColor* _Nullable color);

// Keeps source's dynamic color identifier, so X can reload the color from the
// next palette on an appearance change
UIColor* BHTDimColorPreservingIdentifier(UIColor* dim, UIColor* _Nullable source);

@interface BHTDimPaletteProxy : NSProxy
+ (instancetype)proxyWithPalette:(id)palette;
@end
