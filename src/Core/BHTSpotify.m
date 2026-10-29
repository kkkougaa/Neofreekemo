//
//  BHTSpotify.m
//  NeoFreeBird
//

#import "Core/BHTSpotify.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString* const kClientIDKey = @"spotify_client_id";
static NSString* const kAccessTokenKey = @"nfb_spotify_access_token";
static NSString* const kRefreshTokenKey = @"nfb_spotify_refresh_token";
static NSString* const kExpiryKey = @"nfb_spotify_token_expiry";
static NSString* const kErrorDomain = @"com.neofreebird.spotify";

// The login page sends the user back to a loopback address that this app listens on
// for the length of the login. Custom URL schemes were not being caught by the web
// login session, so the redirect is an ordinary http://127.0.0.1:<port>/callback.
// The dashboard refuses a port-less http redirect as "not secure", so the port is
// fixed and the dashboard entry is http://127.0.0.1:8888/callback.
static NSString* const kRedirectPath = @"/callback";
static const uint16_t kLoopbackPort = 8888;

@interface BHTSpotify () <ASWebAuthenticationPresentationContextProviding>
@property (nonatomic, strong) ASWebAuthenticationSession* session;
@property (nonatomic, strong) dispatch_source_t listener;
@end

@implementation BHTSpotify

+ (instancetype)shared {
    static BHTSpotify* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [BHTSpotify new];
    });
    return shared;
}

#pragma mark - State

- (NSString*)clientID {
    NSString* value = [[NSUserDefaults standardUserDefaults] stringForKey:kClientIDKey];
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (BOOL)isConnected {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kRefreshTokenKey].length > 0;
}

- (void)logout {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kAccessTokenKey];
    [defaults removeObjectForKey:kRefreshTokenKey];
    [defaults removeObjectForKey:kExpiryKey];
}

- (NSError*)errorWithCode:(NSInteger)code message:(NSString*)message {
    return [NSError errorWithDomain:kErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"Spotify error"}];
}

#pragma mark - PKCE

static NSString* Base64URL(NSData* data) {
    NSString* encoded = [data base64EncodedStringWithOptions:0];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSString* RandomString(NSUInteger length) {
    static NSString* const alphabet =
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    NSMutableString* result = [NSMutableString string];
    for (NSUInteger i = 0; i < length; i++) {
        [result appendFormat:@"%C", [alphabet characterAtIndex:arc4random_uniform((uint32_t)alphabet.length)]];
    }
    return result;
}

static NSString* ChallengeForVerifier(NSString* verifier) {
    NSData* input = [verifier dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    return Base64URL([NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH]);
}

#pragma mark - Loopback listener

- (void)stopListener {
    if (self.listener) {
        dispatch_source_cancel(self.listener);
        self.listener = nil;
    }
}

// Listens on 127.0.0.1 on a free port and calls the handler once per request that
// carries a login result. Returns the port, or 0 when the socket couldn't be set up.
- (int)startListenerWithHandler:(void (^)(NSString* code, NSString* state, NSString* errorText))handler {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return 0;
    }
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(kLoopbackPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr*)&address, sizeof(address)) != 0 || listen(fd, 4) != 0) {
        close(fd);
        return 0;
    }
    socklen_t length = sizeof(address);
    getsockname(fd, (struct sockaddr*)&address, &length);
    int port = ntohs(address.sin_port);

    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(source, ^{
        int client = accept(fd, NULL, NULL);
        if (client < 0) {
            return;
        }
        char buffer[4096];
        ssize_t count = recv(client, buffer, sizeof(buffer) - 1, 0);
        NSString* request = count > 0 ? [[NSString alloc] initWithBytes:buffer
                                                                 length:(NSUInteger)count
                                                               encoding:NSUTF8StringEncoding]
                                      : @"";

        // "GET /callback?code=...&state=... HTTP/1.1"
        NSString* firstLine = [request componentsSeparatedByString:@"\r\n"].firstObject;
        NSArray<NSString*>* parts = [firstLine componentsSeparatedByString:@" "];
        NSString *code = nil, *state = nil, *errorText = nil;
        BOOL isCallback = NO;
        if (parts.count >= 2 && [parts[1] hasPrefix:kRedirectPath]) {
            isCallback = YES;
            NSURLComponents* components =
                [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:parts[1]]];
            for (NSURLQueryItem* item in components.queryItems) {
                if ([item.name isEqualToString:@"code"]) {
                    code = item.value;
                } else if ([item.name isEqualToString:@"state"]) {
                    state = item.value;
                } else if ([item.name isEqualToString:@"error"]) {
                    errorText = item.value;
                }
            }
        }

        const char* page =
            isCallback
                ? "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                  "Connection: close\r\n\r\n<html><head><meta name=\"viewport\" "
                  "content=\"width=device-width,initial-scale=1\"></head>"
                  "<body style=\"font-family:-apple-system;text-align:center;padding-top:20vh\">"
                  "<h2>Spotify connected</h2><p>You can go back to the app.</p></body></html>"
                : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        send(client, page, strlen(page), 0);
        close(client);

        if (isCallback && (code.length > 0 || errorText.length > 0)) {
            handler(code, state, errorText);
        }
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
    });
    dispatch_resume(source);
    self.listener = source;
    return port;
}

#pragma mark - Login

- (UIWindow*)keyWindow {
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:
    (ASWebAuthenticationSession*)session {
    return [self keyWindow] ?: [UIWindow new];
}

- (void)loginWithCompletion:(void (^)(NSError* error))completion {
    NSString* clientID = self.clientID;
    if (clientID.length == 0) {
        completion([self errorWithCode:1 message:@"Client ID is empty"]);
        return;
    }

    [self stopListener];
    NSString* verifier = RandomString(64);
    NSString* expectedState = RandomString(24);
    __block BOOL finished = NO;
    __block NSString* redirectURI = nil;

    __weak BHTSpotify* weakSelf = self;
    int port = [self startListenerWithHandler:^(NSString* code, NSString* state, NSString* errorText) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BHTSpotify* strongSelf = weakSelf;
            if (finished || !strongSelf) {
                return;
            }
            finished = YES;
            [strongSelf stopListener];
            [strongSelf.session cancel]; // closes the login sheet
            strongSelf.session = nil;

            if (code.length == 0 || ![state isEqualToString:expectedState]) {
                completion([strongSelf errorWithCode:3
                                             message:errorText.length ? errorText
                                                                      : @"Login failed"]);
                return;
            }
            [strongSelf requestTokenWithForm:@{
                @"grant_type" : @"authorization_code",
                @"code" : code,
                @"redirect_uri" : redirectURI,
                @"client_id" : clientID,
                @"code_verifier" : verifier,
            }
                                  completion:^(NSError* tokenError) {
                                      dispatch_async(dispatch_get_main_queue(), ^{
                                          completion(tokenError);
                                      });
                                  }];
        });
    }];
    if (port == 0) {
        completion([self errorWithCode:4 message:@"Could not start the local login listener"]);
        return;
    }
    redirectURI = [NSString stringWithFormat:@"http://127.0.0.1:%d%@", port, kRedirectPath];

    NSURLComponents* components =
        [NSURLComponents componentsWithString:@"https://accounts.spotify.com/authorize"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client_id" value:clientID],
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
        [NSURLQueryItem queryItemWithName:@"redirect_uri" value:redirectURI],
        [NSURLQueryItem queryItemWithName:@"scope" value:@"user-read-currently-playing"],
        [NSURLQueryItem queryItemWithName:@"state" value:expectedState],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:ChallengeForVerifier(verifier)],
    ];

    // The scheme never matches anything; the session only ends when it is cancelled,
    // either by the user or by the listener above once the code has arrived.
    self.session = [[ASWebAuthenticationSession alloc]
              initWithURL:components.URL
        callbackURLScheme:@"nfbkemo-unused"
        completionHandler:^(NSURL* callbackURL, NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BHTSpotify* strongSelf = weakSelf;
                if (finished) {
                    return;
                }
                finished = YES;
                [strongSelf stopListener];
                strongSelf.session = nil;
                completion(error ?: [strongSelf errorWithCode:2 message:@"Login cancelled"]);
            });
        }];
    self.session.presentationContextProvider = self;
    self.session.prefersEphemeralWebBrowserSession = NO;
    if (![self.session start]) {
        finished = YES;
        [self stopListener];
        self.session = nil;
        completion([self errorWithCode:4 message:@"Could not open the login page"]);
    }
}

#pragma mark - Tokens

- (void)requestTokenWithForm:(NSDictionary<NSString*, NSString*>*)form
                  completion:(void (^)(NSError* error))completion {
    NSMutableURLRequest* request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"https://accounts.spotify.com/api/token"]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    NSURLComponents* body = [NSURLComponents new];
    NSMutableArray<NSURLQueryItem*>* items = [NSMutableArray array];
    for (NSString* key in form) {
        [items addObject:[NSURLQueryItem queryItemWithName:key value:form[key]]];
    }
    body.queryItems = items;
    request.HTTPBody = [body.percentEncodedQuery dataUsingEncoding:NSUTF8StringEncoding];

    __weak BHTSpotify* weakSelf = self;
    [[[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
              BHTSpotify* strongSelf = weakSelf;
              NSDictionary* json = data ? [NSJSONSerialization JSONObjectWithData:data
                                                                          options:0
                                                                            error:nil]
                                        : nil;
              NSString* accessToken = [json isKindOfClass:[NSDictionary class]]
                                          ? json[@"access_token"]
                                          : nil;
              if (error || accessToken.length == 0) {
                  NSString* detail = [json isKindOfClass:[NSDictionary class]]
                                         ? (json[@"error_description"] ?: json[@"error"])
                                         : nil;
                  completion(error ?: [strongSelf errorWithCode:5
                                                        message:detail ?: @"Token request failed"]);
                  return;
              }

              NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
              [defaults setObject:accessToken forKey:kAccessTokenKey];
              [defaults setDouble:[NSDate date].timeIntervalSince1970 +
                                  [json[@"expires_in"] doubleValue]
                           forKey:kExpiryKey];
              NSString* refreshToken = json[@"refresh_token"];
              if (refreshToken.length > 0) {
                  [defaults setObject:refreshToken forKey:kRefreshTokenKey];
              }
              completion(nil);
          }] resume];
}

// Hands back a valid access token, refreshing it first when it is about to expire.
- (void)withAccessToken:(void (^)(NSString* token, NSError* error))block {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* token = [defaults stringForKey:kAccessTokenKey];
    NSTimeInterval expiry = [defaults doubleForKey:kExpiryKey];
    if (token.length > 0 && expiry - 30 > [NSDate date].timeIntervalSince1970) {
        block(token, nil);
        return;
    }

    NSString* refreshToken = [defaults stringForKey:kRefreshTokenKey];
    if (refreshToken.length == 0 || self.clientID.length == 0) {
        block(nil, [self errorWithCode:6 message:@"Not connected"]);
        return;
    }

    [self requestTokenWithForm:@{
        @"grant_type" : @"refresh_token",
        @"refresh_token" : refreshToken,
        @"client_id" : self.clientID,
    }
                    completion:^(NSError* error) {
                        block(error ? nil : [defaults stringForKey:kAccessTokenKey], error);
                    }];
}

#pragma mark - Now playing

- (void)fetchCurrentlyPlaying:(void (^)(NSString* title, NSString* artist, NSString* shareURL,
                                        NSError* error))completion {
    [self withAccessToken:^(NSString* token, NSError* tokenError) {
        if (!token) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, nil, nil, tokenError);
            });
            return;
        }

        NSMutableURLRequest* request = [NSMutableURLRequest
            requestWithURL:[NSURL URLWithString:@"https://api.spotify.com/v1/me/player/"
                                                @"currently-playing?additional_types=episode"]];
        [request setValue:[@"Bearer " stringByAppendingString:token]
            forHTTPHeaderField:@"Authorization"];

        [[[NSURLSession sharedSession]
            dataTaskWithRequest:request
              completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                  NSInteger status = [(NSHTTPURLResponse*)response statusCode];
                  NSString* title = nil;
                  NSString* artist = nil;
                  NSString* url = nil;

                  if (!error && status == 200 && data.length > 0) {
                      NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data
                                                                           options:0
                                                                             error:nil];
                      NSDictionary* item = [json isKindOfClass:[NSDictionary class]]
                                               ? json[@"item"]
                                               : nil;
                      if ([item isKindOfClass:[NSDictionary class]]) {
                          title = item[@"name"];
                          NSArray* artists = item[@"artists"];
                          artist = [artists isKindOfClass:[NSArray class]] && artists.count > 0
                                       ? artists.firstObject[@"name"]
                                       : item[@"show"][@"name"];
                          url = item[@"external_urls"][@"spotify"];
                      }
                  }
                  dispatch_async(dispatch_get_main_queue(), ^{
                      completion(title, artist, url, error);
                  });
              }] resume];
    }];
}

@end
