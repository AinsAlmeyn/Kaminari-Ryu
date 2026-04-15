/* ============================================================================
 * raijin_api.h: C API for the Raijin RV32I+Zicsr simulator.
 *
 * Hourglass design: the Verilated C++ model lives behind an opaque pointer
 * (RaijinSim*) and every exported function is extern "C" so the DLL is
 * callable from C, C#, Python, Rust, etc. without name-mangling issues.
 *
 * All functions are safe to call on a null RaijinSim*: they become no-ops
 * that return zero. Makes C# SafeHandle finalizer races harmless.
 * ============================================================================ */

#ifndef RAIJIN_API_H
#define RAIJIN_API_H

#include <stdint.h>

#if defined(_WIN32) || defined(__CYGWIN__)
  #ifdef RAIJIN_BUILDING_DLL
    #define RAIJIN_API __declspec(dllexport)
  #else
    #define RAIJIN_API __declspec(dllimport)
  #endif
#else
  #if defined(__GNUC__) && (__GNUC__ >= 4)
    #define RAIJIN_API __attribute__((visibility("default")))
  #else
    #define RAIJIN_API
  #endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RaijinSim RaijinSim;

/* ---- lifecycle ---- */
RAIJIN_API RaijinSim* raijin_create(void);
RAIJIN_API void       raijin_destroy(RaijinSim* sim);
RAIJIN_API void       raijin_reset(RaijinSim* sim);

/* ---- program load + execution ----
 * raijin_load_hex returns 0 on success, non-zero on error.
 * raijin_step returns the number of cycles actually executed (may be less
 * than max_cycles if the program halted via tohost).
 */
RAIJIN_API int        raijin_load_hex(RaijinSim* sim, const char* path);
RAIJIN_API uint64_t   raijin_step(RaijinSim* sim, uint64_t max_cycles);
RAIJIN_API int        raijin_halted(RaijinSim* sim);
RAIJIN_API uint32_t   raijin_tohost(RaijinSim* sim);

/* ---- introspection ----
 * out_regs:  x0..x31          (32 words)
 * out_csrs:  mstatus, mepc, mtvec, mcause, mtval, mscratch, mie, mip
 */
RAIJIN_API uint32_t   raijin_get_pc(RaijinSim* sim);
RAIJIN_API void       raijin_get_regs(RaijinSim* sim, uint32_t out_regs[32]);
RAIJIN_API void       raijin_get_csrs(RaijinSim* sim, uint32_t out_csrs[8]);
RAIJIN_API void       raijin_read_dmem(RaijinSim* sim, uint32_t byte_addr,
                                       uint8_t* buf, uint32_t len);
RAIJIN_API uint64_t   raijin_cycle_count(RaijinSim* sim);
RAIJIN_API uint64_t   raijin_instret(RaijinSim* sim);

/* Hardware perfcounters: instruction-class breakdown.
 * out is filled with: [mul, branch_total, branch_taken, jump, load, store, trap].
 */
#define RAIJIN_NUM_CLASS_COUNTERS 7
RAIJIN_API void       raijin_get_class_counters(RaijinSim* sim, uint64_t out[RAIJIN_NUM_CLASS_COUNTERS]);

/* ---- UART ----
 * raijin_uart_read drains up to `max` bytes from the TX ring buffer into
 * `buf`, returning the number of bytes actually written. Non-blocking.
 * raijin_uart_write pushes one byte onto the RX queue (phase 7).
 */
RAIJIN_API int        raijin_uart_read(RaijinSim* sim, char* buf, int max);
RAIJIN_API void       raijin_uart_write(RaijinSim* sim, char c);

#ifdef __cplusplus
}
#endif

#endif /* RAIJIN_API_H */
