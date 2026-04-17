<div align="center">

# ⚡ Kaminari-Ryu &nbsp; 雷龍

A RISC-V CPU designed from scratch in Verilog.

[![Build](https://github.com/AinsAlmeyn/Kaminari-Ryu/actions/workflows/release-raijin-cli.yml/badge.svg)](https://github.com/AinsAlmeyn/Kaminari-Ryu/actions)
[![Release](https://img.shields.io/github/v/release/AinsAlmeyn/Kaminari-Ryu?label=latest&color=orange)](https://github.com/AinsAlmeyn/Kaminari-Ryu/releases/latest)
![Platform](https://img.shields.io/badge/platform-windows%20%7C%20linux%20%7C%20macos-blue)
![ISA](https://img.shields.io/badge/ISA-RISC--V%20RV32IM-red)
![HDL](https://img.shields.io/badge/HDL-Verilog-orange)

</div>

---

## The Vision

The CPU is the most fundamental part of every computer, and yet most of us treat it as a black box. Kaminari-Ryu exists because I wanted to open that box, understand every wire and logic gate inside, and prove that understanding by building something real from nothing.

**Kaminari-Ryu (雷龍)** is the name of the school, the discipline: *Lightning School*. **Raijin** is its first model: a single-cycle CPU that finishes one instruction every clock tick. No pipeline, no caches, no branch prediction. Just the raw fundamentals in Verilog, verified against the official RISC-V compliance test suite. As a stress test and a bit of fun, it also runs DOOM.

The goal was never to build production silicon. The goal was to open up a CPU, understand every wire inside, and prove that understanding by making it run real software through nothing but a serial port. Raijin is the result of that exploration.

---

## ⚡ Raijin

| | |
|---|---|
| **ISA** | RISC-V RV32IM + Zicsr + WFI (56 instructions) |
| **Design** | Single-cycle (every instruction completes in 1 clock tick) |
| **Registers** | 32 general-purpose, 32-bit (x0 hardwired to zero) |
| **Memory** | 16 MB instruction (ROM) + 16 MB data (RAM), Harvard layout |
| **I/O** | Memory-mapped UART at `0x1000_0000`, CLINT timer at `0x0200_0000` |
| **Traps** | ECALL, EBREAK, illegal instruction, misaligned load/store, machine-software interrupt, machine-timer interrupt |
| **Privileged CSRs** | mstatus, mie, mip, mtvec, mepc, mcause, mtval, mscratch, misa, mhartid/mvendorid/marchid/mimpid, mcycle/minstret, mhpmcounter3..6 |
| **Verification** | 15 testbenches (9 unit + 5 integration + 1 compliance harness), 251 self-checks, plus the `rv32ui-p-*` + `rv32um-p-*` riscv-tests suites |
| **Simulated speed** | ~8 MIPS on modern x86 (Verilator-compiled C++) |
| **FPGA estimate** | ~30 MHz (from critical path analysis) |

---

## See It In Action

<details open>
<summary><b>Interactive TUI menu</b></summary>

```
  ⚡ RAIJIN   v0.3.0                              RV32IM · single-cycle · 32 MB

  ▸ run doom                                                          ● ready
    run matrix                                                        ● ready
    run snake                                                         ● ready
    run donut                                                         ● ready
    ──────────
    add program                                                       →
    demos                                                             →
    bench                                                             →
    ──────────
    install                                                           →
    info                                                              →

  [↑↓] navigate   [enter] launch   [esc] quit
```

</details>

<details>
<summary><b>Benchmark output (50M cycles)</b></summary>

```
$ raijin bench matrix --max-cycles 50000000

 Summary
  program           matrix.hex
  result            STOPPED
  runtime           6.4 s
  cycles            50.00M
  instructions      50.00M
  avg speed         7.8 MIPS
  memory used       16.0 KB / 32.00 MB

 Instruction mix
  multiply/divide       17.7K    0.0%
  branches             16.54M   33.1%  99% taken
  loads                 56.5K    0.1%
  stores               102.8K    0.2%
  jumps                  5.1K    0.0%
  CSR reads/writes     16.47M   32.9%
  WFI commits               0    0.0%
```

</details>

<details>
<summary><b>Install on Linux</b></summary>

```
$ ./raijin install

  ✓  installed

    →  ~/.raijin/bin/raijin
    →  ~/.raijin/bin/libraijin.so
    →  ~/.raijin/programs  (4 built-ins)
    →  ~/.raijin/sdk  (compiler support for `raijin add`)

  !  ~/.raijin/bin  is not on your user PATH yet

  one-time setup  (append to ~/.bashrc):

    echo 'export PATH="$HOME/.raijin/bin:$PATH"' >> ~/.bashrc

  open a fresh terminal afterwards, then:
    raijin
```

</details>

---

## Quick Start

### Windows

**Option A: single-file installer** (recommended)

1. Download **`raijin-setup.exe`** from the [latest release](https://github.com/AinsAlmeyn/Kaminari-Ryu/releases/latest)
2. Double-click, select **install**, press Enter
3. Open a fresh terminal
4. Type `raijin`

> [!TIP]
> The installer copies everything into `%USERPROFILE%\.raijin\` and adds the bin directory to your user PATH. You can delete `raijin-setup.exe` afterwards.

**Option B: portable zip** (no install, no PATH changes)

1. Download **`raijin-cli-windows-x64.zip`** from the [latest release](https://github.com/AinsAlmeyn/Kaminari-Ryu/releases/latest)
2. Extract to any folder
3. Open a terminal in that folder

```powershell
.\raijin.exe run doom
```

### Linux x64

1. Download **`raijin-cli-linux-x64.tar.gz`** from the [latest release](https://github.com/AinsAlmeyn/Kaminari-Ryu/releases/latest)

```bash
tar -xzf raijin-cli-linux-x64.tar.gz
./raijin run doom

# optional: install system-wide
./raijin install
# paste the one-liner it prints into your shell, open a new terminal
```

### macOS (Apple Silicon)

1. Download **`raijin-cli-macos-arm64.tar.gz`** (M1 / M2 / M3 / M4) from the [latest release](https://github.com/AinsAlmeyn/Kaminari-Ryu/releases/latest). Intel Mac users can build from source (see [host/Raijin.Cli/README.md](host/Raijin.Cli/README.md))

```bash
tar -xzf raijin-cli-macos-arm64.tar.gz

# First-run only: clear Gatekeeper quarantine on the unsigned binaries.
# Without this, macOS refuses to launch with "cannot be opened because the
# developer cannot be verified". You only need to do this once after
# extraction.
xattr -d com.apple.quarantine ./raijin ./libraijin.dylib

./raijin run doom

# optional: install system-wide
./raijin install
# paste the one-liner it prints into your shell, open a new terminal
```

> [!NOTE]
> The macOS release is **not code-signed** (no Apple Developer Program membership). The one-off `xattr -d com.apple.quarantine` is the standard workaround and is documented inside the bundle's `README.txt` too.

> [!NOTE]
> Release binaries are self-contained. On Windows, `raijin.dll` statically links its GCC runtime (no libstdc++/libgcc/libwinpthread companions needed). On Linux, `libraijin.so` uses the system glibc and libstdc++ already present on every distribution. On macOS, `libraijin.dylib` links only against the system libc++ and libSystem.

---

## CPU Architecture

### Inside raijin_core

The CPU is a single Verilog module ([`raijin_core.v`](raijin/rtl/raijin_core.v)) that wires together 12 sub-modules. Every instruction completes in exactly one clock tick. The combinational path flows left to right within one cycle. State flops (PC, register file, data memory write port, CSR file, CLINT counters, UART) commit on the rising clock edge.

```
  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌──────────┐
  │  FETCH  │───▶│ DECODE  │───▶│ EXECUTE │───▶│ MEMORY  │───▶│WRITEBACK │
  │         │    │         │    │         │    │         │    │          │
  │ pc_reg  │    │decoder  │    │ alu     │    │ dmem    │    │ wb mux   │
  │ imem    │    │control  │    │ m_unit  │    │uart_sim │    │  ↓       │
  │         │    │regfile  │    │ branch  │    │ clint   │    │ regfile  │
  │         │    │ (read)  │    │ csr_file│    │         │    │ (write)  │
  └─────────┘    └─────────┘    └─────────┘    └─────────┘    └──────────┘
       ▲                                                            │
       │                    next_pc (feedback)                      │
       └────────────────────────────────────────────────────────────┘
       priority: trap ▶ mret ▶ jalr ▶ jal/branch ▶ pc+4
```

> [!NOTE]
> This is a **single-cycle** design: there are no pipeline stages or stalls. The boxes above are logical groupings, not clock boundaries. Every instruction is fetched, decoded, executed, and written back within one clock cycle.

The program counter priority logic from [`raijin_core.v`](raijin/rtl/raijin_core.v):

```verilog
always @(*) begin
    if (trap_en)                        next_pc = mtvec_out;          // trap entry
    else if (is_mret)                   next_pc = mepc_out;           // return from trap
    else if (is_jalr_instr)             next_pc = (rs1_data + imm) & ~32'd1;
    else if (is_jal_instr || take_branch) next_pc = alu_result;       // jump or taken branch
    else                                next_pc = pc + 32'd4;         // sequential
end
```

### Inside the ALU

Ten results computed in parallel, one selected by the control unit. From [`alu.v`](raijin/rtl/alu.v):

```verilog
wire [31:0] add_result  = a + b;
wire [31:0] sub_result  = a - b;
wire [31:0] and_result  = a & b;
wire [31:0] or_result   = a | b;
wire [31:0] xor_result  = a ^ b;
wire [31:0] sll_result  = a << b[4:0];
wire [31:0] srl_result  = a >> b[4:0];
wire [31:0] sra_result  = $signed(a) >>> b[4:0];   // arithmetic shift
wire [31:0] slt_result  = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
wire [31:0] sltu_result = (a < b)                   ? 32'd1 : 32'd0;
```

### Branch comparator

Six conditions evaluated every cycle; only used when the instruction is a branch. From [`branch_unit.v`](raijin/rtl/branch_unit.v):

```verilog
case (funct3)
    BEQ  : branch_taken = (rs1 == rs2);
    BNE  : branch_taken = (rs1 != rs2);
    BLT  : branch_taken = ($signed(rs1) <  $signed(rs2));
    BGE  : branch_taken = ($signed(rs1) >= $signed(rs2));
    BLTU : branch_taken = (rs1 <  rs2);
    BGEU : branch_taken = (rs1 >= rs2);
endcase
```

### Memory map

```
  0x0000_0000 ┌──────────────────────────────┐
              │                              │
              │   Instruction Memory (ROM)   │  16 MB
              │   Data Memory (RAM)          │  overlapping address space
              │                              │
  0x00FF_FFFF └──────────────────────────────┘
                          ...
  0x0200_0000 ┌──────────────────────────────┐
              │   CLINT                      │  msip + mtimecmp + mtime
  0x0200_BFFF └──────────────────────────────┘
                          ...
  0x1000_0000 ┌──────────────────────────────┐
              │   UART Registers (MMIO)      │  4 registers, 16 bytes
  0x1000_000F └──────────────────────────────┘
```

| Address range | Region | Access | Notes |
|---|---|---|---|
| `0x0000_0000`..`0x00FF_FFFF` | Instruction memory | Read-only | 16 MB, word-addressed via `pc[31:2]`. Loaded from `.hex` at startup. |
| `0x0000_0000`..`0x00FF_FFFF` | Data memory | Read/Write | 16 MB, byte/halfword/word. Same address space as IMEM (unified load image). |
| `0x0200_0000` | CLINT `msip` | Read/Write | Bit 0 is the machine-software interrupt pending latch. Write 1 to raise, 0 to clear. |
| `0x0200_4000`..`0x0200_4007` | CLINT `mtimecmp` | Read/Write | 64-bit compare register (low then high word). Arm the timer by writing here. |
| `0x0200_BFF8`..`0x0200_BFFF` | CLINT `mtime` | Read/Write | 64-bit free-running timer. Ticks once per core clock in this sim. |
| `0x1000_0000` | UART TX | Write | Emit one byte to the host terminal. |
| `0x1000_0004` | UART status | Read | Always returns 1 (TX ready). |
| `0x1000_0008` | UART RX data | Read | Latched byte from host keyboard. |
| `0x1000_000C` | UART RX valid | Read | Bit 0 = a byte is waiting. |

### Instruction set reference

<details>
<summary><b>RV32I base integer (40 instructions)</b></summary>

**Arithmetic** (register and immediate forms)

| Instruction | What it does |
|---|---|
| `ADD / SUB` | add / subtract two registers |
| `AND / OR / XOR` | bitwise logic |
| `SLL / SRL / SRA` | shift left logical, right logical, right arithmetic |
| `SLT / SLTU` | set-less-than (signed / unsigned) |
| `ADDI / ANDI / ORI / XORI` | immediate variants of the above |
| `SLLI / SRLI / SRAI` | immediate shift variants |
| `SLTI / SLTIU` | immediate compare variants |

**Memory**

| Instruction | Width | Sign |
|---|---|---|
| `LB / LBU` | 8-bit load | signed / unsigned extend |
| `LH / LHU` | 16-bit load | signed / unsigned extend |
| `LW` | 32-bit load | full word |
| `SB / SH / SW` | 8 / 16 / 32-bit store | N/A |

**Control flow**

| Instruction | Condition or target |
|---|---|
| `BEQ / BNE` | branch if equal / not equal |
| `BLT / BGE` | branch if less-than / greater-or-equal (signed) |
| `BLTU / BGEU` | same, unsigned |
| `JAL` | jump and link (PC-relative, saves return address) |
| `JALR` | jump and link register (indirect) |

**Other**

| Instruction | What it does |
|---|---|
| `LUI` | load upper 20-bit immediate into rd |
| `AUIPC` | add upper immediate to PC |
| `FENCE` | memory ordering hint (NOP in single-core) |
| `ECALL` | environment call exception |
| `EBREAK` | breakpoint exception |

</details>

<details>
<summary><b>RV32M multiply / divide (8 instructions)</b></summary>

| Instruction | Result |
|---|---|
| `MUL` | lower 32 bits of rs1 * rs2 |
| `MULH` | upper 32 bits, signed * signed |
| `MULHSU` | upper 32 bits, signed * unsigned |
| `MULHU` | upper 32 bits, unsigned * unsigned |
| `DIV / DIVU` | signed / unsigned quotient |
| `REM / REMU` | signed / unsigned remainder |

Division by zero: DIV returns -1, DIVU returns 2^32-1. Signed overflow (`INT_MIN / -1`): returns `INT_MIN`. All single-cycle (combinational in simulation, would need iterative hardware on real silicon).

</details>

<details>
<summary><b>Zicsr + privileged (8 instructions)</b></summary>

| Instruction | Operation |
|---|---|
| `CSRRW / CSRRWI` | atomic read-write CSR (register / immediate source) |
| `CSRRS / CSRRSI` | atomic read-set bits in CSR |
| `CSRRC / CSRRCI` | atomic read-clear bits in CSR |
| `MRET` | return from machine-mode trap (restores PC and interrupt enable) |
| `WFI` | wait for interrupt. Spec-legal NOP in Raijin (a pipelined successor could gate the clock here) |

**Implemented CSRs:**

- control: `mstatus` (MIE/MPIE), `mie` (MTIE), `mip` (MTIP, read-only), `mtvec`, `mepc`, `mcause`, `mtval`, `mscratch`
- identification: `misa` (`0x40001100` = RV32 + I + M), `mvendorid`, `marchid`, `mimpid`, `mhartid` (all RAZ on this core)
- counters: `mcycle`/`mcycleh`, `minstret`/`minstreth`, `mhpmcounter3..6` (taken-branch, load, store, mul events)

**Trap causes:** illegal instruction (2), breakpoint (3), load misaligned (4), store misaligned (6), environment call from M-mode (11), machine-software interrupt (`0x8000_0003`, async), machine-timer interrupt (`0x8000_0007`, async). Interrupts win over synchronous exceptions; among interrupts, machine-software outranks machine-timer per spec.

**CLINT at `0x0200_0000`:** SiFive-compatible layout with `msip` at offset `0x0`, `mtimecmp` at `+0x4000`, and `mtime` at `+0xBFF8`. Software raises a machine-software interrupt by writing 1 to `msip`, arms the timer by writing `mtimecmp`, and clears either pending line by writing 0 to the respective register.

</details>

---

## Built-in Programs

| Program | What it does | Source |
|---------|-------------|--------|
| **doom** | The 1993 id Software classic, rendering ASCII frames via UART. Keyboard input through stdin. | [raijin/programs/doom/](raijin/programs/doom/) |
| **matrix** | Animated digital rain filling your terminal. | [matrix.c](raijin/programs/matrix.c) |
| **snake** | Arrow-keys snake game. | [snake.c](raijin/programs/snake.c) |
| **donut** | Spinning ASCII donut. | [donut.c](raijin/programs/donut.c) |

All ship pre-compiled as `.hex`. Run any of them with `raijin run <name>`.

---

## Write Your Own Programs

The release includes a minimal C runtime under `sdk/`. With a RISC-V cross-compiler and Python 3 on your system:

```c
// hello.c
#include <stdio.h>
int main() {
    printf("hello from raijin!\n");
    for (int i = 1; i <= 10; i++)
        printf("  %d squared = %d\n", i, i * i);
    return 0;
}
```

```bash
raijin add hello.c --name hello
raijin run hello
```

`raijin add` compiles with the bundled startup ([`crt.S`](tools/c-runtime/crt.S)) and linker script ([`link.ld`](tools/c-runtime/link.ld)), converts to `.hex` via [`elf2hex.py`](tools/runners/elf2hex.py), and registers the result so `raijin run` finds it by name.

---

## Building from Source

<details>
<summary><b>Windows (MSYS2 UCRT64)</b></summary>

**1. Install MSYS2** from [msys2.org](https://www.msys2.org/). Open the **UCRT64** terminal.

**2. Install packages:**

```bash
pacman -Syu
pacman -S git mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-cmake \
            mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-verilator
```

**3. Install Go** from [go.dev/dl](https://go.dev/dl/). Verify: `go version`

**4. Clone and build:**

```bash
git clone https://github.com/AinsAlmeyn/Kaminari-Ryu.git
cd Kaminari-Ryu

# build the simulator (Verilog → C++ → raijin.dll)
cmake -S sim -B build/sim -G Ninja
cmake --build build/sim --config Release

# build the CLI, installer, and portable zip
cd host/Raijin.Cli && chmod +x build.sh && ./build.sh

# run
./bin/raijin.exe run matrix
```

</details>

<details>
<summary><b>Linux (Ubuntu 24.04 / Debian)</b></summary>

**1. Install packages:**

```bash
sudo apt-get update
sudo apt-get install -y verilator cmake ninja-build gcc g++ golang-go git
```

> [!IMPORTANT]
> Verilator **5.0+** is required. Ubuntu 24.04 ships it by default. On 22.04, you may need to build Verilator from source.

**2. Clone and build:**

```bash
git clone https://github.com/AinsAlmeyn/Kaminari-Ryu.git
cd Kaminari-Ryu

# build the simulator (Verilog → C++ → libraijin.so)
cmake -S sim -B build/sim -G Ninja
cmake --build build/sim --config Release

# build the CLI and portable tarball
cd host/Raijin.Cli && chmod +x build.sh && ./build.sh

# run
./bin/raijin run matrix
```

</details>

---

## How It Works

```
  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌──────────┐
  │ VERILOG │───▶│VERILATOR│───▶│  CMAKE  │───▶│ GO CLI  │───▶│TERMINAL  │
  │         │    │         │    │         │    │         │    │          │
  │ 13 .v   │    │ compiles│    │ builds  │    │ loads   │    │ keyboard │
  │ modules │    │ to C++  │    │ shared  │    │ library │    │ + screen │
  │         │    │         │    │ library │    │ via     │    │          │
  │         │    │         │    │ .dll/so │    │ purego  │    │ UART I/O │
  └─────────┘    └─────────┘    └─────────┘    └─────────┘    └──────────┘
  raijin/rtl/                    raijin.dll     raijin         stdin/stdout
                                 libraijin.so   binary
```

1. **Verilog** describes the CPU at register-transfer level: flip-flops, muxes, adders.
2. **Verilator** compiles those `.v` files into cycle-accurate C++.
3. **CMake** builds that C++ into a native shared library with a C API (`raijin_create`, `raijin_step`, `raijin_load_hex`, ...).
4. **The Go CLI** loads the library via [purego](https://github.com/ebitengine/purego) (no cgo), drives the simulation, and bridges UART traffic between the CPU and your terminal.

---

## Project Layout

```
Kaminari-Ryu/
├── raijin/
│   ├── rtl/              13 Verilog modules + 2 definition headers
│   ├── dv/               15 testbenches (9 unit + 5 integration + 1 harness)
│   └── programs/         demos: source (.c/.s) and precompiled (.hex)
│
├── sim/
│   ├── CMakeLists.txt    Verilator build: Verilog → C++ → shared library
│   ├── raijin_api.cpp    C API (17 exported functions)
│   └── dpi_hooks.cpp     UART bridge (DPI: simulator ↔ host I/O)
│
├── host/Raijin.Cli/      Go CLI (cross-platform, no cgo)
│   ├── cmd/              subcommands: run, add, install, bench, demos, ...
│   ├── internal/         sim loader, PATH helpers, theme, runner, reports
│   └── installer/        Windows single-file installer (embedded zip)
│
├── tools/
│   ├── c-runtime/        minimal startup + linker script for user programs
│   ├── runners/          elf2hex.py, test runner, benchmark runner
│   └── riscv-tests/      official RISC-V compliance suite
│
└── .github/workflows/    CI: parallel Windows + Linux build, smoke test, release
```

---

## Acknowledgments

- [RISC-V Foundation](https://riscv.org/) for the open ISA that makes projects like this possible
- [Verilator](https://www.veripool.org/verilator/) for cycle-accurate Verilog simulation
- [purego](https://github.com/ebitengine/purego) for cgo-free shared library loading in Go
- [Charm](https://charm.sh/) for bubbletea, lipgloss, and the terminal UI stack
- [doomgeneric](https://github.com/ozkl/doomgeneric) for the portable Doom engine

---

<div align="center">

**Kaminari-Ryu** · **Raijin**

⚡

</div>
