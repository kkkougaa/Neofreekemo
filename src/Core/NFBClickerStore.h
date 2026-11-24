//
//  NFBClickerStore.h
//  NeoFreeBird
//

#import <Foundation/Foundation.h>

// The clicker characters the user brought in: each is the original BUG Clicker .cvclk,
// kept as is (still locked) in Application Support/NFBClicker. The character page opens it
// with the desktop importer (Clicker/ios-import.js) every time it shows it.
//
// kemo_clicker_chars   [{id, label, names: [..], locked, error}]
// kemo_clicker_char    id of the chosen file, "" for the built-in character
// kemo_clicker_char_index  which character inside that file
@interface NFBClickerStore : NSObject

+ (NSArray<NSDictionary*>*)entries;
// Copies the file in. Returns the new entry's id, or nil with a reason.
+ (NSString*)importFileAtURL:(NSURL*)url error:(NSString**)error;
+ (void)removeEntry:(NSString*)entryId;
+ (void)selectEntry:(NSString*)entryId index:(NSInteger)index;
+ (NSString*)selectedEntry;
+ (NSInteger)selectedIndex;
+ (NSData*)fileForEntry:(NSString*)entryId;
// What the page learned after opening a file: the names inside, or why it failed.
+ (void)noteEntry:(NSString*)entryId names:(NSArray<NSString*>*)names locked:(BOOL)locked error:(NSString*)error;
// The chosen character's name, for the settings row.
+ (NSString*)selectedLabel;

@end
