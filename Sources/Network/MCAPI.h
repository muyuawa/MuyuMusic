#import <Foundation/Foundation.h>
typedef void (^MCAPICompletion)(id result, NSError *error);
@interface MCAPI : NSObject
+ (instancetype)sharedAPI;
@property (nonatomic, readonly, copy) NSDictionary *profile;
@property (nonatomic, readonly) BOOL loggedIn;
- (void)search:(NSString *)query
          type:(NSInteger)type
        offset:(NSUInteger)offset
    completion:(MCAPICompletion)completion;
- (void)discover:(MCAPICompletion)completion;
- (void)dailyRecommendations:(MCAPICompletion)completion;
/* Playlist/likes return tracks, totalCount, unavailableTrackIDs. No invented
   metadata is substituted when the service omits an ID's details. */
- (void)playlist:(NSString *)identifier completion:(MCAPICompletion)completion;
- (void)album:(NSString *)identifier completion:(MCAPICompletion)completion;
- (void)artist:(NSString *)identifier completion:(MCAPICompletion)completion;
- (void)userPlaylists:(MCAPICompletion)completion;
- (void)editablePlaylists:(MCAPICompletion)completion;
- (void)addTrack:(NSString *)trackID toPlaylist:(NSString *)playlistID completion:(MCAPICompletion)completion;
- (void)subscribePlaylist:(NSString *)identifier completion:(MCAPICompletion)completion;
- (void)likedTracks:(MCAPICompletion)completion;
- (void)likeTrack:(NSString *)identifier liked:(BOOL)liked completion:(MCAPICompletion)completion;
- (void)songURL:(NSString *)identifier quality:(NSString *)quality completion:(MCAPICompletion)completion;
- (void)lyrics:(NSString *)identifier completion:(MCAPICompletion)completion;
- (void)createLoginKey:(MCAPICompletion)completion;
- (void)pollLoginKey:(NSString *)key completion:(MCAPICompletion)completion;
- (void)refreshLogin:(MCAPICompletion)completion;
- (void)logout;
@end
