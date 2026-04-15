/* string.h shim: tiny standalone replacements for the libc functions that
 * the riscv-tests benchmarks reach for. No newlib dependency.
 *
 * Only the functions actually used by integer benchmarks are here. Add
 * more as new programs need them.
 */

#ifndef RAIJIN_STRING_H
#define RAIJIN_STRING_H

#include <stddef.h>

static inline void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char       *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

static inline void *memset(void *dst, int c, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    for (size_t i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

static inline int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = (const unsigned char *)a;
    const unsigned char *y = (const unsigned char *)b;
    for (size_t i = 0; i < n; i++)
        if (x[i] != y[i]) return (int)x[i] - (int)y[i];
    return 0;
}

static inline size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

#endif  /* RAIJIN_STRING_H */
