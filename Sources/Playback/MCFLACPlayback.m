#import "MCFLACPlayback.h"
#import "MCAudioSource.h"
#import <AudioToolbox/AudioToolbox.h>
#include <FLAC/stream_decoder.h>
#include <pthread.h>
#include <errno.h>
#include <math.h>
#include <string.h>
#include <sys/time.h>

#define MC_AUDIO_BUFFERS 6
#define MC_AUDIO_START_BUFFERS 4

@interface MCFLACPlayback () {
    MCAudioSource *_source;
    FLAC__StreamDecoder *_decoder;
    dispatch_queue_t _audioControl;
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _buffers[MC_AUDIO_BUFFERS];
    BOOL _busy[MC_AUDIO_BUFFERS];
    UInt32 _bufferFrames[MC_AUDIO_BUFFERS];
    pthread_mutex_t _mutex;
    pthread_cond_t _condition;
    BOOL _cancelled, _started, _playing, _seekPending, _resetting;
    BOOL _queueRunning, _audioStarted, _draining, _terminal, _buffering, _refilling;
    BOOL _hasMetadata, _metadataReading, _seeking, _announcedMetadata, _needsPrebuffer;
    NSUInteger _queuedCount;
    double _seekTarget, _basePosition;
    CFAbsoluteTime _lastAudioProgress;
    uint64_t _completedFrames, _decodedSamples, _totalSamples, _offset, _ioRevision, _prebufferBytes;
    unsigned _rate, _channels, _bits;
    NSError *_decodeFailure;
    NSInteger _fillSlot;
    size_t _fillFrames, _audioBufferBytes;
}
- (FLAC__StreamDecoderReadStatus)read:(FLAC__byte *)buffer count:(size_t *)bytes;
- (FLAC__StreamDecoderSeekStatus)seekBytes:(FLAC__uint64)offset;
- (FLAC__StreamDecoderTellStatus)tellBytes:(FLAC__uint64 *)offset;
- (FLAC__StreamDecoderLengthStatus)lengthBytes:(FLAC__uint64 *)length;
- (FLAC__bool)eof;
- (FLAC__StreamDecoderWriteStatus)writeFrame:(const FLAC__Frame *)frame
                                     samples:(const FLAC__int32 *const *)samples;
- (void)readMetadata:(const FLAC__StreamMetadata *)metadata;
- (void)decoderError:(FLAC__StreamDecoderErrorStatus)error;
- (void)bufferCompleted:(AudioQueueBufferRef)buffer;
- (void)runningChanged:(AudioQueueRef)queue;
- (BOOL)enqueueFilledBuffer;
@end

static FLAC__StreamDecoderReadStatus MCFLACRead(const FLAC__StreamDecoder *d, FLAC__byte b[], size_t *n,
                                                void *c) {
    (void)d;
    return [(__bridge MCFLACPlayback *)c read:b count:n];
}
static FLAC__StreamDecoderSeekStatus MCFLACSeek(const FLAC__StreamDecoder *d, FLAC__uint64 o, void *c) {
    (void)d;
    return [(__bridge MCFLACPlayback *)c seekBytes:o];
}
static FLAC__StreamDecoderTellStatus MCFLACTell(const FLAC__StreamDecoder *d, FLAC__uint64 *o, void *c) {
    (void)d;
    return [(__bridge MCFLACPlayback *)c tellBytes:o];
}
static FLAC__StreamDecoderLengthStatus MCFLACLength(const FLAC__StreamDecoder *d, FLAC__uint64 *n, void *c) {
    (void)d;
    return [(__bridge MCFLACPlayback *)c lengthBytes:n];
}
static FLAC__bool MCFLACEof(const FLAC__StreamDecoder *d, void *c) {
    (void)d;
    return [(__bridge MCFLACPlayback *)c eof];
}
static FLAC__StreamDecoderWriteStatus MCFLACWrite(const FLAC__StreamDecoder *d, const FLAC__Frame *f,
                                                  const FLAC__int32 *const b[], void *c) {
    (void)d;
    return [(__bridge MCFLACPlayback *)c writeFrame:f samples:b];
}
static void MCFLACMetadata(const FLAC__StreamDecoder *d, const FLAC__StreamMetadata *m, void *c) {
    (void)d;
    [(__bridge MCFLACPlayback *)c readMetadata:m];
}
static void MCFLACError(const FLAC__StreamDecoder *d, FLAC__StreamDecoderErrorStatus e, void *c) {
    (void)d;
    [(__bridge MCFLACPlayback *)c decoderError:e];
}
static void MCAudioComplete(void *c, AudioQueueRef q, AudioQueueBufferRef b) {
    (void)q;
    [(__bridge MCFLACPlayback *)c bufferCompleted:b];
}
static void MCAudioRunning(void *c, AudioQueueRef q, AudioQueuePropertyID property) {
    (void)property;
    [(__bridge MCFLACPlayback *)c runningChanged:q];
}
static void MCWaitShort(pthread_cond_t *condition, pthread_mutex_t *mutex) {
    struct timeval now;
    gettimeofday(&now, NULL);
    struct timespec until = {now.tv_sec, now.tv_usec * 1000 + 100000000};
    if (until.tv_nsec >= 1000000000) {
        until.tv_sec++;
        until.tv_nsec -= 1000000000;
    }
    pthread_cond_timedwait(condition, mutex, &until);
}

@implementation MCFLACPlayback
- (id)initWithSource:(MCAudioSource *)source position:(NSTimeInterval)position playing:(BOOL)playing {
    if ((self = [super init])) {
        _source = source;
        _playing = playing;
        _seekTarget = MAX(0, position);
        _basePosition = _seekTarget;
        _seekPending = position > 0;
        _needsPrebuffer = YES;
        _fillSlot = -1;
        _audioControl = dispatch_queue_create("music.flac.output", DISPATCH_QUEUE_SERIAL);
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_condition, NULL);
    }
    return self;
}
- (void)dealloc {
    pthread_cond_destroy(&_condition);
    pthread_mutex_destroy(&_mutex);
}
- (NSTimeInterval)position {
    pthread_mutex_lock(&_mutex);
    double value = _basePosition + (_rate ? (double)_completedFrames / _rate : 0);
    pthread_mutex_unlock(&_mutex);
    return value;
}
- (BOOL)commandPending {
    pthread_mutex_lock(&_mutex);
    BOOL value = _cancelled || _seekPending;
    pthread_mutex_unlock(&_mutex);
    return value;
}
- (BOOL)isCancelled {
    pthread_mutex_lock(&_mutex);
    BOOL value = _cancelled;
    pthread_mutex_unlock(&_mutex);
    return value;
}
- (void)publishBuffering:(BOOL)buffering {
    pthread_mutex_lock(&_mutex);
    BOOL changed = _buffering != buffering;
    _buffering = buffering;
    pthread_mutex_unlock(&_mutex);
    if (changed)
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCancelled] && self.bufferingChanged)
                self.bufferingChanged(self.buffering);
        });
}
- (BOOL)buffering {
    pthread_mutex_lock(&_mutex);
    BOOL value = _buffering;
    pthread_mutex_unlock(&_mutex);
    return value;
}
- (void)start {
    pthread_mutex_lock(&_mutex);
    if (_started || _cancelled) {
        pthread_mutex_unlock(&_mutex);
        return;
    }
    _started = YES;
    pthread_mutex_unlock(&_mutex);
    static NSOperationQueue *decoders;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        decoders = [[NSOperationQueue alloc] init];
        decoders.maxConcurrentOperationCount = 2;
    });
    [decoders addOperationWithBlock:^{
        @autoreleasepool {
            [self runDecoder];
        }
    }];
}
- (void)setPlaying:(BOOL)playing {
    pthread_mutex_lock(&_mutex);
    _playing = playing;
    if (playing)
        _lastAudioProgress = CFAbsoluteTimeGetCurrent();
    pthread_cond_broadcast(&_condition);
    pthread_mutex_unlock(&_mutex);
    dispatch_async(_audioControl, ^{
        pthread_mutex_lock(&self->_mutex);
        BOOL wants = self->_playing && !self->_cancelled;
        BOOL queued = self->_queuedCount > 0;
        BOOL ready = !self->_refilling || self->_queuedCount >= MC_AUDIO_START_BUFFERS || self->_draining;
        pthread_mutex_unlock(&self->_mutex);
        if (!self->_audioQueue)
            return;
        OSStatus status = noErr;
        if (wants && queued && ready) {
            status = AudioQueueStart(self->_audioQueue, NULL);
            if (!status) {
                pthread_mutex_lock(&self->_mutex);
                self->_audioStarted = YES;
                self->_queueRunning = YES;
                self->_refilling = NO;
                pthread_mutex_unlock(&self->_mutex);
            }
        } else if (!wants)
            status = AudioQueuePause(self->_audioQueue);
        if (status && ![self isCancelled])
            [self report:MCPlaybackError(MCPlaybackOutputError,
                                         @"The audio output could not resume. Tap Retry.", NO)];
    });
}
- (void)seek:(NSTimeInterval)position {
    pthread_mutex_lock(&_mutex);
    if (_cancelled || _terminal) {
        pthread_mutex_unlock(&_mutex);
        return;
    }
    mc_spool_interrupt(_source.spool);
    _seekTarget = MAX(0, position);
    _seekPending = YES;
    pthread_cond_broadcast(&_condition);
    pthread_mutex_unlock(&_mutex);
    [self publishBuffering:YES];
}
- (void)cancel {
    pthread_mutex_lock(&_mutex);
    if (_cancelled) {
        pthread_mutex_unlock(&_mutex);
        return;
    }
    _cancelled = YES;
    pthread_cond_broadcast(&_condition);
    pthread_mutex_unlock(&_mutex);
    mc_spool_interrupt(_source.spool);
    dispatch_async(_audioControl, ^{
        if (self->_audioQueue)
            AudioQueueStop(self->_audioQueue, true);
    });
}
- (void)report:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isCancelled] && self.failure)
            self.failure(error);
    });
}
- (BOOL)createAudio {
    _audioBufferBytes = mc_playback_pcm_buffer_bytes(_rate, _channels);
    __block OSStatus status = noErr;
    dispatch_sync(_audioControl, ^{
        if (self->_audioQueue || [self isCancelled])
            return;
        AudioStreamBasicDescription format;
        memset(&format, 0, sizeof format);
        format.mSampleRate = self->_rate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags =
            kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
        format.mBytesPerPacket = format.mBytesPerFrame = self->_channels * 4;
        format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = self->_channels;
        format.mBitsPerChannel = 32;
        status = AudioQueueNewOutput(&format, MCAudioComplete, (__bridge void *)self, NULL, NULL, 0,
                                     &self->_audioQueue);
        if (status)
            return;
        status = AudioQueueAddPropertyListener(self->_audioQueue, kAudioQueueProperty_IsRunning,
                                               MCAudioRunning, (__bridge void *)self);
        for (unsigned i = 0; i < MC_AUDIO_BUFFERS && !status; i++)
            status = AudioQueueAllocateBuffer(self->_audioQueue, (UInt32)self->_audioBufferBytes,
                                              &self->_buffers[i]);
    });
    if (status)
        _decodeFailure = MCPlaybackError(
            MCPlaybackOutputError, @"This FLAC format could not be opened by the device audio output.", NO);
    return status == noErr && ![self isCancelled];
}
- (void)resetAudio {
    _needsPrebuffer = YES;
    _fillSlot = -1;
    _fillFrames = 0;
    dispatch_sync(_audioControl, ^{
        pthread_mutex_lock(&self->_mutex);
        self->_resetting = YES;
        pthread_mutex_unlock(&self->_mutex);
        if (self->_audioQueue) {
            AudioQueueStop(self->_audioQueue, true);
            AudioQueueReset(self->_audioQueue);
        }
        pthread_mutex_lock(&self->_mutex);
        memset(self->_busy, 0, sizeof self->_busy);
        memset(self->_bufferFrames, 0, sizeof self->_bufferFrames);
        self->_queuedCount = 0;
        self->_audioStarted = NO;
        self->_refilling = NO;
        self->_queueRunning = NO;
        self->_draining = NO;
        self->_resetting = NO;
        pthread_cond_broadcast(&self->_condition);
        pthread_mutex_unlock(&self->_mutex);
    });
}
- (void)disposeAudio {
    dispatch_sync(_audioControl, ^{
        pthread_mutex_lock(&self->_mutex);
        self->_resetting = YES;
        pthread_mutex_unlock(&self->_mutex);
        if (self->_audioQueue) {
            AudioQueueRemovePropertyListener(self->_audioQueue, kAudioQueueProperty_IsRunning, MCAudioRunning,
                                             (__bridge void *)self);
            AudioQueueStop(self->_audioQueue, true);
            AudioQueueDispose(self->_audioQueue, true);
            self->_audioQueue = NULL;
        }
        memset(self->_buffers, 0, sizeof self->_buffers);
    });
}
- (void)startQueuedAudio {
    dispatch_sync(_audioControl, ^{
        pthread_mutex_lock(&self->_mutex);
        BOOL start = self->_playing && !self->_cancelled && self->_queuedCount && !self->_audioStarted;
        pthread_mutex_unlock(&self->_mutex);
        if (start && self->_audioQueue) {
            OSStatus status = AudioQueueStart(self->_audioQueue, NULL);
            if (status)
                self->_decodeFailure =
                    MCPlaybackError(MCPlaybackOutputError, @"The device could not start audio playback.", NO);
            else {
                pthread_mutex_lock(&self->_mutex);
                self->_audioStarted = YES;
                self->_queueRunning = YES;
                self->_refilling = NO;
                pthread_mutex_unlock(&self->_mutex);
                [self publishBuffering:NO];
            }
        }
    });
}
- (BOOL)drain {
    pthread_mutex_lock(&_mutex);
    _draining = YES;
    pthread_mutex_unlock(&_mutex);
    if (_fillFrames && ![self enqueueFilledBuffer])
        return NO;
    [self startQueuedAudio];
    pthread_mutex_lock(&_mutex);
    while (_queuedCount && !_cancelled && !_seekPending) {
        MCWaitShort(&_condition, &_mutex);
        if (_playing && _lastAudioProgress && CFAbsoluteTimeGetCurrent() - _lastAudioProgress > 15) {
            _decodeFailure = MCPlaybackError(MCPlaybackOutputError,
                                             @"The device audio output stopped responding. Tap Retry.", NO);
            break;
        }
    }
    BOOL interrupted = _cancelled || _seekPending;
    pthread_mutex_unlock(&_mutex);
    if (interrupted || _decodeFailure)
        return NO;
    dispatch_sync(_audioControl, ^{
        pthread_mutex_lock(&self->_mutex);
        self->_draining = YES;
        pthread_mutex_unlock(&self->_mutex);
        if (self->_audioQueue)
            AudioQueueStop(self->_audioQueue, false);
    });
    pthread_mutex_lock(&_mutex);
    CFAbsoluteTime drainStart = CFAbsoluteTimeGetCurrent();
    while (_queueRunning && !_cancelled && !_seekPending) {
        MCWaitShort(&_condition, &_mutex);
        if (CFAbsoluteTimeGetCurrent() - drainStart > 5) {
            _decodeFailure = MCPlaybackError(
                MCPlaybackOutputError, @"The device audio output did not finish cleanly. Tap Retry.", NO);
            break;
        }
    }
    interrupted = _cancelled || _seekPending;
    pthread_mutex_unlock(&_mutex);
    return !interrupted && !_decodeFailure;
}
- (void)runDecoder {
    if ([self isCancelled])
        return;
    _decoder = FLAC__stream_decoder_new();
    if (!_decoder) {
        [self report:MCPlaybackError(MCPlaybackDecodeError,
                                     @"There is not enough memory to open this FLAC track.", NO)];
        return;
    }
    FLAC__stream_decoder_set_md5_checking(_decoder, true);
    FLAC__stream_decoder_set_metadata_ignore_all(_decoder);
    FLAC__stream_decoder_set_metadata_respond(_decoder, FLAC__METADATA_TYPE_STREAMINFO);
    FLAC__StreamDecoderInitStatus init = FLAC__stream_decoder_init_stream(
        _decoder, MCFLACRead, MCFLACSeek, MCFLACTell, MCFLACLength, MCFLACEof, MCFLACWrite, MCFLACMetadata,
        MCFLACError, (__bridge void *)self);
    if (init != FLAC__STREAM_DECODER_INIT_STATUS_OK)
        _decodeFailure =
            MCPlaybackError(MCPlaybackDecodeError, @"The FLAC decoder could not be initialized.", NO);
    BOOL metadataOK = NO;
    while (!_decodeFailure && ![self isCancelled]) {
        _offset = 0;
        _ioRevision = mc_spool_revision(_source.spool);
        _metadataReading = YES;
        metadataOK = FLAC__stream_decoder_process_until_end_of_metadata(_decoder) && _hasMetadata;
        _metadataReading = NO;
        if (metadataOK || [self isCancelled])
            break;
        if (_ioRevision != mc_spool_revision(_source.spool)) {
            FLAC__stream_decoder_reset(_decoder);
            continue;
        }
        break;
    }
    if (!metadataOK && !_decodeFailure && ![self isCancelled])
        _decodeFailure = [self inputError];
    while (!_decodeFailure && metadataOK && ![self isCancelled]) {
        pthread_mutex_lock(&_mutex);
        BOOL seek = _seekPending;
        double target = _seekTarget;
        if (seek)
            _seekPending = NO;
        pthread_mutex_unlock(&_mutex);
        if (seek) {
            [self resetAudio];
            _ioRevision = mc_spool_revision(_source.spool);
            double sampleValue = target * _rate;
            uint64_t sample = !isfinite(sampleValue) || sampleValue >= (double)INT64_MAX
                                  ? INT64_MAX
                                  : (uint64_t)sampleValue;
            if (_totalSamples && sample >= _totalSamples)
                sample = _totalSamples - 1;
            _decodedSamples = sample;
            pthread_mutex_lock(&_mutex);
            _basePosition = (double)sample / _rate;
            _completedFrames = 0;
            pthread_mutex_unlock(&_mutex);
            FLAC__stream_decoder_flush(_decoder);
            _seeking = YES;
            BOOL success = FLAC__stream_decoder_seek_absolute(_decoder, sample);
            _seeking = NO;
            if (!success) {
                if ([self commandPending]) {
                    FLAC__stream_decoder_flush(_decoder);
                    continue;
                }
                _decodeFailure = [self inputError];
                break;
            }
        }
        if ([self commandPending])
            continue;
        if (_needsPrebuffer) {
            if (![self waitForPrebuffer]) {
                if ([self commandPending])
                    continue;
                break;
            }
            _needsPrebuffer = NO;
        }
        if (!FLAC__stream_decoder_process_single(_decoder)) {
            if ([self commandPending]) {
                FLAC__stream_decoder_flush(_decoder);
                continue;
            }
            if (!_decodeFailure)
                _decodeFailure = [self inputError];
            break;
        }
        if (FLAC__stream_decoder_get_state(_decoder) == FLAC__STREAM_DECODER_END_OF_STREAM) {
            if (mc_spool_error(_source.spool)) {
                _decodeFailure = [self inputError];
                break;
            }
            if (_totalSamples && _decodedSamples != _totalSamples) {
                _decodeFailure =
                    MCPlaybackError(MCPlaybackDecodeError,
                                    @"This FLAC file is truncated or has an invalid sample count.", NO);
                break;
            }
            if (![self drain])
                continue;
            BOOL integrity = FLAC__stream_decoder_finish(_decoder);
            if (!integrity)
                _decodeFailure =
                    MCPlaybackError(MCPlaybackDecodeError, @"This FLAC file failed its integrity check.", NO);
            else {
                pthread_mutex_lock(&_mutex);
                _terminal = YES;
                pthread_mutex_unlock(&_mutex);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![self isCancelled] && self.ended)
                        self.ended();
                });
            }
            break;
        }
    }
    if (_decodeFailure && ![self isCancelled])
        [self report:_decodeFailure];
    [self disposeAudio];
    FLAC__stream_decoder_finish(_decoder);
    FLAC__stream_decoder_delete(_decoder);
    _decoder = NULL;
}
- (NSError *)inputError {
    int error = mc_spool_error(_source.spool);
    if (error)
        return MCPlaybackError(
            error == ENOSPC || error == EFBIG ? MCPlaybackDiskError : MCPlaybackNetworkError,
            error == EFBIG    ? @"This track exceeds the 1 GB streaming storage limit."
            : error == ENOSPC ? @"Audio playback stopped because device storage is full."
                              : @"The audio stream was interrupted or incomplete. Tap Retry.",
            error != ENOSPC && error != EFBIG);
    return MCPlaybackError(MCPlaybackDecodeError,
                           @"This FLAC file is damaged or uses an unsupported bitstream.", NO);
}
- (BOOL)waitForPrebuffer {
    if (mc_spool_complete(_source.spool))
        return YES;
    if (_fillFrames && ![self enqueueFilledBuffer])
        return NO;
    [self publishBuffering:YES];
    int result = mc_spool_wait_buffer(_source.spool, _offset, _prebufferBytes ?: 512 * 1024, _ioRevision);
    if (result && result != -ECANCELED)
        _decodeFailure = [self inputError];
    return result == 0;
}
- (FLAC__StreamDecoderReadStatus)read:(FLAC__byte *)buffer count:(size_t *)bytes {
    if (!*bytes || (!_metadataReading && [self commandPending]) || [self isCancelled]) {
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }
    if (!_metadataReading && !_seeking && !mc_spool_complete(_source.spool) &&
        mc_spool_available(_source.spool) <= _offset && ![self waitForPrebuffer]) {
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }
    ssize_t n = mc_spool_read(_source.spool, buffer, *bytes, &_offset, _ioRevision);
    if (n < 0) {
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }
    *bytes = (size_t)n;
    return n ? FLAC__STREAM_DECODER_READ_STATUS_CONTINUE : FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
}
- (FLAC__StreamDecoderSeekStatus)seekBytes:(FLAC__uint64)offset {
    if ([self commandPending] || mc_spool_seek(_source.spool, offset, _ioRevision))
        return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;
    _offset = offset;
    return FLAC__STREAM_DECODER_SEEK_STATUS_OK;
}
- (FLAC__StreamDecoderTellStatus)tellBytes:(FLAC__uint64 *)offset {
    *offset = _offset;
    return FLAC__STREAM_DECODER_TELL_STATUS_OK;
}
- (FLAC__StreamDecoderLengthStatus)lengthBytes:(FLAC__uint64 *)length {
    uint64_t value;
    if (mc_spool_length(_source.spool, &value, _ioRevision))
        return FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR;
    *length = value;
    return FLAC__STREAM_DECODER_LENGTH_STATUS_OK;
}
- (FLAC__bool)eof {
    return mc_spool_complete(_source.spool) && _offset >= mc_spool_available(_source.spool);
}
- (void)readMetadata:(const FLAC__StreamMetadata *)metadata {
    if (metadata->type != FLAC__METADATA_TYPE_STREAMINFO)
        return;
    const FLAC__StreamMetadata_StreamInfo *info = &metadata->data.stream_info;
    if (!info->sample_rate || info->channels < 1 || info->channels > 2 || info->bits_per_sample < 4 ||
        info->bits_per_sample > 32 || !info->max_blocksize || info->max_blocksize > 65535) {
        _decodeFailure = MCPlaybackError(
            MCPlaybackUnsupportedError,
            @"This FLAC format is unsupported. Mono and stereo FLAC with 4–32 bit samples are supported.",
            NO);
        return;
    }
    pthread_mutex_lock(&_mutex);
    _rate = info->sample_rate;
    _channels = info->channels;
    _bits = info->bits_per_sample;
    _totalSamples = info->total_samples;
    pthread_mutex_unlock(&_mutex);
    _prebufferBytes = mc_playback_prebuffer_bytes(mc_spool_expected_length(_source.spool),
                                                  _totalSamples ? (double)_totalSamples / _rate : 0);
    _hasMetadata = [self createAudio];
    if (_hasMetadata && !_announcedMetadata) {
        _announcedMetadata = YES;
        double duration = _totalSamples ? (double)_totalSamples / _rate : 0;
        double rate = _rate;
        unsigned bits = _bits;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCancelled] && self.metadata)
                self.metadata(rate, bits, duration);
        });
    }
}
- (FLAC__StreamDecoderWriteStatus)writeFrame:(const FLAC__Frame *)frame
                                     samples:(const FLAC__int32 *const *)samples {
    if (_decodeFailure || [self commandPending])
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    if (frame->header.channels != _channels || frame->header.bits_per_sample != _bits ||
        frame->header.sample_rate != _rate || !frame->header.blocksize || frame->header.blocksize > 65535) {
        _decodeFailure =
            MCPlaybackError(MCPlaybackDecodeError,
                            @"This FLAC file changes format unexpectedly or contains invalid frames.", NO);
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    size_t consumed = 0, frames = frame->header.blocksize;
    while (consumed < frames) {
        if (_fillSlot < 0) {
            pthread_mutex_lock(&_mutex);
            while (_fillSlot < 0 && !_cancelled && !_seekPending) {
                for (unsigned i = 0; i < MC_AUDIO_BUFFERS; i++)
                    if (!_busy[i]) {
                        _fillSlot = i;
                        _busy[i] = YES;
                        break;
                    }
                if (_fillSlot < 0) {
                    MCWaitShort(&_condition, &_mutex);
                    if (_playing && _lastAudioProgress &&
                        CFAbsoluteTimeGetCurrent() - _lastAudioProgress > 15) {
                        _decodeFailure =
                            MCPlaybackError(MCPlaybackOutputError,
                                            @"The device audio output stopped responding. Tap Retry.", NO);
                        break;
                    }
                }
            }
            BOOL interrupted = _cancelled || _seekPending;
            pthread_mutex_unlock(&_mutex);
            if (interrupted || _fillSlot < 0 || _decodeFailure)
                return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
        }
        AudioQueueBufferRef buffer = _buffers[_fillSlot];
        const int32_t *planar[2] = {samples[0] + consumed, _channels == 2 ? samples[1] + consumed : NULL};
        size_t take = mc_playback_pcm_append(buffer->mAudioData, buffer->mAudioDataBytesCapacity,
                                             &_fillFrames, planar, _channels, _bits, frames - consumed);
        if (!take) {
            _decodeFailure = MCPlaybackError(MCPlaybackDecodeError, @"Invalid FLAC sample data.", NO);
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
        }
        consumed += take;
        if (_fillFrames == buffer->mAudioDataBytesCapacity / (_channels * sizeof(int32_t)) &&
            ![self enqueueFilledBuffer])
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    _decodedSamples += frames;
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}
- (BOOL)enqueueFilledBuffer {
    if (_fillSlot < 0 || !_fillFrames)
        return YES;
    NSInteger slot = _fillSlot;
    UInt32 frames = (UInt32)_fillFrames;
    AudioQueueBufferRef buffer = _buffers[slot];
    buffer->mAudioDataByteSize = frames * _channels * sizeof(int32_t);
    __block OSStatus status = noErr;
    dispatch_sync(_audioControl, ^{
        pthread_mutex_lock(&self->_mutex);
        BOOL cancelled = self->_cancelled || self->_seekPending;
        if (!cancelled) {
            self->_bufferFrames[slot] = frames;
            if (!self->_queuedCount)
                self->_lastAudioProgress = CFAbsoluteTimeGetCurrent();
            self->_queuedCount++;
        }
        pthread_mutex_unlock(&self->_mutex);
        status = cancelled ? -1 : AudioQueueEnqueueBuffer(self->_audioQueue, buffer, 0, NULL);
    });
    if (status) {
        if (![self commandPending])
            _decodeFailure = MCPlaybackError(MCPlaybackOutputError,
                                             @"The device rejected an audio buffer. Tap Retry.", NO);
        return NO;
    }
    _fillSlot = -1;
    _fillFrames = 0;
    pthread_mutex_lock(&_mutex);
    BOOL enough = _queuedCount >= MC_AUDIO_START_BUFFERS;
    BOOL active = _audioStarted;
    pthread_mutex_unlock(&_mutex);
    if (enough)
        [self startQueuedAudio];
    if (active)
        [self publishBuffering:NO];
    return YES;
}
- (void)decoderError:(FLAC__StreamDecoderErrorStatus)error {
    if (_seeking && error == FLAC__STREAM_DECODER_ERROR_STATUS_LOST_SYNC)
        return;
    if (!_decodeFailure)
        _decodeFailure = MCPlaybackError(MCPlaybackDecodeError,
                                         error == FLAC__STREAM_DECODER_ERROR_STATUS_FRAME_CRC_MISMATCH
                                             ? @"This FLAC file contains a damaged audio frame."
                                             : @"This FLAC file contains invalid or incomplete audio data.",
                                         NO);
}
- (void)bufferCompleted:(AudioQueueBufferRef)buffer {
    pthread_mutex_lock(&_mutex);
    for (unsigned i = 0; i < MC_AUDIO_BUFFERS; i++)
        if (_buffers[i] == buffer && _busy[i]) {
            if (!_resetting)
                _completedFrames += _bufferFrames[i];
            _lastAudioProgress = CFAbsoluteTimeGetCurrent();
            _busy[i] = NO;
            _bufferFrames[i] = 0;
            if (_queuedCount)
                _queuedCount--;
            break;
        }
    BOOL starved = !_queuedCount && !_draining && !_resetting && _playing && !_cancelled;
    if (starved) {
        _refilling = YES;
        _audioStarted = NO;
    }
    pthread_cond_broadcast(&_condition);
    pthread_mutex_unlock(&_mutex);
    if (starved) {
        [self publishBuffering:YES];
        dispatch_async(_audioControl, ^{
            pthread_mutex_lock(&self->_mutex);
            BOOL pause = self->_refilling && !self->_draining && !self->_resetting && !self->_cancelled;
            pthread_mutex_unlock(&self->_mutex);
            if (pause && self->_audioQueue)
                AudioQueuePause(self->_audioQueue);
        });
    }
}
- (void)runningChanged:(AudioQueueRef)queue {
    UInt32 running = 0;
    UInt32 size = sizeof running;
    if (AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size))
        return;
    pthread_mutex_lock(&_mutex);
    _queueRunning = running != 0;
    if (!running && !_draining && !_resetting)
        _audioStarted = NO;
    pthread_cond_broadcast(&_condition);
    pthread_mutex_unlock(&_mutex);
}
@end
