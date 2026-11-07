#import <AVFoundation/AVFoundation.h>
@class MCAudioSource;
/* HTTPS is fetched by the TLS transport; AVPlayer sees a custom-scheme byte
   resource. Range readers never block the resource loader delegate queue. */
@interface MCNativeResourceLoader : NSObject <AVAssetResourceLoaderDelegate>
@property (nonatomic, readonly) NSURL *URL;
@property (nonatomic, readonly) dispatch_queue_t delegateQueue;
@property (nonatomic, readonly) NSError *error;
@property (nonatomic, copy) void (^failure)(NSError *error);
- (id)initWithSource:(MCAudioSource *)source;
- (void)cancel;
@end
