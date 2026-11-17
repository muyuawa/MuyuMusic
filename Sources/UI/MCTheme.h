#import <UIKit/UIKit.h>
extern NSString *const MCThemeDidChangeNotification;
typedef NS_ENUM(NSUInteger, MCTypeRole) {
    MCTypeTitle, MCTypeSection, MCTypeBody, MCTypeLabel, MCTypeCaption
};
/* The app's single ThemeManager, shared by legacy and Material components. */
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
@property (nonatomic, readonly) UIColor *surfaceContainer;
@property (nonatomic, readonly) UIColor *surfaceContainerHigh;
@property (nonatomic, readonly) UIColor *onSurface;
@property (nonatomic, readonly) UIColor *onSurfaceVariant;
@property (nonatomic, readonly) UIColor *primaryContainer;
@property (nonatomic, readonly) UIColor *onPrimaryContainer;
@property (nonatomic, readonly) UIColor *outline;
@property (nonatomic, readonly) CGFloat smallRadius, cardRadius, coverRadius;
- (UIFont *)fontForRole:(MCTypeRole)role;
- (BOOL)setValidatedHex:(NSString *)hex;
- (void)apply;
- (void)applyToNavigationBar:(UINavigationBar *)bar;
- (void)applyToTabBar:(UITabBar *)bar;
- (void)applyToSearchBar:(UISearchBar *)bar;
- (void)applyToSegmentedControl:(UISegmentedControl *)control;
- (void)updateArtwork:(UIImage *)image;
@end

UIButton *MCTextButton(void);
