#define _POSIX_C_SOURCE 200809L
#include "MCPlaybackCore.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

size_t mc_playback_next(size_t count, size_t current, int repeat, int shuffle, uint32_t randomValue,
                        int automatic) {
    if (!count || current >= count)
        return SIZE_MAX;
    if (automatic && repeat == 2)
        return current;
    if (shuffle && count > 1) {
        size_t next = randomValue % (count - 1);
        return next >= current ? next + 1 : next;
    }
    if (current + 1 < count)
        return current + 1;
    return repeat == 1 ? 0 : SIZE_MAX;
}
size_t mc_playback_shuffle_next(size_t count, size_t current, unsigned char *visited, int repeat,
                                uint32_t randomValue) {
    if (!count || current >= count || !visited)
        return SIZE_MAX;
    visited[current] = 1;
    size_t available = 0;
    for (size_t i = 0; i < count; i++)
        if (!visited[i])
            available++;
    if (!available && repeat == 1) {
        memset(visited, 0, count);
        visited[current] = count > 1;
        available = count > 1 ? count - 1 : 1;
    }
    if (!available)
        return SIZE_MAX;
    size_t pick = randomValue % available;
    for (size_t i = 0; i < count; i++)
        if (!visited[i]) {
            if (!pick--) {
                visited[i] = 1;
                return i;
            }
        }
    return SIZE_MAX;
}
size_t mc_playback_remove_index(size_t count, size_t current, size_t removed) {
    if (!count || removed >= count || current >= count)
        return current;
    if (count == 1)
        return SIZE_MAX;
    if (removed < current)
        return current - 1;
    if (removed == current && current == count - 1)
        return current - 1;
    return current;
}
size_t mc_playback_move_index(size_t current, size_t from, size_t to) {
    if (current == from)
        return to;
    if (from < to && current > from && current <= to)
        return current - 1;
    if (to < from && current >= to && current < from)
        return current + 1;
    return current;
}
double mc_playback_seek(double requested, double duration) {
    if (!isfinite(requested) || requested < 0)
        return 0;
    return isfinite(duration) && duration > 0 && requested > duration ? duration : requested;
}
int mc_playback_retry(int transient, unsigned attempts, unsigned limit) {
    return transient && attempts < limit;
}
uint64_t mc_playback_prebuffer_bytes(uint64_t encodedLength, double duration) {
    if (!encodedLength || !isfinite(duration) || duration <= 0)
        return 512 * 1024;
    double bytes = (double)encodedLength / duration * 5.0;
    if (!isfinite(bytes) || bytes >= 2 * 1024 * 1024)
        return 2 * 1024 * 1024;
    if (bytes <= 128 * 1024)
        return 128 * 1024;
    return (uint64_t)ceil(bytes);
}
size_t mc_playback_pcm(int32_t *output, size_t capacity, const int32_t *const *input, unsigned channels,
                       unsigned bits, size_t frames) {
    if (!output || !input || channels < 1 || channels > 8 || bits < 4 || bits > 32 ||
        frames > SIZE_MAX / channels / sizeof(int32_t))
        return 0;
    size_t bytes = frames * channels * sizeof(int32_t);
    if (bytes > capacity)
        return 0;
    for (unsigned c = 0; c < channels; c++)
        if (!input[c])
            return 0;
    for (size_t f = 0; f < frames; f++)
        for (unsigned c = 0; c < channels; c++)
            output[f * channels + c] = (int32_t)((uint32_t)input[c][f] << (32 - bits));
    return bytes;
}
size_t mc_playback_pcm_buffer_bytes(unsigned rate, unsigned channels) {
    if (!rate || channels < 1 || channels > 2)
        return 0;
    size_t frameBytes = channels * sizeof(int32_t);
    uint64_t frames = ((uint64_t)rate + 3) / 4;
    if (frames < 2048)
        frames = 2048;
    if (frames > 128 * 1024 / frameBytes)
        frames = 128 * 1024 / frameBytes;
    return (size_t)frames * frameBytes;
}
size_t mc_playback_pcm_append(int32_t *output, size_t capacity, size_t *usedFrames,
                              const int32_t *const *input, unsigned channels, unsigned bits, size_t frames) {
    if (!usedFrames || channels < 1 || channels > 8)
        return 0;
    size_t frameBytes = channels * sizeof(int32_t), room = capacity / frameBytes;
    if (*usedFrames >= room)
        return 0;
    room -= *usedFrames;
    size_t take = frames < room ? frames : room;
    if (!take || !output ||
        !mc_playback_pcm(output + *usedFrames * channels, capacity - *usedFrames * frameBytes, input,
                         channels, bits, take))
        return 0;
    *usedFrames += take;
    return take;
}

struct MCPlaybackSpool {
    int fd, temporary, done, cancelled, error;
    uint64_t available, expected, maximum, revision;
    char *path;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
};
static MCPlaybackSpool *mc_spool_allocate(void) {
    MCPlaybackSpool *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->fd = -1;
    s->revision = 1;
    pthread_mutex_init(&s->mutex, NULL);
    pthread_cond_init(&s->condition, NULL);
    return s;
}
MCPlaybackSpool *mc_spool_create(const char *directory, uint64_t maximumBytes) {
    if (!directory || !maximumBytes || maximumBytes > INT64_MAX)
        return NULL;
    MCPlaybackSpool *s = mc_spool_allocate();
    if (!s)
        return NULL;
    size_t size = strlen(directory) + 32;
    s->path = malloc(size);
    if (!s->path) {
        mc_spool_destroy(s);
        return NULL;
    }
    snprintf(s->path, size, "%s/muyu-audio-XXXXXX", directory);
    s->fd = mkstemp(s->path);
    s->temporary = 1;
    s->maximum = maximumBytes;
    if (s->fd < 0) {
        mc_spool_destroy(s);
        return NULL;
    }
    fcntl(s->fd, F_SETFD, FD_CLOEXEC);
    return s;
}
MCPlaybackSpool *mc_spool_open(const char *path) {
    if (!path)
        return NULL;
    MCPlaybackSpool *s = mc_spool_allocate();
    if (!s)
        return NULL;
    s->path = strdup(path);
    s->fd = open(path, O_RDONLY);
    struct stat st;
    if (!s->path || s->fd < 0 || fstat(s->fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0) {
        mc_spool_destroy(s);
        return NULL;
    }
    fcntl(s->fd, F_SETFD, FD_CLOEXEC);
    s->available = s->expected = s->maximum = (uint64_t)st.st_size;
    s->done = 1;
    return s;
}
void mc_spool_destroy(MCPlaybackSpool *s) {
    if (!s)
        return;
    if (s->fd >= 0)
        close(s->fd);
    if (s->temporary && s->path)
        unlink(s->path);
    free(s->path);
    pthread_cond_destroy(&s->condition);
    pthread_mutex_destroy(&s->mutex);
    free(s);
}
const char *mc_spool_path(MCPlaybackSpool *s) {
    return s ? s->path : NULL;
}
static void mc_spool_fail_locked(MCPlaybackSpool *s, int error) {
    if (!s->error)
        s->error = error;
    s->done = 1;
    pthread_cond_broadcast(&s->condition);
}
int mc_spool_append(MCPlaybackSpool *s, const void *bytes, size_t length) {
    if (!s || (!bytes && length))
        return -EINVAL;
    pthread_mutex_lock(&s->mutex);
    int result = 0;
    if (s->cancelled)
        result = -ECANCELED;
    else if (s->done)
        result = s->error ? -s->error : -EPIPE;
    else if (length > s->maximum - s->available) {
        mc_spool_fail_locked(s, EFBIG);
        result = -EFBIG;
    } else {
        size_t copied = 0;
        while (copied < length) {
            ssize_t n =
                pwrite(s->fd, (const char *)bytes + copied, length - copied, (off_t)(s->available + copied));
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0) {
                result = -(errno ? errno : EIO);
                break;
            }
            copied += (size_t)n;
        }
        s->available += copied;
        if (result)
            mc_spool_fail_locked(s, -result);
        pthread_cond_broadcast(&s->condition);
    }
    pthread_mutex_unlock(&s->mutex);
    return result;
}
void mc_spool_set_length(MCPlaybackSpool *s, uint64_t expected) {
    if (!s || !expected)
        return;
    pthread_mutex_lock(&s->mutex);
    if (expected > s->maximum)
        mc_spool_fail_locked(s, EFBIG);
    else if (expected < s->available)
        mc_spool_fail_locked(s, EIO);
    else
        s->expected = expected;
    pthread_cond_broadcast(&s->condition);
    pthread_mutex_unlock(&s->mutex);
}
void mc_spool_finish(MCPlaybackSpool *s, int errorCode) {
    if (!s)
        return;
    pthread_mutex_lock(&s->mutex);
    if (!s->done) {
        if (!errorCode && s->expected && s->available != s->expected)
            errorCode = EIO;
        if (errorCode)
            s->error = errorCode;
        s->done = 1;
    }
    pthread_cond_broadcast(&s->condition);
    pthread_mutex_unlock(&s->mutex);
}
void mc_spool_cancel(MCPlaybackSpool *s) {
    if (!s)
        return;
    pthread_mutex_lock(&s->mutex);
    s->cancelled = 1;
    pthread_cond_broadcast(&s->condition);
    pthread_mutex_unlock(&s->mutex);
}
uint64_t mc_spool_revision(MCPlaybackSpool *s) {
    if (!s)
        return 0;
    pthread_mutex_lock(&s->mutex);
    uint64_t value = s->revision;
    pthread_mutex_unlock(&s->mutex);
    return value;
}
void mc_spool_interrupt(MCPlaybackSpool *s) {
    if (!s)
        return;
    pthread_mutex_lock(&s->mutex);
    s->revision++;
    pthread_cond_broadcast(&s->condition);
    pthread_mutex_unlock(&s->mutex);
}
/* No-data waits are finite. Progress resets the inactivity deadline. */
static int mc_spool_wait_locked(MCPlaybackSpool *s, uint64_t revision) {
    if (s->cancelled || revision != s->revision)
        return -ECANCELED;
    struct timespec until;
    struct timeval now;
    gettimeofday(&now, NULL);
    until.tv_sec = now.tv_sec + 30;
    until.tv_nsec = now.tv_usec * 1000;
    uint64_t before = s->available;
    int result = pthread_cond_timedwait(&s->condition, &s->mutex, &until);
    if (s->cancelled || revision != s->revision)
        return -ECANCELED;
    if (result == ETIMEDOUT && before == s->available && !s->done) {
        mc_spool_fail_locked(s, ETIMEDOUT);
        return -ETIMEDOUT;
    }
    return 0;
}
int mc_spool_wait_buffer(MCPlaybackSpool *s, uint64_t offset, uint64_t minimumBytes, uint64_t revision) {
    if (!s || !minimumBytes)
        return -EINVAL;
    pthread_mutex_lock(&s->mutex);
    int result = 0;
    if (offset > s->maximum || (s->expected && offset > s->expected))
        result = -EINVAL;
    while (!result && !s->done) {
        if (s->expected && offset > s->expected) {
            result = -EINVAL;
            break;
        }
        uint64_t remaining = s->expected ? s->expected - offset : s->maximum - offset;
        uint64_t target = minimumBytes < remaining ? minimumBytes : remaining;
        if (s->available >= offset && s->available - offset >= target)
            break;
        result = mc_spool_wait_locked(s, revision);
    }
    if (s->cancelled || revision != s->revision)
        result = -ECANCELED;
    else if (!result && s->error)
        result = -s->error;
    else if (!result && s->done && offset > s->available)
        result = -EIO;
    pthread_mutex_unlock(&s->mutex);
    return result;
}
ssize_t mc_spool_read(MCPlaybackSpool *s, void *bytes, size_t maximum, uint64_t *offset, uint64_t revision) {
    if (!s || !bytes || !maximum || !offset || maximum > SSIZE_MAX)
        return -EINVAL;
    pthread_mutex_lock(&s->mutex);
    int status = 0;
    while (*offset >= s->available && !s->done && !status)
        status = mc_spool_wait_locked(s, revision);
    if (s->cancelled || revision != s->revision)
        status = -ECANCELED;
    ssize_t result = status;
    if (!status && *offset < s->available) {
        uint64_t left = s->available - *offset;
        size_t take = left < maximum ? (size_t)left : maximum;
        do {
            result = pread(s->fd, bytes, take, (off_t)*offset);
        } while (result < 0 && errno == EINTR);
        if (result <= 0) {
            result = -(errno ? errno : EIO);
            mc_spool_fail_locked(s, (int)-result);
        } else
            *offset += (uint64_t)result;
    } else if (!status)
        result = s->error ? -s->error : 0;
    pthread_mutex_unlock(&s->mutex);
    return result;
}
int mc_spool_seek(MCPlaybackSpool *s, uint64_t offset, uint64_t revision) {
    if (!s)
        return -EINVAL;
    pthread_mutex_lock(&s->mutex);
    int result = 0;
    if (offset > s->maximum || (s->expected && offset > s->expected))
        result = -EINVAL;
    while (!result && offset > s->available && !s->done)
        result = mc_spool_wait_locked(s, revision);
    if (s->cancelled || revision != s->revision)
        result = -ECANCELED;
    else if (!result && offset > s->available)
        result = s->error ? -s->error : -EINVAL;
    pthread_mutex_unlock(&s->mutex);
    return result;
}
int mc_spool_length(MCPlaybackSpool *s, uint64_t *length, uint64_t revision) {
    if (!s || !length)
        return -EINVAL;
    pthread_mutex_lock(&s->mutex);
    int result = 0;
    while (!s->expected && !s->done && !result)
        result = mc_spool_wait_locked(s, revision);
    if (s->cancelled || revision != s->revision)
        result = -ECANCELED;
    else if (!result && s->error)
        result = -s->error;
    if (!result)
        *length = s->expected ? s->expected : s->available;
    pthread_mutex_unlock(&s->mutex);
    return result;
}
uint64_t mc_spool_available(MCPlaybackSpool *s) {
    if (!s)
        return 0;
    pthread_mutex_lock(&s->mutex);
    uint64_t result = s->available;
    pthread_mutex_unlock(&s->mutex);
    return result;
}
int mc_spool_complete(MCPlaybackSpool *s) {
    if (!s)
        return 0;
    pthread_mutex_lock(&s->mutex);
    int result = s->done;
    pthread_mutex_unlock(&s->mutex);
    return result;
}
int mc_spool_error(MCPlaybackSpool *s) {
    if (!s)
        return EINVAL;
    pthread_mutex_lock(&s->mutex);
    int result = s->error;
    pthread_mutex_unlock(&s->mutex);
    return result;
}

ssize_t mc_spool_read_timed(MCPlaybackSpool *s, void *bytes, size_t maximum, uint64_t *offset,
                            uint64_t revision, unsigned waitMilliseconds) {
    if (!s || !bytes || !maximum || !offset || maximum > SSIZE_MAX || waitMilliseconds > 1000)
        return -EINVAL;
    pthread_mutex_lock(&s->mutex);
    if (*offset >= s->available && !s->done && !s->cancelled && revision == s->revision && waitMilliseconds) {
        struct timeval now;
        gettimeofday(&now, NULL);
        struct timespec until = {now.tv_sec + waitMilliseconds / 1000,
                                 now.tv_usec * 1000 + (waitMilliseconds % 1000) * 1000000};
        if (until.tv_nsec >= 1000000000) {
            until.tv_sec++;
            until.tv_nsec -= 1000000000;
        }
        pthread_cond_timedwait(&s->condition, &s->mutex, &until);
    }
    ssize_t result;
    if (s->cancelled || revision != s->revision)
        result = -ECANCELED;
    else if (*offset < s->available) {
        uint64_t left = s->available - *offset;
        size_t take = left < maximum ? (size_t)left : maximum;
        do {
            result = pread(s->fd, bytes, take, (off_t)*offset);
        } while (result < 0 && errno == EINTR);
        if (result <= 0) {
            result = -(errno ? errno : EIO);
            mc_spool_fail_locked(s, (int)-result);
        } else
            *offset += (uint64_t)result;
    } else
        result = s->done ? (s->error ? -s->error : 0) : -EAGAIN;
    pthread_mutex_unlock(&s->mutex);
    return result;
}
uint64_t mc_spool_expected_length(MCPlaybackSpool *s) {
    if (!s)
        return 0;
    pthread_mutex_lock(&s->mutex);
    uint64_t result = s->expected ? s->expected : (s->done ? s->available : 0);
    pthread_mutex_unlock(&s->mutex);
    return result;
}
