//
//  TimelineProbe.x
//  NeoFreeBird
//
//  Groundwork for a unified (multi-account) home timeline. With the shake dump
//  on, records the shape of the app's own GraphQL timeline traffic: which
//  operation, which query parameters and header names, and a type-only outline
//  of the response JSON. No values that identify the user or carry credentials
//  are kept: header values, variables' values and JSON leaf values are dropped.
//

#import "HookHelpers.h"

extern BOOL NFBUnifiedProbeActive(void);

static NSMutableDictionary<NSString*, NSString*>* gProbeByOperation;
static NSMutableArray<NSString*>* gProbeOrder;
static NSMutableArray<NSString*>* gProbeLog;

static const NSUInteger kOutlineLimit = 6000;
static const int kOutlineDepth = 14;

static BOOL IsTimelineOperation(NSString* operation) {
    return [operation rangeOfString:@"Timeline" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString* LeafType(id value) {
    if ([value isKindOfClass:[NSString class]]) return @"str";
    if ([value isKindOfClass:[NSNumber class]]) {
        return strcmp([value objCType], @encode(BOOL)) == 0 || [value class] == [@YES class] ? @"bool" : @"num";
    }
    if (value == [NSNull null]) return @"null";
    return NSStringFromClass([value class]);
}

// Keys sorted, arrays show their length and their first element only (for entry
// arrays, also the first element whose content looks like a tweet).
static void Outline(id node, int depth, NSMutableString* out) {
    if (out.length > kOutlineLimit) {
        return;
    }
    NSString* pad = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
    if ([node isKindOfClass:[NSDictionary class]]) {
        if (depth >= kOutlineDepth) {
            [out appendFormat:@"%@{…%lu keys}\n", pad, (unsigned long)[node count]];
            return;
        }
        for (NSString* key in [[node allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            id value = node[key];
            if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
                [out appendFormat:@"%@%@:\n", pad, key];
                Outline(value, depth + 1, out);
            } else if ([value isKindOfClass:[NSString class]] &&
                       ([key isEqualToString:@"__typename"] || [key isEqualToString:@"type"] ||
                        [key isEqualToString:@"entryType"] || [key isEqualToString:@"entry_type"] ||
                        [key isEqualToString:@"cursorType"] || [key isEqualToString:@"cursor_type"] ||
                        [key isEqualToString:@"itemType"] || [key isEqualToString:@"item_type"] ||
                        [key isEqualToString:@"tweetDisplayType"] || [key isEqualToString:@"tweet_display_type"])) {
                // Structural tags only, never user content.
                NSString* tag = [value length] > 40 ? [value substringToIndex:40] : value;
                [out appendFormat:@"%@%@ = \"%@\"\n", pad, key, tag];
            } else if ([key isEqualToString:@"entryId"] || [key isEqualToString:@"entry_id"]) {
                // Keep the prefix (tweet-, cursor-top-, promoted-tweet-...), drop the ID.
                NSString* text = [value isKindOfClass:[NSString class]] ? value : @"";
                NSRange digits = [text rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]];
                NSString* prefix = digits.location == NSNotFound ? text : [text substringToIndex:digits.location];
                [out appendFormat:@"%@%@ = \"%@…\"\n", pad, key, prefix];
            } else {
                [out appendFormat:@"%@%@: %@\n", pad, key, LeafType(value)];
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        NSArray* array = node;
        [out appendFormat:@"%@[%lu]\n", pad, (unsigned long)array.count];
        if (array.count > 0) {
            Outline(array.firstObject, depth + 1, out);
        }
        // An entries array starts with a cursor or a module; show one tweet entry too.
        for (NSUInteger i = 1; i < array.count; i++) {
            id item = array[i];
            NSString* entryID = [item isKindOfClass:[NSDictionary class]]
                                    ? (item[@"entryId"] ?: item[@"entry_id"])
                                    : nil;
            if ([entryID isKindOfClass:[NSString class]] && [entryID hasPrefix:@"tweet-"]) {
                [out appendFormat:@"%@[#%lu, first tweet entry]\n", pad, (unsigned long)i];
                Outline(item, depth + 1, out);
                break;
            }
        }
    } else {
        [out appendFormat:@"%@%@\n", pad, LeafType(node)];
    }
}

// Entry ID prefixes in order, e.g. "cursor-top tweet x18 promoted-tweet x2 cursor-bottom".
static void CollectEntryIDs(id node, NSMutableArray<NSString*>* ids) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        id entryID = node[@"entryId"] ?: node[@"entry_id"];
        if ([entryID isKindOfClass:[NSString class]]) {
            [ids addObject:entryID];
            return;
        }
        for (id value in [node allValues]) {
            CollectEntryIDs(value, ids);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in node) {
            CollectEntryIDs(value, ids);
        }
    }
}

static NSString* EntrySummary(id json) {
    NSMutableArray<NSString*>* ids = [NSMutableArray array];
    CollectEntryIDs(json, ids);
    NSMutableArray<NSString*>* runs = [NSMutableArray array];
    NSString* last = nil;
    NSUInteger count = 0;
    for (NSString* entryID in ids) {
        NSRange digits = [entryID rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]];
        NSString* prefix = digits.location == NSNotFound ? entryID : [entryID substringToIndex:digits.location];
        if ([prefix hasSuffix:@"-"]) prefix = [prefix substringToIndex:prefix.length - 1];
        if ([prefix isEqualToString:last]) {
            count++;
            continue;
        }
        if (last) [runs addObject:count > 1 ? [NSString stringWithFormat:@"%@ x%lu", last, (unsigned long)count] : last];
        last = prefix;
        count = 1;
    }
    if (last) [runs addObject:count > 1 ? [NSString stringWithFormat:@"%@ x%lu", last, (unsigned long)count] : last];
    return [NSString stringWithFormat:@"%lu entries: %@", (unsigned long)ids.count, [runs componentsJoinedByString:@" "]];
}

static NSString* AuthScheme(NSURLRequest* request) {
    NSString* auth = [request valueForHTTPHeaderField:@"Authorization"];
    if (auth.length == 0) return @"none";
    NSRange space = [auth rangeOfString:@" "];
    return space.location == NSNotFound ? @"?" : [auth substringToIndex:space.location];
}

static void RecordTimelineResponse(NSURLRequest* request, NSURLResponse* response, NSData* data, NSInteger source) {
    NSArray* parts = request.URL.path.pathComponents;
    NSUInteger graphql = [parts indexOfObject:@"graphql"];
    if (graphql == NSNotFound || graphql + 2 >= parts.count) {
        return;
    }
    NSString* operation = parts.lastObject;
    if (!IsTimelineOperation(operation)) {
        return;
    }
    NSString* queryID = parts[graphql + 1];

    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse*)response).statusCode : -1;
    NSMutableString* out = [NSMutableString string];
    [out appendFormat:@"%@ host=%@ %@ queryId=%@ status=%ld %lu B source=%ld auth=%@\n", request.HTTPMethod ?: @"GET",
                      request.URL.host, request.URL.path, queryID, (long)status, (unsigned long)data.length,
                      (long)source, AuthScheme(request)];
    [out appendFormat:@"headers: %@\n",
                      [[request.allHTTPHeaderFields.allKeys sortedArrayUsingSelector:@selector(compare:)]
                          componentsJoinedByString:@" "]];

    NSURLComponents* components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem* item in components.queryItems) {
        id parsed = [item.value dataUsingEncoding:NSUTF8StringEncoding]
                        ? [NSJSONSerialization JSONObjectWithData:[item.value dataUsingEncoding:NSUTF8StringEncoding]
                                                          options:0
                                                            error:nil]
                        : nil;
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            // variables / features: key names and value types only.
            NSMutableArray* keys = [NSMutableArray array];
            for (NSString* key in [[parsed allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                [keys addObject:[NSString stringWithFormat:@"%@:%@", key, LeafType(parsed[key])]];
            }
            [out appendFormat:@"query %@ {%@}\n", item.name, [keys componentsJoinedByString:@" "]];
        } else {
            [out appendFormat:@"query %@ (%lu chars)\n", item.name, (unsigned long)item.value.length];
        }
    }
    if (request.HTTPBody.length) {
        [out appendFormat:@"body %lu B\n", (unsigned long)request.HTTPBody.length];
    }

    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (json) {
        [out appendFormat:@"%@\n", EntrySummary(json)];
        Outline(json, 0, out);
        if (out.length > kOutlineLimit) [out appendString:@"…(cut)\n"];
    } else if (data.length) {
        [out appendFormat:@"not JSON, first bytes %@\n",
                          [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, 40))]
                                                encoding:NSUTF8StringEncoding] ?: @"(binary)"];
    }

    static NSDateFormatter* formatter;
    @synchronized([NSObject class]) {
        if (!gProbeByOperation) {
            gProbeByOperation = [NSMutableDictionary dictionary];
            gProbeOrder = [NSMutableArray array];
            gProbeLog = [NSMutableArray array];
            formatter = [NSDateFormatter new];
            formatter.dateFormat = @"HH:mm:ss";
        }
        [gProbeLog addObject:[NSString stringWithFormat:@"%@ %@ %ld %lu B%@", [formatter stringFromDate:[NSDate date]],
                                                        operation, (long)status, (unsigned long)data.length,
                                                        NFBUnifiedProbeActive() ? @" [during probe]" : @""]];
        if (gProbeLog.count > 30) [gProbeLog removeObjectAtIndex:0];
        gProbeByOperation[operation] = out;
        [gProbeOrder removeObject:operation];
        [gProbeOrder addObject:operation];
        if (gProbeOrder.count > 4) {
            [gProbeByOperation removeObjectForKey:gProbeOrder.firstObject];
            [gProbeOrder removeObjectAtIndex:0];
        }
    }
}

NSString* NFBTimelineProbeText(void) {
    @synchronized([NSObject class]) {
        if (gProbeOrder.count == 0) {
            return @"(no timeline requests recorded; scroll or refresh Home first)";
        }
        NSMutableString* out = [NSMutableString string];
        [out appendFormat:@"recent:\n%@\n", [gProbeLog componentsJoinedByString:@"\n"]];
        // Home timelines first, they are what the unified timeline builds on.
        NSArray* order = [gProbeOrder sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
            return [@([b hasPrefix:@"Home"]) compare:@([a hasPrefix:@"Home"])];
        }];
        for (NSString* operation in order) {
            [out appendFormat:@"--- %@ ---\n%@", operation, gProbeByOperation[operation]];
        }
        return out;
    }
}

%hook TNLResponseInfo

- (instancetype)initWithFinalURLRequest:(NSURLRequest*)request
                            URLResponse:(NSURLResponse*)response
                                 source:(NSInteger)source
                                   data:(NSData*)data
                     temporarySavedFile:(id)temporarySavedFile {
    if ([BHTSettings boolForKey:@"kemo_shake_dump"] && request.URL) {
        @try {
            RecordTimelineResponse(request, response, data, source);
        } @catch (__unused NSException* exception) {
        }
    }
    return %orig;
}

%end
