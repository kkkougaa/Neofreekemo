//
//  AppearanceSettingsViewController.m
//  NeoFreeBird
//
//  Created by nyaathea
//

#import "Settings/Pages/AppearanceSettingsViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"
#import "Headers/Helpers.h"
#import "Headers/TWHeaders.h"
#import "Settings/ModernSettingsCells.h"
#import "Hooks/Theme/BHTDimPalette.h"
#import "Core/NFBChirpFonts.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

extern void BHTDimSettingDidChange(BOOL enabled);

@interface AppearanceSettingsViewController () <UIFontPickerViewControllerDelegate,
                                                UIColorPickerViewControllerDelegate,
                                                UIDocumentPickerDelegate>
@end

static NSString* const kThemeColorKeyAssociation = @"nfbThemeColorKey";

@implementation AppearanceSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.estimatedRowHeight = 60;
    [self.tableView registerClass:[ModernSettingsSimpleButtonCell class]
           forCellReuseIdentifier:@"SimpleButtonCell"];
}

- (NSString*)pageKey {
    return @"appearance";
}

- (void)updateVisibleToggles {
    [super updateVisibleToggles];
    // macOS doesn't support alternate app icons, so hide the row entirely.
    if (is_Mac()) {
        NSPredicate* notAppIcon = [NSPredicate predicateWithBlock:^BOOL(NSDictionary* toggle, NSDictionary* bindings) {
            return ![toggle[@"action"] isEqualToString:@"showAppIconViewController:"];
        }];
        self.visibleToggles = [self.visibleToggles filteredArrayUsingPredicate:notAppIcon];
    }
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    NSDictionary* settingData = self.visibleToggles[indexPath.row];
    if ([settingData[@"type"] isEqualToString:@"button"]) {
        ModernSettingsSimpleButtonCell* cell =
            [tableView dequeueReusableCellWithIdentifier:@"SimpleButtonCell"
                                            forIndexPath:indexPath];
        NSString* title = [[BHTBundle sharedBundle] localizedStringForKey:settingData[@"titleKey"]];
        [cell configureWithTitle:title];
        return cell;
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

#pragma mark - Sub-page Navigation

- (void)showThemeViewController:(NSDictionary*)sender {
    Class ColorThemeViewControllerClass = objc_getClass("ColorThemeViewController");
    if (ColorThemeViewControllerClass) {
        UIViewController* themeVC = [[ColorThemeViewControllerClass alloc] init];
        if (self.account) {
            [themeVC.navigationItem
                setTitleView:
                    [objc_getClass("TFNTitleView")
                        titleViewWithTitle:[[BHTBundle sharedBundle]
                                               localizedStringForKey:@"THEME_SETTINGS_NAVIGATION_TITLE"]
                                  subtitle:self.account.displayUsername]];
        }
        [self.navigationController pushViewController:themeVC animated:YES];
    }
}

- (void)showAppIconViewController:(NSDictionary*)sender {
    Class AppIconViewControllerClass = objc_getClass("AppIconViewController");
    if (AppIconViewControllerClass) {
        UIViewController* appIconVC = [[AppIconViewControllerClass alloc] init];
        if (self.account) {
            [appIconVC.navigationItem
                setTitleView:[objc_getClass("TFNTitleView")
                                 titleViewWithTitle:[[BHTBundle sharedBundle]
                                                        localizedStringForKey:
                                                            @"SUBSCRIPTION_APP_ICON_SETTINGS_TITLE"]
                                           subtitle:self.account.displayUsername]];
        }
        [self.navigationController pushViewController:appIconVC animated:YES];
    }
}

- (void)showCustomTabBarVC:(NSDictionary*)sender {
    UIViewController* customTabBarVC = [CustomTabBarUtility editorForAccount:self.account];
    if (customTabBarVC) {
        [self.navigationController pushViewController:customTabBarVC animated:YES];
    } else {
        BHTBundle* bundle = [BHTBundle sharedBundle];
        NSString* messageKey = @"CUSTOM_TAB_BAR_UNAVAILABLE_MESSAGE";
        NSString* message = [bundle localizedStringForKey:messageKey];
        if ([message isEqualToString:messageKey]) {
            message = @"Custom tab bar customization isn't available in this version of the app.";
        }
        UIAlertController* alert = [UIAlertController
            alertControllerWithTitle:[bundle localizedStringForKey:@"CUSTOM_TAB_BAR_SETTINGS_NAVIGATION_TITLE"]
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"OK_ACTION_LABEL"]
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - Tab Bar Refresh

- (void)refreshAllTabViewsWithTheming {
    for (UIWindow* window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow && window.rootViewController) {
            [self refreshTabViewsWithThemingInView:window.rootViewController.view];
        }
    }
}

- (void)refreshTabViewsWithThemingInView:(UIView*)view {
    if ([view respondsToSelector:@selector(nfb_refreshGlassTabLabels)]) {
        [view performSelector:@selector(nfb_refreshGlassTabLabels)];
    }
    if ([view respondsToSelector:@selector(nfb_applyGlassTabAccent)]) {
        [view performSelector:@selector(nfb_applyGlassTabAccent)];
    }
    if ([view isKindOfClass:NSClassFromString(@"T1TabView")]) {
        T1TabView* tabView = (T1TabView*)view;
        [tabView _t1_updateImageViewAnimated:NO];
        if ([view respondsToSelector:@selector(_t1_layoutForTabBar)]) {
            [view performSelector:@selector(_t1_layoutForTabBar)];
        }
        if ([view respondsToSelector:@selector(_t1_layoutBadgeViewMaximized)]) {
            [view performSelector:@selector(_t1_layoutBadgeViewMaximized)];
        }
        if ([view respondsToSelector:@selector(_t1_layoutBadgeViewMinimized)]) {
            [view performSelector:@selector(_t1_layoutBadgeViewMinimized)];
        }
    }

    for (UIView* subview in view.subviews) {
        [self refreshTabViewsWithThemingInView:subview];
    }
}

- (void)refreshAllTabViews {
    for (UIWindow* window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow && window.rootViewController) {
            [self refreshTabViewsInView:window.rootViewController.view];
        }
    }
}

- (void)refreshTabViewsInView:(UIView*)view {
    if ([view respondsToSelector:@selector(nfb_refreshGlassTabLabels)]) {
        [view performSelector:@selector(nfb_refreshGlassTabLabels)];
    }
    if ([view isKindOfClass:NSClassFromString(@"T1TabView")]) {
        [view setNeedsLayout];
        [view layoutIfNeeded];
        if ([view respondsToSelector:@selector(_t1_layoutBadgeViewMaximized)]) {
            [view performSelector:@selector(_t1_layoutBadgeViewMaximized)];
        }
    }

    for (UIView* subview in view.subviews) {
        [self refreshTabViewsInView:subview];
    }
}

- (void)switchChanged:(UISwitch*)sender {
    [super switchChanged:sender];
    NSString* key = objc_getAssociatedObject(sender, @"prefKey");
    if ([key isEqualToString:@"tab_bar_theming"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAllTabViewsWithTheming];
        });
    } else if ([key isEqualToString:@"restore_tab_labels"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAllTabViews];
        });
    } else if ([key isEqualToString:@"enable_dim_theme"]) {
        // Applied live, through a round trip into Light and back (Theme.m).
        BHTDimSettingDidChange(sender.isOn);
    } else if ([key isEqualToString:@"kemo_custom_theme"]) {
        [self showRestartAlert];
    }
}

- (void)showRestartAlert {
    {
        UIAlertController* alertController =
            [UIAlertController alertControllerWithTitle:[[BHTBundle sharedBundle]
                                                            localizedStringForKey:@"DIM_THEME_RESTART_ALERT_TITLE"]
                                                message:[[BHTBundle sharedBundle]
                                                            localizedStringForKey:@"DIM_THEME_RESTART_ALERT_MESSAGE"]
                                         preferredStyle:UIAlertControllerStyleAlert];

        alertController.modalPresentationStyle = UIModalPresentationFullScreen;
        UIAlertAction* restartAction = [UIAlertAction actionWithTitle:[[BHTBundle sharedBundle]
                                                                          localizedStringForKey:@"DIM_THEME_RESTART_ALERT_RESTART_BUTTON"]
                                                                style:UIAlertActionStyleDestructive
                                                              handler:^(UIAlertAction* action) {
                                                                  exit(0);
                                                              }];
        [alertController addAction:restartAction];
        [alertController addAction:[UIAlertAction actionWithTitle:[[BHTBundle sharedBundle]
                                                                      localizedStringForKey:@"KEMO_THEME_RESTART_LATER"]
                                                            style:UIAlertActionStyleCancel
                                                          handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    }
}

#pragma mark - Custom theme colors

- (void)presentThemeColorPickerForKey:(NSString*)key titleKey:(NSString*)titleKey {
    UIColorPickerViewController* picker = [UIColorPickerViewController new];
    picker.title = [[BHTBundle sharedBundle] localizedStringForKey:titleKey];
    picker.supportsAlpha = NO;
    picker.delegate = self;
    UIColor* current =
        BHTColorFromHexString([[NSUserDefaults standardUserDefaults] stringForKey:key]);
    if (current) {
        picker.selectedColor = current;
    } else if ([key isEqualToString:@"kemo_theme_bg"]) {
        picker.selectedColor = [UIColor colorWithRed:21 / 255.0 green:32 / 255.0 blue:43 / 255.0 alpha:1];
    } else {
        picker.selectedColor = [UIColor whiteColor];
    }
    objc_setAssociatedObject(picker, (__bridge const void*)kThemeColorKeyAssociation, key,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)showThemeBackgroundPicker:(NSDictionary*)sender {
    [self presentThemeColorPickerForKey:@"kemo_theme_bg" titleKey:@"KEMO_THEME_BG_TITLE"];
}

- (void)showThemeTextPicker:(NSDictionary*)sender {
    [self presentThemeColorPickerForKey:@"kemo_theme_text" titleKey:@"KEMO_THEME_TEXT_TITLE"];
}

- (void)resetThemeColors:(NSDictionary*)sender {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:@"kemo_theme_bg"];
    [defaults removeObjectForKey:@"kemo_theme_text"];
    [self updateVisibleToggles];
    [self.tableView reloadData];
    [self showRestartAlert];
}

- (void)saveThemeColorFromPicker:(UIColorPickerViewController*)picker {
    NSString* key = objc_getAssociatedObject(picker, (__bridge const void*)kThemeColorKeyAssociation);
    NSString* hex = BHTHexStringFromColor(picker.selectedColor);
    if (key.length == 0 || hex.length == 0) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:hex forKey:key];
    [self updateVisibleToggles];
    [self.tableView reloadData];
}

- (void)colorPickerViewController:(UIColorPickerViewController*)picker
                   didSelectColor:(UIColor*)color
                     continuously:(BOOL)continuously {
    if (!continuously) {
        [self saveThemeColorFromPicker:picker];
    }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController*)picker {
    [self saveThemeColorFromPicker:picker];
    // The picker dismisses itself; wait for that before putting up the alert.
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __typeof(self) strongSelf = weakSelf;
                       if (strongSelf.view.window && !strongSelf.presentedViewController) {
                           [strongSelf showRestartAlert];
                       }
                   });
}

#pragma mark - Fonts in Chirp's place

static char kChirpSlotKey;

- (void)showChirpFontPicker:(NSDictionary*)sender {
    NSString* slot = sender[@"slot"];
    if (!slot) {
        return;
    }
    NSMutableArray<UTType*>* types = [NSMutableArray arrayWithObject:UTTypeFont];
    for (NSString* extension in @[ @"otf", @"ttf" ]) {
        UTType* type = [UTType typeWithFilenameExtension:extension];
        if (type) {
            [types addObject:type];
        }
    }
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    objc_setAssociatedObject(picker, &kChirpSlotKey, slot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    NSString* slot = objc_getAssociatedObject(controller, &kChirpSlotKey);
    NSURL* url = urls.firstObject;
    if (!slot || !url) {
        return;
    }
    NSString* message = nil;
    BOOL ok = NFBChirpImportFont(url, slot, &message);
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"KEMO_CHIRP_FONTS_TITLE"]
                         message:ok ? [bundle localizedStringForKey:@"KEMO_CHIRP_FONT_RESTART_MESSAGE"] : message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"OK_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [self.tableView reloadData];
}

- (void)resetChirpFonts:(NSDictionary*)sender {
    NFBChirpResetFonts();
    [self.tableView reloadData];
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"KEMO_CHIRP_FONTS_TITLE"]
                         message:[bundle localizedStringForKey:@"KEMO_CHIRP_FONT_RESTART_MESSAGE"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"OK_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Font Pickers

- (void)showRegularFontPicker:(NSDictionary*)sender {
    UIFontPickerViewControllerConfiguration* configuration =
        [[UIFontPickerViewControllerConfiguration alloc] init];
    [configuration setFilteredTraits:UIFontDescriptorClassMask];
    [configuration setIncludeFaces:NO];
    UIFontPickerViewController* fontPicker =
        [[UIFontPickerViewController alloc] initWithConfiguration:configuration];
    fontPicker.delegate = (id<UIFontPickerViewControllerDelegate>)self;
    objc_setAssociatedObject(fontPicker, @"fontType", @"regular", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.account) {
        [fontPicker.navigationItem
            setTitleView:
                [objc_getClass("TFNTitleView")
                    titleViewWithTitle:[[BHTBundle sharedBundle]
                                           localizedStringForKey:@"REGULAR_FONTS_PICKER_OPTION_TITLE"]
                              subtitle:self.account.displayUsername]];
    } else {
        fontPicker.title =
            [[BHTBundle sharedBundle] localizedStringForKey:@"REGULAR_FONTS_PICKER_OPTION_TITLE"];
    }
    [self.navigationController pushViewController:fontPicker animated:YES];
}

- (void)showBoldFontPicker:(NSDictionary*)sender {
    UIFontPickerViewControllerConfiguration* configuration =
        [[UIFontPickerViewControllerConfiguration alloc] init];
    [configuration setIncludeFaces:YES];
    [configuration setFilteredTraits:UIFontDescriptorClassMask];
    UIFontPickerViewController* fontPicker =
        [[UIFontPickerViewController alloc] initWithConfiguration:configuration];
    fontPicker.delegate = (id<UIFontPickerViewControllerDelegate>)self;
    objc_setAssociatedObject(fontPicker, @"fontType", @"bold", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.account) {
        [fontPicker.navigationItem
            setTitleView:
                [objc_getClass("TFNTitleView")
                    titleViewWithTitle:[[BHTBundle sharedBundle]
                                           localizedStringForKey:@"BOLD_FONTS_PICKER_OPTION_TITLE"]
                              subtitle:self.account.displayUsername]];
    } else {
        fontPicker.title =
            [[BHTBundle sharedBundle] localizedStringForKey:@"BOLD_FONTS_PICKER_OPTION_TITLE"];
    }
    [self.navigationController pushViewController:fontPicker animated:YES];
}

- (void)fontPickerViewControllerDidPickFont:(UIFontPickerViewController*)viewController {
    NSString* fontName =
        viewController.selectedFontDescriptor.fontAttributes[UIFontDescriptorNameAttribute];
    NSString* fontFamily =
        viewController.selectedFontDescriptor.fontAttributes[UIFontDescriptorFamilyAttribute];
    NSString* fontType = objc_getAssociatedObject(viewController, @"fontType");
    if ([fontType isEqualToString:@"bold"]) {
        [[NSUserDefaults standardUserDefaults] setObject:fontName forKey:@"bhtwitter_font_2"];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:fontFamily forKey:@"bhtwitter_font_1"];
    }
    [self updateVisibleToggles];
    [self.tableView reloadData];
    [viewController.navigationController popViewControllerAnimated:YES];
}

@end
