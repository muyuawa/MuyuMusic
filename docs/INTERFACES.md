# Shared subsystem contracts

All Objective-C uses ARC, iOS 6-compatible APIs and dispatch blocks. iOS 7-only paths are protected by runtime availability checks. Completion blocks arrive on the main queue unless a stream callback explicitly says worker. All asynchronous methods return immediately. Never log cookies or QR tokens.

## Track and catalog dictionaries

Track: `id` NSString; `title`, `artist`, `album` NSString; `artwork` NSString URL/path; `duration` NSNumber seconds; `path` NSString for local files. Optional: `format` NSString, `bitDepth`, `sampleRate` NSNumber. Catalog item: `id`, `title`, `artwork`, `subtitle` NSString. Local IDs begin `local:`. Artist/album IDs may be included as `artistID`, `albumID`.

## Network — Sources/Network/MCAPI.h

`typedef void (^MCAPICompletion)(id result, NSError *error);`

`+[MCAPI sharedAPI]`; readonly `NSDictionary *profile`; readonly `BOOL loggedIn`.

Methods:
`-search:(NSString *)query type:(NSInteger)type offset:(NSUInteger)offset completion:(MCAPICompletion)completion` (type 1 songs, 10 albums, 100 artists, 1000 playlists; result dictionary `items` array, `more` BOOL).
`-discover:(MCAPICompletion)completion` → catalog array.
`-dailyRecommendations:(MCAPICompletion)completion` → login required, dictionary `tracks`, `totalCount`, `unavailableTrackIDs` (empty). Uses `/api/v3/discovery/recommend/songs`, preserves `data.dailySongs` order and genuine metadata; missing/malformed data errors rather than inventing recommendations.
`-playlist:(NSString *)identifier completion:(MCAPICompletion)completion` → dictionary `title`, `tracks` array, `totalCount`, `unavailableTrackIDs` string array. Fetch every ID in bounded batches; omitted detail records are reported without blocking available real tracks.
`-album:(NSString *)identifier completion:(MCAPICompletion)completion` → same.
`-artist:(NSString *)identifier completion:(MCAPICompletion)completion` → dictionary `title`, `tracks`, `albums` catalog array.
`-userPlaylists:(MCAPICompletion)completion` → catalog array.
`-likedTracks:(MCAPICompletion)completion` → dictionary `tracks`, `totalCount`, `unavailableTrackIDs`, matching playlist detail results.
`-likeTrack:(NSString *)identifier liked:(BOOL)liked completion:(MCAPICompletion)completion`.
`-editablePlaylists:(MCAPICompletion)completion` → all current-account-created playlists, filtered by normalized creator ID after pagination; subscribed playlists are not offered as add targets.
`-addTrack:(NSString *)trackID toPlaylist:(NSString *)playlistID completion:(MCAPICompletion)completion`; `-subscribePlaylist:(NSString *)identifier completion:(MCAPICompletion)completion`. Both require login and valid NetEase IDs, preserve service/network failures, and complete on main.
`-songURL:(NSString *)identifier quality:(NSString *)quality completion:(MCAPICompletion)completion` → dictionary `url`, `format`, `bitrate`, `bitDepth`, `sampleRate`, `expires` (optional Unix time), `size` (optional); denied/trial-only rights → NSError, never silently substitute preview.
`-lyrics:(NSString *)identifier completion:(MCAPICompletion)completion` → NSString LRC.
`-createLoginKey:(MCAPICompletion)completion` → NSDictionary `key`, `url`.
`-pollLoginKey:(NSString *)key completion:(MCAPICompletion)completion` → NSDictionary `status` numeric 800/801/802/803; on authorized save session.
`-refreshLogin:(MCAPICompletion)completion`; `-logout`.

## Transport — Sources/Network/MCHTTPClient.h

`MCRequest` has `-cancel`.
`+[MCHTTPClient sharedClient]`
`-requestURL:(NSURL *)url method:(NSString *)method body:(NSData *)body headers:(NSDictionary *)headers completion:(void (^)(NSData *, NSDictionary *, NSError *))completion` → MCRequest; response dictionary `status` NSNumber and lower-case header keys.
`-streamURL:(NSURL *)url headers:(NSDictionary *)headers response:(void (^)(NSDictionary *))response data:(BOOL (^)(const void *, size_t))data completion:(void (^)(NSError *))completion` → MCRequest. Response/data/completion for STREAM ONLY on worker thread; data returns NO to cancel. Uses 32KB or smaller blocks, bounded workers, HTTPS and CA verification. No whole-song buffering. Caller handles redirects only to HTTPS trusted TLS endpoints. API cookies must never be forwarded to other hosts.

`sourceRequestURL:method:body:headers:timeout:completion:` and `sourceStreamURL:headers:response:data:completion:` are the explicit custom-source paths. They enforce the default-enabled `music.sources.httpsOnly` preference; disabling it permits HTTP for custom control/audio and permitted audio redirects. Ordinary transport and NetEase remain HTTPS-only. Audio streams strip credentials regardless of source; custom control can send only the source's own configured credentials. Control responses are bounded to 2 MiB, while audio remains streamed to the disk spool.

## Library — Sources/Library/MCLibrary.h and MCLyrics.h

`+[MCLibrary sharedLibrary]`; `-initWithDatabasePath:(NSString *)path documentsPath:(NSString *)documents` for host tests.
`-scan:(void (^)(NSUInteger imported, NSArray *errors))completion`.
`-tracksMatching:(NSString *)query completion:(void (^)(NSArray *tracks))completion`.
`-favoriteTracks:(void (^)(NSArray *))completion`; `-recentTracks:(void (^)(NSArray *))completion`.
`-setFavorite:(BOOL)favorite track:(NSDictionary *)track`; `-recordPlay:(NSDictionary *)track`.
`-playlists:(void (^)(NSArray *))completion` → catalog items.
`-createPlaylist:(NSString *)name completion:(void (^)(NSString *identifier))completion`.
`-tracksInPlaylist:(NSString *)identifier completion:(void (^)(NSArray *))completion`.
`-addTrack:(NSDictionary *)track toPlaylist:(NSString *)identifier`; `-removeTrack:(NSString *)trackID fromPlaylist:(NSString *)identifier`; `-deletePlaylist:(NSString *)identifier`.
`-lyricsForTrack:(NSDictionary *)track completion:(void (^)(NSString *))completion`.
Notification `MCLibraryDidChangeNotification`.

`+[MCLyrics parse:(NSString *)text]` → array of dictionaries `time` NSNumber seconds, `text` NSString, sorted ascending, expands multiple time tags, respects offset tag; `+[MCLyrics indexAtTime:(NSTimeInterval)time lines:(NSArray *)lines]` → NSInteger (-1 before first).

## Player — Sources/Playback/MCPlayer.h

`+[MCPlayer sharedPlayer]`; properties readonly `NSArray *queue`, `NSUInteger index`, `NSDictionary *currentTrack`, `BOOL playing`, `BOOL buffering`, `NSTimeInterval position`, `NSTimeInterval duration`, `NSString *qualityLabel`, `NSError *error`; readwrite `NSInteger repeatMode` (0 off, 1 all, 2 one), `BOOL shuffle`, `NSString *preferredQuality` (`standard`, `exhigh`, `lossless`).
`-playTracks:(NSArray *)tracks index:(NSUInteger)index`; `-enqueueTrack:(NSDictionary *)track`; `-removeQueueIndex:(NSUInteger)index`; `-moveQueueIndex:(NSUInteger)from toIndex:(NSUInteger)to`; `-toggle`; `-pause`; `-next`; `-previous`; `-seek:(NSTimeInterval)position`; `-retry`; `-handleRemoteEvent:(UIEvent *)event`.
Notifications `MCPlayerDidChangeNotification` (track/state/error/queue), `MCPlayerProgressNotification` (about 2Hz while visible/playing). All state and notifications on main queue. `error.localizedDescription` is user facing. Empty queue safe. Root UI observes notifications; root app receives remote events and forwards them.

`MCQueueTransition` exposes the preview track. `MCPlayer -queueTransitionForward:` prepares a side-effect-free next/previous selection, including copied shuffle state. `-commitQueueTransition:` returns NO for stale queue/index/generation/repeat/shuffle or another player; successful commit plays the exact preview and updates history/visited state once. Both run on main. Carousel cancellation discards the plan without changing playback.
