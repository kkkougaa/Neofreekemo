//
//  InterfaceDirection.x
//  NeoFreeBird
//

#import <CoreText/CoreText.h>
#import "../HookHelpers.h"

// MARK: - Disable RTL

// CoreText picks direction from the first strong directional character; forcing
// LTR on the render input's paragraph style is the only reliable override.

// CTParagraphStyle is immutable with no mutable counterpart, so forcing the
// writing direction means rebuilding the style with its specifiers copied over.
static CTParagraphStyleRef CreateLTRParagraphStyle(CTParagraphStyleRef original) {
    static const struct {
        CTParagraphStyleSpecifier specifier;
        size_t valueSize;
    } copiedSpecifiers[] = {
        {kCTParagraphStyleSpecifierAlignment, sizeof(CTTextAlignment)},
        {kCTParagraphStyleSpecifierFirstLineHeadIndent, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierHeadIndent, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierTailIndent, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierTabStops, sizeof(CFArrayRef)},
        {kCTParagraphStyleSpecifierDefaultTabInterval, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierLineBreakMode, sizeof(CTLineBreakMode)},
        {kCTParagraphStyleSpecifierLineHeightMultiple, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierMaximumLineHeight, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierMinimumLineHeight, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierLineSpacingAdjustment, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierMaximumLineSpacing, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierMinimumLineSpacing, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierParagraphSpacing, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(CGFloat)},
        {kCTParagraphStyleSpecifierLineBoundsOptions, sizeof(CTLineBoundsOptions)},
    };
    enum { copiedCount = sizeof(copiedSpecifiers) / sizeof(copiedSpecifiers[0]) };

    uint8_t values[copiedCount][sizeof(CFArrayRef)];
    CTParagraphStyleSetting settings[copiedCount + 1];
    size_t count = 0;

    for (size_t i = 0; i < copiedCount; i++) {
        if (CTParagraphStyleGetValueForSpecifier(original, copiedSpecifiers[i].specifier,
                                                 copiedSpecifiers[i].valueSize, values[count])) {
            settings[count] = (CTParagraphStyleSetting){copiedSpecifiers[i].specifier,
                                                        copiedSpecifiers[i].valueSize, values[count]};
            count++;
        }
    }

    CTWritingDirection direction = kCTWritingDirectionLeftToRight;
    settings[count++] = (CTParagraphStyleSetting){kCTParagraphStyleSpecifierBaseWritingDirection,
                                                  sizeof(direction), &direction};

    return CTParagraphStyleCreate(settings, count);
}

%hook TFNAttributedTextModel

- (void)setAttributedString:(NSAttributedString*)attributedString {
    if (![BHTSettings boolForKey:@"disable_rtl"] || attributedString.length == 0) {
        return %orig;
    }

    NSMutableAttributedString* text = [attributedString mutableCopy];
    [attributedString
        enumerateAttribute:NSParagraphStyleAttributeName
                   inRange:NSMakeRange(0, attributedString.length)
                   options:0
                usingBlock:^(id value, NSRange range, BOOL* stop) {
                    // Some models carry a raw CTParagraphStyleRef under the same key.
                    if (value != nil && ![value isKindOfClass:[NSParagraphStyle class]]) {
                        if (CFGetTypeID((__bridge CFTypeRef)value) == CTParagraphStyleGetTypeID()) {
                            CTParagraphStyleRef ltrStyle =
                                CreateLTRParagraphStyle((__bridge CTParagraphStyleRef)value);
                            [text addAttribute:NSParagraphStyleAttributeName
                                         value:(__bridge_transfer id)ltrStyle
                                         range:range];
                        }
                        return;
                    }

                    NSMutableParagraphStyle* style =
                        value ? [value mutableCopy] : [NSMutableParagraphStyle new];
                    style.baseWritingDirection = NSWritingDirectionLeftToRight;
                    [text addAttribute:NSParagraphStyleAttributeName value:style range:range];
                }];

    %orig(text);
}

%end

%hook NSString

- (BOOL)tfs_plainTextShouldBeRenderedFromRight {
    return [BHTSettings boolForKey:@"disable_rtl"] ? NO : %orig;
}

- (BOOL)tfs_statusTextShouldBeRenderedFromRight {
    return [BHTSettings boolForKey:@"disable_rtl"] ? NO : %orig;
}

- (BOOL)tfs_labelTextShouldBeRenderedFromRight {
    return [BHTSettings boolForKey:@"disable_rtl"] ? NO : %orig;
}

%end

%hook TFNTwitterStatus

- (BOOL)shouldBeRenderedFromRight {
    return [BHTSettings boolForKey:@"disable_rtl"] ? NO : %orig;
}

%end

%hook TFNTwitterDisplayTextModel

- (BOOL)_tfn_shouldBeRenderedFromRight {
    return [BHTSettings boolForKey:@"disable_rtl"] ? NO : %orig;
}

%end

