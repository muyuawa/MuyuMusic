#import <UIKit/UIKit.h>
@interface MCArtwork : NSObject
+ (instancetype)sharedCache;
- (void)load:(NSString *)location into:(UIImageView *)view;
- (void)load:(NSString *)location into:(UIImageView *)view completion:(void (^)(UIImage *image))completion;
- (void)load:(NSString *)location into:(UIImageView *)view animated:(BOOL)animated completion:(void (^)(UIImage *image))completion;
- (void)clearDisk:(void (^)(void))completion;
@end
