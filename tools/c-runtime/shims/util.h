/* util.h shim: minimal stand-in for riscv-tests' util.h header.
 *
 * The integer benchmarks under tools/riscv-tests/benchmarks/<bench>/
 * include "util.h" and expect setStats() and verify(). The original
 * header is part of the riscv-tests world and pulls in printf through
 * the spike tohost protocol. We satisfy the include with this self-
 * contained version that talks directly to Raijin's UART instead.
 *
 * Use this directory FIRST on the include path so our shim wins:
 *     -I tools/c-runtime/shims  -I tools/riscv-tests/benchmarks/<bench>
 */

#ifndef RAIJIN_UTIL_H
#define RAIJIN_UTIL_H

#include <stdint.h>

/* ---- MMIO UART exposed by uart_sim.v ------------------------------ */

#define UART_TX_DATA  (*(volatile unsigned int *)0x10000000)

static inline void putchar_(char c) {
    UART_TX_DATA = (unsigned)c;
}

static inline void puts_(const char *s) {
    while (*s) putchar_(*s++);
}

static inline void putint_(int v) {
    if (v < 0) { putchar_('-'); v = -v; }
    char buf[12]; int n = 0;
    if (v == 0) buf[n++] = '0';
    while (v > 0) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) putchar_(buf[n]);
}

static inline void putuint_(unsigned v) {
    char buf[12]; int n = 0;
    if (v == 0) buf[n++] = '0';
    while (v > 0) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) putchar_(buf[n]);
}

static inline void puthex_(unsigned v) {
    char buf[8]; int n = 0;
    for (int i = 7; i >= 0; i--) {
        unsigned nib = (v >> (i * 4)) & 0xF;
        buf[n++] = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
    }
    for (int i = 0; i < n; i++) putchar_(buf[i]);
}

/* ---- Performance counter stub (real hardware would read mcycle) --- */

static inline void setStats(int enable) { (void)enable; }

/* ---- Verify helper (lifted verbatim from the original util.h) ----- */

static int verify(int n, const volatile int *test, const int *ref) {
    for (int i = 0; i < n; i++)
        if (test[i] != ref[i])
            return i + 1;
    return 0;
}

#endif  /* RAIJIN_UTIL_H */
