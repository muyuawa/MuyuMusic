#import <Foundation/Foundation.h>
extern NSString *const MCLyricsOptionsDidChangeNotification;
BOOL MCLyricsShowTranslation(void);
BOOL MCLyricsUseRomanization(void);
void MCSetLyricsShowTranslation(BOOL value);
void MCSetLyricsUseRomanization(BOOL value);

@interface MCLyrics : NSObject
+ (NSArray *)parse:(NSString *)text;
+ (NSArray *)parseOriginal:(NSString *)original translation:(NSString *)translation romanization:(NSString *)romanization;
+ (NSString *)displayTextForLine:(NSDictionary *)line romanization:(BOOL)romanization;
+ (NSInteger)indexAtTime:(NSTimeInterval)time lines:(NSArray *)lines;
@end
