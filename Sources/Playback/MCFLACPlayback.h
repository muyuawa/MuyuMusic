#import <Foundation/Foundation.h>
@class MCAudioSource;
/* All blocks arrive on main. Cancel never waits for network, decoder or AQ. */
@interface MCFLACPlayback : NSObject
@property (nonatomic, copy) void (^metadata)(double sampleRate, unsigned bits, double duration);
@property (nonatomic, copy) void (^bufferingChanged)(BOOL buffering);
@property (nonatomic, copy) void (^failure)(NSError *error);
@property (nonatomic, copy) void (^ended)(void);
@property (nonatomic, readonly) NSTimeInterval position;
@property (nonatomic, readonly) BOOL buffering;
- (id)initWithSource:(MCAudioSource *)source position:(NSTimeInterval)position playing:(BOOL)playing;
- (void)start;
- (void)setPlaying:(BOOL)playing;
- (void)seek:(NSTimeInterval)position;
- (void)cancel;
@end
