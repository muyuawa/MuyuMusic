#import <Foundation/Foundation.h>
#import "MCHTTPClient.h"
#import "MCAudioSource.h"
#import <objc/runtime.h>
#import <curl/curl.h>
@interface NetworkTestClient : MCHTTPClient
@end
@implementation NetworkTestClient
- (NSString *)CAPath {
    return [[[NSProcessInfo processInfo] environment] objectForKey:@"MC_TEST_CA"];
}
@end
static id fixtureClient;
static id FixtureShared(id self, SEL selector) {
    (void)self;
    (void)selector;
    return fixtureClient;
}
static unsigned failures = 0, pending = 0;
#define CHECK(...)                                                                                           \
    do {                                                                                                     \
        if (!(__VA_ARGS__)) {                                                                                \
            fprintf(stderr, "FAIL transport line %d: %s\n", __LINE__, #__VA_ARGS__);                         \
            __sync_fetch_and_add(&failures, 1);                                                              \
        }                                                                                                    \
    } while (0)
static void finish(void) {
    if (__sync_sub_and_fetch(&pending, 1) == 0) {
        fprintf(stdout, "network_transport: %u failures\n", failures);
        exit(failures ? 1 : 0);
    }
}
int main(void) {
    @autoreleasepool {
        NetworkTestClient *client = [[NetworkTestClient alloc] init];
        NSString *base = [[[NSProcessInfo processInfo] environment] objectForKey:@"MC_TEST_BASE"];
        const curl_version_info_data *version = curl_version_info(CURLVERSION_NOW);
        fprintf(stdout, "transport backend curl/%s %s\n", version->version, version->ssl_version);
        if (getenv("MC_EXPECT_MBEDTLS")) {
            CHECK(strcmp(version->version, "8.23.0") == 0);
            CHECK(strstr(version->ssl_version, "mbedTLS/3.6.7") != NULL);
        }
        pending = 14;
        [client requestURL:[NSURL URLWithString:[base stringByAppendingString:@"/headers"]]
                    method:@"GET"
                      body:nil
                   headers:@{
                       @"Cookie" : @"MUSIC_U=must-never-leak",
                       @"Authorization" : @"secret",
                       @"X-Allowed" : @"yes"
                   }
                completion:^(NSData *data, NSDictionary *response, NSError *error) {
                    CHECK([NSThread isMainThread]);
                    CHECK(error == nil);
                    CHECK([response[@"status"] integerValue] == 200);
                    NSDictionary *headers = [NSJSONSerialization JSONObjectWithData:data
                                                                            options:0
                                                                              error:NULL];
                    CHECK(!headers[@"Cookie"]);
                    CHECK(!headers[@"Authorization"]);
                    CHECK([headers[@"X-Allowed"] isEqual:@"yes"]);
                    finish();
                }];
        [client requestURL:[NSURL URLWithString:[base stringByAppendingString:@"/large"]]
                    method:@"GET"
                      body:nil
                   headers:nil
                completion:^(NSData *data, NSDictionary *response, NSError *error) {
                    (void)response;
                    CHECK(error != nil);
                    CHECK([data length] <= 8 * 1024 * 1024);
                    finish();
                }];
        __block NSUInteger received = 0;
        [client streamURL:[NSURL URLWithString:[base stringByAppendingString:@"/large"]]
            headers:@{@"Cookie" : @"secret"}
            response:^(NSDictionary *response) {
                CHECK(![NSThread isMainThread]);
                CHECK([response[@"status"] integerValue] == 200);
            }
            data:^BOOL(const void *bytes, size_t length) {
                CHECK(![NSThread isMainThread]);
                CHECK(bytes != NULL && length <= 32768);
                received += length;
                return received < 100000;
            }
            completion:^(NSError *error) {
                CHECK(![NSThread isMainThread]);
                CHECK(error.code == NSURLErrorCancelled);
                CHECK(received >= 100000 && received < 132768);
                finish();
            }];
        [client streamURL:[NSURL URLWithString:[base stringByAppendingString:@"/redirect"]]
            headers:nil
            response:^(NSDictionary *response) {
                CHECK([response[@"status"] integerValue] == 302);
                CHECK(response[@"location"] != nil);
            }
            data:^BOOL(const void *bytes, size_t length) {
                (void)bytes;
                (void)length;
                CHECK(NO);
                return YES;
            }
            completion:^(NSError *error) {
                CHECK(error == nil);
                finish();
            }];
        [client requestURL:[NSURL URLWithString:@"http://localhost/invalid"]
                    method:@"GET"
                      body:nil
                   headers:nil
                completion:^(NSData *data, NSDictionary *response, NSError *error) {
                    (void)data;
                    (void)response;
                    CHECK([NSThread isMainThread]);
                    CHECK(error != nil);
                    finish();
                }];
        MCRequest *cancel =
            [client requestURL:[NSURL URLWithString:[base stringByAppendingString:@"/headers"]]
                        method:@"GET"
                          body:nil
                       headers:nil
                    completion:^(NSData *data, NSDictionary *response, NSError *error) {
                        (void)data;
                        (void)response;
                        CHECK(error.code == NSURLErrorCancelled);
                        finish();
                    }];
        [cancel cancel];
        /* The ordinary trust store must reject this test-only certificate. */
        [[MCHTTPClient sharedClient]
            requestURL:[NSURL URLWithString:[base stringByAppendingString:@"/headers"]]
                method:@"GET"
                  body:nil
               headers:nil
            completion:^(NSData *data, NSDictionary *response, NSError *error) {
                (void)data;
                (void)response;
                CHECK(error != nil);
                finish();
            }];
        [client sourceRequestURL:[NSURL URLWithString:[base stringByAppendingString:@"/headers"]]
                          method:@"GET"
                            body:nil
                         headers:@{
                             @"Authorization" : @"Bearer user-api-token",
                             @"Cookie" : @"user-source-cookie",
                             @"Proxy-Authorization" : @"never",
                             @"X-Allowed" : @"yes"
                         }
                         timeout:5
                      completion:^(NSData *data, NSDictionary *response, NSError *error) {
                          CHECK([NSThread isMainThread]);
                          CHECK(error == nil);
                          CHECK([response[@"headers"] isKindOfClass:[NSDictionary class]]);
                          NSDictionary *headers = [NSJSONSerialization JSONObjectWithData:data
                                                                                  options:0
                                                                                    error:NULL];
                          CHECK([headers[@"Authorization"] isEqual:@"Bearer user-api-token"]);
                          CHECK([headers[@"Cookie"] isEqual:@"user-source-cookie"]);
                          CHECK(!headers[@"Proxy-Authorization"]);
                          finish();
                      }];
        [client sourceRequestURL:[NSURL URLWithString:[base stringByAppendingString:@"/large"]]
                          method:@"GET"
                            body:nil
                         headers:nil
                         timeout:5
                      completion:^(NSData *data, NSDictionary *response, NSError *error) {
                          (void)response;
                          CHECK(error != nil);
                          CHECK(data.length <= 2 * 1024 * 1024);
                          CHECK([error.localizedDescription rangeOfString:@"token"].location == NSNotFound);
                          finish();
                      }];
        [client sourceRequestURL:[NSURL URLWithString:[base stringByAppendingString:@"/redirect"]]
                          method:@"GET"
                            body:nil
                         headers:nil
                         timeout:5
                      completion:^(NSData *data, NSDictionary *response, NSError *error) {
                          CHECK(error == nil);
                          CHECK([response[@"status"] integerValue] == 302);
                          CHECK(response[@"location"] != nil);
                          CHECK(!data.length);
                          finish();
                      }];
        [client sourceRequestURL:[NSURL URLWithString:@"http://localhost/invalid?token=secret"]
                          method:@"GET"
                            body:nil
                         headers:nil
                         timeout:5
                      completion:^(NSData *data, NSDictionary *response, NSError *error) {
                          (void)data;
                          (void)response;
                          CHECK(error != nil);
                          CHECK([error.localizedDescription rangeOfString:@"secret"].location == NSNotFound);
                          finish();
                      }];
        fixtureClient = client;
        method_setImplementation(class_getClassMethod([MCHTTPClient class], @selector(sharedClient)),
                                 (IMP)FixtureShared);
        __block MCAudioSource *custom = [[MCAudioSource alloc]
               initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/audio-redirect"]]
            expectedLength:0
                    format:nil
              customSource:YES];
        __block BOOL ready = NO;
        __weak MCAudioSource *weakCustom = custom;
        custom.ready = ^(BOOL flac) {
            CHECK(!flac);
            CHECK([weakCustom.contentType isEqual:@"com.microsoft.waveform-audio"]);
            ready = YES;
        };
        custom.failure = ^(NSError *error) {
            (void)error;
            CHECK(NO);
            finish();
        };
        custom.downloadCompleted = ^(NSString *path) {
            CHECK(ready);
            NSData *audio = [NSData dataWithContentsOfFile:path];
            CHECK(audio.length == 1644);
            CHECK(!memcmp(audio.bytes, "RIFF", 4));
            [custom cancel];
            custom = nil;
            finish();
        };
        [custom start];
        __block MCAudioSource *builtin =
            [[MCAudioSource alloc] initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/audio"]]
                                expectedLength:0
                                        format:nil];
        builtin.failure = ^(NSError *error) {
            CHECK(error.code == MCPlaybackURLError);
            [builtin cancel];
            builtin = nil;
            finish();
        };
        [builtin start];
        __block MCAudioSource *insecure = [[MCAudioSource alloc]
               initWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/http-redirect"]]
            expectedLength:0
                    format:nil
              customSource:YES];
        insecure.ready = ^(BOOL flac) {
            (void)flac;
            CHECK(NO);
        };
        insecure.failure = ^(NSError *error) {
            CHECK(error.code == MCPlaybackURLError);
            [insecure cancel];
            insecure = nil;
            finish();
        };
        [insecure start];
        CFRunLoopRun();
    }
}
