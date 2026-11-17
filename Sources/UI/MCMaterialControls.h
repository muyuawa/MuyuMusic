#import <UIKit/UIKit.h>
#import "MCPlaybackButton.h"

@interface MCMaterialCard : UIView
@property (nonatomic) BOOL emphasized;
@end

@interface MCMaterialSegmentedControl : UISegmentedControl
@end

/* A small filled segmented button, with explicit 44pt child hit areas. */
@interface MCMaterialModeControl : UIControl
@property (nonatomic) NSInteger selectedSegmentIndex;
- (id)initWithItems:(NSArray *)items;
@end

@interface MCMaterialChip : UIButton
@property (nonatomic) BOOL leading;
/* Optional cover-local colors; other chips retain the shared theme. */
@property (nonatomic, strong) UIColor *fill;
@property (nonatomic, strong) UIColor *ink;
@end

@interface MCMaterialButton : UIButton
@property (nonatomic) BOOL filled;
@property (nonatomic) BOOL vertical;
- (id)initWithTitle:(NSString *)title icon:(MCPlaybackIcon)icon filled:(BOOL)filled;
@end

/* A bounded, reusable shelf tile. The controller owns navigation/actions. */
@interface MCCatalogTile : UIControl
- (void)showItem:(NSDictionary *)item;
@end
