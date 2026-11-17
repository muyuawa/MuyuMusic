#import <UIKit/UIKit.h>
#import "MCMaterialControls.h"

/* Image and metadata share one clipped card; playback actions stay in the controller. */
@interface MCPlayerCoverCard : UIView
@property (nonatomic, strong, readonly) UIImageView *artworkView;
@property (nonatomic, strong, readonly) UIButton *titleButton;
@property (nonatomic, strong, readonly) MCMaterialChip *qualityButton;
@property (nonatomic, strong, readonly) MCPlaybackButton *favoriteButton;
- (void)showTitle:(NSString *)title artist:(NSString *)artist quality:(NSString *)quality;
/* Called with the actual loaded image, or nil for the theme placeholder. */
- (void)updateArtwork:(UIImage *)image;
@end
