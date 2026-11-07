#import <Foundation/Foundation.h>
#import "MCHTTPClient.h"
#import "MCAudioSource.h"
#import "MCSourceSecurity.h"
#import <objc/runtime.h>
#include <assert.h>
@interface HTTPFixtureClient : MCHTTPClient
@end
@implementation HTTPFixtureClient
- (NSString *)CAPath {
    return [NSString stringWithUTF8String:getenv("MC_TEST_CA")];
}
@end
static MCHTTPClient *client;
static id Shared(id self, SEL selector) {
    (void)self;
    (void)selector;
    return client;
}
static void Wait(BOOL *done) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!*done && end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    assert(*done);
}
static void Audio(NSString *address, BOOL custom, BOOL success, NSString *reason) {
    MCAudioSource *source = [[MCAudioSource alloc] initWithURL:[NSURL URLWithString:address]
                                                expectedLength:0
                                                        format:nil
                                                  customSource:custom];
    __block BOOL done = NO, ready = NO;
    source.ready = ^(BOOL flac) {
        assert(success && !flac);
        ready = YES;
    };
    source.failure = ^(NSError *error) {
        assert(!success && [error.localizedDescription containsString:reason]);
        done = YES;
    };
    source.downloadCompleted = ^(NSString *path) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        assert(success && ready && data.length == 1644 && !memcmp(data.bytes, "RIFF", 4));
        done = YES;
    };
    [source start];
    Wait(&done);
    [source cancel];
}
int main(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        id saved = [defaults objectForKey:MCSourceHTTPSOnlyKey];
        [defaults removeObjectForKey:MCSourceHTTPSOnlyKey];
        assert(MCSourceHTTPSOnly());
        client = [HTTPFixtureClient new];
        method_setImplementation(class_getClassMethod([MCHTTPClient class], @selector(sharedClient)),
                                 (IMP)Shared);
        NSString *plain = [NSString stringWithUTF8String:getenv("MC_TEST_HTTP_BASE")];
        NSString *tls = [NSString stringWithUTF8String:getenv("MC_TEST_BASE")];
        __block BOOL done = NO;
        [client sourceRequestURL:[NSURL URLWithString:[plain stringByAppendingString:@"/headers"]]
                          method:@"GET"
                            body:nil
                         headers:nil
                         timeout:5
                      completion:^(NSData *data, NSDictionary *response, NSError *error) {
                          (void)data;
                          (void)response;
                          assert([error.localizedDescription containsString:@"仅允许 HTTPS"]);
                          done = YES;
                      }];
        Wait(&done);
        Audio([plain stringByAppendingString:@"/audio"], YES, NO, @"仅允许 HTTPS");
        Audio([tls stringByAppendingString:@"/http-redirect"], YES, NO, @"仅允许 HTTPS");
        MCSetSourceHTTPSOnly(NO);
        done = NO;
        [client sourceRequestURL:[NSURL URLWithString:[plain stringByAppendingString:@"/headers"]]
                          method:@"GET"
                            body:nil
                         headers:@{@"Authorization" : @"source-auth", @"Cookie" : @"source-cookie"}
                         timeout:5
                      completion:^(NSData *data, NSDictionary *response, NSError *error) {
                          NSDictionary *headers = [NSJSONSerialization JSONObjectWithData:data
                                                                                  options:0
                                                                                    error:NULL];
                          assert(!error && [response[@"status"] integerValue] == 200);
                          assert([headers[@"Authorization"] isEqual:@"source-auth"] &&
                                 [headers[@"Cookie"] isEqual:@"source-cookie"]);
                          done = YES;
                      }];
        Wait(&done);
        done = NO;
        [client sourceStreamURL:[NSURL URLWithString:[plain stringByAppendingString:@"/headers"]]
            headers:@{@"Authorization" : @"must-strip", @"Cookie" : @"must-strip"}
            response:nil
            data:^BOOL(const void *bytes, size_t length) {
                NSString *text = [[NSString alloc] initWithBytes:bytes
                                                          length:length
                                                        encoding:NSUTF8StringEncoding];
                assert(![text containsString:@"must-strip"]);
                return YES;
            }
            completion:^(NSError *error) {
                assert(!error);
                done = YES;
            }];
        Wait(&done);
        done = NO;
        [client requestURL:[NSURL URLWithString:[plain stringByAppendingString:@"/headers"]]
                    method:@"GET"
                      body:nil
                   headers:nil
                completion:^(NSData *data, NSDictionary *response, NSError *error) {
                    (void)data;
                    (void)response;
                    assert(error);
                    done = YES;
                }];
        Wait(&done);
        done = NO;
        [client streamURL:[NSURL URLWithString:[plain stringByAppendingString:@"/audio"]]
                  headers:nil
                 response:nil
                     data:nil
               completion:^(NSError *error) {
                   assert(error);
                   done = YES;
               }];
        Wait(&done);
        Audio([plain stringByAppendingString:@"/audio-redirect"], YES, YES, nil);
        Audio([tls stringByAppendingString:@"/http-redirect"], YES, YES, nil);
        Audio([[tls stringByReplacingOccurrencesOfString:@"localhost"
                                              withString:@"127.0.0.1"] stringByAppendingString:@"/audio"],
              YES, NO, @"TLS 证书验证失败");
        Audio([plain stringByAppendingString:@"/status403"], YES, NO, @"HTTP 403");
        Audio([plain stringByAppendingString:@"/audio"], NO, NO, @"网易云");
        MCSetSourceHTTPSOnly(YES);
        Audio([plain stringByAppendingString:@"/audio"], YES, NO, @"仅允许 HTTPS");
        if (saved)
            [defaults setObject:saved forKey:MCSourceHTTPSOnlyKey];
        else
            [defaults removeObjectForKey:MCSourceHTTPSOnlyKey];
        puts("network_http: policy, credentials, streaming, redirects and status reasons passed");
    }
    return 0;
}
