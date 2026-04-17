/*
 * Minimal benchmark harness that links directly against raijin.dll.
 * Accepts --dll <path> so we can A/B test two builds in the same workflow.
 *   bench --dll build/sim-v1/bin/raijin.dll --hex programs/matrix.hex --cycles 10000000 --runs 3
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE dll_handle;
#define LOAD_LIB(p)  LoadLibraryA(p)
#define GET_SYM(h,s) (void*)GetProcAddress((h),(s))
#define CLOSE_LIB(h) FreeLibrary(h)
#else
#include <dlfcn.h>
typedef void* dll_handle;
#define LOAD_LIB(p)  dlopen((p), RTLD_NOW)
#define GET_SYM(h,s) dlsym((h),(s))
#define CLOSE_LIB(h) dlclose(h)
#endif

typedef struct RaijinSim RaijinSim;
typedef RaijinSim* (*fn_create)(void);
typedef void       (*fn_destroy)(RaijinSim*);
typedef void       (*fn_reset)(RaijinSim*);
typedef int        (*fn_load_hex)(RaijinSim*, const char*);
typedef uint64_t   (*fn_step)(RaijinSim*, uint64_t);
typedef int        (*fn_halted)(RaijinSim*);
typedef uint64_t   (*fn_cycles)(RaijinSim*);
typedef uint64_t   (*fn_instret)(RaijinSim*);
typedef void       (*fn_classctrs)(RaijinSim*, uint64_t*);
typedef void       (*fn_classctrs_v2)(RaijinSim*, uint64_t*);

static double now_s(void) {
#ifdef _WIN32
    LARGE_INTEGER f, t;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)f.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
#endif
}

int main(int argc, char** argv) {
    const char* dll_path = NULL;
    const char* hex_path = NULL;
    uint64_t max_cycles = 10000000;
    int runs = 3;
    const char* label = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dll") && i + 1 < argc) dll_path = argv[++i];
        else if (!strcmp(argv[i], "--hex") && i + 1 < argc) hex_path = argv[++i];
        else if (!strcmp(argv[i], "--cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--runs") && i + 1 < argc) runs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--label") && i + 1 < argc) label = argv[++i];
    }

    if (!dll_path || !hex_path) {
        fprintf(stderr, "usage: bench --dll PATH --hex PATH [--cycles N] [--runs N] [--label TAG]\n");
        return 1;
    }

    dll_handle h = LOAD_LIB(dll_path);
    if (!h) { fprintf(stderr, "cannot load %s\n", dll_path); return 2; }

    fn_create    f_create  = (fn_create)  GET_SYM(h, "raijin_create");
    fn_destroy   f_destroy = (fn_destroy) GET_SYM(h, "raijin_destroy");
    fn_reset     f_reset   = (fn_reset)   GET_SYM(h, "raijin_reset");
    fn_load_hex  f_load    = (fn_load_hex)GET_SYM(h, "raijin_load_hex");
    fn_step      f_step    = (fn_step)    GET_SYM(h, "raijin_step");
    fn_halted    f_halted  = (fn_halted)  GET_SYM(h, "raijin_halted");
    fn_cycles    f_cycles  = (fn_cycles)  GET_SYM(h, "raijin_cycle_count");
    fn_instret   f_instret = (fn_instret) GET_SYM(h, "raijin_instret");
    fn_classctrs    f_ctrs    = (fn_classctrs)   GET_SYM(h, "raijin_get_class_counters");
    fn_classctrs_v2 f_ctrs_v2 = (fn_classctrs_v2)GET_SYM(h, "raijin_get_class_counters_v2");

    if (!f_create || !f_step) { fprintf(stderr, "missing symbols in DLL\n"); return 3; }

    const char* tag = label ? label : dll_path;
    printf("# dll=%s hex=%s cycles=%llu runs=%d\n",
           tag, hex_path, (unsigned long long)max_cycles, runs);

    double total_mips = 0.0, best = -1.0, worst = 1e30;
    uint64_t final_cycles = 0, final_instret = 0;
    uint64_t ctrs[8]     = {0};
    uint64_t ctrs_v2[12] = {0};

    for (int r = 0; r < runs; r++) {
        RaijinSim* sim = f_create();
        if (!sim) { fprintf(stderr, "create failed\n"); return 4; }
        if (f_load(sim, hex_path) != 0) { fprintf(stderr, "load failed\n"); f_destroy(sim); return 5; }
        f_reset(sim);

        double t0 = now_s();
        uint64_t executed = f_step(sim, max_cycles);
        double t1 = now_s();

        uint64_t cyc = f_cycles ? f_cycles(sim) : executed;
        uint64_t ins = f_instret ? f_instret(sim) : executed;
        int halted = f_halted ? f_halted(sim) : 0;
        double elapsed = t1 - t0;
        double mips = (ins / elapsed) / 1e6;

        if (f_ctrs)    f_ctrs   (sim, ctrs);
        if (f_ctrs_v2) f_ctrs_v2(sim, ctrs_v2);
        final_cycles = cyc;
        final_instret = ins;

        printf("  run %d: %8.3f MIPS   cycles=%llu  instret=%llu  elapsed=%.3fs  halted=%d\n",
               r + 1, mips, (unsigned long long)cyc, (unsigned long long)ins, elapsed, halted);

        total_mips += mips;
        if (mips > best) best = mips;
        if (mips < worst) worst = mips;

        f_destroy(sim);
    }

    double mean = total_mips / runs;
    printf("RESULT label=%s mean_mips=%.3f best_mips=%.3f worst_mips=%.3f cycles=%llu instret=%llu\n",
           tag, mean, best, worst,
           (unsigned long long)final_cycles, (unsigned long long)final_instret);
    printf("  counters: mul=%llu br_total=%llu br_taken=%llu jump=%llu load=%llu store=%llu trap=%llu\n",
           (unsigned long long)ctrs[0], (unsigned long long)ctrs[1], (unsigned long long)ctrs[2],
           (unsigned long long)ctrs[3], (unsigned long long)ctrs[4], (unsigned long long)ctrs[5],
           (unsigned long long)ctrs[6]);
    if (f_ctrs_v2) {
        printf("  v2     : exc=%llu int=%llu wfi=%llu csr=%llu\n",
               (unsigned long long)ctrs_v2[7],  (unsigned long long)ctrs_v2[8],
               (unsigned long long)ctrs_v2[9],  (unsigned long long)ctrs_v2[10]);
    }

    CLOSE_LIB(h);
    return 0;
}
