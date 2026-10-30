//
//  BHTAvatars.m
//  NeoFreeBird
//

#import "Core/BHTAvatars.h"

@implementation BHTAvatars

+ (NSURL*)directory {
    NSURL* caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                            inDomains:NSUserDomainMask] firstObject];
    NSURL* directory = [caches URLByAppendingPathComponent:@"nfb_avatars" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return directory;
}

+ (NSMutableSet<NSString*>*)pending {
    static NSMutableSet<NSString*>* pending;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pending = [NSMutableSet set];
    });
    return pending;
}

// Handles whose download failed, with when: not retried for a few minutes.
+ (NSMutableDictionary<NSString*, NSDate*>*)failures {
    static NSMutableDictionary<NSString*, NSDate*>* failures;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        failures = [NSMutableDictionary dictionary];
    });
    return failures;
}

+ (NSCache<NSString*, UIImage*>*)memory {
    static NSCache<NSString*, UIImage*>* memory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        memory = [NSCache new];
    });
    return memory;
}

+ (UIImage*)imageForHandle:(NSString*)handle completion:(void (^)(void))completion {
    if (handle.length == 0) {
        return nil;
    }
    NSString* key = handle.lowercaseString;
    UIImage* cached = [[self memory] objectForKey:key];
    if (cached) {
        return cached;
    }

    NSURL* file = [[self directory] URLByAppendingPathComponent:[key stringByAppendingString:@".img"]];
    NSData* stored = [NSData dataWithContentsOfURL:file];
    UIImage* fromDisk = stored ? [UIImage imageWithData:stored] : nil;
    if (fromDisk) {
        [[self memory] setObject:fromDisk forKey:key];
        return fromDisk;
    }

    NSDate* failedAt = [self failures][key];
    if ([[self pending] containsObject:key] || (failedAt && -[failedAt timeIntervalSinceNow] < 300)) {
        return nil;
    }
    [[self pending] addObject:key];

    NSString* encoded =
        [key stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL* url = [NSURL URLWithString:[@"https://unavatar.io/x/" stringByAppendingString:encoded]];
    [[[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
          UIImage* image = data.length > 0 ? [UIImage imageWithData:data] : nil;
          dispatch_async(dispatch_get_main_queue(), ^{
              [[self pending] removeObject:key];
              if (!image) {
                  [self failures][key] = [NSDate date];
                  return;
              }
              [data writeToURL:file atomically:YES];
              [[self memory] setObject:image forKey:key];
              if (completion) {
                  completion();
              }
          });
      }] resume];
    return nil;
}

@end
