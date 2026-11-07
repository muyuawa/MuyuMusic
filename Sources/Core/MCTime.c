/* Mbed TLS' supported MS_TIME_ALT hook: iOS 7 predates clock_gettime. */
#include <stdint.h>
#include <mach/mach_time.h>
#include <pthread.h>
static mach_timebase_info_data_t mc_timebase;
static pthread_once_t mc_time_once = PTHREAD_ONCE_INIT;
static void mc_time_init(void) {
    mach_timebase_info(&mc_timebase);
}
int64_t mbedtls_ms_time(void) {
    pthread_once(&mc_time_once, mc_time_init);
    uint64_t ticks = mach_absolute_time();
    uint64_t nanos = (ticks / mc_timebase.denom) * mc_timebase.numer +
                     ((ticks % mc_timebase.denom) * mc_timebase.numer) / mc_timebase.denom;
    return (int64_t)(nanos / 1000000);
}
