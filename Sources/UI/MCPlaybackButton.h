#import <UIKit/UIKit.h>
typedef NS_ENUM(NSUInteger, MCPlaybackIcon) {
    MCPlaybackIconPlay, MCPlaybackIconPause, MCPlaybackIconPrevious, MCPlaybackIconNext,
    MCPlaybackIconSequence, MCPlaybackIconRepeat, MCPlaybackIconRepeatOne,
    MCPlaybackIconShuffle, MCPlaybackIconFavorite, MCPlaybackIconDetails,
    MCPlaybackIconRecent, MCPlaybackIconLocal, MCPlaybackIconPlaylist,
    MCPlaybackIconAccount, MCPlaybackIconSearch, MCPlaybackIconSettings, MCPlaybackIconQueue
};
@interface MCPlaybackButton : UIButton
@property (nonatomic) MCPlaybackIcon icon;
@property (nonatomic, strong) UIColor *ink;
/* Optional thin contrast edge for a favorite drawn over complex artwork. */
@property (nonatomic, strong) UIColor *contrastOutline;
@property (nonatomic, strong) UIColor *fill;
@property (nonatomic, strong) UIColor *selectionFill;
@end
UIImage *MCPlayerSliderTrack(UIColor *color);
UIImage *MCPlayerSliderThumb(UIColor *color, BOOL highlighted);
