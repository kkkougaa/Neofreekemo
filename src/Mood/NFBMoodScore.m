#import "Mood/NFBMoodScore.h"
#import "Mood/NFBMoodLexicon.h"
#import <NaturalLanguage/NaturalLanguage.h>

static const NSUInteger kMoodScoreCap = 4000;

typedef struct {
    NSInteger latin;
    NSInteger latinUpper;
    NSInteger bangs;
    BOOL sigh;
    BOOL interrobang;
} NFBMoodMarks;

static NFBMoodMarks NFBScanMarks(NSString *text) {
    NFBMoodMarks marks = {0};
    NSUInteger length = text.length;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= 'A' && c <= 'Z') {
            marks.latin++;
            marks.latinUpper++;
        } else if (c >= 'a' && c <= 'z') {
            marks.latin++;
        } else if (c == '!') {
            marks.bangs++;
            if (i + 1 < length && [text characterAtIndex:i + 1] == '?') {
                marks.interrobang = YES;
            }
            if (i > 0 && [text characterAtIndex:i - 1] == '?') {
                marks.interrobang = YES;
            }
        }
    }
    if ([text rangeOfString:@"ㅡㅡ"].location != NSNotFound ||
        [text rangeOfString:@"ㅡ.ㅡ"].location != NSNotFound ||
        [text rangeOfString:@"-_-"].location != NSNotFound) {
        marks.sigh = YES;
    }
    return marks;
}

// NLTagger sentiment is only consulted when the tweet actually has Latin
// text. Korean tone comes from the lexicon and the mark scan above.
static NSInteger NFBSentimentHeat(NSString *text, NSInteger latin) {
    if (latin < 12) {
        return 0;
    }
    NLTagger *tagger = [[NLTagger alloc] initWithTagSchemes:@[ NLTagSchemeSentimentScore ]];
    tagger.string = text;
    NSString *tag = [tagger tagAtIndex:0
                                   unit:NLTokenUnitParagraph
                                 scheme:NLTagSchemeSentimentScore
                             tokenRange:NULL];
    if (tag.length == 0) {
        return 0;
    }
    double score = tag.doubleValue;
    if (score >= -0.05) {
        return 0;
    }
    double magnitude = score < -1.0 ? 1.0 : -score;
    return (NSInteger)(magnitude * 40.0 + 0.5);
}

// sensitivity 0 pushes the boundaries up (harder to leave 평온). 100 pulls
// them down. A tweet with no signals stays level 1 at every setting.
static NSInteger NFBLevelForHeat(NSInteger heat, NSInteger sensitivity) {
    if (sensitivity < 0) {
        sensitivity = 0;
    } else if (sensitivity > 100) {
        sensitivity = 100;
    }
    double t = ((double)sensitivity - 50.0) / 50.0;
    double calm = 16.0 - t * 10.0;
    double neutral = 36.0 - t * 16.0;
    double tense = 58.0 - t * 20.0;
    if (heat < calm) {
        return 1;
    }
    if (heat < neutral) {
        return 2;
    }
    if (heat < tense) {
        return 3;
    }
    return 4;
}

NSInteger NFBMoodScore(NSString *text, NSInteger sensitivity) {
    if (text.length == 0) {
        return 0;
    }
    NSString *trimmed =
        [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return 0;
    }
    if (trimmed.length > kMoodScoreCap) {
        trimmed = [trimmed substringToIndex:kMoodScoreCap];
    }
    if (NFBMoodContainsConflict(trimmed)) {
        return 6;
    }
    if (NFBMoodContainsProfanity(trimmed)) {
        return 5;
    }

    NFBMoodMarks marks = NFBScanMarks(trimmed);
    NSInteger heat = NFBMoodAngerHits(trimmed) * 15;
    if (heat > 45) {
        heat = 45;
    }
    if (marks.bangs >= 2) {
        NSInteger extra = (marks.bangs - 1) * 6;
        heat += extra > 20 ? 20 : extra;
    }
    if (marks.interrobang) {
        heat += 8;
    }
    if (marks.sigh) {
        heat += 18;
    }
    if (marks.latin >= 8 && marks.latinUpper * 10 >= marks.latin * 7) {
        heat += 16;
    }
    heat += NFBSentimentHeat(trimmed, marks.latin);
    if (heat > 100) {
        heat = 100;
    }
    return NFBLevelForHeat(heat, sensitivity);
}
