//
//  PresetsSettingsViewController.m
//  NeoFreeBird
//
//  Created by orionblur
//

#import "Settings/Pages/PresetsSettingsViewController.h"
#import <CoreImage/CoreImage.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/BHTBundle.h"
#import "Core/BHTSettingsTransfer.h"
#import "Headers/TWHeaders.h"

// The picker's own mode property is deprecated, so the purpose is tagged on the
// controller instead and read back in the shared delegate callback.
static char kPickerPurposeKey;
static NSString* const kPickerPurposeImport = @"import";

@interface PresetsSettingsViewController () <UIDocumentPickerDelegate>
@end

@implementation PresetsSettingsViewController

- (NSString*)pageKey {
    return @"presets";
}

#pragma mark - Alerts

- (void)showAlertWithTitleKey:(NSString*)titleKey message:(NSString*)message {
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:titleKey]
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[[BHTBundle sharedBundle]
                                                        localizedStringForKey:@"OK_ACTION_LABEL"]
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Export

- (void)exportSettings:(NSDictionary*)sender {
    NSError* error = nil;
    NSURL* fileURL = [BHTSettingsTransfer writeExportToTemporaryDirectory:&error];
    if (!fileURL) {
        [self showAlertWithTitleKey:@"SETTINGS_EXPORT_FAILED_TITLE"
                            message:error.localizedDescription];
        return;
    }

    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[fileURL]
                                                              asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Import

// Importing replaces every setting the file names, so it is worth a confirm
// before the file browser takes over the screen.
- (void)importSettings:(NSDictionary*)sender {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"SETTINGS_IMPORT_CONFIRM_TITLE"]
                         message:[bundle localizedStringForKey:@"SETTINGS_IMPORT_CONFIRM_MESSAGE"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle
                                                        localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction
                         actionWithTitle:[bundle
                                             localizedStringForKey:@"SETTINGS_IMPORT_CONFIRM_BUTTON"]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     [self presentImportPicker];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetSettings:(NSDictionary*)sender {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"SETTINGS_RESET_CONFIRM_TITLE"]
                         message:[bundle localizedStringForKey:@"SETTINGS_RESET_CONFIRM_MESSAGE"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle
                                                        localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction
                         actionWithTitle:[bundle
                                             localizedStringForKey:@"SETTINGS_RESET_CONFIRM_BUTTON"]
                                   style:UIAlertActionStyleDestructive
                                 handler:^(UIAlertAction* action) {
                                     [BHTSettingsTransfer resetAllSettings];
                                     [self updateVisibleToggles];
                                     [self.tableView reloadData];
                                     [self presentResetRestartPrompt];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentResetRestartPrompt {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"SETTINGS_RESET_SUCCESS_TITLE"]
                         message:[bundle localizedStringForKey:@"SETTINGS_RESET_SUCCESS_MESSAGE"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle
                                                        localizedStringForKey:@"SETTINGS_IMPORT_LATER_BUTTON"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle
                                                        localizedStringForKey:@"SETTINGS_IMPORT_RESTART_BUTTON"]
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction* action) {
                                                exit(0);
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentImportPicker {
    UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeJSON]
                            asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    objc_setAssociatedObject(picker, &kPickerPurposeKey, kPickerPurposeImport,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)applyImportFromURL:(NSURL*)url {
    NSError* error = nil;
    NSInteger applied = [BHTSettingsTransfer importSettingsFromFileAtURL:url error:&error];
    if (applied < 0) {
        [self showAlertWithTitleKey:@"SETTINGS_IMPORT_FAILED_TITLE"
                            message:error.localizedDescription];
        return;
    }

    // Rows on this page never change, but the imported values have to be live
    // for whichever page the user opens next.
    [self updateVisibleToggles];
    [self.tableView reloadData];

    BHTBundle* bundle = [BHTBundle sharedBundle];
    NSString* format = [bundle localizedStringForKey:@"SETTINGS_IMPORT_SUCCESS_MESSAGE"];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"SETTINGS_IMPORT_SUCCESS_TITLE"]
                         message:[NSString stringWithFormat:format, (long)applied]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:
                                                                @"SETTINGS_IMPORT_LATER_BUTTON"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:
                                                                @"SETTINGS_IMPORT_RESTART_BUTTON"]
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction* action) {
                                                exit(0);
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Clipboard code

- (NSString*)localized:(NSString*)key {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

- (void)showToast:(NSString*)text {
    if (text.length == 0) {
        return;
    }
    UILabel* label = [UILabel new];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.layer.cornerRadius = 14;
    label.clipsToBounds = YES;
    CGSize fit = [label sizeThatFits:CGSizeMake(self.view.bounds.size.width - 64, 80)];
    label.bounds = CGRectMake(0, 0, MIN(self.view.bounds.size.width - 40, fit.width + 28),
                              MAX(36, fit.height + 16));
    label.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetHeight(self.view.bounds) - 88);
    label.alpha = 0;
    [self.view addSubview:label];
    [UIView animateWithDuration:0.2
        animations:^{
            label.alpha = 1;
        }
        completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25
                delay:1.5
                options:UIViewAnimationOptionCurveEaseIn
                animations:^{
                    label.alpha = 0;
                }
                completion:^(BOOL done) {
                    [label removeFromSuperview];
                }];
        }];
}

- (UIImage*)qrImageForString:(NSString*)text {
    NSData* data = [text dataUsingEncoding:NSUTF8StringEncoding];
    // A single QR code cannot hold a very large backup. The clipboard still has it.
    if (data.length == 0 || data.length > 2800) {
        return nil;
    }
    CIFilter* filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:data forKey:@"inputMessage"];
    [filter setValue:@"L" forKey:@"inputCorrectionLevel"];
    CIImage* output = filter.outputImage;
    if (!output) {
        return nil;
    }
    CIImage* scaled = [output imageByApplyingTransform:CGAffineTransformMakeScale(8, 8)];
    CIContext* context = [CIContext context];
    CGImageRef cgImage = [context createCGImage:scaled fromRect:scaled.extent];
    if (!cgImage) {
        return nil;
    }
    UIImage* image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

- (void)presentCodeSheet:(NSString*)code {
    UIViewController* sheet = [UIViewController new];
    sheet.view.backgroundColor = [UIColor systemBackgroundColor];
    sheet.title = [self localized:@"SETTINGS_CODE_EXPORT_TITLE"];
    UIImage* qr = [self qrImageForString:code];
    UIImageView* imageView = [[UIImageView alloc] initWithImage:qr];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    [sheet.view addSubview:imageView];
    UILabel* caption = [UILabel new];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.numberOfLines = 0;
    caption.textAlignment = NSTextAlignmentCenter;
    caption.text = [self localized:qr ? @"SETTINGS_CODE_COPIED" : @"SETTINGS_CODE_TOO_BIG"];
    caption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    [sheet.view addSubview:caption];
    [NSLayoutConstraint activateConstraints:@[
        [imageView.centerXAnchor constraintEqualToAnchor:sheet.view.centerXAnchor],
        [imageView.centerYAnchor constraintEqualToAnchor:sheet.view.centerYAnchor constant:-24],
        [imageView.widthAnchor constraintEqualToConstant:qr ? 240 : 0],
        [imageView.heightAnchor constraintEqualToConstant:qr ? 240 : 0],
        [caption.topAnchor constraintEqualToAnchor:imageView.bottomAnchor constant:16],
        [caption.leadingAnchor constraintEqualToAnchor:sheet.view.leadingAnchor constant:24],
        [caption.trailingAnchor constraintEqualToAnchor:sheet.view.trailingAnchor constant:-24]
    ]];
    UINavigationController* navigation =
        [[UINavigationController alloc] initWithRootViewController:sheet];
    sheet.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:[self localized:@"OK_ACTION_LABEL"]
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(dismissCodeSheet)];
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)dismissCodeSheet {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)exportSettingsCode:(NSDictionary*)sender {
    NSError* error = nil;
    NSString* code = [BHTSettingsTransfer exportBase64String:&error];
    if (code.length == 0) {
        [self showAlertWithTitleKey:@"SETTINGS_EXPORT_FAILED_TITLE" message:error.localizedDescription];
        return;
    }
    [UIPasteboard generalPasteboard].string = code;
    [self presentCodeSheet:code];
}

- (void)importSettingsCode:(NSDictionary*)sender {
    NSString* code = [UIPasteboard generalPasteboard].string;
    if (code.length == 0) {
        [self showAlertWithTitleKey:@"SETTINGS_CODE_IMPORT_TITLE"
                            message:[self localized:@"SETTINGS_CODE_EMPTY"]];
        return;
    }
    BHTBundle* bundle = [BHTBundle sharedBundle];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:[bundle localizedStringForKey:@"SETTINGS_IMPORT_CONFIRM_TITLE"]
                         message:[bundle localizedStringForKey:@"SETTINGS_IMPORT_CONFIRM_MESSAGE"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"CANCEL_ACTION_LABEL"]
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak PresetsSettingsViewController* weakSelf = self;
    [alert addAction:[UIAlertAction
                         actionWithTitle:[bundle localizedStringForKey:@"SETTINGS_IMPORT_CONFIRM_BUTTON"]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     [weakSelf applyImportFromCode:code];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyImportFromCode:(NSString*)code {
    NSError* error = nil;
    NSInteger applied = [BHTSettingsTransfer importSettingsFromBase64String:code error:&error];
    if (applied < 0) {
        [self showAlertWithTitleKey:@"SETTINGS_IMPORT_FAILED_TITLE" message:error.localizedDescription];
        return;
    }
    [self updateVisibleToggles];
    [self.tableView reloadData];
    NSString* format = [self localized:@"SETTINGS_CODE_RESTORED"];
    [self showToast:[NSString stringWithFormat:format, (long)applied]];
}

#pragma mark - Document Picker

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    NSString* purpose = objc_getAssociatedObject(controller, &kPickerPurposeKey);
    // An export reports the location it saved to, which there is nothing to do
    // with.
    if (![purpose isEqualToString:kPickerPurposeImport] || urls.firstObject == nil) {
        return;
    }
    [self applyImportFromURL:urls.firstObject];
}

@end
