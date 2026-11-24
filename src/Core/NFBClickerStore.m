//
//  NFBClickerStore.m
//  NeoFreeBird
//

#import "Core/NFBClickerStore.h"
#import "Core/BHTBundle.h"

static NSString* const kEntriesKey = @"kemo_clicker_chars";
static NSString* const kSelectedKey = @"kemo_clicker_char";
static NSString* const kIndexKey = @"kemo_clicker_char_index";
static NSString* const kLabelKey = @"kemo_clicker_char_label";
static const NSUInteger kMaxFile = 200 * 1024 * 1024;

@implementation NFBClickerStore

+ (NSURL*)directory {
    NSURL* base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSURL* dir = [base URLByAppendingPathComponent:@"NFBClicker" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSURL*)urlForEntry:(NSString*)entryId {
    if (entryId.length == 0 || [entryId containsString:@"/"] || [entryId hasPrefix:@"."]) {
        return nil;
    }
    return [[self directory] URLByAppendingPathComponent:[entryId stringByAppendingPathExtension:@"cvclk"]];
}

+ (NSArray<NSDictionary*>*)entries {
    NSArray* list = [[NSUserDefaults standardUserDefaults] arrayForKey:kEntriesKey];
    NSMutableArray* out = [NSMutableArray array];
    for (id e in list) {
        if ([e isKindOfClass:[NSDictionary class]] && [e[@"id"] isKindOfClass:[NSString class]]) {
            [out addObject:e];
        }
    }
    return out;
}

+ (void)saveEntries:(NSArray*)entries {
    [[NSUserDefaults standardUserDefaults] setObject:entries forKey:kEntriesKey];
}

+ (NSString*)importFileAtURL:(NSURL*)url error:(NSString**)error {
    BHTBundle* bundle = [BHTBundle sharedBundle];
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData* data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }
    if (data.length < 12 || data.length > kMaxFile) {
        if (error) *error = [bundle localizedStringForKey:@"KEMO_CLICKER_IMPORT_BAD"];
        return nil;
    }
    const char* head = data.bytes;
    BOOL locked = memcmp(head, "BCVCLK2\n", 8) == 0;
    BOOL parts = memcmp(head, "BCVPART1", 8) == 0;
    // The older, unlocked .cvclk is plain JSON (maybe after a BOM).
    NSUInteger skip = data.length >= 3 && memcmp(head, "\xEF\xBB\xBF", 3) == 0 ? 3 : 0;
    BOOL json = head[skip] == '{';
    if (parts) {
        if (error) *error = [bundle localizedStringForKey:@"KEMO_CLICKER_IMPORT_PARTS"];
        return nil;
    }
    if (!locked && !json) {
        if (error) *error = [bundle localizedStringForKey:@"KEMO_CLICKER_IMPORT_BAD"];
        return nil;
    }
    NSString* entryId = [[NSUUID UUID].UUIDString lowercaseString];
    if (![data writeToURL:[self urlForEntry:entryId] options:NSDataWritingAtomic error:nil]) {
        if (error) *error = [bundle localizedStringForKey:@"KEMO_CLICKER_IMPORT_BAD"];
        return nil;
    }
    NSString* label = url.lastPathComponent.stringByDeletingPathExtension ?: entryId;
    NSMutableArray* list = [[self entries] mutableCopy];
    [list addObject:@{@"id": entryId, @"label": label, @"names": @[], @"locked": @NO, @"error": @""}];
    [self saveEntries:list];
    return entryId;
}

+ (void)removeEntry:(NSString*)entryId {
    NSURL* file = [self urlForEntry:entryId];
    if (file) {
        [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
    }
    NSMutableArray* list = [NSMutableArray array];
    for (NSDictionary* e in [self entries]) {
        if (![e[@"id"] isEqualToString:entryId]) {
            [list addObject:e];
        }
    }
    [self saveEntries:list];
    if ([[self selectedEntry] isEqualToString:entryId]) {
        [self selectEntry:@"" index:0];
    }
}

+ (void)selectEntry:(NSString*)entryId index:(NSInteger)index {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d setObject:entryId ?: @"" forKey:kSelectedKey];
    [d setInteger:MAX(0, index) forKey:kIndexKey];
    [d setObject:[self labelFor:entryId index:index] forKey:kLabelKey];
}

+ (NSString*)selectedEntry {
    NSString* s = [[NSUserDefaults standardUserDefaults] stringForKey:kSelectedKey] ?: @"";
    return s.length && [self urlForEntry:s] && [[NSFileManager defaultManager] fileExistsAtPath:[self urlForEntry:s].path]
               ? s
               : @"";
}

+ (NSInteger)selectedIndex {
    return MAX(0, [[NSUserDefaults standardUserDefaults] integerForKey:kIndexKey]);
}

+ (NSData*)fileForEntry:(NSString*)entryId {
    NSURL* file = [self urlForEntry:entryId];
    return file ? [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil] : nil;
}

+ (NSDictionary*)entry:(NSString*)entryId {
    for (NSDictionary* e in [self entries]) {
        if ([e[@"id"] isEqualToString:entryId]) {
            return e;
        }
    }
    return nil;
}

+ (NSString*)labelFor:(NSString*)entryId index:(NSInteger)index {
    if (entryId.length == 0) {
        return [[BHTBundle sharedBundle] localizedStringForKey:@"KEMO_CLICKER_DEFAULT_CHARACTER"];
    }
    NSDictionary* e = [self entry:entryId];
    NSArray* names = [e[@"names"] isKindOfClass:[NSArray class]] ? e[@"names"] : @[];
    if (index >= 0 && index < (NSInteger)names.count && [names[index] isKindOfClass:[NSString class]]) {
        return names[index];
    }
    return e[@"label"] ?: entryId;
}

+ (NSString*)selectedLabel {
    return [self labelFor:[self selectedEntry] index:[self selectedIndex]];
}

+ (void)noteEntry:(NSString*)entryId names:(NSArray<NSString*>*)names locked:(BOOL)locked error:(NSString*)error {
    NSMutableArray* list = [NSMutableArray array];
    BOOL changed = NO;
    for (NSDictionary* e in [self entries]) {
        if (![e[@"id"] isEqualToString:entryId]) {
            [list addObject:e];
            continue;
        }
        NSMutableDictionary* m = [e mutableCopy];
        NSMutableArray* clean = [NSMutableArray array];
        for (id n in names) {
            if ([n isKindOfClass:[NSString class]]) {
                [clean addObject:[n length] > 60 ? [n substringToIndex:60] : n];
            }
        }
        if (clean.count) {
            m[@"names"] = clean;
        }
        m[@"locked"] = @(locked);
        m[@"error"] = error ?: @"";
        changed = changed || ![m isEqualToDictionary:e];
        [list addObject:m];
    }
    if (!changed) {
        return;
    }
    [self saveEntries:list];
    if ([[self selectedEntry] isEqualToString:entryId]) {
        [[NSUserDefaults standardUserDefaults] setObject:[self selectedLabel] forKey:kLabelKey];
    }
}

@end
