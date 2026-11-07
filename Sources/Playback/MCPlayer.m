#import "MCPlayer.h"
#import "MCAudioSource.h"
#import "MCFLACPlayback.h"
#import "MCNativeResourceLoader.h"
#import "MCPlaybackCore.h"
#import "MCAudioCache.h"
#import "MCAudioPolicy.h"
#import "../Network/MCAPI.h"
#import "../Network/MCMusicSources.h"
#import "../Library/MCLibrary.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaPlayer/MediaPlayer.h>
#import <ImageIO/ImageIO.h>
#include <math.h>

NSString *const MCPlayerDidChangeNotification = @"MCPlayerDidChangeNotification";
NSString *const MCPlayerProgressNotification = @"MCPlayerProgressNotification";
static void *MCPlayerItemContext = &MCPlayerItemContext;
#define MC_MAIN(method)                                                                                      \
    do {                                                                                                     \
        if (![NSThread isMainThread]) {                                                                      \
            dispatch_async(dispatch_get_main_queue(), ^{                                                     \
                method;                                                                                      \
            });                                                                                              \
            return;                                                                                          \
        }                                                                                                    \
    } while (0)

@interface MCPlayer () {
    NSArray *_queue;
    NSUInteger _index, _generation;
    BOOL _playing, _buffering, _desiredPlaying, _shuffle, _resumeAfterInterruption;
    NSInteger _repeatMode;
    NSString *_preferredQuality, *_qualityLabel;
    NSString *_activeCacheKey;
    MCSourceTask *_resolutionTask;
    NSDictionary *_sourceEntrySnapshot;
    NSTimeInterval _position, _duration, _savedPosition;
    NSError *_error;
    unsigned _retryAttempts;
    AVPlayer *_nativePlayer;
    AVPlayerItem *_nativeItem;
    AVURLAsset *_nativeAsset;
    MCAudioSource *_source;
    MCFLACPlayback *_flacPlayer;
    MCNativeResourceLoader *_nativeLoader;
    BOOL _nativePrepared, _nativeSeeking, _flacSeeking;
    NSMutableArray *_history;
    NSMutableData *_shuffleVisited;
    NSTimer *_progressTimer;
    MPMediaItemArtwork *_nowArtwork;
    BOOL _observingNative;
    NSUInteger _nativeSeekGeneration;
}
@end

@implementation MCPlayer
+ (instancetype)sharedPlayer {
    static MCPlayer *player;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        player = [[MCPlayer alloc] init];
    });
    return player;
}
- (id)init {
    if ((self = [super init])) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *cache =
                [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
            NSString *legacyLog =
                [cache stringByAppendingPathComponent:@"MuyuMusic/PlaybackDiagnostics.json"];
            [[NSFileManager defaultManager] removeItemAtPath:legacyLog error:NULL];
        });
        _queue = @[];
        _index = NSNotFound;
        _history = [NSMutableArray array];
        _shuffleVisited = [NSMutableData data];
        _qualityLabel = @"—";
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        _repeatMode = [defaults integerForKey:@"player.repeatMode"];
        if (_repeatMode < 0 || _repeatMode > 2)
            _repeatMode = 0;
        _shuffle = [defaults boolForKey:@"player.shuffle"];
        _preferredQuality = [defaults stringForKey:@"player.preferredQuality"];
        if (![@[ @"standard", @"exhigh", @"lossless" ] containsObject:_preferredQuality ?: @""])
            _preferredQuality = @"lossless";
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(sourcesChanged:)
                       name:MCMusicSourcesDidChangeNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(interruption:)
                       name:AVAudioSessionInterruptionNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(routeChanged:)
                       name:AVAudioSessionRouteChangeNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(mediaReset:)
                       name:AVAudioSessionMediaServicesWereResetNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(becameActive:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
            self->_progressTimer = [NSTimer timerWithTimeInterval:0.5
                                                           target:self
                                                         selector:@selector(tick:)
                                                         userInfo:nil
                                                          repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:self->_progressTimer forMode:NSRunLoopCommonModes];
        });
    }
    return self;
}
- (void)sourcesChanged:(NSNotification *)notification {
    NSString *identifier = notification.userInfo[@"removedIdentifier"];
    if ([identifier isKindOfClass:[NSString class]])
        [[MCAudioCache sharedCache] invalidateSourceIdentifier:identifier];
}
- (NSArray *)queue {
    return _queue;
}
- (NSUInteger)index {
    return _index;
}
- (NSDictionary *)currentTrack {
    return _index < [_queue count] ? _queue[_index] : nil;
}
- (BOOL)playing {
    return _playing;
}
- (BOOL)buffering {
    return _buffering;
}
- (NSTimeInterval)position {
    return [self enginePosition];
}
- (NSTimeInterval)duration {
    return _duration;
}
- (NSString *)qualityLabel {
    return _qualityLabel;
}
- (NSString *)playbackSourceName {
    return [self.currentTrack[@"path"] length] ? @"本地音乐" : (_sourceEntrySnapshot[@"name"] ?: @"网易云");
}
- (NSError *)error {
    return _error;
}
- (NSInteger)repeatMode {
    return _repeatMode;
}
- (BOOL)shuffle {
    return _shuffle;
}
- (NSString *)preferredQuality {
    return _preferredQuality;
}
- (void)setRepeatMode:(NSInteger)mode {
    MC_MAIN([self setRepeatMode:mode]);
    mode = MAX(0, MIN(2, mode));
    if (_repeatMode == mode)
        return;
    _repeatMode = mode;
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:@"player.repeatMode"];
    [self changed];
}
- (void)setShuffle:(BOOL)shuffle {
    MC_MAIN([self setShuffle:shuffle]);
    if (_shuffle == shuffle)
        return;
    _shuffle = shuffle;
    [self resetShuffle];
    [_history removeAllObjects];
    [[NSUserDefaults standardUserDefaults] setBool:shuffle forKey:@"player.shuffle"];
    [self changed];
}
- (void)setPreferredQuality:(NSString *)quality {
    MC_MAIN([self setPreferredQuality:quality]);
    if (![@[ @"standard", @"exhigh", @"lossless" ] containsObject:quality ?: @""])
        return;
    _preferredQuality = [quality copy];
    [[NSUserDefaults standardUserDefaults] setObject:quality forKey:@"player.preferredQuality"];
    [self changed];
}
- (void)resetShuffle {
    _shuffleVisited = [NSMutableData dataWithLength:[_queue count]];
    if (_index < [_queue count])
        ((unsigned char *)[_shuffleVisited mutableBytes])[_index] = 1;
}
- (void)changed {
    NSAssert([NSThread isMainThread], @"Player state must be published on main");
    [self updateNowPlaying];
    [[NSNotificationCenter defaultCenter] postNotificationName:MCPlayerDidChangeNotification object:self];
}
- (NSTimeInterval)enginePosition {
    double position = _savedPosition;
    if (_flacPlayer)
        position = _flacSeeking ? _savedPosition : _flacPlayer.position;
    else if (_nativeSeeking)
        position = _savedPosition;
    else if (_nativePlayer && _nativeItem.status == AVPlayerItemStatusReadyToPlay) {
        double value = CMTimeGetSeconds(_nativePlayer.currentTime);
        if (isfinite(value) && value >= 0)
            position = value;
    }
    return mc_playback_seek(position, _duration);
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    if (!_playing && [UIApplication sharedApplication].applicationState != UIApplicationStateActive)
        return;
    _position = [self enginePosition];
    if (_flacPlayer) {
        BOOL buffering = _desiredPlaying && _flacPlayer.buffering;
        if (_buffering != buffering) {
            _buffering = buffering;
            [self changed];
        }
    }
    if (_nativeItem && _nativeItem.status == AVPlayerItemStatusReadyToPlay) {
        double duration = CMTimeGetSeconds(_nativeItem.duration);
        if (isfinite(duration) && duration > 0)
            _duration = duration;
    }
    if (_nativeItem && _desiredPlaying && !_nativeSeeking &&
        _nativeItem.status == AVPlayerItemStatusReadyToPlay) {
        BOOL buffering = _nativeItem.playbackBufferEmpty && !_nativeItem.playbackLikelyToKeepUp;
        if (_buffering != buffering) {
            _buffering = buffering;
            [self changed];
        }
    }
    [self updateNowPlaying];
    [[NSNotificationCenter defaultCenter] postNotificationName:MCPlayerProgressNotification object:self];
}
- (void)playTracks:(NSArray *)tracks index:(NSUInteger)index {
    MC_MAIN([self playTracks:tracks index:index]);
    if (![tracks isKindOfClass:[NSArray class]])
        return;
    NSMutableArray *valid = [NSMutableArray array];
    NSUInteger selected = NSNotFound;
    for (NSUInteger i = 0; i < [tracks count]; i++) {
        id track = tracks[i];
        if ([track isKindOfClass:[NSDictionary class]] && [track[@"id"] isKindOfClass:[NSString class]]) {
            if (i == index)
                selected = [valid count];
            [valid addObject:[track copy]];
        }
    }
    [self stopEngines];
    _generation++;
    _queue = [valid copy];
    _index = selected != NSNotFound ? selected : ([_queue count] ? 0 : NSNotFound);
    [_history removeAllObjects];
    [self resetShuffle];
    _retryAttempts = 0;
    _savedPosition = _position = 0;
    _nowArtwork = nil;
    _desiredPlaying = [_queue count] > 0;
    _playing = _desiredPlaying;
    _error = nil;
    _duration = 0;
    _qualityLabel = @"—";
    if (_desiredPlaying)
        [self beginTrackAt:0];
    else {
        _buffering = NO;
        [self changed];
    }
}
- (void)enqueueTrack:(NSDictionary *)track {
    MC_MAIN([self enqueueTrack:track]);
    if (![track isKindOfClass:[NSDictionary class]] || ![track[@"id"] isKindOfClass:[NSString class]])
        return;
    NSMutableArray *queue = [_queue mutableCopy];
    [queue addObject:[track copy]];
    _queue = [queue copy];
    if (_index == NSNotFound) {
        _index = 0;
        _duration = [self.currentTrack[@"duration"] doubleValue];
    }
    [self resetShuffle];
    [self changed];
}
- (void)removeQueueIndex:(NSUInteger)index {
    MC_MAIN([self removeQueueIndex:index]);
    if (index >= [_queue count])
        return;
    BOOL removedCurrent = index == _index;
    NSUInteger nextIndex = mc_playback_remove_index([_queue count], _index, index);
    NSMutableArray *queue = [_queue mutableCopy];
    [queue removeObjectAtIndex:index];
    _queue = [queue copy];
    NSMutableArray *history = [NSMutableArray array];
    for (NSNumber *old in _history) {
        NSUInteger value = [old unsignedIntegerValue];
        if (value != index)
            [history addObject:@(value > index ? value - 1 : value)];
    }
    _history = history;
    _index = nextIndex;
    [self resetShuffle];
    if (removedCurrent) {
        _retryAttempts = 0;
        if (_index == NSNotFound) {
            [self stopEngines];
            _generation++;
            _desiredPlaying = _playing = _buffering = NO;
            _savedPosition = _position = _duration = 0;
            _qualityLabel = @"—";
            _error = nil;
            _nowArtwork = nil;
        } else
            [self beginTrackAt:0];
    }
    [self changed];
}
- (void)moveQueueIndex:(NSUInteger)from toIndex:(NSUInteger)to {
    MC_MAIN([self moveQueueIndex:from toIndex:to]);
    if (from >= [_queue count] || to >= [_queue count] || from == to)
        return;
    NSMutableArray *queue = [_queue mutableCopy];
    id track = queue[from];
    [queue removeObjectAtIndex:from];
    [queue insertObject:track atIndex:to];
    _queue = [queue copy];
    _index = mc_playback_move_index(_index, from, to);
    for (NSUInteger i = 0; i < [_history count]; i++)
        _history[i] = @(mc_playback_move_index([_history[i] unsignedIntegerValue], from, to));
    [self resetShuffle];
    [self changed];
}
- (void)selectIndex:(NSUInteger)index history:(BOOL)history {
    if (index >= [_queue count])
        return;
    if (history && _index != NSNotFound && index != _index) {
        [_history addObject:@(_index)];
        if ([_history count] > 512)
            [_history removeObjectAtIndex:0];
    }
    _index = index;
    _retryAttempts = 0;
    _desiredPlaying = _playing = YES;
    [self beginTrackAt:0];
}
- (void)advanceAutomatically:(BOOL)automatic {
    if (!self.currentTrack)
        return;
    size_t next;
    if (automatic && _repeatMode == 2)
        next = _index;
    else if (_shuffle)
        next = mc_playback_shuffle_next([_queue count], _index, [_shuffleVisited mutableBytes],
                                        _repeatMode == 2 ? 0 : (int)_repeatMode, arc4random());
    else
        next = mc_playback_next([_queue count], _index, (int)_repeatMode, 0, 0, automatic);
    if (next == SIZE_MAX) {
        _savedPosition = [self enginePosition];
        [self stopEngines];
        _generation++;
        _desiredPlaying = _playing = _buffering = NO;
        [self changed];
        return;
    }
    [self selectIndex:next history:YES];
}
- (void)next {
    MC_MAIN([self next]);
    [self advanceAutomatically:NO];
}
- (void)previous {
    MC_MAIN([self previous]);
    if (!self.currentTrack)
        return;
    if ([self enginePosition] > 3) {
        [self seek:0];
        return;
    }
    if (_shuffle && [_history count]) {
        NSUInteger previous = [[_history lastObject] unsignedIntegerValue];
        [_history removeLastObject];
        [self selectIndex:previous history:NO];
    } else {
        NSUInteger previous =
            _index ? _index - 1 : (_repeatMode == 1 && [_queue count] ? [_queue count] - 1 : 0);
        [self selectIndex:previous history:NO];
    }
}
- (void)toggle {
    MC_MAIN([self toggle]);
    if (!self.currentTrack)
        return;
    if (_desiredPlaying) {
        [self pause];
        return;
    }
    _desiredPlaying = _playing = YES;
    _resumeAfterInterruption = NO;
    if (![self activateSession])
        return;
    if (_error || (!_nativePlayer && !_flacPlayer && !_source)) {
        _retryAttempts = 0;
        double position = [self enginePosition];
        if (_duration > 0 && position >= _duration - 0.1)
            position = 0;
        [self beginTrackAt:position];
        return;
    }
    if (_flacPlayer)
        [_flacPlayer setPlaying:YES];
    if (_nativePlayer && _nativeItem.status == AVPlayerItemStatusReadyToPlay)
        [_nativePlayer play];
    [self changed];
}
- (void)pause {
    MC_MAIN([self pause]);
    _desiredPlaying = _playing = NO;
    _resumeAfterInterruption = NO;
    [_nativePlayer pause];
    [_flacPlayer setPlaying:NO];
    [self changed];
}
- (void)seek:(NSTimeInterval)position {
    MC_MAIN([self seek:position]);
    if (!self.currentTrack)
        return;
    position = mc_playback_seek(position, _duration);
    _savedPosition = _position = position;
    if (_flacPlayer) {
        _flacSeeking = YES;
        [_flacPlayer seek:position];
        _buffering = _desiredPlaying;
    } else if (_nativePlayer && _nativeItem.status == AVPlayerItemStatusReadyToPlay)
        [self seekNative:position];
    else if (!_source && !_error)
        [self beginTrackAt:position];
    [self changed];
}
- (void)retry {
    MC_MAIN([self retry]);
    if (!self.currentTrack)
        return;
    double position = [self enginePosition];
    _retryAttempts = 0;
    _desiredPlaying = _playing = YES;
    [self beginTrackAt:position];
}
- (BOOL)activateSession {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES
                                                                                            error:&error]) {
        _error = MCPlaybackError(MCPlaybackOutputError,
                                 @"Audio is unavailable. Finish the other audio session and tap Retry.", NO);
        _playing = _desiredPlaying = _buffering = NO;
        [self changed];
        return NO;
    }
    return YES;
}
- (void)stopEngines {
    [_resolutionTask cancel];
    _resolutionTask = nil;
    _nativeSeekGeneration++;
    if (_observingNative && _nativeItem) {
        [_nativeItem removeObserver:self forKeyPath:@"status" context:MCPlayerItemContext];
        [_nativeItem removeObserver:self forKeyPath:@"playbackBufferEmpty" context:MCPlayerItemContext];
        [_nativeItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:MCPlayerItemContext];
        _observingNative = NO;
    }
    if (_nativeItem)
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:_nativeItem];
    if (_nativeItem)
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                      object:_nativeItem];
    [_nativePlayer pause];
    [_nativeAsset cancelLoading];
    [_nativeLoader cancel];
    _nativeLoader = nil;
    _nativePlayer = nil;
    _nativeItem = nil;
    _nativeAsset = nil;
    _nativePrepared = _nativeSeeking = _flacSeeking = NO;
    [_flacPlayer cancel];
    _flacPlayer = nil;
    [_source cancel];
    _source = nil;
}
- (void)beginTrackAt:(NSTimeInterval)position {
    [self stopEngines];
    _activeCacheKey = nil;
    NSUInteger generation = ++_generation;
    _savedPosition = _position = position;
    _error = nil;
    _buffering = YES;
    _playing = _desiredPlaying;
    _duration = MAX(0, [self.currentTrack[@"duration"] doubleValue]);
    _qualityLabel = @"—";
    _nowArtwork = nil;
    [self changed];
    if (![self activateSession])
        return;
    [self prepareArtworkForGeneration:generation];
    _sourceEntrySnapshot = nil;
    NSString *path = self.currentTrack[@"path"];
    if ([path isKindOfClass:[NSString class]] && [path length]) {
        [self attachSource:[[MCAudioSource alloc] initWithLocalPath:path] generation:generation];
        return;
    }
    NSString *identifier = self.currentTrack[@"id"];
    if (![identifier length] || [identifier hasPrefix:@"local:"]) {
        [self failed:MCPlaybackError(MCPlaybackFileError,
                                     @"This local file is unavailable. Rescan the library.", NO)
            generation:generation];
        return;
    }
    __weak MCPlayer *weakSelf = self;
    _sourceEntrySnapshot = [[MCMusicSources sharedSources].selectedEntry copy];
    _resolutionTask = [[MCMusicSources sharedSources]
        resolveTrack:self.currentTrack
             quality:_preferredQuality
          completion:^(id result, NSError *error) {
              dispatch_async(dispatch_get_main_queue(), ^{
                  MCPlayer *self = weakSelf;
                  if (!self || generation != self->_generation)
                      return;
                  self->_resolutionTask = nil;
                  if (error || ![result isKindOfClass:[NSDictionary class]]) {
                      BOOL transport =
                          [error.domain isEqualToString:@"MCHTTPErrorDomain"] && error.code > 0 &&
                          (error.code < 100 || error.code == 408 || error.code == 429 || error.code >= 500);
                      BOOL transient = transport || [error.domain isEqualToString:NSURLErrorDomain] ||
                                       (error.code >= 500 && error.code < 600) ||
                                       [error.userInfo[MCPlaybackRetryableKey] boolValue];
                      [self failed:MCPlaybackError(
                                       MCPlaybackAccessError,
                                       error.localizedDescription
                                           ?: @"This track is unavailable for this account or region.",
                                       transient)
                          generation:generation];
                      return;
                  }
                  NSString *url = result[@"url"];
                  NSTimeInterval expires = [result[@"expires"] doubleValue];
                  if (expires > 0 && expires < [[NSDate date] timeIntervalSince1970] + 5) {
                      [self failed:MCPlaybackError(MCPlaybackAccessError,
                                                   @"The service returned an expired audio link. Tap Retry.",
                                                   YES)
                          generation:generation];
                      return;
                  }
                  if (![url isKindOfClass:[NSString class]] || ![url length]) {
                      [self failed:MCPlaybackError(MCPlaybackURLError, @"No playable audio URL was returned.",
                                                   NO)
                          generation:generation];
                      return;
                  }
                  [self attachOnlineResource:result trackID:identifier generation:generation];
              });
          }];
}
- (void)attachOnlineResource:(NSDictionary *)resource
                     trackID:(NSString *)identifier
                  generation:(NSUInteger)generation {
    MCAPI *api = [MCAPI sharedAPI];
    id userID = api.profile[@"userId"];
    NSString *account = [userID respondsToSelector:@selector(stringValue)] ? [userID stringValue]
                        : [userID isKindOfClass:[NSString class]]          ? userID
                                                                           : nil;
    if (!api.loggedIn)
        account = @"guest";
    BOOL customSource = [resource[@"customSource"] boolValue];
    if (customSource)
        account = @"custom";
    NSString *key =
        account.length ? [MCAudioCache keyForTrackID:identifier resource:resource account:account] : nil;
    MCAudioCache *cache = [MCAudioCache sharedCache];
    NSUInteger cacheGeneration = cache.generation;
    __weak MCPlayer *weakSelf = self;
    [cache leaseForKey:key
            completion:^(MCAudioCacheLease *lease) {
                MCPlayer *self = weakSelf;
                if (!self || generation != self->_generation)
                    return;
                self->_activeCacheKey = key;
                MCAudioSource *source;
                if (lease) {
                    source = [[MCAudioSource alloc] initWithLocalPath:lease.path];
                    source.cacheLease = lease;
                    self->_activeCacheKey = key;
                } else {
                    source = [[MCAudioSource alloc] initWithURL:[NSURL URLWithString:resource[@"url"]]
                                                 expectedLength:[resource[@"size"] unsignedLongLongValue]
                                                         format:resource[@"format"]
                                                   customSource:customSource];
                    __weak MCAudioSource *weakSource = source;
                    source.downloadCompleted = ^(NSString *path) {
                        MCAudioSource *retainedSource = weakSource;
                        MCPlayer *player = weakSelf;
                        if (!retainedSource || !player || generation != player->_generation)
                            return;
                        NSString *sourceID = customSource ? resource[@"sourceIdentifier"] : nil;
                        if (customSource) {
                            BOOL exists = NO;
                            for (NSDictionary *entry in [MCMusicSources sharedSources].entries)
                                if ([entry[@"identifier"] isEqual:sourceID] &&
                                    [entry[@"revision"] isEqual:resource[@"sourceRevision"]])
                                    exists = YES;
                            if (!exists)
                                return;
                        }
                        [cache storeFile:path
                                         key:key
                            sourceIdentifier:sourceID
                                  generation:cacheGeneration
                                  completion:^{
                                      (void)retainedSource; // Keep its temporary spool alive until the disk
                                                            // operation finishes.
                                  }];
                    };
                }
                [self attachSource:source generation:generation];
            }];
}
- (void)attachSource:(MCAudioSource *)source generation:(NSUInteger)generation {
    if (generation != _generation)
        return;
    _source = source;
    __weak MCPlayer *weakSelf = self;
    __weak MCAudioSource *weakSource = source;
    source.failure = ^(NSError *error) {
        [weakSelf failed:error generation:generation];
    };
    source.ready = ^(BOOL flac) {
        MCPlayer *self = weakSelf;
        MCAudioSource *source = weakSource;
        if (!self || !source || self->_generation != generation)
            return;
        if (flac)
            [self prepareFLAC:source generation:generation];
        else
            [self prepareNative:source generation:generation];
    };
    [source start];
}
- (void)prepareFLAC:(MCAudioSource *)source generation:(NSUInteger)generation {
    MCFLACPlayback *flac = [[MCFLACPlayback alloc] initWithSource:source
                                                         position:_savedPosition
                                                          playing:_desiredPlaying];
    _flacPlayer = flac;
    _flacSeeking = _savedPosition > 0;
    __weak MCPlayer *weakSelf = self;
    flac.metadata = ^(double rate, unsigned bits, double duration) {
        MCPlayer *self = weakSelf;
        if (!self || self->_generation != generation)
            return;
        if (duration > 0)
            self->_duration = duration;
        self->_qualityLabel = [NSString stringWithFormat:@"FLAC · %u-bit / %.1f kHz", bits, rate / 1000];
        [[MCLibrary sharedLibrary] recordPlay:self.currentTrack];
        [self changed];
    };
    flac.bufferingChanged = ^(BOOL buffering) {
        MCPlayer *self = weakSelf;
        if (!self || self->_generation != generation)
            return;
        if (!buffering)
            self->_flacSeeking = NO;
        self->_buffering = buffering && self->_desiredPlaying;
        [self changed];
    };
    flac.failure = ^(NSError *error) {
        [weakSelf failed:error generation:generation];
    };
    flac.ended = ^{
        MCPlayer *self = weakSelf;
        if (!self || self->_generation != generation)
            return;
        [self completedTrack];
    };
    [flac start];
}
- (void)prepareNative:(MCAudioSource *)source generation:(NSUInteger)generation {
    NSURL *url = [NSURL fileURLWithPath:source.path];
    BOOL progressive = !mc_spool_complete(source.spool) && source.contentLength > 0;
    if (progressive) {
        _nativeLoader = [[MCNativeResourceLoader alloc] initWithSource:source];
        __weak MCPlayer *weakSelf = self;
        _nativeLoader.failure = ^(NSError *error) {
            [weakSelf failed:error generation:generation];
        };
        url = _nativeLoader.URL;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
    _nativeAsset = asset;
    if (_nativeLoader)
        [asset.resourceLoader setDelegate:_nativeLoader queue:_nativeLoader.delegateQueue];
    __weak MCPlayer *weakSelf = self;
    NSArray *keys = @[ @"playable", @"tracks" ];
    [asset
        loadValuesAsynchronouslyForKeys:keys
                      completionHandler:^{
                          dispatch_async(dispatch_get_main_queue(), ^{
                              MCPlayer *self = weakSelf;
                              if (!self || self->_generation != generation || self->_nativeAsset != asset)
                                  return;
                              NSError *error = nil;
                              for (NSString *key in keys) {
                                  if ([asset statusOfValueForKey:key
                                                           error:&error] != AVKeyValueStatusLoaded) {
                                      [self failed:[self nativeFailureError] generation:generation];
                                      return;
                                  }
                              }
                              if (!asset.playable || ![[asset tracksWithMediaType:AVMediaTypeAudio] count]) {
                                  [self failed:MCPlaybackError(
                                                   MCPlaybackUnsupportedError,
                                                   @"This file contains no supported audio track.", NO)
                                      generation:generation];
                                  return;
                              }
                              [self describeNativeAsset:asset];
                              self->_nativeItem = [AVPlayerItem playerItemWithAsset:asset];
                              self->_nativePlayer = [AVPlayer playerWithPlayerItem:self->_nativeItem];
                              [self->_nativeItem addObserver:self
                                                  forKeyPath:@"status"
                                                     options:NSKeyValueObservingOptionNew
                                                     context:MCPlayerItemContext];
                              [self->_nativeItem addObserver:self
                                                  forKeyPath:@"playbackBufferEmpty"
                                                     options:NSKeyValueObservingOptionNew
                                                     context:MCPlayerItemContext];
                              [self->_nativeItem addObserver:self
                                                  forKeyPath:@"playbackLikelyToKeepUp"
                                                     options:NSKeyValueObservingOptionNew
                                                     context:MCPlayerItemContext];
                              self->_observingNative = YES;
                              [[NSNotificationCenter defaultCenter]
                                  addObserver:self
                                     selector:@selector(nativeEnded:)
                                         name:AVPlayerItemDidPlayToEndTimeNotification
                                       object:self->_nativeItem];
                              [[NSNotificationCenter defaultCenter]
                                  addObserver:self
                                     selector:@selector(nativeFailed:)
                                         name:AVPlayerItemFailedToPlayToEndTimeNotification
                                       object:self->_nativeItem];
                              [self nativeStatusChanged];
                          });
                      }];
}
- (void)describeNativeAsset:(AVAsset *)asset {
    NSString *format = @"Audio";
    double rate = 0;
    unsigned bits = 0;
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    for (id value in track.formatDescriptions) {
        CMAudioFormatDescriptionRef description = (__bridge CMAudioFormatDescriptionRef)value;
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(description);
        if (!asbd)
            continue;
        rate = asbd->mSampleRate;
        bits = asbd->mBitsPerChannel;
        switch (asbd->mFormatID) {
        case kAudioFormatMPEGLayer3:
            format = @"MP3";
            bits = 0;
            break;
        case kAudioFormatMPEG4AAC:
        case kAudioFormatMPEG4AAC_HE:
        case kAudioFormatMPEG4AAC_HE_V2:
            format = @"AAC";
            bits = 0;
            break;
        case kAudioFormatAppleLossless: {
            format = @"ALAC";
            switch (asbd->mFormatFlags) {
            case 1:
                bits = 16;
                break;
            case 2:
                bits = 20;
                break;
            case 3:
                bits = 24;
                break;
            case 4:
                bits = 32;
                break;
            default:
                break;
            }
            break;
        }
        case kAudioFormatLinearPCM:
            format = @"PCM";
            break;
        default:
            break;
        }
        break;
    }
    if (bits && rate > 0)
        _qualityLabel = [NSString stringWithFormat:@"%@ · %u-bit / %.1f kHz", format, bits, rate / 1000];
    else if (rate > 0)
        _qualityLabel = [NSString stringWithFormat:@"%@ · %.1f kHz", format, rate / 1000];
    else
        _qualityLabel = format;
}
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context != MCPlayerItemContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    (void)keyPath;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (object == self->_nativeItem)
            [self nativeStatusChanged];
    });
}
- (NSError *)nativeFailureError {
    NSError *error = _nativeLoader.error;
    if (error)
        return error;
    if (_source && mc_spool_error(_source.spool) && ![self.currentTrack[@"path"] length])
        return MCPlaybackError(MCPlaybackNetworkError,
                               @"The audio stream was interrupted or incomplete. Tap Retry.", YES);
    return MCPlaybackError(MCPlaybackDecodeError, @"This audio file is damaged or cannot be played by iOS 7.",
                           NO);
}
- (void)nativeStatusChanged {
    if (!_nativeItem)
        return;
    if (_nativeItem.status == AVPlayerItemStatusFailed) {
        [self failed:[self nativeFailureError] generation:_generation];
        return;
    }
    if (_nativeItem.status == AVPlayerItemStatusReadyToPlay) {
        if (!_nativePrepared) {
            _nativePrepared = YES;
            [[MCLibrary sharedLibrary] recordPlay:self.currentTrack];
            if (_savedPosition > 0)
                [self seekNative:_savedPosition];
            else {
                _buffering = NO;
                if (_desiredPlaying)
                    [_nativePlayer play];
            }
            [self changed];
        } else if (!_nativeSeeking) {
            BOOL buffering =
                _desiredPlaying && _nativeItem.playbackBufferEmpty && !_nativeItem.playbackLikelyToKeepUp;
            if (_buffering != buffering) {
                _buffering = buffering;
                [self changed];
            }
            if (_desiredPlaying && _nativePlayer.rate == 0 && !_nativeItem.playbackBufferEmpty)
                [_nativePlayer play];
        }
    }
}
- (void)seekNative:(NSTimeInterval)position {
    if (!_nativePlayer)
        return;
    NSUInteger generation = _generation;
    NSUInteger seekGeneration = ++_nativeSeekGeneration;
    position = mc_playback_seek(position, _duration);
    _savedPosition = position;
    _nativeSeeking = YES;
    _buffering = _desiredPlaying;
    __weak MCPlayer *weakSelf = self;
    [_nativePlayer
               seekToTime:CMTimeMakeWithSeconds(position, 600)
          toleranceBefore:kCMTimeZero
           toleranceAfter:kCMTimeZero
        completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MCPlayer *self = weakSelf;
                if (!self || generation != self->_generation || seekGeneration != self->_nativeSeekGeneration)
                    return;
                self->_nativeSeeking = NO;
                if (!finished) {
                    [self failed:MCPlaybackError(MCPlaybackDecodeError,
                                                 @"The audio seek could not be completed. Tap Retry.", NO)
                        generation:generation];
                    return;
                }
                self->_buffering = NO;
                if (self->_desiredPlaying)
                    [self->_nativePlayer play];
                [self changed];
            });
        }];
}
- (void)completedTrack {
    if (_desiredPlaying)
        [self advanceAutomatically:YES];
    else {
        _savedPosition = [self enginePosition];
        [self stopEngines];
        _generation++;
        _playing = _buffering = NO;
        [self changed];
    }
}
- (void)nativeEnded:(NSNotification *)notification {
    MC_MAIN([self nativeEnded:notification]);
    if (notification.object == _nativeItem)
        [self completedTrack];
}
- (void)nativeFailed:(NSNotification *)notification {
    MC_MAIN([self nativeFailed:notification]);
    if (notification.object == _nativeItem)
        [self failed:[self nativeFailureError] generation:_generation];
}
- (void)failed:(NSError *)error generation:(NSUInteger)generation {
    MC_MAIN([self failed:error generation:generation]);
    if (generation != _generation)
        return;
    double position = [self enginePosition];
    BOOL online = ![self.currentTrack[@"path"] length];
    if (_activeCacheKey.length) {
        [[MCAudioCache sharedCache] invalidateKey:_activeCacheKey];
        _activeCacheKey = nil;
    }
    BOOL retry =
        online && _desiredPlaying &&
        MCSourceSnapshotMatches(_sourceEntrySnapshot, [MCMusicSources sharedSources].selectedEntry) &&
        mc_playback_retry([error.userInfo[MCPlaybackRetryableKey] boolValue], _retryAttempts, 2);
    [self stopEngines];
    _savedPosition = _position = position;
    NSUInteger retryGeneration = ++_generation;
    if (retry) {
        _retryAttempts++;
        _buffering = YES;
        _error = nil;
        _playing = _desiredPlaying;
        [self changed];
        double delay = _retryAttempts == 1 ? 0.75 : 1.5;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (retryGeneration != self->_generation)
                               return;
                           if (MCSourceSnapshotMatches(self->_sourceEntrySnapshot,
                                                       [MCMusicSources sharedSources].selectedEntry))
                               [self beginTrackAt:self->_savedPosition];
                           else
                               [self failed:MCPlaybackError(MCPlaybackAccessError,
                                                            @"音源已更改，请手动重试使用当前音源。", NO)
                                   generation:retryGeneration];
                       });
    } else {
        _error = error;
        _buffering = _playing = _desiredPlaying = NO;
        [self changed];
    }
}
- (void)prepareArtworkForGeneration:(NSUInteger)generation {
    NSString *path = self.currentTrack[@"artwork"];
    if (![path isKindOfClass:[NSString class]] || ![path length] ||
        [path rangeOfString:@"://"].location != NSNotFound)
        return;
    static dispatch_queue_t artworkQueue;
    static dispatch_once_t artworkOnce;
    dispatch_once(&artworkOnce, ^{
        artworkQueue = dispatch_queue_create("music.player.artwork", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(artworkQueue, ^{
        @autoreleasepool {
            CGImageSourceRef source =
                CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
            if (!source)
                return;
            NSDictionary *options = @{
                (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                (id)kCGImageSourceThumbnailMaxPixelSize : @256,
                (id)kCGImageSourceCreateThumbnailWithTransform : @YES
            };
            CGImageRef thumbnail =
                CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
            CFRelease(source);
            UIImage *image = thumbnail ? [UIImage imageWithCGImage:thumbnail] : nil;
            if (thumbnail)
                CGImageRelease(thumbnail);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_generation || !image)
                    return;
                self->_nowArtwork = [[MPMediaItemArtwork alloc] initWithImage:image];
                [self updateNowPlaying];
            });
        }
    });
}
- (void)updateNowPlaying {
    NSDictionary *track = self.currentTrack;
    if (!track) {
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
        return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = track[@"title"] ?: @"Untitled";
    info[MPMediaItemPropertyArtist] = track[@"artist"] ?: @"";
    info[MPMediaItemPropertyAlbumTitle] = track[@"album"] ?: @"";
    info[MPMediaItemPropertyPlaybackDuration] = @(_duration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @([self enginePosition]);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(_playing && !_buffering ? 1.0 : 0.0);
    info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = @(_index);
    info[MPNowPlayingInfoPropertyPlaybackQueueCount] = @([_queue count]);
    if (_nowArtwork)
        info[MPMediaItemPropertyArtwork] = _nowArtwork;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}
- (void)interruption:(NSNotification *)notification {
    MC_MAIN([self interruption:notification]);
    NSInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        BOOL resume = _desiredPlaying;
        [self pause];
        _resumeAfterInterruption = resume;
    } else {
        BOOL resume = _resumeAfterInterruption &&
                      ([notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] &
                       AVAudioSessionInterruptionOptionShouldResume);
        _resumeAfterInterruption = NO;
        if (resume && !_desiredPlaying)
            [self toggle];
    }
}
- (void)routeChanged:(NSNotification *)notification {
    MC_MAIN([self routeChanged:notification]);
    if ([notification.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue] ==
        AVAudioSessionRouteChangeReasonOldDeviceUnavailable)
        [self pause];
}
- (void)mediaReset:(NSNotification *)notification {
    MC_MAIN([self mediaReset:notification]);
    (void)notification;
    if (!self.currentTrack)
        return;
    double position = [self enginePosition];
    [self beginTrackAt:position];
}
- (void)becameActive:(NSNotification *)notification {
    MC_MAIN([self becameActive:notification]);
    (void)notification;
    [self tick:nil];
}
- (void)handleRemoteEvent:(UIEvent *)event {
    MC_MAIN([self handleRemoteEvent:event]);
    if (event.type != UIEventTypeRemoteControl)
        return;
    switch (event.subtype) {
    case UIEventSubtypeRemoteControlPlay:
        if (!_desiredPlaying)
            [self toggle];
        break;
    case UIEventSubtypeRemoteControlPause:
    case UIEventSubtypeRemoteControlStop:
        [self pause];
        break;
    case UIEventSubtypeRemoteControlTogglePlayPause:
        [self toggle];
        break;
    case UIEventSubtypeRemoteControlNextTrack:
        [self next];
        break;
    case UIEventSubtypeRemoteControlPreviousTrack:
        [self previous];
        break;
    case UIEventSubtypeRemoteControlBeginSeekingForward:
        [self seek:self.position + 15];
        break;
    case UIEventSubtypeRemoteControlBeginSeekingBackward:
        [self seek:self.position - 15];
        break;
    default:
        break;
    }
}
@end
