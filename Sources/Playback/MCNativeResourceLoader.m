#import "MCNativeResourceLoader.h"
#import "MCAudioSource.h"
#include <errno.h>

@interface MCNativeRange : NSObject
@property (nonatomic, strong) AVAssetResourceLoadingRequest *request;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic) BOOL cancelled;
- (BOOL)active;
- (void)cancel;
- (BOOL)respond:(NSData *)bytes;
- (BOOL)finish:(NSError *)error;
@end
@implementation MCNativeRange
- (id)init {
    if ((self = [super init]))
        _lock = [[NSLock alloc] init];
    return self;
}
- (BOOL)active {
    [_lock lock];
    BOOL value = !_cancelled;
    [_lock unlock];
    return value;
}
- (void)cancel {
    [_lock lock];
    _cancelled = YES;
    [_lock unlock];
}
- (BOOL)respond:(NSData *)bytes {
    if (@available(iOS 7.0, *)) {
        [_lock lock];
        BOOL active = !_cancelled;
        if (active)
            [_request.dataRequest respondWithData:bytes];
        [_lock unlock];
        return active;
    }
    return NO;
}
- (BOOL)finish:(NSError *)error {
    if (@available(iOS 7.0, *)) {
        [_lock lock];
        BOOL active = !_cancelled;
        if (active) {
            _cancelled = YES;
            if (error)
                [_request finishLoadingWithError:error];
            else
                [_request finishLoading];
        }
        [_lock unlock];
        return active;
    }
    return NO;
}
@end

@interface MCNativeResourceLoader () {
    MCAudioSource *_source;
    NSOperationQueue *_workers;
    NSMutableDictionary *_ranges;
    dispatch_queue_t _delegateQueue;
    BOOL _cancelled, _failureReported;
    NSError *_error;
}
@end
@implementation MCNativeResourceLoader
- (id)initWithSource:(MCAudioSource *)source {
    if ((self = [super init])) {
        _source = source;
        _delegateQueue = dispatch_queue_create("music.native.resource", DISPATCH_QUEUE_SERIAL);
        _workers = [[NSOperationQueue alloc] init];
        _workers.maxConcurrentOperationCount = 4;
        _ranges = [NSMutableDictionary dictionary];
    }
    return self;
}
- (dispatch_queue_t)delegateQueue {
    return _delegateQueue;
}
- (NSError *)error {
    @synchronized(self) {
        return _error;
    }
}
- (NSURL *)URL {
    NSString *type = _source.contentType;
    NSString *extension = [type isEqualToString:@"com.apple.m4a-audio"]            ? @"m4a"
                          : [type isEqualToString:@"public.aac-audio"]             ? @"aac"
                          : [type isEqualToString:@"com.microsoft.waveform-audio"] ? @"wav"
                          : [type isEqualToString:@"public.aiff-audio"]            ? @"aiff"
                                                                                   : @"mp3";
    return [NSURL URLWithString:[@"muyu-audio://stream/audio." stringByAppendingString:extension]];
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request {
    if (@available(iOS 7.0, *)) {
        (void)resourceLoader;
        @synchronized(self) {
            if (_cancelled)
                return NO;
        }
        if (![[request.request.URL scheme] isEqualToString:@"muyu-audio"])
            return NO;
        AVAssetResourceLoadingContentInformationRequest *info = request.contentInformationRequest;
        if (info) {
            info.contentType = _source.contentType;
            info.contentLength = (long long)_source.contentLength;
            info.byteRangeAccessSupported = YES;
        }
        if (!request.dataRequest) {
            [request finishLoading];
            return YES;
        }
        MCNativeRange *range = [[MCNativeRange alloc] init];
        range.request = request;
        NSValue *key = [NSValue valueWithNonretainedObject:request];
        @synchronized(self) {
            if (_cancelled)
                return NO;
            _ranges[key] = range;
        }
        [_workers addOperationWithBlock:^{
            @autoreleasepool {
                [self serve:range key:key];
            }
        }];
        return YES;
    }
    return NO;
}
- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)request {
    (void)resourceLoader;
    NSValue *key = [NSValue valueWithNonretainedObject:request];
    @synchronized(self) {
        [_ranges[key] cancel];
        [_ranges removeObjectForKey:key];
    }
}
- (void)serve:(MCNativeRange *)range key:(NSValue *)key {
    if (@available(iOS 7.0, *)) {
        AVAssetResourceLoadingDataRequest *data = range.request.dataRequest;
        long long requested = data.requestedOffset;
        long long current = data.currentOffset;
        long long count = data.requestedLength;
        uint64_t length = _source.contentLength;
        NSError *error = nil;
        if (requested < 0 || count < 0 || (uint64_t)requested > length) {
            error = MCPlaybackError(MCPlaybackDecodeError,
                                    @"The media decoder requested an invalid audio byte range.", NO);
        }
        uint64_t offset = (uint64_t)MAX(requested, current);
        uint64_t end = MIN(length, (uint64_t)MAX(0LL, requested) + (uint64_t)MAX(0LL, count));
        uint64_t revision = mc_spool_revision(_source.spool);
        uint64_t downloaded = mc_spool_available(_source.spool);
        CFAbsoluteTime lastProgress = CFAbsoluteTimeGetCurrent();
        unsigned char bytes[32768];
        while (!error && offset < end && [range active]) {
            @autoreleasepool {
                size_t take = (size_t)MIN((uint64_t)sizeof bytes, end - offset);
                ssize_t n = mc_spool_read_timed(_source.spool, bytes, take, &offset, revision, 100);
                if (![range active])
                    break;
                if (n > 0) {
                    if (![range respond:[NSData dataWithBytes:bytes length:(NSUInteger)n]])
                        break;
                    lastProgress = CFAbsoluteTimeGetCurrent();
                } else if (n == -EAGAIN) {
                    uint64_t available = mc_spool_available(_source.spool);
                    if (available > downloaded) {
                        downloaded = available;
                        lastProgress = CFAbsoluteTimeGetCurrent();
                    }
                    if (CFAbsoluteTimeGetCurrent() - lastProgress > 30)
                        error = MCPlaybackError(
                            MCPlaybackNetworkError,
                            @"The audio stream stopped responding. Check your connection and tap Retry.",
                            YES);
                } else if (n == -ECANCELED) {
                    [range cancel];
                    break;
                } else {
                    error = MCPlaybackError(
                        MCPlaybackNetworkError,
                        @"The audio stream ended before the requested bytes arrived. Tap Retry.", YES);
                }
            }
        }
        if (error && [range active]) {
            @synchronized(self) {
                if (!_cancelled)
                    _error = error;
            }
        }
        BOOL delivered = [range finish:error];
        @synchronized(self) {
            if (_ranges[key] == range)
                [_ranges removeObjectForKey:key];
            if (error && delivered && !_cancelled && !_failureReported) {
                _failureReported = YES;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.failure)
                        self.failure(error);
                });
            }
        }
    }
}
- (void)cancel {
    @synchronized(self) {
        if (_cancelled)
            return;
        _cancelled = YES;
        for (MCNativeRange *range in [_ranges allValues])
            [range cancel];
        [_ranges removeAllObjects];
    }
    [_workers cancelAllOperations];
}
@end
