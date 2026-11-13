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
    if (flac) memcpy(bytes, "fLaC", 4);
    else { bytes[0]=0xff; bytes[1]=0xfb; bytes[2]=0x90; }
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

/* Catches extensionless/.audio playback paths and decoder selection from stale hints. */
static void FormatCase(const unsigned char *bytes, NSString *hint, NSString *extension,
                       NSString *type, BOOL flac, BOOL local) {
    NSString *input = nil, *playback = nil;
    @autoreleasepool {
        NSData *payload = [NSData dataWithBytes:bytes length:24];
        MCAudioSource *source;
        if (local) {
            input = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [[[NSUUID UUID] UUIDString] stringByAppendingPathExtension:@"audio"]];
            assert([payload writeToFile:input atomically:YES]);
            source = [[MCAudioSource alloc] initWithLocalPath:input];
        } else {
            source = [[MCAudioSource alloc] initWithURL:[NSURL URLWithString:@"https://m7.music.126.net/test"]
                                        expectedLength:24 format:hint];
            source.allowsProgressiveNativePlayback = YES; /* iOS 7+ path */
        }
        __block unsigned ready = 0, failed = 0;
        source.ready = ^(BOOL actualFLAC) { assert(actualFLAC == flac); ready++; };
        source.failure = ^(NSError *error) { (void)error; failed++; };
        [source start];
        if (!local) {
            assert(deliver(bytes, 12));
            Drain();
            assert(ready == 1 && failed == 0);
            assert(!mc_spool_complete(source.spool));
            assert([source.path.pathExtension isEqual:extension]);
            assert([source.contentType isEqual:type]);
            assert([[NSData dataWithContentsOfFile:source.path] length] == 12);
            assert(deliver(bytes + 12, 12));
            finish(nil);
        }
        Drain();
        assert(ready == 1 && failed == 0);
        playback = source.path;
        assert([playback.pathExtension isEqual:extension]);
        assert([source.contentType isEqual:type]);
        assert([[NSData dataWithContentsOfFile:playback] isEqual:payload]);
        [source cancel];
        source = nil;
        Drain();
        deliver = nil; finish = nil;
    }
    assert(![[NSFileManager defaultManager] fileExistsAtPath:playback]);
    if (local) {
        assert([[NSFileManager defaultManager] fileExistsAtPath:input]);
        [[NSFileManager defaultManager] removeItemAtPath:input error:NULL];
    }
}
static void FormatPaths(void) {
    unsigned char mp3[24] = {0xff,0xfb,0x90,0}, flac[24] = {'f','L','a','C'};
    unsigned char taggedFLAC[24] = {'I','D','3',3,0,0,0,0,0,0,'f','L','a','C'};
    unsigned char taggedAAC[24] = {'I','D','3',4,0,0,0,0,0,0,0xff,0xf1,0x50,0x80};
    unsigned char m4a[24] = {0,0,0,24,'f','t','y','p','M','4','A',' '};
    unsigned char aac[24] = {0xff,0xf1,0x50,0x80}, wav[24] = {'R','I','F','F',0,0,0,0,'W','A','V','E'};
    unsigned char aiff[24] = {'F','O','R','M',0,0,0,0,'A','I','F','F'};
    FormatCase(mp3, @"flac", @"mp3", @"public.mp3", NO, NO);
    FormatCase(flac, @"mp3", @"flac", @"org.xiph.flac", YES, NO);
    FormatCase(m4a, @"alac", @"m4a", @"com.apple.m4a-audio", NO, NO);
    FormatCase(aac, @"aac", @"aac", @"public.aac-audio", NO, NO);
    FormatCase(wav, @"wav", @"wav", @"com.microsoft.waveform-audio", NO, NO);
    FormatCase(aiff, @"aiff", @"aiff", @"public.aiff-audio", NO, NO);
    FormatCase(mp3, nil, @"mp3", @"public.mp3", NO, YES);
    FormatCase(flac, nil, @"flac", @"org.xiph.flac", YES, YES);
    FormatCase(taggedFLAC, nil, @"flac", @"org.xiph.flac", YES, YES);
    FormatCase(taggedAAC, nil, @"aac", @"public.aac-audio", NO, YES);
    FormatCase(m4a, nil, @"m4a", @"com.apple.m4a-audio", NO, YES);
    FormatCase(aac, nil, @"aac", @"public.aac-audio", NO, YES);
    FormatCase(wav, nil, @"wav", @"com.microsoft.waveform-audio", NO, YES);
    FormatCase(aiff, nil, @"aiff", @"public.aiff-audio", NO, YES);
    puts("audio formats: iOS 7+ progressive readiness, typed paths, legacy caches and alias cleanup passed");
}

int main(void) {
    @autoreleasepool {
        FormatPaths();
        Case(NO, NO, NO, NO);
        Case(YES, NO, NO, NO);
        Case(NO, YES, NO, NO);
        Case(NO, NO, YES, NO);
        Case(NO, NO, NO, YES);
        puts("iOS 6 audio source: native waits, FLAC streams, truncation/cancel passed");
    }
}
