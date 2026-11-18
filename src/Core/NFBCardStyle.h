//
//  NFBCardStyle.h
//  NeoFreeBird
//
//  The look of the timeline and notification cards, chosen on the "Cards and
//  text" settings page. Read by Hooks/Readability.x and by that page's preview,
//  so both draw a card the same way.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, NFBCardLook) {
    NFBCardLookOutlined = 0, // a hairline border (7.3.86)
    NFBCardLookFloating = 1, // no border, a soft shadow (outline in dark mode)
};

typedef struct {
    NFBCardLook look;
    CGFloat radius;      // corner radius
    CGFloat gap;         // page colour between two cards
    CGFloat inner;       // extra room between the card edge and the row's content
    CGFloat bodyStep;    // points added to tweet text
    CGFloat nameScale;   // the name line (name and @handle), 1 = X's size
    CGFloat avatarScale; // the avatar, 1 = X's size
    CGFloat nameGap;     // points the name line moves up, away from the tweet text
    NSInteger paper;     // NFBCardPaper*
} NFBCardStyle;

typedef NS_ENUM(NSInteger, NFBCardPaper) {
    NFBCardPaperDefault = 0, // X's own background
    NFBCardPaperGray = 1,
    NFBCardPaperWarm = 2,
    NFBCardPaperTint = 3,    // a hint of the accent colour
    NFBCardPaperCustom = 4,  // kemo_card_paper_rgb
};

extern NSString* const NFBCardLookKey;
extern NSString* const NFBCardRadiusKey;
extern NSString* const NFBCardGapKey;
extern NSString* const NFBCardInnerKey;
extern NSString* const NFBCardBodyKey;   // tenths of a point
extern NSString* const NFBCardNameKey;   // percent
extern NSString* const NFBCardAvatarKey; // percent
extern NSString* const NFBCardNameGapKey; // points
extern NSString* const NFBCardPaperKey;
extern NSString* const NFBCardPaperRGBKey;

// Every value, with the defaults filled in. Safe on any thread.
NFBCardStyle NFBCardStyleCurrent(void);
// Puts every value back to its default.
void NFBCardStyleReset(void);

// The card colour. `xPaper` is X's own background, used for the default.
UIColor* NFBCardPaperColor(NFBCardStyle style, UIColor* xPaper, UIColor* accent);
// The page between cards, derived from the card colour.
UIColor* NFBCardPageColor(UIColor* paper);
// `from` mixed toward `to` (0 = from, 1 = to).
UIColor* NFBCardBlend(UIColor* from, UIColor* to, CGFloat amount);
// One card: its colour, corners, and a hairline outline or a soft shadow by
// look. An open edge has square corners and no outline or shadow along it, so
// two open edges meeting read as one card (a thread drawn as one card).
@interface NFBCardView : UIView
@property (nonatomic, assign) NFBCardStyle style;
@property (nonatomic, assign) BOOL openTop;
@property (nonatomic, assign) BOOL openBottom;
@property (nonatomic, assign) CGFloat radiusOverride; // > 0: use instead of style.radius
@property (nonatomic, assign) BOOL plain;             // no outline or shadow at all
@end
