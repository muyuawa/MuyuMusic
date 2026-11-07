#import "MCAudioSource.h"
#import "MCAudioPolicy.h"
#import "../Network/MCHTTPClient.h"
#import "../Network/MCSourceSecurity.h"
#include <errno.h>
#include <string.h>

NSString *const MCPlaybackErrorDomain = @"MCPlayback";
NSString *const MCPlaybackRetryableKey = @"MCPlaybackRetryable";
NSError *MCPlaybackError(MCPlaybackErrorCode code, NSString *description, BOOL retryable) {
    return [NSError errorWithDomain:MCPlaybackErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey : description,
                               MCPlaybackRetryableKey : @(retryable)
                           }];
}
@interface MCAudioSource () {
    MCPlaybackSpool *_spool;
    NSURL *_url;
    NSString *_localPath, *_format, *_contentType;
    MCRequest *_request;
    uint64_t _expected;
    NSUInteger _redirects, _requestGeneration;
    BOOL _customSource;
    BOOL _cancelled, _announced, _flac, _started;
}
@end
@implementation MCAudioSource
- (id)initWithLocalPath:(NSString *)path {
    if ((self = [super init]))
        _localPath = [path copy];
    return self;
}
- (id)initWithURL:(NSURL *)url expectedLength:(uint64_t)length format:(NSString *)format {
    return [self initWithURL:url expectedLength:length format:format customSource:NO];
}
- (id)initWithURL:(NSURL *)url
    expectedLength:(uint64_t)length
            format:(NSString *)format
      customSource:(BOOL)customSource {
    if ((self = [super init])) {
        _customSource = customSource;
        _url = url;
        _expected = length;
        _format = [format isKindOfClass:[NSString class]] ? [format lowercaseString] : @"";
    }
    return self;
}
- (void)dealloc {
    mc_spool_destroy(_spool);
}
- (MCPlaybackSpool *)spool {
    return _spool;
}
- (NSString *)path {
    const char *path = mc_spool_path(_spool);
    return path ? [NSString stringWithUTF8String:path] : nil;
}
- (NSString *)contentType {
    return _contentType ?: @"public.mp3";
}
- (uint64_t)contentLength {
    return mc_spool_expected_length(_spool);
}
- (BOOL)identifyNative {
    if (mc_spool_available(_spool) < 12)
        return NO;
    unsigned char bytes[12];
    uint64_t offset = 0;
    if (mc_spool_read_timed(_spool, bytes, sizeof bytes, &offset, mc_spool_revision(_spool), 0) !=
        sizeof bytes)
        return NO;
    if (!memcmp(bytes + 4, "ftyp", 4))
        _contentType = @"com.apple.m4a-audio";
    else if (!memcmp(bytes, "RIFF", 4) && !memcmp(bytes + 8, "WAVE", 4))
        _contentType = @"com.microsoft.waveform-audio";
    else if (!memcmp(bytes, "FORM", 4) && (!memcmp(bytes + 8, "AIFF", 4) || !memcmp(bytes + 8, "AIFC", 4)))
        _contentType = @"public.aiff-audio";
    else if (bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0)
        _contentType = @"public.aac-audio";
    else if (!memcmp(bytes, "ID3", 3) || (bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0))
        _contentType = @"public.mp3";
    else if ([_format isEqualToString:@"m4a"] || [_format isEqualToString:@"alac"])
        _contentType = @"com.apple.m4a-audio";
    else if ([_format isEqualToString:@"aac"])
        _contentType = @"public.aac-audio";
    else
        return NO;
    return YES;
}
- (void)announce:(BOOL)flac {
    @synchronized(self) {
        if (_cancelled || _announced)
            return;
        _announced = YES;
        _flac = flac;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self) {
            if (self->_cancelled)
                return;
        }
        if (self.ready)
            self.ready(flac);
    });
}
- (void)fail:(NSError *)error {
    @synchronized(self) {
        if (_cancelled)
            return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self) {
            if (self->_cancelled)
                return;
        }
        if (self.failure)
            self.failure(error);
    });
}
- (void)start {
    @synchronized(self) {
        if (_started || _cancelled)
            return;
        _started = YES;
    }
    /* Only short, bounded initialization is done here. No network or decoding
       runs on the caller's queue. Local probing runs on a shared serial worker. */
    if (_localPath) {
        static dispatch_queue_t probe;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            probe = dispatch_queue_create("music.audio.probe", DISPATCH_QUEUE_SERIAL);
        });
        dispatch_async(probe, ^{
            @autoreleasepool {
                @synchronized(self) {
                    if (self->_cancelled)
                        return;
                    self->_spool = mc_spool_open([self->_localPath fileSystemRepresentation]);
                }
                if (!self->_spool) {
                    [self fail:MCPlaybackError(MCPlaybackFileError,
                                               @"This audio file cannot be opened. Rescan the library if it "
                                               @"was moved or deleted.",
                                               NO)];
                    return;
                }
                char magic[4] = {0};
                uint64_t offset = 0;
                ssize_t n = mc_spool_read(self->_spool, magic, sizeof magic, &offset,
                                          mc_spool_revision(self->_spool));
                BOOL flac = n == 4 && !memcmp(magic, "fLaC", 4);
                flac = flac || [[[self->_localPath pathExtension] lowercaseString] isEqualToString:@"flac"];
                if (n <= 0)
                    [self fail:MCPlaybackError(MCPlaybackFileError,
                                               @"This audio file is empty or unreadable.", NO)];
                else
                    [self announce:flac];
            }
        });
    } else {
        @synchronized(self) {
            if (_cancelled)
                return;
            _spool =
                mc_spool_create([NSTemporaryDirectory() fileSystemRepresentation], 1024ULL * 1024 * 1024);
        }
        if (!_spool) {
            [self fail:MCPlaybackError(MCPlaybackDiskError,
                                       @"There is not enough storage to prepare this track.", NO)];
            return;
        }
        mc_spool_set_length(_spool, _expected);
        [self startURL:_url];
    }
}
- (void)startURL:(NSURL *)url {
    if (!MCIsAllowedAudioURL(url, _customSource)) {
        mc_spool_finish(_spool, EACCES);
        [self fail:MCPlaybackError(
                       MCPlaybackURLError,
                       _customSource ? MCSourceURLFailure(url) : @"网易云返回了不支持的播放地址。", NO)];
        return;
    }
    __block NSURL *redirect = nil;
    __block NSError *responseError = nil;
    __block BOOL responseAccepted = NO;
    NSUInteger generation;
    @synchronized(self) {
        if (_cancelled)
            return;
        generation = ++_requestGeneration;
    }
    void (^responseBlock)(NSDictionary *) = ^(NSDictionary *response) {
        @synchronized(self) {
            if (self->_cancelled || generation != self->_requestGeneration)
                return;
        }
        NSInteger status = [response[@"status"] integerValue];
        if (status >= 300 && status < 400) {
            NSString *location = response[@"location"];
            NSURL *candidate = [location isKindOfClass:[NSString class]]
                                   ? [[NSURL URLWithString:location relativeToURL:url] absoluteURL]
                                   : nil;
            if (self->_redirects < 4 && MCIsAllowedAudioURL(candidate, self->_customSource))
                redirect = candidate;
            else
                responseError = MCPlaybackError(MCPlaybackURLError,
                                                self->_redirects >= 4 ? @"音源重定向次数过多（最多 4 次）。"
                                                : self->_customSource ? MCSourceURLFailure(candidate)
                                                                      : @"网易云返回了不支持的重定向地址。",
                                                NO);
            return;
        }
        if (status < 200 || status >= 300 || status == 206) {
            BOOL auth = status == 401 || status == 403 || status == 404 || status == 410;
            responseError = MCPlaybackError(
                auth ? MCPlaybackAccessError : MCPlaybackNetworkError,
                [NSString stringWithFormat:@"音频下载失败（HTTP %ld）：%@", (long)status,
                                           auth ? @"链接已失效或访问被拒绝，可重试或切换音源。"
                                                : @"服务器未返回可用的完整音频，请稍后重试。"],
                auth || status == 408 || status == 429 || status >= 500);
            return;
        }
        responseAccepted = YES;
        NSString *length = response[@"content-length"];
        if ([length respondsToSelector:@selector(longLongValue)] && [length longLongValue] > 0)
            mc_spool_set_length(self->_spool, (uint64_t)[length longLongValue]);
    };
    BOOL (^dataBlock)(const void *, size_t) = ^BOOL(const void *bytes, size_t length) {
        @synchronized(self) {
            if (self->_cancelled || generation != self->_requestGeneration)
                return NO;
        }
        if (!responseAccepted || redirect || responseError)
            return NO;
        if (mc_spool_append(self->_spool, bytes, length))
            return NO;
        if (!self->_announced && mc_spool_available(self->_spool) >= 4) {
            char magic[4];
            uint64_t offset = 0;
            if (mc_spool_read(self->_spool, magic, sizeof magic, &offset, mc_spool_revision(self->_spool)) ==
                    4 &&
                (!memcmp(magic, "fLaC", 4) || [self->_format isEqualToString:@"flac"]))
                [self announce:YES];
            else if (self.contentLength && [self identifyNative])
                [self announce:NO];
        }
        return YES;
    };
    void (^completionBlock)(NSError *) = ^(NSError *error) {
        @synchronized(self) {
            if (self->_cancelled || generation != self->_requestGeneration)
                return;
        }
        if (redirect) {
            self->_redirects++;
            [self startURL:redirect];
            return;
        }
        int spoolError = mc_spool_error(self->_spool);
        NSError *failure = responseError;
        if (!failure && spoolError)
            failure = MCPlaybackError(
                spoolError == ETIMEDOUT ? MCPlaybackNetworkError : MCPlaybackDiskError,
                spoolError == EFBIG ? @"This track exceeds the 1 GB streaming storage limit."
                : spoolError == ETIMEDOUT
                    ? @"The audio stream stopped responding. Check your connection and tap Retry."
                    : @"Unable to write the audio stream. Check free storage.",
                spoolError == ETIMEDOUT);
        if (!failure && (error || !responseAccepted))
            failure = MCPlaybackError(
                MCPlaybackNetworkError,
                MCSourceFailureText(error.localizedDescription, @"音频下载中断，请检查网络后重试。"), YES);
        mc_spool_finish(self->_spool, failure ? EIO : 0);
        if (!failure && mc_spool_error(self->_spool))
            failure = MCPlaybackError(MCPlaybackNetworkError,
                                      @"The audio download ended before the complete track arrived.", YES);
        if (failure)
            [self fail:failure];
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized(self) {
                    if (self->_cancelled)
                        return;
                }
                if (self.downloadCompleted)
                    self.downloadCompleted(self.path);
            });
            if (!self->_announced) {
                [self identifyNative];
                [self announce:[self->_format isEqualToString:@"flac"]];
            }
        }
    };
    NSDictionary *headers =
        @{@"Accept-Encoding" : @"identity", @"Accept" : @"audio/*,application/octet-stream"};
    MCHTTPClient *client = [MCHTTPClient sharedClient];
    MCRequest *request = _customSource ? [client sourceStreamURL:url
                                                         headers:headers
                                                        response:responseBlock
                                                            data:dataBlock
                                                      completion:completionBlock]
                                       : [client streamURL:url
                                                   headers:headers
                                                  response:responseBlock
                                                      data:dataBlock
                                                completion:completionBlock];
    @synchronized(self) {
        if (_cancelled || generation != _requestGeneration)
            [request cancel];
        else
            _request = request;
    }
}
- (void)cancel {
    MCRequest *request;
    @synchronized(self) {
        if (_cancelled)
            return;
        _cancelled = YES;
        _requestGeneration++;
        request = _request;
        _request = nil;
        mc_spool_cancel(_spool);
    }
    [request cancel];
}
@end
