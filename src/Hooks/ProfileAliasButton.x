//
//  ProfileAliasButton.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import "Core/BHTAliases.h"

// MARK: - Alias button on profiles
// A round "+" button in the profile's button row, to the left of the notification
// and share buttons, with the same size and spacing. It opens a prompt for the
// profile's alias. The button turns accent-colored when the account has an alias.

@interface XDSButtonRow : UIView
@end

static const NSInteger kAliasButtonTag = 0x4e464235;
static const CGFloat kButtonSize = 40.0;

// MARK: Which account is this profile?

static NSString* StringForSelectors(id object, NSArray<NSString*>* names) {
    for (NSString* name in names) {
        SEL selector = NSSelectorFromString(name);
        if ([object respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value isKindOfClass:[NSString class]] && [(NSString*)value length] > 0) {
                return value;
            }
        }
    }
    return nil;
}

static UIViewController* ProfileController(UIView* view) {
    for (UIResponder* responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            for (UIViewController* vc = (UIViewController*)responder; vc; vc = vc.parentViewController) {
                if ([NSStringFromClass(vc.class) isEqualToString:@"T1ProfileViewController"]) {
                    return vc;
                }
            }
            return nil;
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

// The profile's @handle: from the view controller's user object when it has one, else
// the handle that appears most often on the tweets listed on the page.
static NSString* ProfileHandle(UIViewController* profile) {
    for (NSString* userKey in @[ @"user", @"profileUser", @"twitterUser", @"displayedUser" ]) {
        SEL selector = NSSelectorFromString(userKey);
        if (![profile respondsToSelector:selector]) {
            continue;
        }
        id user = ((id (*)(id, SEL))objc_msgSend)(profile, selector);
        NSString* handle = StringForSelectors(user, @[ @"screenName", @"username", @"handle" ]);
        if (handle) {
            return [BHTAliases normalizedHandle:handle];
        }
    }

    NSMutableDictionary<NSString*, NSNumber*>* counts = [NSMutableDictionary dictionary];
    EnumerateSubviewsRecursively(profile.view, ^(UIView* view) {
        if ([view isKindOfClass:[UILabel class]] &&
            [view.accessibilityIdentifier isEqualToString:@"StatusUsername"]) {
            NSString* handle = [BHTAliases normalizedHandle:CleanHandle(((UILabel*)view).text)];
            if (handle) {
                counts[handle] = @(counts[handle].integerValue + 1);
            }
        }
    });
    NSString* best = nil;
    for (NSString* handle in counts) {
        if (!best || counts[handle].integerValue > counts[best].integerValue) {
            best = handle;
        }
    }
    return best;
}

// MARK: Prompt

static void RefreshAuthorRows(UIView* root) {
    EnumerateSubviewsRecursively(root, ^(UIView* view) {
        if ([NSStringFromClass(view.class) isEqualToString:@"TTAStatusAuthorView"]) {
            [view setNeedsLayout];
        }
    });
}

static void PromptForAlias(UIViewController* profile, UIButton* button) {
    NSString* handle = ProfileHandle(profile);
    BHTBundle* bundle = [BHTBundle sharedBundle];

    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"KEMO_ALIAS_ADD_TITLE"]
                         message:handle ? [@"@" stringByAppendingString:handle] : nil
                  preferredStyle:UIAlertControllerStyleAlert];

    // When the handle couldn't be worked out, it is asked for too.
    if (!handle) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
            field.placeholder = [bundle localizedStringForKey:@"KEMO_ALIAS_HANDLE_PLACEHOLDER"];
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
    }
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = [bundle localizedStringForKey:@"KEMO_ALIAS_NAME_PLACEHOLDER"];
        field.text = handle ? [BHTAliases aliasForHandle:handle] : nil;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak UIAlertController* weakAlert = alert;
    __weak UIViewController* weakProfile = profile;
    __weak UIButton* weakButton = button;
    [alert addAction:[UIAlertAction
                         actionWithTitle:[bundle localizedStringForKey:@"OK_ACTION_LABEL"]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     NSArray<UITextField*>* fields = weakAlert.textFields;
                                     NSString* target =
                                         handle ?: [BHTAliases normalizedHandle:fields.firstObject.text];
                                     NSString* aliasText = fields.lastObject.text;
                                     if (!target) {
                                         return;
                                     }
                                     [BHTAliases setAlias:aliasText forHandle:target];
                                     weakButton.tintColor =
                                         [BHTAliases aliasForHandle:target] ? CurrentAccentColor()
                                                                           : [UIColor labelColor];
                                     RefreshAuthorRows(weakProfile.view);
                                 }]];
    [profile presentViewController:alert animated:YES completion:nil];
}

// MARK: Button

static UIButton* MakeAliasButton(void) {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = kAliasButtonTag;
    UIImageSymbolConfiguration* config =
        [UIImageSymbolConfiguration configurationWithPointSize:18
                                                        weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:@"plus" withConfiguration:config]
            forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    button.layer.cornerRadius = kButtonSize / 2;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor separatorColor].CGColor;
    button.accessibilityLabel = [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_ALIAS_ADD_TITLE"];
    return button;
}

static void PlaceAliasButton(UIView* row) {
    // Only the profile header's button row (the one holding the notification button).
    if (![row.superview.accessibilityIdentifier isEqualToString:@"ProfileHeader"]) {
        return;
    }
    UIView* leftmost = nil;
    for (UIView* sub in row.subviews) {
        if (sub.tag == kAliasButtonTag || ![NSStringFromClass(sub.class) isEqualToString:@"XDSButton"]) {
            continue;
        }
        if (!leftmost || CGRectGetMinX(sub.frame) < CGRectGetMinX(leftmost.frame)) {
            leftmost = sub;
        }
    }
    if (!leftmost) {
        return;
    }

    UIButton* button = (UIButton*)[row viewWithTag:kAliasButtonTag];
    if (!button) {
        button = MakeAliasButton();
        __weak UIView* weakRow = row;
        __weak UIButton* weakButton = button;
        [button addAction:[UIAction actionWithHandler:^(UIAction* action) {
                    UIViewController* profile = ProfileController(weakRow);
                    if (profile && weakButton) {
                        PromptForAlias(profile, weakButton);
                    }
                }]
         forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:button];
    }

    // Same size and gap as the buttons already in the row.
    CGFloat gap = 8.0;
    button.frame = CGRectMake(CGRectGetMinX(leftmost.frame) - gap - kButtonSize,
                              CGRectGetMinY(leftmost.frame), kButtonSize, kButtonSize);
    NSString* handle = ProfileHandle(ProfileController(row));
    button.tintColor = (handle && [BHTAliases aliasForHandle:handle]) ? CurrentAccentColor()
                                                                      : [UIColor labelColor];
    button.layer.borderColor = [UIColor separatorColor].CGColor;
}

%hook XDSButtonRow

- (void)layoutSubviews {
    %orig;
    PlaceAliasButton((UIView*)self);
}

%end
