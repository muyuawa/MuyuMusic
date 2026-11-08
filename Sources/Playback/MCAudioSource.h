#import <Foundation/Foundation.h>
#import "MCPlaybackCore.h"
@class MCAudioCacheLease;

extern NSString *const MCPlaybackErrorDomain;
extern NSString *const MCPlaybackRetryableKey;
typedef NS_ENUM(NSInteger, MCPlaybackErrorCode) {
    MCPlaybackFileError = 1,
    MCPlaybackDecodeError,
    MCPlaybackOutputError,
    MCPlaybackNetworkError,
    MCPlaybackAccessError,
    MCPlaybackDiskError,
    MCPlaybackURLError,
    MCPlaybackUnsupportedError
};
NSError *MCPlaybackError(MCPlaybackErrorCode code, NSString *description, BOOL retryable);
/* Owns a disk spool. Callback blocks are always dispatched to the main queue.
   The spool may be read on the decoder worker while the transport appends it. */
@interface MCAudioSource : NSObject
@property (nonatomic, readonly) MCPlaybackSpool *spool;
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSString *contentType;
@property (nonatomic, readonly) uint64_t contentLength;
/* AVAssetResourceLoadingDataRequest requires iOS 7. Disable early native
   readiness on iOS 6; FLAC uses our own decoder and remains incremental. */
@property (nonatomic) BOOL allowsProgressiveNativePlayback;
@property (nonatomic, copy) void (^ready)(BOOL flac);
@property (nonatomic, copy) void (^failure)(NSError *error);
@property (nonatomic, copy) void (^downloadCompleted)(NSString *path);
@property (nonatomic, strong) MCAudioCacheLease *cacheLease;
- (id)initWithLocalPath:(NSString *)path;
- (id)initWithURL:(NSURL *)url
    expectedLength:(uint64_t)length
            format:(NSString *)format
      customSource:(BOOL)customSource;
- (id)initWithURL:(NSURL *)url expectedLength:(uint64_t)length format:(NSString *)format;
- (void)start;
- (void)cancel;
@end
