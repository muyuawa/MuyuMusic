#import <UIKit/UIKit.h>
extern NSString *const MCThemeDidChangeNotification;
@interface MCTheme : NSObject
+ (instancetype)sharedTheme;
@property (nonatomic, copy) NSString *hex;
@property (nonatomic) BOOL dark;
@property (nonatomic) BOOL followArtwork;
@property (nonatomic, readonly) UIColor *primary;
@property (nonatomic, readonly) UIColor *onPrimary;
@property (nonatomic, readonly) UIColor *background;
@property (nonatomic, readonly) UIColor *surface;
@property (nonatomic, readonly) UIColor *text;
@property (nonatomic, readonly) UIColor *muted;
@property (nonatomic, readonly) UIColor *accent;
- (BOOL)setValidatedHex:(NSString *)hex;
- (void)apply;
- (void)updateArtwork:(UIImage *)image;
@end
