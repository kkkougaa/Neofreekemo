//
//  StatusRowTweaks.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Core/BHTAliases.h"

// MARK: - Tweak the look of timeline tweet rows
// 1. Account aliases: a small nickname between the display name and the @handle.
// 2. Media-only mode (kemo_media_only, home timeline): hide the tweet text, the
//    display name and the time so only the avatar, the @handle and the media remain.
//
// Both work on the row's own subviews (TTAStatusAuthorView / T1StandardStatusView,
// laid out by frames), after X has laid them out. A row is only adjusted once per
// layout: the position it was moved to is remembered, and when the frames still
// hold that position nothing is moved again.

static NSString* const kMediaOnlyKey = @"kemo_media_only";

static const void* kAliasLabelKey = &kAliasLabelKey;
static const void* kAppliedKey = &kAppliedKey;
static const void* kHiddenByUsKey = &kHiddenByUsKey;

// MARK: Helpers

static BOOL IsInHomeTimeline(UIView* view) {
    for (UIResponder* responder = view; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:[UIViewController class]]) {
            continue;
        }
        for (UIViewController* vc = (UIViewController*)responder; vc; vc = vc.parentViewController) {
            if ([NSStringFromClass(vc.class) containsString:@"HomeTimelineContainerViewController"]) {
                return YES;
            }
        }
        return NO;
    }
    return NO;
}

static BOOL MediaOnlyActive(UIView* view) {
    return [BHTSettings boolForKey:kMediaOnlyKey] && IsInHomeTimeline(view);
}

static UIView* SubviewOfClass(UIView* parent, NSString* className) {
    for (UIView* sub in parent.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:className]) {
            return sub;
        }
    }
    return nil;
}

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

static void SetHidden(UIView* view, BOOL hidden) {
    if (!view) {
        return;
    }
    if (hidden) {
        if (!view.hidden) {
            view.hidden = YES;
            objc_setAssociatedObject(view, kHiddenByUsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if ([objc_getAssociatedObject(view, kHiddenByUsKey) boolValue]) {
        view.hidden = NO;
        objc_setAssociatedObject(view, kHiddenByUsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void MoveX(UIView* view, CGFloat delta) {
    CGRect frame = view.frame;
    frame.origin.x += delta;
    view.frame = frame;
}

// MARK: Author row (name, @handle, time)

static void ApplyAuthorRow(UIView* author) {
    UILabel* fullname = LabelWithIdentifier(author, @"StatusFullname");
    UILabel* username = LabelWithIdentifier(author, @"StatusUsername");
    UILabel* timestamp = LabelWithIdentifier(author, @"StatusTimeStamp");
    UILabel* dot = LabelWithText(author, @"·");
    UIView* badge = SubviewOfClass(author, @"TFNBadgesImageView");
    UILabel* alias = objc_getAssociatedObject(author, kAliasLabelKey);
    if (!username) {
        alias.hidden = YES;
        return;
    }

    BOOL mediaOnly = MediaOnlyActive(author);
    SetHidden(fullname, mediaOnly);
    SetHidden(timestamp, mediaOnly);
    SetHidden(dot, mediaOnly);
    SetHidden(badge, mediaOnly);

    NSString* aliasText = [BHTAliases aliasForHandle:CleanHandle(username.text)];
    if (!mediaOnly && aliasText.length == 0) {
        alias.hidden = YES;
        return;
    }

    // Already moved for this layout?
    NSNumber* appliedX = objc_getAssociatedObject(author, kAppliedKey);
    BOOL aliasUnchanged = (aliasText.length == 0 && alias.hidden) ||
                          [alias.text isEqualToString:aliasText];
    if (appliedX && fabs(CGRectGetMinX(username.frame) - appliedX.doubleValue) < 0.01 &&
        aliasUnchanged) {
        return;
    }

    // Media-only: the @handle slides to the left edge where the name used to be.
    if (mediaOnly) {
        MoveX(username, -CGRectGetMinX(username.frame));
    }

    if (aliasText.length == 0) {
        alias.hidden = YES;
        objc_setAssociatedObject(author, kAppliedKey, @(CGRectGetMinX(username.frame)),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
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

    // Room to the right: up to the "more" button, past the time when it's showing.
    static const CGFloat kLeadGap = 5.0;
    static const CGFloat kTrailGap = 5.0;
    CGFloat rightEdge = CGRectGetWidth(author.bounds) - 28.0;
    CGFloat usedRight = CGRectGetMaxX(username.frame);
    if (!mediaOnly && timestamp) {
        usedRight = MAX(usedRight, CGRectGetMaxX(timestamp.frame));
    }
    CGFloat spare = rightEdge - usedRight - kLeadGap - kTrailGap;
    CGFloat textWidth = ceil([alias sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGRectGetHeight(username.frame))].width);
    CGFloat aliasWidth = MIN(textWidth, MAX(spare, 0));
    if (aliasWidth < 14) {
        alias.hidden = YES;
        objc_setAssociatedObject(author, kAppliedKey, @(CGRectGetMinX(username.frame)),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // [name][badge] <gap> alias <gap> @handle · time
    CGFloat delta = kLeadGap + aliasWidth + kTrailGap;
    alias.frame = CGRectMake(CGRectGetMinX(username.frame) + kLeadGap, CGRectGetMinY(username.frame),
                             aliasWidth, CGRectGetHeight(username.frame));
    alias.hidden = NO;
    MoveX(username, delta);
    if (!mediaOnly) {
        MoveX(dot, delta);
        MoveX(timestamp, delta);
    }
    objc_setAssociatedObject(author, kAppliedKey, @(CGRectGetMinX(username.frame)),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook TTAStatusAuthorView

- (void)layoutSubviews {
    %orig;
    ApplyAuthorRow((UIView*)self);
}

%end

// MARK: Whole row (media-only)

static void ApplyMediaOnlyRow(UIView* row) {
    UIView* body = SubviewOfClass(row, @"TTAStatusBodyTextView");
    UIView* social = SubviewOfClass(row, @"T1TimelinesItemSocialContextView");
    UIView* container = SubviewOfClass(row, @"T1StatusViewAttachmentContainerView");
    UIView* actions = SubviewOfClass(row, @"TTAStatusInlineActionsView");

    BOOL active = container && CGRectGetHeight(container.frame) > 10 && MediaOnlyActive(row);
    SetHidden(body, active);
    SetHidden(social, active);
    if (!active) {
        return;
    }

    // Pull the media and the action row up into the room the text took.
    NSNumber* appliedY = objc_getAssociatedObject(container, kAppliedKey);
    if (appliedY && fabs(CGRectGetMinY(container.frame) - appliedY.doubleValue) < 0.01) {
        return;
    }
    CGFloat shift = CGRectGetHeight(body.frame);
    if (shift <= 0) {
        return;
    }
    CGRect frame = container.frame;
    frame.origin.y -= shift;
    container.frame = frame;
    if (actions) {
        CGRect actionsFrame = actions.frame;
        actionsFrame.origin.y -= shift;
        actions.frame = actionsFrame;
    }
    objc_setAssociatedObject(container, kAppliedKey, @(CGRectGetMinY(container.frame)),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook T1StandardStatusView

- (void)layoutSubviews {
    %orig;
    ApplyMediaOnlyRow((UIView*)self);
}

%end
