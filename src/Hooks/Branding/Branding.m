#import "Branding.h"

// Three layers, driven by locale files in the tweak bundle:
//   1. RenameOverrides.strings — Twitter localization key -> exact replacement,
//      a missing key falls through to the generic replacement
//   2. RenamePhrases.strings — exact source text -> complete translated phrase.
//   3. RenameWords.strings — generic word replacements ("X" -> "Twitter",
//      "Post" -> "Tweet", etc.) applied to localized and server-side strings

// Foundation may localize an error while loading a table. Do not recursively
// enter the dispatch_once initializers on the same thread.

static NSDictionary<NSString*, NSString*>* RenameTable(NSString* name) {
    BOOL wasHandlingLocalization = handlingTerminologyLocalization;
    handlingTerminologyLocalization = YES;
    @try {
        NSBundle* bundle = [BHTBundle sharedBundle].mainBundle;
        NSString* appLanguage =
            [[NSBundle mainBundle] preferredLocalizations].firstObject ?: @"en";
        NSString* localization =
            [NSBundle preferredLocalizationsFromArray:bundle.localizations
                                       forPreferences:@[appLanguage]]
                .firstObject;

        // preferredLocalizationsFromArray: falls back to en when nothing matches, so
        // reject a mismatch: unsupported languages skip renaming, not get English
        // rules.
        NSString* appCode =
            [[appLanguage stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
                componentsSeparatedByString:@"-"]
                .firstObject;
        NSString* lprojCode =
            [[localization stringByReplacingOccurrencesOfString:@"_" withString:@"-"]
                componentsSeparatedByString:@"-"]
                .firstObject;
        if (![appCode isEqualToString:lprojCode]) {
            return @{};
        }

        // Read the selected directory directly: NSBundle resource lookup can fall
        // back to another language when this particular table is missing.
        NSString* directory = [bundle.bundlePath stringByAppendingPathComponent:
                                                     [localization stringByAppendingPathExtension:@"lproj"]];
        NSString* path = [directory stringByAppendingPathComponent:
                                        [name stringByAppendingPathExtension:@"strings"]];
        return BHTLoadTerminologyTable(path);
    } @finally {
        handlingTerminologyLocalization = wasHandlingLocalization;
    }
}

static NSArray<NSDictionary*>* RenameEdits(NSString* input) {
    static BHTTerminology* terminology = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* language = [NSBundle mainBundle].preferredLocalizations.firstObject ?: @"en";
        terminology = [[BHTTerminology alloc] initWithWords:RenameTable(@"RenameWords")
                                                    phrases:RenameTable(@"RenamePhrases")
                                                     locale:[NSLocale localeWithLocaleIdentifier:language]];
    });
    return [terminology editsForString:input];
}

NSDictionary<NSString*, NSString*>* RenameKeyOverrides(void) {
    static NSDictionary* overrides = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrides = RenameTable(@"RenameOverrides");
    });
    return overrides;
}

// The facepile pill variant hardcodes blank text (no feature flag gates it).
// The tweak ships the label in the app's terminology and routes it through the
// rename pipeline, so "restore_twitter_names" converts it per-language.
NSString* PillLabelText(void) {
    NSString* label =
        [[BHTBundle sharedBundle] localizedStringForKey:@"REFRESH_PILL_TEXT"];
    if ([BHTSettings boolForKey:@"restore_twitter_names"]) {
        label = RestoreTwitterTerminology(label);
    }
    return label;
}

NSString* RestoreTwitterTerminology(NSString* input) {
    NSArray<NSDictionary*>* edits = RenameEdits(input);
    if (!edits) {
        // Plural formats from .stringsdict may have identical text but carry
        // different localization metadata. Preserve the original string object.
        return input;
    }

    NSMutableString* result = [input mutableCopy];
    for (NSDictionary* edit in edits.reverseObjectEnumerator) {
        [result replaceCharactersInRange:[edit[@"range"] rangeValue]
                              withString:edit[@"repl"]];
    }
    return [result copy];
}

NSAttributedString* RestoreTwitterAttributed(NSAttributedString* input) {
    NSArray<NSDictionary*>* edits = RenameEdits(input.string);
    if (!edits) {
        return input;
    }

    NSMutableAttributedString* result = [input mutableCopy];
    for (NSDictionary* edit in edits.reverseObjectEnumerator) {
        NSRange range = [edit[@"range"] rangeValue];
        NSDictionary* attrs = [result attributesAtIndex:range.location
                                         effectiveRange:NULL];
        NSAttributedString* piece =
            [[NSAttributedString alloc] initWithString:edit[@"repl"]
                                            attributes:attrs];
        [result replaceCharactersInRange:range withAttributedString:piece];
    }
    return result;
}

// Debug aid for the shake dump: which localization keys come back as "...시간 전" (hours
// ago), with the table and bundle they came from. Only collected while the dump is on.
static NSMutableArray<NSString*>* gTimeStringProbe;

NSString* NFBStringProbeText(void) {
    return [gTimeStringProbe componentsJoinedByString:[NSString stringWithFormat:@"%c", 10]] ?: @"(nothing collected yet)";
}

void ProbeTimeString(NSBundle* bundle, NSString* key, NSString* table, NSString* result) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"kemo_shake_dump"]) {
        return;
    }
    // Poll duration and "time ago" keys, whatever they return; plus any short "... 전" or
    // vote ("표") string.
    NSString* lower = key.lowercaseString;
    BOOL keyHit = ([lower containsString:@"poll"] &&
                   ([lower containsString:@"day"] || [lower containsString:@"hour"] ||
                    [lower containsString:@"minute"] || [lower containsString:@"duration"])) ||
                  [lower containsString:@"_ago"] || [lower containsString:@"relative"] ||
                  [lower containsString:@"minute"] || [lower containsString:@"second"] ||
                  [lower containsString:@"remaining"] || [lower containsString:@"time_left"] ||
                  [lower containsString:@"_left"] || [lower containsString:@"vote"];
    BOOL valueHit = result.length > 0 && result.length <= 16 &&
                    ([result containsString:@" 전"] || [result hasSuffix:@"표"]);
    if ((!keyHit && !valueHit) || result.length > 80) {
        return;
    }
    if (!gTimeStringProbe) {
        gTimeStringProbe = [NSMutableArray array];
    }
    NSString* line = [NSString stringWithFormat:@"key=%@ table=%@ value=%@", key, table, result];
    if (![gTimeStringProbe containsObject:line] && gTimeStringProbe.count < 70) {
        [gTimeStringProbe addObject:line];
    }
}
