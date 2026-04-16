# sim

<div align="center">

**The simulator.** Turns the Verilog RTL in [`raijin/rtl/`](../raijin/rtl/)\
into a native shared library any host program can load and drive.

</div>

This is the bridge between the hardware description (Verilog) and the software that talks to it (the Go CLI in [`host/Raijin.Cli/`](../host/Raijin.Cli/)).

---

## The pipeline

```
  ┌──────────────┐    ┌─────────────┐    ┌──────────────┐    ┌──────────────┐
  │ Verilog RTL  │───▶│  Verilator  │───▶│    CMake     │───▶│  raijin.dll  │
  │              │    │             │    │              │    │ libraijin.so │
  │ 12 .v + 2.vh │    │  → C++      │    │  → LTO build │    │              │
  │              │    │  cycle-     │    │  → strip     │    │  16 exported │
  │              │    │  accurate   │    │  → link      │    │  C functions │
  └──────────────┘    └─────────────┘    └──────────────┘    └──────────────┘
```

The output is a self-contained shared library that exports a C API (`raijin_api.h`). Any language with FFI can call it: C, C++, Go (via purego), Python (via ctypes), Rust (via libloading), C# (via P/Invoke), and so on.

> [!NOTE]
> On Windows the released DLL has zero external MinGW runtime dependencies. `libstdc++`, `libgcc`, and `winpthread` are all statically linked. The only imports at runtime are `KERNEL32.dll` and the `api-ms-win-crt-*` set shipped with every Windows 10 and 11 install.

---

## Files

| File | Role |
|------|------|
| [`CMakeLists.txt`](CMakeLists.txt) | Build recipe. Invokes Verilator on the RTL, compiles the generated C++ with LTO and `-march=x86-64-v3`, statically links libstdc++/libgcc/winpthread on Windows so the DLL has zero external MinGW dependencies. |
| [`raijin_api.h`](raijin_api.h) | Public C header. 16 functions across four groups: lifecycle, load/step, introspection, UART. |
| [`raijin_api.cpp`](raijin_api.cpp) | Implementation. Wraps the Verilated model behind an opaque `RaijinSim*` handle, parses `.hex` files into memory, drives the cycle loop, extracts register and CSR state. |
| [`dpi_hooks.cpp`](dpi_hooks.cpp) | DPI-C bridge for UART: host side of the TX ring buffer and the RX queue. When the simulated CPU writes to `0x1000_0000`, it calls into here, and the byte ends up in a host-side ring that `raijin_uart_read` drains. |

---

## The C API

All 16 exported functions from [`raijin_api.h`](raijin_api.h), grouped by purpose. Every function is safe to call with a null `RaijinSim*` (returns zero or does nothing), so host languages don't need to worry about finalizer races.

### Lifecycle

| Function | Purpose |
|----------|---------|
| `raijin_create()` | Allocate a new simulator instance. Returns an opaque handle. |
| `raijin_destroy(sim)` | Release all resources for a simulator. |
| `raijin_reset(sim)` | Hard reset: PC=0, registers cleared, memory preserved. |

### Load and execute

| Function | Purpose |
|----------|---------|
| `raijin_load_hex(sim, path)` | Load a `.hex` file into IMEM+DMEM. Returns 0 on success. |
| `raijin_step(sim, max_cycles)` | Run up to `max_cycles` cycles, or until `tohost` becomes non-zero. Returns cycles actually executed. |
| `raijin_halted(sim)` | 1 if the program wrote a non-zero `tohost`. |
| `raijin_tohost(sim)` | Current `tohost` value (halt code). |

### Introspection

| Function | Purpose |
|----------|---------|
| `raijin_get_pc(sim)` | Current program counter. |
| `raijin_get_regs(sim, out)` | Fill `out[32]` with x0..x31. |
| `raijin_get_csrs(sim, out)` | Fill `out[8]` with mstatus, mepc, mtvec, mcause, mtval, mscratch, mie, mip. |
| `raijin_read_dmem(sim, addr, buf, len)` | Copy `len` bytes from data memory starting at `addr`. |
| `raijin_cycle_count(sim)` | Total cycles executed since reset. |
| `raijin_instret(sim)` | Retired instruction count (equals cycle count for single-cycle). |
| `raijin_get_class_counters(sim, out)` | Fill `out[7]` with per-class counters: mul, branch_total, branch_taken, jump, load, store, trap. |

### UART

| Function | Purpose |
|----------|---------|
| `raijin_uart_read(sim, buf, max)` | Drain up to `max` bytes from the simulator's TX ring into `buf`. Non-blocking; returns bytes actually read. |
| `raijin_uart_write(sim, c)` | Push one byte onto the simulator's RX queue (keyboard input). |

### Using it from C

A minimal program that loads a hex file, runs it for a million cycles, and prints the final PC.

```c
#include <stdio.h>
#include "raijin_api.h"

int main(int argc, char** argv) {
    RaijinSim* sim = raijin_create();
    if (raijin_load_hex(sim, argv[1]) != 0) {
        fprintf(stderr, "cannot load %s\n", argv[1]);
        return 1;
    }

    uint64_t ran = raijin_step(sim, 1000000);
    printf("ran %llu cycles, final PC = 0x%08x\n",
           (unsigned long long)ran, raijin_get_pc(sim));

    raijin_destroy(sim);
    return 0;
}
```

Link against `-lraijin` (Linux) or `raijin.lib` (Windows import library, generated next to the DLL).

---

## Building standalone

From the repository root:

```bash
cmake -S sim -B build/sim -G Ninja
cmake --build build/sim --config Release
```

Output appears in `build/sim/bin/`:

```
$ ls build/sim/bin/
raijin.dll       # Windows: the shared library
raijin.lib       # Windows: import library for link-time binding
libraijin.so     # Linux: the shared library
```

The only runtime dependency on Windows is the Universal C Runtime shipped with Windows 10 and 11. On Linux, the default glibc and libstdc++ that ship with any modern distribution.

### Checking the Windows DLL is clean

If you want to confirm the static linkage worked, use `objdump` to list the DLL's dynamic imports. You should only see Windows system libraries.

```
$ objdump -p build/sim/bin/raijin.dll | grep "DLL Name"
    DLL Name: KERNEL32.dll
    DLL Name: api-ms-win-crt-convert-l1-1-0.dll
    DLL Name: api-ms-win-crt-environment-l1-1-0.dll
    DLL Name: api-ms-win-crt-filesystem-l1-1-0.dll
    DLL Name: api-ms-win-crt-heap-l1-1-0.dll
    DLL Name: api-ms-win-crt-locale-l1-1-0.dll
    DLL Name: api-ms-win-crt-math-l1-1-0.dll
    DLL Name: api-ms-win-crt-runtime-l1-1-0.dll
    DLL Name: api-ms-win-crt-stdio-l1-1-0.dll
    DLL Name: api-ms-win-crt-string-l1-1-0.dll
    DLL Name: api-ms-win-crt-time-l1-1-0.dll
```

No `libstdc++-6.dll`, no `libgcc_s_seh-1.dll`, no `libwinpthread-1.dll`. The DLL is self-contained.

---

## Verilator tuning notes

The simulator is optimized for speed because Doom on Raijin is strictly CPU-time bound. Flags applied in [`CMakeLists.txt`](CMakeLists.txt):

- `-O3 -flto=auto -march=x86-64-v3` for aggressive optimization on modern x86 (BMI2, AVX2).
- `-fno-stack-protector -fomit-frame-pointer -fvisibility=hidden` for tight hot-path codegen.
- `--x-assign fast --x-initial fast --no-timing --noassert` are Verilator flags that skip unused features.
- `-Wl,--gc-sections -Wl,--as-needed` strip dead code and drop unused dynamic dependencies.

The 16 MB instruction and 16 MB data memories are set via `-GIMEM_DEPTH_WORDS=4194304 -GDMEM_DEPTH_WORDS=4194304` at Verilator-time, which is what lets Doom (about 37 MB of code plus the WAD file) fit.

> [!TIP]
> On Windows, a small `nanosleep64` stub in [`raijin_api.cpp`](raijin_api.cpp) short-circuits libstdc++'s sleep glue so the last dynamic symbol that would otherwise pull in `libwinpthread-1.dll` goes away. That is what makes the fully self-contained DLL possible. The stub just wraps `Sleep()` in the shape libstdc++ expects.
