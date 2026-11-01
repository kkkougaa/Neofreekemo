#import "Conflict/NFBConflict.h"

static const NSUInteger kConflictScanCap = 4000;

static BOOL NFBIsHangulSyllable(unichar c) {
    return c >= 0xAC00 && c <= 0xD7A3;
}

static BOOL NFBIsHangulJamo(unichar c) {
    return (c >= 0x1100 && c <= 0x11FF) || (c >= 0x3130 && c <= 0x318F) ||
           (c >= 0xA960 && c <= 0xA97F) || (c >= 0xD7B0 && c <= 0xD7FF);
}

static BOOL NFBIsLatin(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static NSString *NFBCompact(NSString *text) {
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= 'A' && c <= 'Z') {
            c = (unichar)(c - 'A' + 'a');
        }
        if (NFBIsLatin(c) || NFBIsHangulSyllable(c) || NFBIsHangulJamo(c)) {
            [out appendFormat:@"%C", c];
        }
    }
    return out;
}

// Spaces stay so "vs" does not match inside "canvas".
static NSString *NFBSpaced(NSString *text) {
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length];
    BOOL pendingSpace = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c <= ' ' || c == '\n' || c == '\t') {
            pendingSpace = out.length > 0;
            continue;
        }
        if (c >= 'A' && c <= 'Z') {
            c = (unichar)(c - 'A' + 'a');
        }
        if (!NFBIsLatin(c)) {
            continue;
        }
        if (pendingSpace) {
            [out appendString:@" "];
        }
        pendingSpace = NO;
        [out appendFormat:@"%C", c];
    }
    return out;
}

static BOOL NFBInflected(NSString *haystack, NSUInteger end) {
    static NSArray<NSString *> *suffixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suffixes = @[ @"ing", @"ers", @"er", @"ed", @"es", @"s" ];
    });
    if (end >= haystack.length) {
        return YES;
    }
    NSString *rest = [haystack substringFromIndex:end];
    for (NSString *suffix in suffixes) {
        if (![rest hasPrefix:suffix]) {
            continue;
        }
        if (suffix.length == rest.length || !NFBIsLatin([rest characterAtIndex:suffix.length])) {
            return YES;
        }
    }
    return NO;
}

static BOOL NFBHasToken(NSString *haystack, NSString *token) {
    if (token.length == 0 || haystack.length < token.length) {
        return NO;
    }
    NSRange window = NSMakeRange(0, haystack.length);
    while (window.length >= token.length) {
        NSRange found = [haystack rangeOfString:token options:0 range:window];
        if (found.location == NSNotFound) {
            return NO;
        }
        BOOL leftOK = found.location == 0 || !NFBIsLatin([haystack characterAtIndex:found.location - 1]);
        NSUInteger end = NSMaxRange(found);
        BOOL rightOK = end >= haystack.length || !NFBIsLatin([haystack characterAtIndex:end]) ||
                       NFBInflected(haystack, end);
        if (leftOK && rightOK) {
            return YES;
        }
        if (end >= haystack.length) {
            return NO;
        }
        window = NSMakeRange(end, haystack.length - end);
    }
    return NO;
}

// Skip a hit when the next syllables are an innocent continuation ("한남자").
static BOOL NFBContainsTerm(NSString *haystack, NSString *needle, NSString *skipSuffix) {
    NSRange window = NSMakeRange(0, haystack.length);
    while (window.length >= needle.length) {
        NSRange found = [haystack rangeOfString:needle options:0 range:window];
        if (found.location == NSNotFound) {
            return NO;
        }
        NSUInteger end = NSMaxRange(found);
        BOOL skipped = NO;
        if (skipSuffix.length > 0 && end + skipSuffix.length <= haystack.length) {
            NSString *tail = [haystack substringWithRange:NSMakeRange(end, skipSuffix.length)];
            skipped = [tail isEqualToString:skipSuffix];
        }
        if (!skipped) {
            return YES;
        }
        if (end >= haystack.length) {
            return NO;
        }
        window = NSMakeRange(end, haystack.length - end);
    }
    return NO;
}

static NSInteger NFBCountTerms(NSString *haystack, NSArray<NSString *> *needles) {
    NSInteger hits = 0;
    for (NSString *needle in needles) {
        if ([haystack rangeOfString:needle].location != NSNotFound) {
            hits++;
        }
    }
    return hits;
}

static NSArray<NSString *> *NFBStrongKorean(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[
            @"한녀", @"김치녀", @"김치남", @"틀딱", @"메갈", @"워마드", @"남혐", @"여혐",
            @"좌빨", @"수꼴", @"토착왜구", @"대깨", @"빨갱이", @"일베", @"홍어", @"전라디언",
            @"쌍도", @"갈라치기", @"패드립", @"지역드립", @"어그로", @"분탕", @"놈들은", @"년들은"
        ];
    });
    return words;
}

static NSArray<NSString *> *NFBWeakKorean(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // One of these is not enough. "것들" and "논란" show up in ordinary tweets.
        words = @[ @"논란", @"것들", @"들은다", @"꼰대" ];
    });
    return words;
}

// A short Hangul word ending on 충. Everyday words (대충, 곤충, 방충…) are
// ignored, and a bare 충 is not a slur.
static BOOL NFBChungSlur(NSString *compact) {
    static NSSet<NSString *> *ordinary;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ordinary = [NSSet setWithObjects:@"대충", @"곤충", @"해충", @"익충", @"완충", @"보충",
                                         @"방충", @"살충", @"구충", @"기생충", @"유충", @"성충",
                                         @"회충", @"요충", @"촌충", @"편충", @"선충", nil];
    });
    static const unichar kChung = 0xCDA9;
    NSUInteger length = compact.length;
    for (NSUInteger i = 0; i < length; i++) {
        if ([compact characterAtIndex:i] != kChung) {
            continue;
        }
        BOOL sawWord = NO;
        BOOL ordinaryWord = NO;
        for (NSUInteger syllables = 2; syllables <= 4; syllables++) {
            if (i + 1 < syllables) {
                continue;
            }
            NSUInteger start = i + 1 - syllables;
            BOOL hangul = YES;
            for (NSUInteger k = start; k <= i; k++) {
                if (!NFBIsHangulSyllable([compact characterAtIndex:k])) {
                    hangul = NO;
                    break;
                }
            }
            if (!hangul) {
                continue;
            }
            sawWord = YES;
            NSString *token = [compact substringWithRange:NSMakeRange(start, syllables)];
            if ([ordinary containsObject:token]) {
                ordinaryWord = YES;
            }
        }
        if (sawWord && !ordinaryWord) {
            return YES;
        }
    }
    return NO;
}

BOOL NFBConflictIsDivisive(NSString *text) {
    if (text.length == 0) {
        return NO;
    }
    NSString *trimmed =
        [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return NO;
    }
    if (trimmed.length > kConflictScanCap) {
        trimmed = [trimmed substringToIndex:kConflictScanCap];
    }
    NSString *compact = NFBCompact(trimmed);
    // "한남자" is "a man", not the slur.
    if (NFBContainsTerm(compact, @"한남", @"자")) {
        return YES;
    }
    for (NSString *word in NFBStrongKorean()) {
        if ([compact rangeOfString:word].location != NSNotFound) {
            return YES;
        }
    }
    if (NFBChungSlur(compact)) {
        return YES;
    }
    NSString *spaced = NFBSpaced(trimmed);
    if (NFBHasToken(spaced, @"libtard")) {
        return YES;
    }
    NSInteger weak = NFBCountTerms(compact, NFBWeakKorean());
    for (NSString *word in @[ @"vs", @"woke", @"ratio" ]) {
        if (NFBHasToken(spaced, word)) {
            weak++;
        }
    }
    return weak >= 2;
}
