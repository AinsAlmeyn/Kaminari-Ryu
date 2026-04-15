/* raijin_time.c: cycle-counter-driven time for doomgeneric.
 *
 * Doom expects DG_GetTicksMs() to return a monotonic millisecond counter.
 * We derive it from rdcycle (mcycle CSR) divided by an estimate of cycles
 * per ms. On our single-cycle CPU, "cycles" means "instructions retired",
 * which on Verilator runs at ~1 MHz wall clock in browser, ~5-10 MHz
 * native. The exact number doesn't matter for game logic, only relative
 * pacing does.
 *
 * DG_SleepMs() is a busy loop on the same source.
 */

#include <stdint.h>
#include "doomgeneric.h"

/* Empirical: Verilator native at ~5 MHz instruction rate. Tune to taste
 * if Doom timing feels off. The doomgeneric tic system is forgiving. */
#define CYCLES_PER_MS  5000ULL

static inline uint64_t rdcycle(void) {
    uint32_t lo, hi, hi2;
    /* Standard double-read trick: read high, low, high again, retry on
     * overflow. mcycle is two 32-bit CSRs (mcycleh, mcycle). */
    do {
        __asm__ volatile ("csrr %0, mcycleh" : "=r"(hi));
        __asm__ volatile ("csrr %0, mcycle"  : "=r"(lo));
        __asm__ volatile ("csrr %0, mcycleh" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

uint32_t DG_GetTicksMs(void) {
    return (uint32_t)(rdcycle() / CYCLES_PER_MS);
}

void DG_SleepMs(uint32_t ms) {
    uint32_t target = DG_GetTicksMs() + ms;
    while ((int32_t)(target - DG_GetTicksMs()) > 0) {
        /* spin */
    }
}
