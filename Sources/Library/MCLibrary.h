#import <Foundation/Foundation.h>

extern NSString *const MCLibraryDidChangeNotification;
// Notification userInfo["errors"] contains any asynchronous mutation/database errors.
@interface MCLibrary : NSObject
+ (MCLibrary *)sharedLibrary;
- (id)initWithDatabasePath:(NSString *)path documentsPath:(NSString *)documents;
- (void)scan:(void (^)(NSUInteger imported, NSArray *errors))completion;
- (void)tracksMatching:(NSString *)query completion:(void (^)(NSArray *tracks))completion;
- (void)favoriteTracks:(void (^)(NSArray *tracks))completion;
- (void)recentTracks:(void (^)(NSArray *tracks))completion;
- (void)setFavorite:(BOOL)favorite track:(NSDictionary *)track;
- (void)recordPlay:(NSDictionary *)track;
- (void)playlists:(void (^)(NSArray *playlists))completion;
- (void)createPlaylist:(NSString *)name completion:(void (^)(NSString *identifier))completion;
- (void)tracksInPlaylist:(NSString *)identifier completion:(void (^)(NSArray *tracks))completion;
- (void)addTrack:(NSDictionary *)track toPlaylist:(NSString *)identifier;
- (void)removeTrack:(NSString *)trackID fromPlaylist:(NSString *)identifier;
- (void)deletePlaylist:(NSString *)identifier;
- (void)lyricsForTrack:(NSDictionary *)track completion:(void (^)(NSString *text))completion;
@end
