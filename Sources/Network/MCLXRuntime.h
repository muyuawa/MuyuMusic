#import <Foundation/Foundation.h>
@class MCSourceTask;
@interface MCLXRuntime : NSObject
- (instancetype)initWithScript:(NSString *)script information:(NSDictionary *)information;
@property (nonatomic, readonly) NSDictionary *sources;
- (void)start:(void (^)(NSDictionary *sources, NSError *error))completion;
- (MCSourceTask *)resolveTrack:(NSDictionary *)track
                       quality:(NSString *)quality
                    completion:(void (^)(NSDictionary *resource, NSError *error))completion;
- (void)invalidate;
@end
