#import <Foundation/Foundation.h>
@class MCSourceTask;
@interface MCSourceAPI : NSObject
+ (NSDictionary *)validateConfiguration:(NSDictionary *)configuration error:(NSError **)error;
+ (NSDictionary *)resourceFromData:(NSData *)data
                          response:(NSDictionary *)response
                     configuration:(NSDictionary *)configuration
                             error:(NSError **)error;
+ (MCSourceTask *)resolveConfiguration:(NSDictionary *)configuration
                                 track:(NSDictionary *)track
                               quality:(NSString *)quality
                            completion:(void (^)(NSDictionary *, NSError *))completion;
@end
