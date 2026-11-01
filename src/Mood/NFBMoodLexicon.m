#import "Mood/NFBMoodLexicon.h"

// Compact form keeps Hangul, jamo, and letters so "시1발", "씨@발", and
// "f*ck" land on the same tokens as the plain spellings. Spaces and digits
// are removed. "$" becomes "s" so "a$$" matches "ass".
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
        if (c == '$') {
            [out appendString:@"s"];
            continue;
        }
        if (c >= 'A' && c <= 'Z') {
            c = (unichar)(c - 'A' + 'a');
        }
        if (NFBIsLatin(c) || NFBIsHangulSyllable(c) || NFBIsHangulJamo(c)) {
            [out appendFormat:@"%C", c];
        }
    }
    return out;
}

// Latin words keep their spaces so "vs" does not match inside "canvas".
static NSString *NFBSpaced(NSString *text) {
    NSMutableString *out = [NSMutableString stringWithCapacity:text.length];
    BOOL pendingSpace = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c <= ' ' || c == '\n' || c == '\t') {
            pendingSpace = out.length > 0;
            continue;
        }
        if (c == '$') {
            if (pendingSpace) {
                [out appendString:@" "];
            }
            pendingSpace = NO;
            [out appendString:@"s"];
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

static BOOL NFBContainsAny(NSString *haystack, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([haystack rangeOfString:needle].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// A following s/es/ed/er/ing still counts ("fucking", "libtards"). Anything
// else ("cunningham", "woken", "canvas") does not.
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
        if (suffix.length == rest.length) {
            return YES;
        }
        if (!NFBIsLatin([rest characterAtIndex:suffix.length])) {
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
        NSUInteger step = found.location + 1;
        if (step >= haystack.length) {
            return NO;
        }
        window = NSMakeRange(step, haystack.length - step);
    }
    return NO;
}

static BOOL NFBHasAnyToken(NSString *haystack, NSArray<NSString *> *tokens) {
    for (NSString *token in tokens) {
        if (NFBHasToken(haystack, token)) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *NFBProfanityKorean(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[
            @"씨발", @"시발", @"씨팔", @"시팔", @"씨벌", @"시벌", @"씨빨", @"시빨",
            @"ㅆㅂ", @"ㅅㅂ", @"ㅆ발", @"ㅅ발", @"씨ㅂ", @"시ㅂ",
            @"병신", @"병쉰", @"벙신", @"ㅂㅅ",
            @"좆",   @"좃",   @"ㅈ같", @"ㅈㄴ",
            @"존나", @"존내",
            @"개새끼", @"개색끼", @"개쉐", @"개새",
            @"지랄", @"느금", @"씹년", @"씹할", @"씹새"
        ];
    });
    return words;
}

static NSArray<NSString *> *NFBProfanityEnglish(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[
            @"fuck", @"fck", @"fuk", @"fucc", @"fuq", @"motherfucker", @"motherfker",
            @"shit", @"sht", @"bullshit", @"bitch", @"btch", @"asshole", @"cunt",
            @"dickhead", @"nigger", @"nigga", @"faggot"
        ];
    });
    return words;
}

static NSArray<NSString *> *NFBConflictKorean(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[
            @"한남", @"한녀", @"김치녀", @"김치남", @"틀딱", @"꼰대",
            @"메갈", @"워마드", @"남혐", @"여혐",
            @"좌빨", @"수꼴", @"토착왜구", @"대깨", @"빨갱이", @"일베",
            @"홍어", @"전라디언", @"쌍도",
            @"어그로", @"논란", @"분탕", @"갈라치기", @"패드립", @"지역드립"
        ];
    });
    return words;
}

static NSArray<NSString *> *NFBConflictEnglish(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[ @"vs", @"woke", @"ratio", @"libtard" ];
    });
    return words;
}

static NSArray<NSString *> *NFBGroupPatterns(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // "들은 다" and "~것들" after spaces are stripped, plus the plural
        // slur particles. Bare "충" is intentionally not here.
        words = @[ @"들은다", @"것들", @"놈들은", @"년들은" ];
    });
    return words;
}

static NSArray<NSString *> *NFBAngerWords(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[
            @"화나", @"화났", @"화난", @"짜증", @"열받", @"빡치", @"빡쳐", @"빡쳤",
            @"빡친", @"답답", @"싫어", @"싫다", @"어이없", @"황당", @"분노",
            @"극혐", @"노답", @"한숨", @"환장"
        ];
    });
    return words;
}

// "~충" as its own short word. Spaces are already gone, so look at the 2–4
// syllables that end on 충. Everyday words (대충, 곤충, 기생충, 방충…) are
// skipped; bare 충, with nothing in front of it, is not a slur.
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

BOOL NFBMoodContainsProfanity(NSString *text) {
    if (text.length == 0) {
        return NO;
    }
    NSString *compact = NFBCompact(text);
    if (NFBContainsAny(compact, NFBProfanityKorean())) {
        return YES;
    }
    // Spaced, not compact, so "fuck you" still matches and "cunningham" does not.
    return NFBHasAnyToken(NFBSpaced(text), NFBProfanityEnglish());
}

BOOL NFBMoodContainsConflict(NSString *text) {
    if (text.length == 0) {
        return NO;
    }
    NSString *compact = NFBCompact(text);
    if (NFBContainsAny(compact, NFBConflictKorean()) || NFBChungSlur(compact) ||
        NFBContainsAny(compact, NFBGroupPatterns())) {
        return YES;
    }
    return NFBHasAnyToken(NFBSpaced(text), NFBConflictEnglish());
}

NSInteger NFBMoodAngerHits(NSString *text) {
    if (text.length == 0) {
        return 0;
    }
    NSString *compact = NFBCompact(text);
    NSInteger hits = 0;
    for (NSString *word in NFBAngerWords()) {
        if ([compact rangeOfString:word].location != NSNotFound) {
            hits++;
        }
    }
    return hits;
}
