//
//  KeywordHighlight.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Core/BHTKeywords.h"

// MARK: - Highlight tweets that contain a keyword
// A thin accent-colored bar on the left edge and a very faint accent wash behind the
// whole row, for tweets whose text contains one of the keywords from the kemo
// settings. The mark sits behind the row's content, so it never covers the name or
// the text.

static const NSInteger kHighlightTag = 0x4e464236;
static const CGFloat kBarWidth = 3.0;

@interface NFBHighlightView : UIView
@property (nonatomic, strong) UIView* bar;
@end

@implementation NFBHighlightView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.tag = kHighlightTag;
        self.userInteractionEnabled = NO;
        _bar = [UIView new];
        _bar.userInteractionEnabled = NO;
        [self addSubview:_bar];
    }
    return self;
}

- (void)applyAccent {
    UIColor* accent = CurrentAccentColor();
    self.backgroundColor = [accent colorWithAlphaComponent:0.07];
    self.bar.backgroundColor = accent;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.bar.frame = CGRectMake(0, 0, kBarWidth, CGRectGetHeight(self.bounds));
}

@end

// The tweet's own text, as exposed to accessibility by the body text view.
static NSString* BodyText(UIView* row) {
    for (UIView* sub in row.subviews) {
        if (![NSStringFromClass(sub.class) isEqualToString:@"TTAStatusBodyTextView"]) {
            continue;
        }
        for (UIView* inner in sub.subviews) {
            if (inner.accessibilityLabel.length > 0) {
                return inner.accessibilityLabel;
            }
        }
        return sub.accessibilityLabel;
    }
    return nil;
}

static void ApplyHighlight(UIView* row) {
    NFBHighlightView* mark = (NFBHighlightView*)[row viewWithTag:kHighlightTag];
    BOOL matches = [BHTKeywords textMatches:BodyText(row)];
    if (!matches) {
        mark.hidden = YES;
        return;
    }

    if (!mark) {
        mark = [[NFBHighlightView alloc] initWithFrame:row.bounds];
        [row insertSubview:mark atIndex:0];
    }
    mark.frame = row.bounds;
    [mark applyAccent];
    mark.hidden = NO;
    if (row.subviews.firstObject != mark) {
        [row sendSubviewToBack:mark];
    }
}

%hook T1StandardStatusView

- (void)layoutSubviews {
    %orig;
    ApplyHighlight((UIView*)self);
}

%end
