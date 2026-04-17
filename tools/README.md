# tools

<div align="center">

**The support tooling.** A minimal C runtime, Python build and test utilities,\
and the RISC-V compliance test suite.

</div>

Everything a host needs outside the hardware itself: the runtime so you can write programs for Raijin, the glue that turns those programs into the `.hex` format the simulator loads, and the third-party tests used to prove the CPU is spec-compliant.

---

## How it fits together

```
   your program.c
         │
         ▼
  ┌─────────────────┐    riscv-none-elf-gcc
  │   c-runtime/    │───▶  + link.ld     ───▶  program.elf
  │  crt.S, link.ld │
  └─────────────────┘
                                                │
                                                ▼
                                    ┌─────────────────────┐
                                    │  runners/elf2hex.py │
                                    └──────────┬──────────┘
                                               │
                                               ▼
                                         program.hex
                                               │
                                               ▼
                                    ┌─────────────────────┐
                                    │   raijin simulator  │
                                    └─────────────────────┘
```

---

## Layout

```
tools/
├── c-runtime/         minimal startup + linker script for user C programs
├── runners/           Python utilities: elf2hex, program builder, test runners
├── riscv-tests/       upstream RISC-V compliance test suite
├── isa-runtime/       linker script variant for raw ISA tests
└── external/          third-party sources vendored into the tree (doomgeneric)
```

---

## c-runtime

The minimal C environment. Three pieces turn a raw RISC-V binary into something `main()` can live in.

| File | Role |
|------|------|
| [`crt.S`](c-runtime/crt.S) | Startup code. Sets up the stack pointer at the top of DMEM, zeros the `.bss` section, calls `main()`, and passes the return value back through the `tohost` memory location using the riscv-tests convention (`tohost = (ret << 1) \| 1`). |
| [`link.ld`](c-runtime/link.ld) | Linker script. Places `.text` at address 0, sets aside space for `.rodata`, `.data`, and `.bss`, and defines `_stack_top` at the end of DMEM. |
| [`shims/`](c-runtime/shims/) | Tiny freestanding implementations of common libc functions (printf, memcpy, and similar) that the simulator needs. |

A program compiled with this runtime is self-contained. No OS, no newlib, no syscalls beyond what the runtime itself defines.

> [!NOTE]
> The `tohost` convention is a riscv-tests legacy. When a test program writes `1` to the fixed memory location the testbench polls, the bench exits with PASS. Any other non-zero value is a FAIL code encoded as `(ret_code << 1) | 1`. Raijin's `crt.S` uses this same contract at `main()` return, so every program halts cleanly with a status byte the testbench can read.

---

## runners

Python 3 scripts that glue the RISC-V toolchain to the simulator.

| Script | What it does |
|--------|--------------|
| [`elf2hex.py`](runners/elf2hex.py) | Reads an ELF produced by `riscv64-unknown-elf-gcc` and emits the `$readmemh`-format `.hex` file the simulator expects. Handles multiple segments and address offsets. |
| [`run_c_program.py`](runners/run_c_program.py) | Compile, convert, and run in one shot. Takes a `.c` source file, invokes GCC, calls `elf2hex.py`, loads the result into the simulator, returns whatever UART output the program produced. |
| [`build_builtin_programs.py`](runners/build_builtin_programs.py) | Rebuilds all four demo programs (matrix, snake, donut, doom) from source. Used to refresh the `.hex` files checked into [`raijin/programs/`](../raijin/programs/) when the C sources change. |
| [`run_riscv_tests.py`](runners/run_riscv_tests.py) | Runs the official RV32I, RV32M, and Zicsr compliance test suites. Each test is a tiny program that writes 1 to `tohost` on PASS or some other non-zero value on FAIL. Reports per-test results and a final summary. |
| [`run_benchmarks.py`](runners/run_benchmarks.py) | Runs a fixed benchmark set and reports cycles, instructions, and MIPS. Used to measure the impact of RTL or Verilator flag changes. |
| [`activate-toolchain.sh`](runners/activate-toolchain.sh) | Sources `riscv-none-elf-gcc` into PATH on Linux or macOS if you installed it outside system directories. |

These scripts need Python 3 and `riscv64-unknown-elf-gcc` (or `riscv-none-elf-gcc`) on PATH.

> [!TIP]
> The CLI's `raijin add` subcommand is a user-friendly wrapper around `run_c_program.py` for the common case. You rarely need to call the Python scripts directly unless you are changing the build pipeline.

### Example: running the compliance suite

```
$ python tools/runners/run_riscv_tests.py --all

  rv32ui-p-add       PASS   (cycles: 382)
  rv32ui-p-addi      PASS   (cycles: 297)
  rv32ui-p-and       PASS   (cycles: 263)
  rv32ui-p-andi      PASS   (cycles: 240)
  ...
  rv32um-p-mul       PASS   (cycles: 251)
  rv32um-p-mulh      PASS   (cycles: 277)
  rv32um-p-div       PASS   (cycles: 1089)
  ...

  summary: all tests passed
```

---

## riscv-tests

Upstream clone of [riscv-software-src/riscv-tests](https://github.com/riscv-software-src/riscv-tests). The canonical test suite for RISC-V implementations.

| Subset | Covers |
|--------|--------|
| `isa/rv32ui-*` | All 40 RV32I base integer instructions |
| `isa/rv32um-*` | All 8 RV32M multiply and divide instructions |

Each test compiles down to a small program that exercises one or more instructions across many edge cases (signed and unsigned boundaries, division by zero, misaligned addresses, and so on) and writes 1 to `tohost` if every check passed.

Raijin passes the full `rv32ui-p-*` and `rv32um-p-*` subsets. Zicsr and trap semantics are proven by the in-tree `zicsr_tb`, `timer_int_tb`, and `soft_int_tb` testbenches under [`raijin/dv/`](../raijin/dv/) rather than by the upstream `rv32mi-*` suite (which needs privileged-mode harness support we did not port).

---

## isa-runtime

Bare-metal linker for compliance tests. [`isa-runtime/link.ld`](isa-runtime/link.ld) is a linker script variant used specifically by the riscv-tests harness. The upstream tests assume a specific memory layout (entry at `0x80000000`, `tohost` and `fromhost` at fixed offsets) that differs from what the regular C runtime expects. This linker script produces the layout the compliance harness wants without touching the normal C runtime.

---

## external

Vendored third-party sources. [`external/doomgeneric/`](external/doomgeneric/) is the portable Doom engine, the platform-independent core of Doom originally by [ozkl](https://github.com/ozkl/doomgeneric). The port-specific glue (video via UART ASCII, input via UART RX, timing via cycle counter) lives in [`raijin/programs/doom/`](../raijin/programs/doom/).

No other third-party code is vendored. RISC-V tests live in their own directory for clarity, not under `external/`, because they are a structured test suite rather than a library.
