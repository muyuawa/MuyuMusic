#include "../Sources/Playback/MCPlaybackCore.h"
#include <assert.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>

/* These cases catch wrong repeat branches, skipped queue items, unsafe offsets,
   unbounded disk writes, premature EOF, and missing cancellation wakeups. */
static void queue_tests(void) {
    assert(mc_playback_next(0, 0, 1, 0, 0, 1) == SIZE_MAX);
    assert(mc_playback_next(3, 1, 0, 0, 0, 1) == 2);
    assert(mc_playback_next(3, 2, 0, 0, 0, 1) == SIZE_MAX);
    assert(mc_playback_next(3, 2, 1, 0, 0, 1) == 0);
    assert(mc_playback_next(3, 1, 2, 0, 0, 1) == 1);
    assert(mc_playback_next(3, 1, 2, 0, 0, 0) == 2);
    assert(mc_playback_next(3, 1, 0, 1, 1, 1) == 2);
    assert(mc_playback_next(3, 1, 0, 1, 0, 1) == 0);
    unsigned char visited[3] = {0};
    assert(mc_playback_shuffle_next(3, 1, visited, 0, 0) == 0);
    assert(mc_playback_shuffle_next(3, 0, visited, 0, 0) == 2);
    assert(mc_playback_shuffle_next(3, 2, visited, 0, 0) == SIZE_MAX);
    assert(mc_playback_shuffle_next(3, 2, visited, 1, 0) == 0);
    unsigned char original[3] = {1, 0, 0}, planned[3] = {0};
    assert(mc_playback_shuffle_preview(3, 0, original, 0, 1, planned) == 2);
    assert(original[0] == 1 && original[1] == 0 && original[2] == 0);
    assert(planned[0] == 1 && planned[1] == 0 && planned[2] == 1);
    memcpy(original, planned, sizeof original); // Commit the exact preview, without choosing again.
    assert(mc_playback_shuffle_next(3, 2, original, 0, 0) == 1);
    assert(mc_playback_shuffle_preview(3, 1, original, 1, 0, planned) == 0);
    assert(original[0] == 1 && original[1] == 1 && original[2] == 1); // Cancel preserves cycle.
    assert(planned[0] == 1 && planned[1] == 1 && planned[2] == 0);
    assert(mc_playback_shuffle_preview(3, 1, original, 0, 0, original) == SIZE_MAX);
    assert(mc_playback_shuffle_preview(0, 0, original, 0, 0, planned) == SIZE_MAX);
    assert(mc_playback_remove_index(3, 2, 0) == 1);
    assert(mc_playback_remove_index(3, 1, 1) == 1);
    assert(mc_playback_remove_index(3, 2, 2) == 1);
    assert(mc_playback_remove_index(1, 0, 0) == SIZE_MAX);
    assert(mc_playback_move_index(2, 0, 3) == 1);
    assert(mc_playback_move_index(0, 0, 3) == 3);
    assert(mc_playback_move_index(2, 3, 0) == 3);
    assert(mc_playback_seek(-7, 100) == 0);
    assert(mc_playback_seek(NAN, 100) == 0);
    assert(mc_playback_seek(140, 100) == 100);
    assert(mc_playback_seek(40, 0) == 40);
    assert(mc_playback_retry(1, 0, 2));
    assert(mc_playback_retry(1, 1, 2));
    assert(!mc_playback_retry(1, 2, 2));
    assert(!mc_playback_retry(0, 0, 2));
}
static void pcm_tests(void) {
    int32_t left[] = {-32768, 0, 32767};
    int32_t right[] = {32767, -32768, -1};
    const int32_t *input[] = {left, right};
    int32_t actual[6] = {0};
    assert(mc_playback_pcm(actual, sizeof actual, input, 2, 16, 3) == 24);
    const int32_t want[] = {INT32_MIN, 2147418112, 0, INT32_MIN, 2147418112, -65536};
    assert(!memcmp(actual, want, sizeof want));
    assert(!mc_playback_pcm(actual, 4, input, 2, 16, 3));
    assert(!mc_playback_pcm(actual, sizeof actual, input, 9, 16, 3));
    assert(!mc_playback_pcm(actual, sizeof actual, input, 2, 33, 3));
    int32_t hi[] = {INT32_MIN, INT32_MAX};
    const int32_t *native[] = {hi};
    assert(mc_playback_pcm(actual, sizeof actual, native, 1, 32, 2) == 8);
    assert(actual[0] == INT32_MIN && actual[1] == INT32_MAX);
}
static void pcm_staging_tests(void) {
    size_t capacity = mc_playback_pcm_buffer_bytes(44100, 2);
    assert(capacity == 11025 * 2 * sizeof(int32_t));
    assert(mc_playback_pcm_buffer_bytes(192000, 2) == 128 * 1024);
    assert(!mc_playback_pcm_buffer_bytes(0, 2));
    assert(!mc_playback_pcm_buffer_bytes(44100, 3));
    /* Uneven FLAC frames must fill the output buffers without dropping or
       duplicating samples, including the final short buffer. */
    const size_t total = 29000;
    int32_t *left = malloc(total * sizeof(int32_t)), *right = malloc(total * sizeof(int32_t));
    int32_t *buffer = malloc(capacity);
    assert(left && right && buffer);
    for (size_t i = 0; i < total; i++) {
        left[i] = (int32_t)i - 14500;
        right[i] = -left[i];
    }
    size_t consumed = 0, produced = 0, used = 0, buffers = 0;
    while (consumed < total) {
        size_t fragment = consumed % 2 ? 4608 : 4096;
        if (fragment > total - consumed)
            fragment = total - consumed;
        size_t offset = 0;
        while (offset < fragment) {
            const int32_t *planes[] = {left + consumed + offset, right + consumed + offset};
            size_t take = mc_playback_pcm_append(buffer, capacity, &used, planes, 2, 24, fragment - offset);
            assert(take && take <= fragment - offset);
            offset += take;
            if (used == capacity / 8 || (consumed + offset == total)) {
                for (size_t i = 0; i < used; i++) {
                    assert(buffer[i * 2] == (int32_t)((uint32_t)left[produced + i] * 256));
                    assert(buffer[i * 2 + 1] == (int32_t)((uint32_t)right[produced + i] * 256));
                }
                produced += used;
                buffers++;
                used = 0;
            }
        }
        consumed += fragment;
    }
    assert(produced == total && buffers == 3 && used == 0);
    size_t invalid = SIZE_MAX;
    const int32_t *planes[] = {left, right};
    assert(!mc_playback_pcm_append(buffer, capacity, &invalid, planes, 2, 24, 1));
    free(buffer);
    free(left);
    free(right);
    puts("PCM staging: quarter-second capacity, uneven FLAC frames and exact final tail passed");
}
struct Read {
    MCPlaybackSpool *s;
    ssize_t result;
    uint64_t offset;
    uint64_t revision;
    char bytes[8];
};
static void *read_thread(void *arg) {
    struct Read *r = arg;
    r->result = mc_spool_read(r->s, r->bytes, sizeof r->bytes, &r->offset, r->revision);
    return NULL;
}
static void spool_tests(void) {
    MCPlaybackSpool *s = mc_spool_create("/tmp", 16);
    assert(s);
    char poll[4];
    uint64_t pollOffset = 0;
    assert(mc_spool_read_timed(s, poll, 4, &pollOffset, mc_spool_revision(s), 1) == -EAGAIN);
    assert(mc_spool_error(s) == 0); /* A cancelled native range must not poison all readers. */
    assert(mc_spool_expected_length(s) == 0);
    char *path = strdup(mc_spool_path(s));
    struct Read r = {s, -999, 0, mc_spool_revision(s), {0}};
    pthread_t t;
    assert(!pthread_create(&t, NULL, read_thread, &r));
    usleep(10000);
    assert(!mc_spool_append(s, "abcdef", 6));
    assert(!pthread_join(t, NULL));
    assert(r.result == 6 && r.offset == 6 && !memcmp(r.bytes, "abcdef", 6));
    r.result = -999;
    assert(!pthread_create(&t, NULL, read_thread, &r));
    usleep(10000);
    mc_spool_interrupt(s);
    assert(!pthread_join(t, NULL));
    assert(r.result == -ECANCELED);
    r.revision = mc_spool_revision(s);
    assert(!mc_spool_append(s, "ghij", 4));
    mc_spool_set_length(s, 10);
    assert(mc_spool_expected_length(s) == 10);
    mc_spool_finish(s, 0);
    uint64_t length = 0;
    assert(!mc_spool_length(s, &length, r.revision) && length == 10);
    pollOffset = 6;
    assert(mc_spool_read_timed(s, poll, sizeof poll, &pollOffset, r.revision, 0) == 4);
    assert(!memcmp(poll, "ghij", 4));
    pollOffset = 2;
    assert(mc_spool_read_timed(s, poll, sizeof poll, &pollOffset, r.revision, 0) == 4);
    assert(!memcmp(poll, "cdef", 4)); /* Independent backwards native byte ranges. */
    assert(!mc_spool_seek(s, 0, r.revision));
    assert(mc_spool_seek(s, 11, r.revision) == -EINVAL);
    r.offset = 0;
    assert(mc_spool_read(s, r.bytes, 8, &r.offset, r.revision) == 8);
    assert(!memcmp(r.bytes, "abcdefgh", 8));
    assert(mc_spool_read(s, r.bytes, 8, &r.offset, r.revision) == 2);
    assert(mc_spool_read(s, r.bytes, 8, &r.offset, r.revision) == 0);
    mc_spool_destroy(s);
    assert(access(path, F_OK) == -1);
    free(path);

    s = mc_spool_create("/tmp", 8);
    assert(s);
    assert(!mc_spool_append(s, "12345678", 8));
    assert(mc_spool_append(s, "9", 1) == -EFBIG);
    assert(mc_spool_error(s) == EFBIG);
    assert(mc_spool_available(s) == 8);
    mc_spool_destroy(s);

    s = mc_spool_create("/tmp", 8);
    assert(s);
    mc_spool_set_length(s, 8);
    assert(!mc_spool_append(s, "123", 3));
    mc_spool_finish(s, 0);
    assert(mc_spool_error(s) == EIO); /* Content-Length truncation is never EOF. */
    mc_spool_destroy(s);

    s = mc_spool_create("/tmp", 8);
    assert(s);
    r = (struct Read){s, -999, 0, mc_spool_revision(s), {0}};
    assert(!pthread_create(&t, NULL, read_thread, &r));
    usleep(10000);
    mc_spool_cancel(s);
    assert(!pthread_join(t, NULL));
    assert(r.result == -ECANCELED);
    mc_spool_destroy(s);
    puts("playback: queue, seek, PCM, concurrent spool, cancellation, bounds and truncation passed");
}
struct BufferWait {
    MCPlaybackSpool *spool;
    uint64_t offset, target, revision;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int started, finished, result;
};
static void *buffer_wait_thread(void *context) {
    struct BufferWait *w = context;
    pthread_mutex_lock(&w->mutex);
    w->started = 1;
    pthread_cond_signal(&w->condition);
    pthread_mutex_unlock(&w->mutex);
    int result = mc_spool_wait_buffer(w->spool, w->offset, w->target, w->revision);
    pthread_mutex_lock(&w->mutex);
    w->result = result;
    w->finished = 1;
    pthread_cond_signal(&w->condition);
    pthread_mutex_unlock(&w->mutex);
    return NULL;
}
static void buffer_tests(void) {
    uint64_t target = mc_playback_prebuffer_bytes(44203497, 213.89);
    assert(target > 1030000 && target < 1040000); /* Approx. five seconds of the observed FLAC. */
    assert(mc_playback_prebuffer_bytes(0, 0) == 512 * 1024);
    assert(mc_playback_prebuffer_bytes(1, 1000) == 128 * 1024);
    assert(mc_playback_prebuffer_bytes(UINT64_MAX, .001) == 2 * 1024 * 1024);
    MCPlaybackSpool *s = mc_spool_create("/tmp", 16);
    assert(s);
    struct BufferWait w = {.spool = s,
                           .target = 6,
                           .revision = mc_spool_revision(s),
                           .mutex = PTHREAD_MUTEX_INITIALIZER,
                           .condition = PTHREAD_COND_INITIALIZER};
    pthread_t thread;
    assert(!pthread_create(&thread, NULL, buffer_wait_thread, &w));
    pthread_mutex_lock(&w.mutex);
    while (!w.started)
        pthread_cond_wait(&w.condition, &w.mutex);
    pthread_mutex_unlock(&w.mutex);
    assert(!mc_spool_append(s, "abc", 3));
    pthread_mutex_lock(&w.mutex);
    struct timeval now;
    gettimeofday(&now, NULL);
    struct timespec until = {now.tv_sec, now.tv_usec * 1000 + 50000000};
    if (until.tv_nsec >= 1000000000) {
        until.tv_sec++;
        until.tv_nsec -= 1000000000;
    }
    while (!w.finished && pthread_cond_timedwait(&w.condition, &w.mutex, &until) != ETIMEDOUT) {
    }
    assert(!w.finished); /* A single tiny packet must not start/refill playback. */
    pthread_mutex_unlock(&w.mutex);
    assert(!mc_spool_append(s, "def", 3));
    assert(!pthread_join(thread, NULL));
    assert(!w.result);
    w.offset = 6;
    w.target = 8;
    w.revision = mc_spool_revision(s);
    w.started = w.finished = 0;
    assert(!pthread_create(&thread, NULL, buffer_wait_thread, &w));
    mc_spool_interrupt(s);
    assert(!pthread_join(thread, NULL));
    assert(w.result == -ECANCELED);
    assert(!mc_spool_append(s, "ghi", 3));
    mc_spool_finish(s, 0);
    assert(!mc_spool_wait_buffer(s, 6, 8, mc_spool_revision(s))); /* Short final tail is playable. */
    mc_spool_destroy(s);
    pthread_cond_destroy(&w.condition);
    pthread_mutex_destroy(&w.mutex);
    puts("prebuffer: watermark, short tail and seek cancellation passed");
}
int main(void) {
    alarm(10);
    queue_tests();
    pcm_tests();
    pcm_staging_tests();
    spool_tests();
    buffer_tests();
    return 0;
}
