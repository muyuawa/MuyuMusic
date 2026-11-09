#ifndef MCPlaybackCore_h
#define MCPlaybackCore_h
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/* SIZE_MAX means no selection. Manual next ignores repeat-one. */
size_t mc_playback_next(size_t count, size_t current, int repeat, int shuffle, uint32_t randomValue,
                        int automatic);
size_t mc_playback_shuffle_next(size_t count, size_t current, unsigned char *visited, int repeat,
                                uint32_t randomValue);
size_t mc_playback_shuffle_preview(size_t count, size_t current, const unsigned char *visited, int repeat,
                                   uint32_t randomValue, unsigned char *nextVisited);
size_t mc_playback_remove_index(size_t count, size_t current, size_t removed);
size_t mc_playback_move_index(size_t current, size_t from, size_t to);
double mc_playback_seek(double requested, double duration);
int mc_playback_retry(int transient, unsigned attempts, unsigned limit);
/* Five seconds of encoded lookahead, bounded for prompt startup on old devices. */
uint64_t mc_playback_prebuffer_bytes(uint64_t encodedLength, double duration);
/* Signed, native-endian 32-bit PCM, left-aligned without signed-shift UB. */
size_t mc_playback_pcm(int32_t *output, size_t capacity, const int32_t *const *input, unsigned channels,
                       unsigned bits, size_t frames);
/* Six quarter-second output buffers, individually capped at 128 KiB. */
size_t mc_playback_pcm_buffer_bytes(unsigned rate, unsigned channels);
/* Append a FLAC frame fragment to a partially filled output buffer. Returns
   consumed frames; the caller retains/queues the final short tail at EOF. */
size_t mc_playback_pcm_append(int32_t *output, size_t capacity, size_t *usedFrames,
                              const int32_t *const *input, unsigned channels, unsigned bits, size_t frames);

typedef struct MCPlaybackSpool MCPlaybackSpool;
/* A temp spool unlinks itself on destruction. Local files are never deleted. */
MCPlaybackSpool *mc_spool_create(const char *directory, uint64_t maximumBytes);
MCPlaybackSpool *mc_spool_open(const char *path);
void mc_spool_destroy(MCPlaybackSpool *spool);
const char *mc_spool_path(MCPlaybackSpool *spool);
int mc_spool_append(MCPlaybackSpool *spool, const void *bytes, size_t length);
void mc_spool_set_length(MCPlaybackSpool *spool, uint64_t expected);
void mc_spool_finish(MCPlaybackSpool *spool, int errorCode);
void mc_spool_cancel(MCPlaybackSpool *spool);
/* Revision interrupts a blocked read/seek for a newer seek, without losing data. */
uint64_t mc_spool_revision(MCPlaybackSpool *spool);
void mc_spool_interrupt(MCPlaybackSpool *spool);
/* Wait for a disk-backed lookahead watermark. EOF permits a shorter final tail.
   Seek/cancel wakes this immediately; no PCM or whole-song memory is allocated. */
int mc_spool_wait_buffer(MCPlaybackSpool *spool, uint64_t offset, uint64_t minimumBytes, uint64_t revision);
ssize_t mc_spool_read(MCPlaybackSpool *spool, void *bytes, size_t maximum, uint64_t *offset,
                      uint64_t revision);
/* Short cancellable polling reads for independent AVAsset range requests.
   -EAGAIN means no bytes yet, not EOF. This does not poison other readers. */
ssize_t mc_spool_read_timed(MCPlaybackSpool *spool, void *bytes, size_t maximum, uint64_t *offset,
                            uint64_t revision, unsigned waitMilliseconds);
uint64_t mc_spool_expected_length(MCPlaybackSpool *spool);
int mc_spool_seek(MCPlaybackSpool *spool, uint64_t offset, uint64_t revision);
int mc_spool_length(MCPlaybackSpool *spool, uint64_t *length, uint64_t revision);
uint64_t mc_spool_available(MCPlaybackSpool *spool);
int mc_spool_complete(MCPlaybackSpool *spool);
int mc_spool_error(MCPlaybackSpool *spool);
#endif
