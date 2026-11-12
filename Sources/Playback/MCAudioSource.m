#import "MCAudioSource.h"
#import "MCAudioPolicy.h"
#import "../Network/MCHTTPClient.h"
#import "../Network/MCSourceSecurity.h"
#include <errno.h>
#include <string.h>
#include <unistd.h>

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
    NSString *_localPath, *_format, *_contentType, *_formatExtension, *_playbackAlias;
    MCRequest *_request;
    uint64_t _expected;
    NSUInteger _redirects, _requestGeneration;
    BOOL _customSource;
    BOOL _cancelled, _announced, _started;
}
@end
@implementation MCAudioSource
- (id)initWithLocalPath:(NSString *)path {
    if ((self = [super init])) {
        _localPath = [path copy];
        _format = path.pathExtension.lowercaseString;
    }
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
        if (@available(iOS 7.0, *))
            _allowsProgressiveNativePlayback = YES;
        _customSource = customSource;
        _url = url;
        _expected = length;
        _format = [format isKindOfClass:[NSString class]] ? [format lowercaseString] : @"";
    }
    return self;
}
- (void)dealloc {
    if (_playbackAlias)
        unlink(_playbackAlias.fileSystemRepresentation);
    mc_spool_destroy(_spool);
}
- (MCPlaybackSpool *)spool {
    return _spool;
}
- (NSString *)path {
    if (_playbackAlias)
        return _playbackAlias;
    const char *path = mc_spool_path(_spool);
    return path ? [NSString stringWithUTF8String:path] : nil;
}
- (NSString *)contentType {
    return _contentType ?: @"public.mp3";
}
- (uint64_t)contentLength {
    return mc_spool_expected_length(_spool);
}
/* Actual container/frame bytes win over URL suffixes and service hints. */
- (BOOL)identifyFormat {
    if (_formatExtension)
        return YES;
    if (mc_spool_available(_spool) < 4)
        return NO;
    unsigned char bytes[12] = {0};
    uint64_t offset = 0;
    ssize_t count = mc_spool_read_timed(_spool, bytes, sizeof bytes, &offset,
                                        mc_spool_revision(_spool), 0);
    if (count < 4)
        return NO;
    /* ID3 tags may precede FLAC or AAC as well as MP3. Skip their bounded
       synchsafe size before deciding which decoder owns the payload. */
    if (!memcmp(bytes, "ID3", 3)) {
        if (count < 10)
            return NO;
        if (bytes[3] >= 2 && bytes[3] <= 4 &&
            !((bytes[6] | bytes[7] | bytes[8] | bytes[9]) & 0x80)) {
            offset = 10 + ((uint64_t)bytes[6] << 21) + ((uint64_t)bytes[7] << 14) +
                     ((uint64_t)bytes[8] << 7) + bytes[9];
            if (bytes[3] == 4 && (bytes[5] & 0x10))
                offset += 10;
            if (mc_spool_available(_spool) < offset + 4)
                return NO;
            count = mc_spool_read_timed(_spool, bytes, sizeof bytes, &offset,
                                        mc_spool_revision(_spool), 0);
            if (count < 4)
                return NO;
        }
    }
    NSString *extension = nil;
    if (!memcmp(bytes, "fLaC", 4))
        extension = @"flac";
    else if (count >= 12 && !memcmp(bytes + 4, "ftyp", 4))
        extension = @"m4a";
    else if (count >= 12 && !memcmp(bytes, "RIFF", 4) && !memcmp(bytes + 8, "WAVE", 4))
        extension = @"wav";
    else if (count >= 12 && !memcmp(bytes, "FORM", 4) &&
             (!memcmp(bytes + 8, "AIFF", 4) || !memcmp(bytes + 8, "AIFC", 4)))
        extension = @"aiff";
    else if (bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0)
        extension = @"aac";
    else if (bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0)
        extension = @"mp3";
    else if (mc_spool_complete(_spool))
        extension = [_format isEqual:@"alac"] ? @"m4a" : ([_format isEqual:@"aif"] ? @"aiff" : _format);
    NSDictionary *types = @{@"mp3":@"public.mp3", @"flac":@"org.xiph.flac",
                            @"m4a":@"com.apple.m4a-audio", @"aac":@"public.aac-audio",
                            @"wav":@"com.microsoft.waveform-audio", @"aiff":@"public.aiff-audio"};
    NSString *type = extension ? types[extension] : nil;
    if (!type)
        return NO;
    _formatExtension = extension;
    _contentType = type;
    return YES;
}
- (void)announce:(BOOL)flac {
    @synchronized(self) {
        if (_cancelled || _announced)
            return;
        /* iOS 6 AVURLAsset needs a recognized suffix, including cache hits.
           A hard link keeps the original cache/spool and avoids copying audio. */
        NSString *original = [self path];
        if (_formatExtension && ![original.pathExtension.lowercaseString isEqual:_formatExtension]) {
            NSString *name = [[@"muyu-playback-" stringByAppendingString:[[NSUUID UUID] UUIDString]]
                stringByAppendingPathExtension:_formatExtension];
            NSString *alias = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
            if (link(original.fileSystemRepresentation, alias.fileSystemRepresentation)) {
                [self fail:MCPlaybackError(MCPlaybackDiskError,
                    @"无法准备音频播放文件，请检查剩余存储空间后重试。", NO)];
                return;
            }
            _playbackAlias = alias;
        }
        _announced = YES;
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
                [self identifyFormat];
                if (!mc_spool_available(self->_spool))
                    [self fail:MCPlaybackError(MCPlaybackFileError,
                                               @"This audio file is empty or unreadable.", NO)];
                else
                    [self announce:[self->_formatExtension isEqual:@"flac"]];
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
        if (!self->_announced && [self identifyFormat]) {
            BOOL flac = [self->_formatExtension isEqual:@"flac"];
            if (flac || (self.allowsProgressiveNativePlayback && self.contentLength))
                [self announce:flac];
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
            if (!self->_announced) {
                [self identifyFormat];
                [self announce:[self->_formatExtension isEqual:@"flac"]];
            }
            if (!self->_announced)
                return;
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized(self) {
                    if (self->_cancelled)
                        return;
                }
                if (self.downloadCompleted)
                    self.downloadCompleted(self.path);
            });
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
