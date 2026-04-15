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

#define UART_TX_DATA   (*(volatile unsigned int *)0x10000000)
#define UART_TX_READY  (*(volatile unsigned int *)0x10000004)
#define UART_RX_DATA   (*(volatile unsigned int *)0x10000008)
#define UART_RX_STATUS (*(volatile unsigned int *)0x1000000C)

static inline void putchar_(char c) {
    UART_TX_DATA = (unsigned)c;
}

/* Non-blocking RX. Returns -1 if no byte is waiting, else the byte. */
static inline int uart_rx_poll(void) {
    if (UART_RX_STATUS & 1u) return (int)(UART_RX_DATA & 0xFFu);
    return -1;
}

/* Blocking RX. Spins until a byte is available. */
static inline int uart_rx_get(void) {
    while (!(UART_RX_STATUS & 1u)) { /* spin */ }
    return (int)(UART_RX_DATA & 0xFFu);
}

/* Deterministic delay paced off the mcycle CSR. The constant is the
 * "assumed" cycles per ms — i.e. the simulator's target real-time MIPS.
 * With Verilator + -O3/LTO on modern x86-64 we land around 8 MIPS, so a
 * 1 ms delay here burns 8000 cycles, which at 8 MIPS is ~1 ms wall clock.
 * If the simulator throughput changes, the game pacing scales with it
 * automatically (CYCLES_PER_MS defines "virtual MHz", not wall clock). */
#define RAIJIN_CYCLES_PER_MS 8000u

static inline unsigned raijin_cycle_lo_(void) {
    unsigned v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

static inline void delay_ms_(int ms) {
    unsigned start  = raijin_cycle_lo_();
    unsigned target = start + (unsigned)ms * RAIJIN_CYCLES_PER_MS;
    /* Wrap-safe compare: `target - now` interpreted as signed stays
     * positive while we haven't reached target yet. */
    while ((int)(target - raijin_cycle_lo_()) > 0) { /* spin */ }
}

/* xorshift32 PRNG. Caller seeds; returns new state via pointer. */
static inline unsigned rng_next_(unsigned *state) {
    unsigned x = *state ? *state : 0xDEADBEEFu;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
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
