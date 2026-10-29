//
//  StatusRowTweaks.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Core/BHTAliases.h"

// MARK: - Account aliases in tweet rows
// A small nickname between the display name and the @handle of a tweet's author row
// (TTAStatusAuthorView, laid out by frames). It is added after X has laid the row
// out. A row is only adjusted once per layout: the position the @handle was moved to
// is remembered, and when the frames still hold that position nothing moves again.

static const void* kAliasLabelKey = &kAliasLabelKey;
static const void* kAppliedKey = &kAppliedKey;
static const void* kDeltaKey = &kDeltaKey;

// MARK: Helpers

static UILabel* LabelWithIdentifier(UIView* parent, NSString* identifier) {
    for (UIView* sub in parent.subviews) {
        if ([sub isKindOfClass:[UILabel class]] &&
            [sub.accessibilityIdentifier isEqualToString:identifier]) {
            return (UILabel*)sub;
        }
    }
    return nil;
}

static UILabel* LabelWithText(UIView* parent, NSString* text) {
    for (UIView* sub in parent.subviews) {
        if ([sub isKindOfClass:[UILabel class]] && [((UILabel*)sub).text isEqualToString:text]) {
            return (UILabel*)sub;
        }
    }
    return nil;
}

// "⁦@name⁩" -> "@name": drops the invisible bidirectional marks around the handle.
static NSString* CleanHandle(NSString* raw) {
    NSMutableString* clean = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        BOOL mark = (c >= 0x2066 && c <= 0x2069) || c == 0x200E || c == 0x200F ||
                    (c >= 0x202A && c <= 0x202E);
        if (!mark) {
            [clean appendFormat:@"%C", c];
        }
    }
    return clean;
}

static void MoveX(UIView* view, CGFloat delta) {
    CGRect frame = view.frame;
    frame.origin.x += delta;
    view.frame = frame;
}

// MARK: Author row (name, @handle, time)

static void ApplyAlias(UIView* author) {
    UILabel* username = LabelWithIdentifier(author, @"StatusUsername");
    UILabel* timestamp = LabelWithIdentifier(author, @"StatusTimeStamp");
    UILabel* dot = LabelWithText(author, @"·");
    UILabel* alias = objc_getAssociatedObject(author, kAliasLabelKey);
    if (!username) {
        alias.hidden = YES;
        return;
    }

    NSString* aliasText = [BHTAliases aliasForHandle:CleanHandle(username.text)];
    if (aliasText.length == 0) {
        alias.hidden = YES;
        // The alias was just removed: give back the room it took.
        NSNumber* moved = objc_getAssociatedObject(author, kAppliedKey);
        if (moved && fabs(CGRectGetMinX(username.frame) - moved.doubleValue) < 0.01) {
            CGFloat previous = [objc_getAssociatedObject(author, kDeltaKey) doubleValue];
            MoveX(username, -previous);
            MoveX(dot, -previous);
            MoveX(timestamp, -previous);
            objc_setAssociatedObject(author, kAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    // Already moved for this layout?
    NSNumber* appliedX = objc_getAssociatedObject(author, kAppliedKey);
    if (appliedX && fabs(CGRectGetMinX(username.frame) - appliedX.doubleValue) < 0.01 &&
        [alias.text isEqualToString:aliasText]) {
        return;
    }

    // The alias changed but X didn't re-lay the row out: take the old shift back first.
    if (appliedX && fabs(CGRectGetMinX(username.frame) - appliedX.doubleValue) < 0.01) {
        CGFloat previous = [objc_getAssociatedObject(author, kDeltaKey) doubleValue];
        MoveX(username, -previous);
        MoveX(dot, -previous);
        MoveX(timestamp, -previous);
    }

    if (!alias) {
        alias = [UILabel new];
        alias.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        alias.textColor = [[UIColor labelColor] colorWithAlphaComponent:0.55];
        alias.lineBreakMode = NSLineBreakByTruncatingTail;
        alias.userInteractionEnabled = NO;
        [author addSubview:alias];
        objc_setAssociatedObject(author, kAliasLabelKey, alias, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    alias.text = aliasText;

    // The alias sits where the @handle was (the row already leaves a gap after the
    // name), so only the space after it is added. Room to the right runs up to the
    // "more" button, past the time.
    static const CGFloat kTrailGap = 5.0;
    CGFloat rightEdge = CGRectGetWidth(author.bounds) - 28.0;
    CGFloat usedRight = CGRectGetMaxX(username.frame);
    if (timestamp) {
        usedRight = MAX(usedRight, CGRectGetMaxX(timestamp.frame));
    }
    CGFloat spare = rightEdge - usedRight - kTrailGap;
    CGFloat textWidth =
        ceil([alias sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGRectGetHeight(username.frame))].width);
    CGFloat aliasWidth = MIN(textWidth, MAX(spare, 0));
    if (aliasWidth < 14) {
        alias.hidden = YES;
        return;
    }

    // [name][badge] alias <gap> @handle · time
    CGFloat delta = aliasWidth + kTrailGap;
    alias.frame = CGRectMake(CGRectGetMinX(username.frame), CGRectGetMinY(username.frame),
                             aliasWidth, CGRectGetHeight(username.frame));
    alias.hidden = NO;
    MoveX(username, delta);
    MoveX(dot, delta);
    MoveX(timestamp, delta);
    objc_setAssociatedObject(author, kAppliedKey, @(CGRectGetMinX(username.frame)),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(author, kDeltaKey, @(delta), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook TTAStatusAuthorView

- (void)layoutSubviews {
    %orig;
    ApplyAlias((UIView*)self);
}

%end
