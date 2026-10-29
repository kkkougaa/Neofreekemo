//
//  BHTSpotify.m
//  NeoFreeBird
//

#import "Core/BHTSpotify.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>

static NSString* const kClientIDKey = @"spotify_client_id";
static NSString* const kAccessTokenKey = @"nfb_spotify_access_token";
static NSString* const kRefreshTokenKey = @"nfb_spotify_refresh_token";
static NSString* const kExpiryKey = @"nfb_spotify_token_expiry";
static NSString* const kCallbackScheme = @"nfbkemo";
static NSString* const kRedirectURI = @"nfbkemo://spotify";
static NSString* const kErrorDomain = @"com.neofreebird.spotify";

@interface BHTSpotify () <ASWebAuthenticationPresentationContextProviding>
@property (nonatomic, strong) ASWebAuthenticationSession* session;
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

static NSString* RandomVerifier(void) {
    static NSString* const alphabet =
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    NSMutableString* verifier = [NSMutableString string];
    for (int i = 0; i < 64; i++) {
        [verifier appendFormat:@"%C", [alphabet characterAtIndex:arc4random_uniform((uint32_t)alphabet.length)]];
    }
    return verifier;
}

static NSString* ChallengeForVerifier(NSString* verifier) {
    NSData* input = [verifier dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    return Base64URL([NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH]);
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

    NSString* verifier = RandomVerifier();
    NSURLComponents* components =
        [NSURLComponents componentsWithString:@"https://accounts.spotify.com/authorize"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client_id" value:clientID],
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
        [NSURLQueryItem queryItemWithName:@"redirect_uri" value:kRedirectURI],
        [NSURLQueryItem queryItemWithName:@"scope" value:@"user-read-currently-playing"],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:ChallengeForVerifier(verifier)],
    ];

    __weak BHTSpotify* weakSelf = self;
    self.session = [[ASWebAuthenticationSession alloc]
              initWithURL:components.URL
        callbackURLScheme:kCallbackScheme
        completionHandler:^(NSURL* callbackURL, NSError* error) {
            BHTSpotify* strongSelf = weakSelf;
            strongSelf.session = nil;
            if (error || !callbackURL) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(error ?: [strongSelf errorWithCode:2 message:@"Login cancelled"]);
                });
                return;
            }

            NSString* code = nil;
            for (NSURLQueryItem* item in [NSURLComponents componentsWithURL:callbackURL
                                                    resolvingAgainstBaseURL:NO]
                     .queryItems) {
                if ([item.name isEqualToString:@"code"]) {
                    code = item.value;
                }
            }
            if (code.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion([strongSelf errorWithCode:3 message:@"No authorization code"]);
                });
                return;
            }

            [strongSelf requestTokenWithForm:@{
                @"grant_type" : @"authorization_code",
                @"code" : code,
                @"redirect_uri" : kRedirectURI,
                @"client_id" : clientID,
                @"code_verifier" : verifier,
            }
                                  completion:^(NSError* tokenError) {
                                      dispatch_async(dispatch_get_main_queue(), ^{
                                          completion(tokenError);
                                      });
                                  }];
        }];
    self.session.presentationContextProvider = self;
    self.session.prefersEphemeralWebBrowserSession = NO;
    if (![self.session start]) {
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
                  completion(error ?: [strongSelf errorWithCode:5 message:@"Token request failed"]);
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
