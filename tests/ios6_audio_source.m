#import <Foundation/Foundation.h>
#import "../Sources/Playback/MCAudioSource.h"
#import "../Sources/Network/MCHTTPClient.h"
#include <assert.h>
/* The transport boundary delivers controlled chunks; the real spool/source
   must decide when AVPlayer or the FLAC decoder can safely start. */
static BOOL (^deliver)(const void *, size_t);
static void (^finish)(NSError *);
@implementation MCRequest
- (void)cancel {
}
@end
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation MCHTTPClient
+ (instancetype)sharedClient {
    static MCHTTPClient *client;
    if (!client)
        client = [self new];
    return client;
}
- (MCRequest *)streamURL:(NSURL *)url
                 headers:(NSDictionary *)headers
                response:(void (^)(NSDictionary *))response
                    data:(BOOL (^)(const void *, size_t))data
              completion:(void (^)(NSError *))completion {
    (void)url;
    (void)headers;
    response(@{@"status" : @200, @"content-length" : @"24"});
    deliver = [data copy];
    finish = [completion copy];
    return [MCRequest new];
}
@end
#pragma clang diagnostic pop
static void Drain(void) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:.03];
    while (end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}
static void Case(BOOL streaming, BOOL flac, BOOL truncate, BOOL cancel) {
    MCAudioSource *source =
        [[MCAudioSource alloc] initWithURL:[NSURL URLWithString:@"https://m7.music.126.net/test"]
                            expectedLength:24
                                    format:flac ? @"flac" : @"mp3"];
    source.allowsProgressiveNativePlayback = streaming;
    __block unsigned ready = 0, failed = 0, complete = 0;
    source.ready = ^(BOOL actualFLAC) {
        assert(actualFLAC == flac);
        ready++;
    };
    source.failure = ^(NSError *error) {
        assert(error);
        failed++;
    };
    source.downloadCompleted = ^(NSString *path) {
        assert(path.length);
        complete++;
    };
    [source start];
    unsigned char bytes[12] = {0};
    memcpy(bytes, flac ? "fLaC" : "ID3", flac ? 4 : 3);
    assert(deliver(bytes, sizeof bytes));
    Drain();
    assert(ready == (unsigned)(streaming || flac));
    assert(!failed && !complete);
    if (cancel) {
        [source cancel];
        finish(nil);
        Drain();
        assert(!failed && !complete);
    } else {
        if (!truncate)
            assert(deliver(bytes, sizeof bytes));
        finish(nil);
        Drain();
        assert(ready == (unsigned)((!truncate) || streaming || flac));
        assert(failed == (unsigned)truncate);
        assert(complete == (unsigned)!truncate);
    }
    [source cancel];
    deliver = nil;
    finish = nil;
}
int main(void) {
    @autoreleasepool {
        Case(NO, NO, NO, NO);
        Case(YES, NO, NO, NO);
        Case(NO, YES, NO, NO);
        Case(NO, NO, YES, NO);
        Case(NO, NO, NO, YES);
        puts("iOS 6 audio source: native waits, FLAC streams, truncation/cancel passed");
    }
}
