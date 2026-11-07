#import <UIKit/UIKit.h>
typedef NS_ENUM(NSUInteger, MCPlaybackIcon) {
    MCPlaybackIconPlay, MCPlaybackIconPause, MCPlaybackIconPrevious, MCPlaybackIconNext,
    MCPlaybackIconSequence, MCPlaybackIconRepeat, MCPlaybackIconRepeatOne,
    MCPlaybackIconShuffle, MCPlaybackIconFavorite, MCPlaybackIconDetails
};
@interface MCPlaybackButton : UIButton
@property (nonatomic) MCPlaybackIcon icon;
@property (nonatomic, strong) UIColor *ink;
@property (nonatomic, strong) UIColor *fill;
@end
UIImage *MCPlayerSliderTrack(UIColor *color);
UIImage *MCPlayerSliderThumb(UIColor *color, BOOL highlighted);
