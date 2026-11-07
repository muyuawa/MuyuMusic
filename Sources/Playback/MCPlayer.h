#import <UIKit/UIKit.h>
extern NSString *const MCPlayerDidChangeNotification;
extern NSString *const MCPlayerProgressNotification;

@interface MCPlayer : NSObject
+ (instancetype)sharedPlayer;
@property (nonatomic, readonly) NSArray *queue;
@property (nonatomic, readonly) NSUInteger index;
@property (nonatomic, readonly) NSDictionary *currentTrack;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL buffering;
@property (nonatomic, readonly) NSTimeInterval position;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSString *qualityLabel;
@property (nonatomic, readonly) NSString *playbackSourceName;
@property (nonatomic, readonly) NSError *error;
@property (nonatomic) NSInteger repeatMode; /* 0 off, 1 all, 2 one */
@property (nonatomic) BOOL shuffle;
@property (nonatomic, copy) NSString *preferredQuality;
- (void)playTracks:(NSArray *)tracks index:(NSUInteger)index;
- (void)enqueueTrack:(NSDictionary *)track;
- (void)removeQueueIndex:(NSUInteger)index;
- (void)moveQueueIndex:(NSUInteger)from toIndex:(NSUInteger)to;
- (void)toggle;
- (void)pause;
- (void)next;
- (void)previous;
- (void)seek:(NSTimeInterval)position;
- (void)retry;
- (void)handleRemoteEvent:(UIEvent *)event;
@end
