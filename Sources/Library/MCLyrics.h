#import <Foundation/Foundation.h>

@interface MCLyrics : NSObject
+ (NSArray *)parse:(NSString *)text;
+ (NSInteger)indexAtTime:(NSTimeInterval)time lines:(NSArray *)lines;
@end
