//
//  Fonts.x
//  NeoFreeBird
//

#import <CoreText/CoreText.h>
#import <os/lock.h>
#import "Fonts.h"

// MARK: - Change font

%hook UIFontPickerViewController
- (void)viewWillAppear:(BOOL)arg1 {
    %orig(arg1);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:[[BHTBundle sharedBundle]
                          localizedStringForKey:@"CUSTOM_FONTS_NAVIGATION_BUTTON_TITLE"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(customFontsHandler)];
}
%new
- (void)customFontsHandler {
    if ([[NSFileManager defaultManager]
            fileExistsAtPath:@"/var/mobile/Library/Fonts/AddedFontCache.plist"]) {
        NSAttributedString* AttString = [[NSAttributedString alloc]
            initWithString:[[BHTBundle sharedBundle] localizedStringForKey:@"CUSTOM_FONTS_MENU_TITLE"]
                attributes:@{
                    NSFontAttributeName: [BHTManager menuTitleFont],
                    NSForegroundColorAttributeName: UIColor.labelColor
                }];
        TFNActiveTextItem* title =
            [[%c(TFNActiveTextItem) alloc] initWithTextModel:[[%c(TFNAttributedTextModel) alloc]
                                                                     initWithAttributedString:AttString]
                                                    activeRanges:nil];

        NSMutableArray* actions = [[NSMutableArray alloc] init];
        [actions addObject:title];

        NSDictionary* plistDictionary = [NSPropertyListSerialization
            propertyListWithData:
                [NSData dataWithContentsOfURL:
                            [NSURL fileURLWithPath:@"/var/mobile/Library/Fonts/AddedFontCache.plist"]]
                         options:NSPropertyListImmutable
                          format:NULL
                           error:nil];
        [plistDictionary enumerateKeysAndObjectsUsingBlock:^(id _Nonnull key, id _Nonnull obj,
                                                             BOOL* _Nonnull stop) {
            @try {
                NSString* fontName = ((NSArray*)[obj valueForKey:@"psNames"]).firstObject;
                TFNActionItem* fontAction = [%c(TFNActionItem)
                    actionItemWithTitle:fontName
                                 action:^{
                                     if (self.configuration.includeFaces) {
                                         [self setSelectedFontDescriptor:[UIFontDescriptor
                                                                             fontDescriptorWithFontAttributes:@{
                                                                                 UIFontDescriptorNameAttribute:
                                                                                     fontName
                                                                             }]];
                                     } else {
                                         [self setSelectedFontDescriptor:[UIFontDescriptor
                                                                             fontDescriptorWithFontAttributes:@{
                                                                                 UIFontDescriptorFamilyAttribute:
                                                                                     fontName
                                                                             }]];
                                     }
                                     [self.delegate fontPickerViewControllerDidPickFont:self];
                                 }];
                [actions addObject:fontAction];
            } @catch (NSException* exception) {
                NSLog(@"Unable to find installed fonts /n reason: %@", exception.reason);
            }
        }];

        TFNMenuSheetViewController* alert = [[%c(TFNMenuSheetViewController) alloc]
            initWithActionItems:[NSArray arrayWithArray:actions]];
        [alert tfnPresentedCustomPresentFromViewController:self animated:YES completion:nil];
    } else {
        UIAlertController* errAlert = [UIAlertController
            alertControllerWithTitle:@"BHTwitter"
                             message:[[BHTBundle sharedBundle]
                                         localizedStringForKey:@"CUSTOM_FONTS_TUT_ALERT_MESSAGE"]
                      preferredStyle:UIAlertControllerStyleAlert];

        [errAlert
            addAction:
                [UIAlertAction
                    actionWithTitle:[[BHTBundle sharedBundle]
                                        localizedStringForKey:@"INSTALL_IFONT_BUTTON_TITLE"]
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction* _Nonnull action) {
                                [[UIApplication sharedApplication]
                                              openURL:[NSURL
                                                          URLWithString:
                                                              @"https://apps.apple.com/sa/app/"
                                                              @"ifont-find-install-any-font/id1173222289"]
                                              options:@{}
                                    completionHandler:nil];
                            }]];
        [errAlert addAction:[UIAlertAction
                                actionWithTitle:[[BHTBundle sharedBundle]
                                                    localizedTwitterStringForKey:@"OK_ACTION_LABEL"]
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
        [self presentViewController:errAlert animated:true completion:nil];
    }
}
%end

// The picked font names, read once per settings change. These getters run for nearly
// every font X makes (often off the main thread while it lays rows out), so they must
// not hit NSUserDefaults or allocate each time.
//
// A picked name that no longer makes a font (a profile font that was removed, or a
// family name UIFont can't open) is dropped here, so the hooks below fall straight
// back to X's own fonts instead of trying again on every call.
static os_unfair_lock gFontNameLock = OS_UNFAIR_LOCK_INIT;
static BOOL gFontNamesLoaded = NO;
static NSString* gRegularFontName = nil;
static NSString* gBoldFontName = nil;

static NSString* UsableFontName(id name) {
    if (![name isKindOfClass:[NSString class]] || [name length] == 0) {
        return nil;
    }
    if ([UIFont fontWithName:name size:12]) {
        return name;
    }
    // The regular picker stores a family name; open its regular face instead.
    NSArray<NSString*>* faces = [UIFont fontNamesForFamilyName:name];
    NSString* best = nil;
    for (NSString* face in faces) {
        if ([face hasSuffix:@"-Regular"] || [face isEqualToString:name]) {
            best = face;
            break;
        }
    }
    best = best ?: faces.firstObject;
    return best && [UIFont fontWithName:best size:12] ? best : nil;
}

static void LoadFontNamesLocked(void) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    // The picker that swapped fonts here as X made them is gone from the settings
    // (it raced X's font cache and crashed the timeline). Fonts are now put in
    // Chirp's place at launch (ChirpFiles.x), so this path stays off even for
    // someone who had it on.
    BOOL enabled = NO;
    gRegularFontName = enabled ? UsableFontName([defaults objectForKey:@"bhtwitter_font_1"]) : nil;
    gBoldFontName = enabled ? UsableFontName([defaults objectForKey:@"bhtwitter_font_2"]) : nil;
    gFontNamesLoaded = YES;
}

// The picked font name for a weight, or nil when the user runs Twitter's own.
NSString* CustomFontName(BOOL isBold) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSUserDefaultsDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification* note) {
                        os_unfair_lock_lock(&gFontNameLock);
                        gFontNamesLoaded = NO;
                        os_unfair_lock_unlock(&gFontNameLock);
                    }];
    });
    os_unfair_lock_lock(&gFontNameLock);
    if (!gFontNamesLoaded) {
        LoadFontNamesLocked();
    }
    NSString* name = isBold ? gBoldFontName : gRegularFontName;
    os_unfair_lock_unlock(&gFontNameLock);
    return name;
}

static BOOL CustomFontsEnabled(void) {
    return CustomFontName(NO) != nil || CustomFontName(YES) != nil;
}

// Twitter keeps the fonts from +tfn_fontWithName:size: in its own cache and then
// stores the CTFont (toll-free with UIFont) into attributed strings without an
// extra retain. A font we hand back from +fontWithName: or -tfn_withMonospacedDigits
// is not in that cache. Quoted-tweet cells add a second attribute after the
// autorelease pool has drained, and hashing the dead font crashes. This map is
// intentionally not an NSCache: eviction would bring the crash back.
static NSMutableDictionary<NSString*, UIFont*>* BHTFontCache(void) {
    static NSMutableDictionary* cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

// Every font in the cache above, by identity, for a constant-time "is this ours" check.
// Guarded by the cache's lock.
static NSHashTable* BHTRememberedFonts(void) {
    static NSHashTable* table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [[NSHashTable alloc]
            initWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                   capacity:64];
    });
    return table;
}

static UIFont* BHTRememberFont(NSString* key, UIFont* font) {
    if (key.length == 0 || ![font isKindOfClass:[UIFont class]]) {
        return [font isKindOfClass:[UIFont class]] ? font : nil;
    }
    NSMutableDictionary* cache = BHTFontCache();
    @synchronized(cache) {
        UIFont* existing = cache[key];
        if (existing) {
            return existing;
        }
        cache[key] = font;
        [BHTRememberedFonts() addObject:font];
        return font;
    }
}

static BOOL BHTFontIsRemembered(UIFont* font) {
    if (![font isKindOfClass:[UIFont class]]) {
        return NO;
    }
    NSMutableDictionary* cache = BHTFontCache();
    @synchronized(cache) {
        return [BHTRememberedFonts() containsObject:font];
    }
}

// kNumberSpacingType / kMonospacedNumbersSelector. Built here so the result is a
// real UIFont we retain, instead of -tfn_withMonospacedDigits' temporary font.
static UIFont* BHTMonospacedDigits(UIFont* font) {
    if (![font isKindOfClass:[UIFont class]] || font.pointSize <= 0) {
        return font;
    }
    NSString* key = [NSString stringWithFormat:@"mono|%@|%.2f", font.fontName ?: @"", font.pointSize];
    NSMutableDictionary* cache = BHTFontCache();
    @synchronized(cache) {
        UIFont* existing = cache[key];
        if (existing) {
            return existing;
        }
    }
    UIFontDescriptor* descriptor = [font.fontDescriptor fontDescriptorByAddingAttributes:@{
        UIFontDescriptorFeatureSettingsAttribute : @[
            @{
                UIFontFeatureTypeIdentifierKey : @(kNumberSpacingType),
                UIFontFeatureSelectorIdentifierKey : @(kMonospacedNumbersSelector)
            }
        ]
    }];
    UIFont* made = [UIFont fontWithDescriptor:descriptor size:font.pointSize];
    if (![made isKindOfClass:[UIFont class]]) {
        made = font;
    }
    return BHTRememberFont(key, made);
}

BOOL BHTFontIsBold(UIFont* font) {
    if (!font) {
        return NO;
    }
    NSString* name = font.fontName;
    NSString* selectedBold = CustomFontName(YES);
    if (selectedBold && [name isEqualToString:selectedBold]) {
        return YES;
    }
    NSString* selectedRegular = CustomFontName(NO);
    if (selectedRegular && [name isEqualToString:selectedRegular]) {
        return NO;
    }
    if ([name containsString:@"Bold"] || [name containsString:@"Heavy"] ||
        [name containsString:@"Black"] || [name containsString:@"Semibold"] ||
        [name containsString:@"SemiBold"] || [name containsString:@"Demi"]) {
        return YES;
    }
    if (font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) {
        return YES;
    }
    NSDictionary* traits = font.fontDescriptor.fontAttributes[UIFontDescriptorTraitsAttribute];
    NSNumber* weight = traits[UIFontWeightTrait];
    return weight && weight.doubleValue >= UIFontWeightSemibold;
}

static BOOL BHTNameMatchesCustomFont(NSString* name) {
    if (name.length == 0) {
        return NO;
    }
    NSString* regular = CustomFontName(NO);
    NSString* bold = CustomFontName(YES);
    return (regular && [name isEqualToString:regular]) || (bold && [name isEqualToString:bold]);
}

UIFont* BHTReplaceFont(UIFont* originalFont, BOOL isBold) {
    NSString* customName = CustomFontName(isBold);
    if (!customName || ![originalFont isKindOfClass:[UIFont class]] || originalFont.pointSize <= 0) {
        return originalFont;
    }
    if ([originalFont.fontName isEqualToString:customName] ||
        [originalFont.familyName isEqualToString:customName]) {
        return BHTRememberFont(
            [NSString stringWithFormat:@"face|%@|%.2f", originalFont.fontName, originalFont.pointSize],
            originalFont);
    }
    NSString* key = [NSString stringWithFormat:@"%@|%.2f", customName, originalFont.pointSize];
    NSMutableDictionary* cache = BHTFontCache();
    @synchronized(cache) {
        UIFont* existing = cache[key];
        if (existing) {
            return existing;
        }
    }
    UIFont* created = [UIFont fontWithName:customName size:originalFont.pointSize];
    if (![created isKindOfClass:[UIFont class]]) {
        return originalFont;
    }
    return BHTRememberFont(key, created);
}

%hook UIFont

+ (UIFont*)tfn_fontWithName:(NSString*)name size:(CGFloat)size {
    UIFont* originalFont = %orig;
    BOOL isBold = [name containsString:@"Bold"] || [name containsString:@"Heavy"] ||
                  [name containsString:@"Black"] || [name containsString:@"Semibold"];
    UIFont* replaced = BHTReplaceFont(originalFont, isBold);
    return [replaced isKindOfClass:[UIFont class]] ? replaced : originalFont;
}

- (UIFont*)tfn_withMonospacedDigits {
    if (!CustomFontsEnabled()) {
        return %orig;
    }
    // Only the faces we substituted. System fonts keep Twitter's own implementation.
    BOOL custom = BHTNameMatchesCustomFont(self.fontName) || BHTNameMatchesCustomFont(self.familyName) ||
                  BHTFontIsRemembered(self);
    if (!custom) {
        return %orig;
    }
    UIFont* made = BHTMonospacedDigits(self);
    return [made isKindOfClass:[UIFont class]] ? made : self;
}

%end

// XDSFoundation.Fonts wraps the result of +fontForToken: as a SwiftUI.Font.
// This catalog hook therefore covers its SwiftUI token getters as well.
%hook XFontCatalog

+ (UIFont*)fontForToken:(NSInteger)token {
    UIFont* originalFont = %orig;
    return BHTReplaceFont(originalFont, BHTFontIsBold(originalFont));
}

+ (UIFont*)customFontOfSize:(CGFloat)size weight:(NSInteger)weight
      scalesWithDynamicType:(BOOL)scales {
    UIFont* originalFont = %orig;
    return BHTReplaceFont(originalFont, weight >= 2);
}

+ (UIFont*)contentFontWithOffset:(CGFloat)offset weight:(NSInteger)weight {
    UIFont* originalFont = %orig;
    return BHTReplaceFont(originalFont, weight >= 2);
}

+ (UIFont*)tabularDigitsFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    UIFont* originalFont = %orig;
    UIFont* customFont = BHTReplaceFont(originalFont, weight >= UIFontWeightSemibold);
    if (customFont == originalFont || ![customFont isKindOfClass:[UIFont class]]) {
        return originalFont;
    }
    return BHTMonospacedDigits(customFont);
}

%end

%hook XDSButtonContentElement

+ (id)labelWithText:(id)text font:(id)font color:(id)color {
    if (![font isKindOfClass:[UIFont class]]) {
        return %orig;
    }
    UIFont* customFont = BHTReplaceFont((UIFont*)font, BHTFontIsBold((UIFont*)font));
    return %orig(text, customFont, color);
}

%end

UIBarButtonItemAppearance* BHTBarButtonAppearanceWithFont(
    UIBarButtonItemAppearance* originalAppearance, NSString* fontName) {
    if (!originalAppearance || !fontName) {
        return originalAppearance;
    }

    UIBarButtonItemAppearance* appearance = [originalAppearance copy];
    for (UIBarButtonItemStateAppearance* state in
         @[appearance.normal, appearance.highlighted, appearance.disabled, appearance.focused]) {
        NSMutableDictionary* attributes =
            [state.titleTextAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
        UIFont* existingFont = attributes[NSFontAttributeName];
        CGFloat size = existingFont ? existingFont.pointSize : 17.0;
        UIFont* customFont = [UIFont fontWithName:fontName size:size];
        if (customFont) {
            customFont = BHTRememberFont([NSString stringWithFormat:@"%@|%.2f", fontName, size], customFont);
            attributes[NSFontAttributeName] = customFont;
            state.titleTextAttributes = attributes;
        }
    }
    return appearance;
}

UINavigationBarAppearance* BHTNavigationAppearanceWithFonts(
    UINavigationBarAppearance* originalAppearance) {
    if (!originalAppearance) {
        return nil;
    }

    NSString* boldName = CustomFontName(YES);
    NSString* regularName = CustomFontName(NO);
    if (!boldName && !regularName) {
        return originalAppearance;
    }

    UINavigationBarAppearance* appearance = [originalAppearance copy];
    if (boldName) {
        NSMutableDictionary* attributes =
            [appearance.titleTextAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
        UIFont* existingFont = attributes[NSFontAttributeName];
        CGFloat size = existingFont ? existingFont.pointSize : 17.0;
        UIFont* customFont = [UIFont fontWithName:boldName size:size];
        if (customFont) {
            customFont = BHTRememberFont([NSString stringWithFormat:@"%@|%.2f", boldName, size], customFont);
            attributes[NSFontAttributeName] = customFont;
            appearance.titleTextAttributes = attributes;
        }
        appearance.doneButtonAppearance =
            BHTBarButtonAppearanceWithFont(appearance.doneButtonAppearance, boldName);
    }
    if (regularName) {
        appearance.buttonAppearance =
            BHTBarButtonAppearanceWithFont(appearance.buttonAppearance, regularName);
        appearance.backButtonAppearance =
            BHTBarButtonAppearanceWithFont(appearance.backButtonAppearance, regularName);
    }
    return appearance;
}

%hook XNAVNavigationController

- (void)viewDidLoad {
    %orig;

    UINavigationBar* navigationBar = self.navigationBar;
    navigationBar.standardAppearance =
        BHTNavigationAppearanceWithFonts(navigationBar.standardAppearance);
    if (navigationBar.scrollEdgeAppearance) {
        navigationBar.scrollEdgeAppearance =
            BHTNavigationAppearanceWithFonts(navigationBar.scrollEdgeAppearance);
    }
    if (navigationBar.compactAppearance) {
        navigationBar.compactAppearance =
            BHTNavigationAppearanceWithFonts(navigationBar.compactAppearance);
    }
    if (@available(iOS 15.0, *)) {
        if (navigationBar.compactScrollEdgeAppearance) {
            navigationBar.compactScrollEdgeAppearance =
                BHTNavigationAppearanceWithFonts(navigationBar.compactScrollEdgeAppearance);
        }
    }
}

%end

// MARK: - Chirp in every language
// X only draws tweets and names with its bundled Chirp when
// +[UIFont tfn_isChirpFontEnabled] says yes (UIFont (TFNUIFontGroup) in
// XServiceLibraries, X 12.44); otherwise they use the system font, which is
// what happens with a Korean or Japanese device. The Chirp files inside this
// IPA are swapped for fonts that cover those languages (Pretendard JP, or the
// user's own from the font swap page), so Chirp is turned on everywhere.
static BOOL gChirpEnabledHooked = NO;
static BOOL gChirpEnabledOriginal = NO;

NSString* NFBChirpFontDebugText(void) {
    return [NSString stringWithFormat:@"chirpEnabled hook=%d original=%d", gChirpEnabledHooked,
                                      gChirpEnabledOriginal];
}

%group ChirpEverywhere
%hook UIFont
+ (BOOL)tfn_isChirpFontEnabled {
    gChirpEnabledOriginal = %orig;
    return YES;
}
%end
%end

%ctor {
    %init;
    if (class_getClassMethod([UIFont class], NSSelectorFromString(@"tfn_isChirpFontEnabled"))) {
        %init(ChirpEverywhere);
        gChirpEnabledHooked = YES;
    }
}
