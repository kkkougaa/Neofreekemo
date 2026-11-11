//
//  TFSArrayForKeyFix.m
//  NeoFreeBird
//
//  XServiceLibraries' -[NSBundle tfs_clientPrimaryScheme] calls
//  -_tfs_arrayForKey: on [NSBundle mainBundle].infoDictionary, but the app only
//  defines that method in an NSMutableDictionary category (TFSAdditions).
//  infoDictionary is an immutable __NSFrozenDictionaryM, so the call throws
//  "unrecognized selector" and aborts. TwitterNotifications reaches this path,
//  which is why it shows up once push notifications work.
//
//  Add the missing method to NSDictionary only. class_addMethod does nothing if
//  NSDictionary already implements it, and NSMutableDictionary keeps its own
//  implementation.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static id nfb_tfs_arrayForKey(id self, SEL _cmd, id key) {
    id value = [self objectForKey:key];
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

__attribute__((constructor)) static void NFBAddTFSArrayForKey(void) {
    class_addMethod([NSDictionary class], NSSelectorFromString(@"_tfs_arrayForKey:"),
                    (IMP)nfb_tfs_arrayForKey, "@@:@");
}
