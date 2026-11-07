#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
extern int64_t mbedtls_ms_time(void);
int main(void) {int64_t before=mbedtls_ms_time();usleep(30000);int64_t after=mbedtls_ms_time();assert(after-before>=20&&after-before<1000);puts("TLS monotonic clock: elapsed-time check passed");}
