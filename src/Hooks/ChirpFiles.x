//
//  ChirpFiles.x
//  NeoFreeBird
//
//  The user's fonts in Chirp's place (see Core/NFBChirpFonts.h).
//
//  X (12.44) registers the Chirp files of TwitterSharedResources_TFNUIAppResources.bundle
//  with CTFontManagerRegisterGraphicsFont and asks for them by PostScript name:
//  Chirp-Light/Regular/Medium/Bold/Heavy, ChirpUIVF202601 and its named
//  instances ChirpUIVF-{XS,S,M,L}{Light,Regular,Medium,Bold,Heavy} (names read
//  from XServiceLibraries). Each picked font is copied once per name with its
//  'name' table rewritten to that name, and those copies are registered when
//  this library loads, before X registers its own. X's registration of a name
//  that is already taken fails, so UIFont hands back the user's font.
//
//  A launch that dies while this is in effect turns it off for the next launch.
//

#import <CoreText/CoreText.h>
#import "Core/NFBChirpFonts.h"
#import "HookHelpers.h"

NSString* const NFBChirpSlotLight = @"light";
NSString* const NFBChirpSlotRegular = @"regular";
NSString* const NFBChirpSlotMedium = @"medium";
NSString* const NFBChirpSlotBold = @"bold";
NSString* const NFBChirpSlotHeavy = @"heavy";

static NSString* const kGuardKey = @"kemo_chirp_fonts_launching";
static NSString* const kSkippedKey = @"kemo_chirp_fonts_skipped";

static NSMutableArray<NSString*>* gRegistered;
static NSMutableArray<NSString*>* gFailed;
static NSString* gState = @"off";

NSString* NFBChirpSlotNameKey(NSString* slot) {
    return [@"kemo_chirp_font_name_" stringByAppendingString:slot];
}

static NSArray<NSString*>* AllSlots(void) {
    return @[ NFBChirpSlotLight, NFBChirpSlotRegular, NFBChirpSlotMedium, NFBChirpSlotBold, NFBChirpSlotHeavy ];
}

static NSString* FontsFolder(void) {
    NSString* support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"NFBChirpFonts"];
}

static NSString* SlotFolder(NSString* slot) {
    return [FontsFolder() stringByAppendingPathComponent:slot];
}

// PostScript name -> (slot, family, style). Style is what the name table says.
static NSDictionary<NSString*, NSArray<NSString*>*>* Targets(void) {
    static NSDictionary* targets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary* map = [NSMutableDictionary dictionary];
        map[@"Chirp-Light"] = @[ NFBChirpSlotLight, @"Chirp Light", @"Regular" ];
        map[@"Chirp-Regular"] = @[ NFBChirpSlotRegular, @"Chirp", @"Regular" ];
        map[@"Chirp-Medium"] = @[ NFBChirpSlotMedium, @"Chirp Medium", @"Regular" ];
        map[@"Chirp-Bold"] = @[ NFBChirpSlotBold, @"Chirp", @"Bold" ];
        map[@"Chirp-Heavy"] = @[ NFBChirpSlotHeavy, @"Chirp Heavy", @"Regular" ];
        map[@"ChirpUIVF202601"] = @[ NFBChirpSlotRegular, @"Chirp UI VF 202601", @"Regular" ];
        NSDictionary* weights = @{
            @"Light": NFBChirpSlotLight, @"Regular": NFBChirpSlotRegular, @"Medium": NFBChirpSlotMedium,
            @"Bold": NFBChirpSlotBold, @"Heavy": NFBChirpSlotHeavy
        };
        for (NSString* size in @[ @"XS", @"S", @"M", @"L" ]) {
            [weights enumerateKeysAndObjectsUsingBlock:^(NSString* weight, NSString* slot, BOOL* stop) {
                NSString* ps = [NSString stringWithFormat:@"ChirpUIVF-%@%@", size, weight];
                map[ps] = @[ slot, @"Chirp UI VF 202601", [size stringByAppendingString:weight] ];
            }];
        }
        targets = map;
    });
    return targets;
}

// The slot whose file stands in for `slot` when it has none of its own. The
// settings only offer Regular and Bold (as the old picker did): Light and
// Medium are drawn with Regular, Heavy with Bold.
static NSString* ResolvedSlot(NSString* slot, NSSet<NSString*>* present) {
    NSDictionary* order = @{
        NFBChirpSlotLight: @[ NFBChirpSlotLight, NFBChirpSlotRegular ],
        NFBChirpSlotRegular: @[ NFBChirpSlotRegular ],
        NFBChirpSlotMedium: @[ NFBChirpSlotMedium, NFBChirpSlotRegular ],
        NFBChirpSlotBold: @[ NFBChirpSlotBold, NFBChirpSlotRegular ],
        NFBChirpSlotHeavy: @[ NFBChirpSlotHeavy, NFBChirpSlotBold, NFBChirpSlotRegular ],
    };
    for (NSString* candidate in order[slot]) {
        if ([present containsObject:candidate]) return candidate;
    }
    return nil;
}

// MARK: - Renaming

static uint16_t Read16(const uint8_t* p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t Read32(const uint8_t* p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static void Write16(uint8_t* p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xff; }
static void Write32(uint8_t* p, uint32_t v) { p[0] = v >> 24; p[1] = (v >> 16) & 0xff; p[2] = (v >> 8) & 0xff; p[3] = v & 0xff; }

static uint32_t TableChecksum(const uint8_t* bytes, NSUInteger length) {
    uint32_t sum = 0;
    for (NSUInteger i = 0; i < length; i += 4) {
        uint8_t word[4] = {0, 0, 0, 0};
        for (NSUInteger k = 0; k < 4 && i + k < length; k++) word[k] = bytes[i + k];
        sum += Read32(word);
    }
    return sum;
}

static NSData* NameTable(NSString* family, NSString* style, NSString* ps) {
    NSString* full = [style isEqualToString:@"Regular"] ? family : [NSString stringWithFormat:@"%@ %@", family, style];
    NSArray* records = @[
        @[ @1, family ], @[ @2, style ], @[ @3, [ps stringByAppendingString:@";neofreebird"] ], @[ @4, full ], @[ @6, ps ]
    ];
    NSMutableData* strings = [NSMutableData data];
    NSMutableData* table = [NSMutableData dataWithLength:6 + 12 * records.count];
    uint8_t* head = table.mutableBytes;
    Write16(head, 0);
    Write16(head + 2, (uint16_t)records.count);
    Write16(head + 4, (uint16_t)(6 + 12 * records.count));
    for (NSUInteger i = 0; i < records.count; i++) {
        NSData* text = [records[i][1] dataUsingEncoding:NSUTF16BigEndianStringEncoding];
        uint8_t* r = head + 6 + 12 * i;
        Write16(r, 3);
        Write16(r + 2, 1);
        Write16(r + 4, 0x409);
        Write16(r + 6, [records[i][0] unsignedShortValue]);
        Write16(r + 8, (uint16_t)text.length);
        Write16(r + 10, (uint16_t)strings.length);
        [strings appendData:text];
    }
    [table appendData:strings];
    return table;
}

// The font with its 'name' table replaced by one that names it `ps`. The new
// table goes at the end; only its directory entry changes.
static NSData* RenamedFont(NSData* source, NSString* family, NSString* style, NSString* ps) {
    const uint8_t* bytes = source.bytes;
    if (source.length < 12) return nil;
    uint32_t version = Read32(bytes);
    if (version != 0x00010000 && version != 'OTTO' && version != 'true') return nil;
    uint16_t count = Read16(bytes + 4);
    if (source.length < 12 + 16 * (NSUInteger)count) return nil;
    NSInteger nameEntry = -1;
    for (uint16_t i = 0; i < count; i++) {
        if (Read32(bytes + 12 + 16 * i) == 'name') nameEntry = i;
    }
    if (nameEntry < 0) return nil;

    NSMutableData* out = [source mutableCopy];
    while (out.length % 4) [out appendBytes:"\0" length:1];
    NSUInteger offset = out.length;
    NSData* name = NameTable(family, style, ps);
    [out appendData:name];
    while (out.length % 4) [out appendBytes:"\0" length:1];
    uint8_t* entry = (uint8_t*)out.mutableBytes + 12 + 16 * nameEntry;
    Write32(entry + 4, TableChecksum(name.bytes, name.length));
    Write32(entry + 8, (uint32_t)offset);
    Write32(entry + 12, (uint32_t)name.length);
    return out;
}

static NSString* PostScriptNameOf(NSData* data) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) return nil;
    CGFontRef font = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (!font) return nil;
    NSString* ps = (__bridge_transfer NSString*)CGFontCopyPostScriptName(font);
    CGFontRelease(font);
    return ps;
}

static NSString* FullNameOf(NSData* data) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) return nil;
    CGFontRef cg = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (!cg) return nil;
    CTFontRef font = CTFontCreateWithGraphicsFont(cg, 12, NULL, NULL);
    CGFontRelease(cg);
    if (!font) return nil;
    NSString* full = (__bridge_transfer NSString*)CTFontCopyFullName(font);
    CFRelease(font);
    return full;
}

// MARK: - Import

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

BOOL NFBChirpImportFont(NSURL* url, NSString* slot, NSString** message) {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData* data = [NSData dataWithContentsOfURL:url options:0 error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (data.length < 12) {
        if (message) *message = L(@"KEMO_CHIRP_FONT_ERROR_READ");
        return NO;
    }
    uint32_t tag = Read32(data.bytes);
    if (tag == 'ttcf') {
        if (message) *message = L(@"KEMO_CHIRP_FONT_ERROR_COLLECTION");
        return NO;
    }
    if (tag == 'wOFF' || tag == 'wOF2') {
        if (message) *message = L(@"KEMO_CHIRP_FONT_ERROR_WOFF");
        return NO;
    }
    NSString* fullName = FullNameOf(data);
    if (!fullName) {
        if (message) *message = L(@"KEMO_CHIRP_FONT_ERROR_OPEN");
        return NO;
    }
    // Check the renaming works on this file before keeping anything.
    NSData* probe = RenamedFont(data, @"Chirp", @"Regular", @"Chirp-Regular");
    if (!probe || ![PostScriptNameOf(probe) isEqualToString:@"Chirp-Regular"]) {
        if (message) *message = L(@"KEMO_CHIRP_FONT_ERROR_RENAME");
        return NO;
    }

    NSFileManager* files = [NSFileManager defaultManager];
    NSString* folder = SlotFolder(slot);
    [files removeItemAtPath:folder error:nil];
    [files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:[folder stringByAppendingPathComponent:@"source.font"] atomically:YES];
    [[NSUserDefaults standardUserDefaults] setObject:fullName forKey:NFBChirpSlotNameKey(slot)];
    // Chirp-named copies are made for every name this slot serves, now or
    // through a missing slot; rebuild them all so a new slot takes its names over.
    NSSet* present = [NSSet setWithArray:[AllSlots() filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSString* s, id bindings) {
            return [files fileExistsAtPath:[SlotFolder(s) stringByAppendingPathComponent:@"source.font"]];
        }]]];
    NSString* built = [FontsFolder() stringByAppendingPathComponent:@"built"];
    [files removeItemAtPath:built error:nil];
    [files createDirectoryAtPath:built withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary<NSString*, NSData*>* sources = [NSMutableDictionary dictionary];
    [Targets() enumerateKeysAndObjectsUsingBlock:^(NSString* ps, NSArray<NSString*>* info, BOOL* stop) {
        NSString* from = ResolvedSlot(info[0], present);
        if (!from) return;
        NSData* source = sources[from];
        if (!source) {
            source = [NSData dataWithContentsOfFile:[SlotFolder(from) stringByAppendingPathComponent:@"source.font"]
                                            options:NSDataReadingMappedIfSafe
                                              error:nil];
            if (!source) return;
            sources[from] = source;
        }
        NSData* renamed = RenamedFont(source, info[1], info[2], ps);
        [renamed writeToFile:[built stringByAppendingPathComponent:[ps stringByAppendingString:@".font"]] atomically:YES];
    }];
    if (message) *message = nil;
    return YES;
}

void NFBChirpResetFonts(void) {
    [[NSFileManager defaultManager] removeItemAtPath:FontsFolder() error:nil];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    for (NSString* slot in AllSlots()) [defaults removeObjectForKey:NFBChirpSlotNameKey(slot)];
}

// MARK: - Launch

static void RegisterBuiltFonts(void) {
    NSString* built = [FontsFolder() stringByAppendingPathComponent:@"built"];
    NSArray* names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:built error:nil];
    if (names.count == 0) {
        gState = @"no fonts";
        return;
    }
    gRegistered = [NSMutableArray array];
    gFailed = [NSMutableArray array];
    for (NSString* file in names) {
        if (![file hasSuffix:@".font"]) continue;
        NSString* ps = [file stringByDeletingPathExtension];
        NSData* data = [NSData dataWithContentsOfFile:[built stringByAppendingPathComponent:file]
                                              options:NSDataReadingMappedIfSafe
                                                error:nil];
        CGDataProviderRef provider = data ? CGDataProviderCreateWithCFData((__bridge CFDataRef)data) : NULL;
        CGFontRef font = provider ? CGFontCreateWithDataProvider(provider) : NULL;
        if (provider) CGDataProviderRelease(provider);
        CFErrorRef error = NULL;
        if (font && CTFontManagerRegisterGraphicsFont(font, &error)) {
            [gRegistered addObject:ps];
        } else {
            [gFailed addObject:[NSString stringWithFormat:@"%@(%ld)", ps, error ? (long)CFErrorGetCode(error) : -1L]];
        }
        if (error) CFRelease(error);
        if (font) CGFontRelease(font);
    }
    gState = @"registered";
}

NSString* NFBChirpFontsDebugText(void) {
    NSMutableString* text = [NSMutableString stringWithFormat:@"userFonts state=%@", gState];
    for (NSString* slot in AllSlots()) {
        NSString* name = [[NSUserDefaults standardUserDefaults] stringForKey:NFBChirpSlotNameKey(slot)];
        if (name) [text appendFormat:@" %@=%@", slot, name];
    }
    if (gRegistered) [text appendFormat:@"\nuserFonts registered=%lu", (unsigned long)gRegistered.count];
    if (gFailed.count) [text appendFormat:@" failed=%@", [gFailed componentsJoinedByString:@","]];
    return text;
}

%ctor {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"kemo_chirp_fonts"]) return;
    if ([defaults boolForKey:kGuardKey]) {
        // The last launch with the user's fonts never got going: start with X's own.
        [defaults setBool:NO forKey:kGuardKey];
        [defaults setBool:YES forKey:kSkippedKey];
        gState = @"skipped after a failed launch";
        return;
    }
    [defaults setBool:YES forKey:kGuardKey];
    [defaults synchronize];
    RegisterBuiltFonts();
    // The launch went through once the app has been on screen for a while.
    __block id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* note) {
                    [[NSNotificationCenter defaultCenter] removeObserver:observer];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                       [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kGuardKey];
                                   });
                }];
}
