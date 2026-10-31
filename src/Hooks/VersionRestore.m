//
//  VersionRestore.m
//  NeoFreeBird
//
//  SideStore compares the IPA's version with the source, so the sideloaded
//  build stamps CFBundleShortVersionString / CFBundleVersion down to the tweak
//  version (7.3.x). X Chat refuses a client that announces that version.
//  The real X version is kept under NFBOriginal* and reported at runtime.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static IMP nfb_origInfoKey;
static IMP nfb_origInfoDict;
static NSDictionary* nfb_patchedInfo;

static id nfb_objectForInfoDictionaryKey(id self, SEL _cmd, NSString* key) {
    id (*orig)(id, SEL, NSString*) = (id (*)(id, SEL, NSString*))nfb_origInfoKey;
    if (self == [NSBundle mainBundle] && [key isKindOfClass:[NSString class]]) {
        NSString* savedKey = nil;
        if ([key isEqualToString:@"CFBundleShortVersionString"]) {
            savedKey = @"NFBOriginalShortVersion";
        } else if ([key isEqualToString:@"CFBundleVersion"]) {
            savedKey = @"NFBOriginalBundleVersion";
        }
        if (savedKey) {
            id saved = orig(self, _cmd, savedKey);
            if ([saved isKindOfClass:[NSString class]] && [(NSString*)saved length] > 0) {
                return saved;
            }
        }
    }
    return orig(self, _cmd, key);
}

static NSDictionary* nfb_infoDictionary(id self, SEL _cmd) {
    NSDictionary* (*orig)(id, SEL) = (NSDictionary * (*)(id, SEL))nfb_origInfoDict;
    NSDictionary* dict = orig(self, _cmd);
    if (self != [NSBundle mainBundle]) {
        return dict;
    }
    NSString* shortVersion = dict[@"NFBOriginalShortVersion"];
    if (![shortVersion isKindOfClass:[NSString class]] || shortVersion.length == 0) {
        return dict;
    }
    if (!nfb_patchedInfo) {
        NSMutableDictionary* copy = [dict mutableCopy];
        copy[@"CFBundleShortVersionString"] = shortVersion;
        NSString* buildVersion = dict[@"NFBOriginalBundleVersion"];
        if ([buildVersion isKindOfClass:[NSString class]] && buildVersion.length > 0) {
            copy[@"CFBundleVersion"] = buildVersion;
        }
        nfb_patchedInfo = [copy copy];
    }
    return nfb_patchedInfo;
}

@interface NFBVersionRestore : NSObject
@end

@implementation NFBVersionRestore

+ (void)load {
    Class bundle = [NSBundle class];
    Method keyMethod = class_getInstanceMethod(bundle, @selector(objectForInfoDictionaryKey:));
    Method dictMethod = class_getInstanceMethod(bundle, @selector(infoDictionary));
    if (keyMethod) {
        nfb_origInfoKey = method_getImplementation(keyMethod);
        method_setImplementation(keyMethod, (IMP)nfb_objectForInfoDictionaryKey);
    }
    if (dictMethod) {
        nfb_origInfoDict = method_getImplementation(dictMethod);
        method_setImplementation(dictMethod, (IMP)nfb_infoDictionary);
    }
}

@end
