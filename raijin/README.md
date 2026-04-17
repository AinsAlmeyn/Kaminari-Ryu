# raijin

<div align="center">

**The hardware.** Verilog source for the single-cycle RV32IM + Zicsr CPU
with machine-timer interrupts, its per-module testbenches, and the demo
programs compiled to `.hex`.

</div>

Everything here is synthesizable RTL. A Verilator-based simulator in [`sim/`](../sim/) compiles these files into a native shared library. A Go CLI in [`host/Raijin.Cli/`](../host/Raijin.Cli/) drives that library at runtime.

---

## Layout

```
raijin/
├── rtl/                 13 Verilog modules + 2 definition headers
├── dv/                  15 testbenches (9 unit + 5 integration + 1 harness)
└── programs/            demo programs (source + precompiled .hex)
```

---

## rtl

The Verilog design. [`raijin_core.v`](rtl/raijin_core.v) is the top module. It instantiates 12 sub-modules and wires them together into a single-cycle datapath.

### Modules at a glance

| Module | File | Kind | What it does |
|--------|------|------|--------------|
| **pc_reg** | [`pc_reg.v`](rtl/pc_reg.v) | 🔘 state | 32-bit program counter. Resets to `0x0`, updates on every clock edge from `next_pc`. |
| **imem** | [`imem.v`](rtl/imem.v) | 🔵 memory | Instruction memory. 16 MB, word-addressed, loaded from `.hex` at startup. |
| **decoder** | [`decoder.v`](rtl/decoder.v) | 🟣 control | Splits a 32-bit instruction into opcode, rs1, rs2, rd, funct3/7, and sign-extends immediates for every RISC-V format (R/I/S/B/U/J). |
| **control** | [`control.v`](rtl/control.v) | 🟣 control | Maps opcode + funct3/7 into 13 control signals: ALU op, mux selects, write enables, branch/jump flags, CSR access. |
| **regfile** | [`regfile.v`](rtl/regfile.v) | 🟢 register | 32 × 32-bit register file. Two async read ports, one sync write port. x0 is hardwired to zero. |
| **alu** | [`alu.v`](rtl/alu.v) | 🟠 compute | Ten operations (ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU) computed in parallel; the control unit picks one. |
| **m_unit** | [`m_unit.v`](rtl/m_unit.v) | 🟠 compute | RV32M extension: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU. Combinational in simulation. |
| **branch_unit** | [`branch_unit.v`](rtl/branch_unit.v) | 🟠 compute | Six branch conditions: BEQ, BNE, BLT, BGE, BLTU, BGEU. Always computes; the control unit decides when to use it. |
| **dmem** | [`dmem.v`](rtl/dmem.v) | 🔵 memory | Data memory. 16 MB, byte/halfword/word access with alignment checks. |
| **uart_sim** | [`uart_sim.v`](rtl/uart_sim.v) | 🔷 I/O | Memory-mapped UART at `0x1000_0000`. TX writes go out to host stdout, RX reads pull from host stdin via DPI. |
| **clint** | [`clint.v`](rtl/clint.v) | 🔷 I/O | SiFive-compatible timer + software-interrupt peripheral at `0x0200_0000`. Owns `msip`, `mtime`, `mtimecmp`; drives `mip.MSIP` and `mip.MTIP`. |
| **csr_file** | [`csr_file.v`](rtl/csr_file.v) | 🟢 register | M-mode CSRs (mstatus, mie, mip, mtvec, mepc, mcause, mtval, mscratch, misa, mvendorid/marchid/mimpid/mhartid, mcycle/minstret, mhpmcounter3..6) plus trap entry, MRET and interrupt arbitration. |

### Definition headers

`.vh` files that every module includes. They hold the numeric constants the design agrees on so the encoding is specified in exactly one place.

[`riscv_defs.vh`](rtl/riscv_defs.vh) holds RISC-V spec constants: opcodes, funct3/7 codes, CSR addresses, exception cause codes.

[`raijin_defs.vh`](rtl/raijin_defs.vh) holds internal control encodings: ALU op numbers, ALU source mux selects, writeback mux selects, CSR op codes.

### A taste of the RTL

The ALU is pure combinational logic: ten candidate results computed in parallel, one picked by the `op` selector. From [`alu.v`](rtl/alu.v):

```verilog
wire [31:0] add_result  = a + b;
wire [31:0] sub_result  = a - b;
wire [31:0] and_result  = a & b;
wire [31:0] or_result   = a | b;
wire [31:0] xor_result  = a ^ b;
wire [31:0] sll_result  = a << b[4:0];
wire [31:0] srl_result  = a >> b[4:0];
wire [31:0] sra_result  = $signed(a) >>> b[4:0];
wire [31:0] slt_result  = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
wire [31:0] sltu_result = (a < b)                   ? 32'd1 : 32'd0;
```

---

## dv

One testbench per module, plus two integration-level ones.

```
┌─────────────────────────────────┬──────────────────────────────────────────┐
│  unit testbenches               │   integration testbenches                │
├─────────────────────────────────┼──────────────────────────────────────────┤
│  alu_tb          regfile_tb     │   raijin_core_tb                          │
│  branch_unit_tb  imem_tb        │   (runs sum_1_to_5.hex end-to-end)       │
│  pc_reg_tb       dmem_tb        │                                           │
│  decoder_tb      control_tb     │   coverage_tb                             │
│  csr_file_tb     zicsr_tb       │   (runs coverage_all.hex across all opc) │
│                                 │                                           │
│                                 │   riscv_test_tb                           │
│                                 │   (generic harness for the RISC-V        │
│                                 │   compliance suite in ../../tools/       │
│                                 │   riscv-tests/)                          │
└─────────────────────────────────┴──────────────────────────────────────────┘
```

### What each one checks

| Testbench | Scope |
|-----------|-------|
| `alu_tb.v`, `branch_unit_tb.v`, `pc_reg_tb.v`, `regfile_tb.v`, `imem_tb.v`, `dmem_tb.v`, `decoder_tb.v`, `control_tb.v`, `csr_file_tb.v` | One module in isolation. Feed inputs, check outputs. |
| `zicsr_tb.v` | Zicsr instructions end to end: CSRRW/S/C plus the "no-write when rs1=0" spec rule. |
| `coverage_tb.v` | Runs `programs/coverage_all.hex` which exercises every RV32I + M instruction at least once. |
| `raijin_core_tb.v` | Integration: runs `programs/sum_1_to_5.hex` and checks final register/memory state. |
| `timer_int_tb.v` | Integration: runs `programs/timer_int_test.hex` which programs mtimecmp, enables MTIE, and verifies that 10 machine-timer interrupts fire end to end. |
| `soft_int_tb.v` | Integration: runs `programs/soft_int_test.hex` which raises MSIP via the CLINT and verifies the software-interrupt path (5 dispatches, no exceptions). |
| `riscv_test_tb.v` | Generic harness for the official RISC-V compliance suite. Polls the `tohost` memory location; 1 = PASS, any other non-zero = FAIL. |

> [!TIP]
> Every testbench in this project follows the same `tohost` convention popularized by riscv-tests: writing 1 to a fixed DMEM location signals PASS, any other non-zero value encodes a FAIL code. The testbench polls that word and exits with the matching shell exit code.

Run them with iverilog or verilator. See the root [README](../README.md) for build instructions.

---

## programs

Each demo ships both as source (C or assembly) and as a pre-compiled `.hex` that the CLI can load directly.

| Program | Source | Description |
|---------|--------|-------------|
| `matrix` | [`matrix.c`](programs/matrix.c) | Green digital rain effect. Uses rand-based column generators. |
| `snake` | [`snake.c`](programs/snake.c) | Snake game with arrow-key input via UART RX. |
| `donut` | [`donut.c`](programs/donut.c) | Spinning ASCII donut. Heavy trig plus float emulation, good stress test. |
| `doom` | [`doom/`](programs/doom/) | 1993 id Software classic, ported via doomgeneric. See [`programs/doom/README.md`](programs/doom/README.md) for the port details. |
| `timer_int_test` | [`timer_int_test.py`](programs/timer_int_test.py) | Hand-assembled demo that sets mtimecmp, enables MTIE, and counts 10 machine-timer traps. The generator script is self-contained (no cross-compiler needed) and emits the `.hex` directly. |
| `soft_int_test` | [`soft_int_test.py`](programs/soft_int_test.py) | Hand-assembled demo that raises MSIP via the CLINT register, handles the trap, and re-raises until 5 software interrupts have fired. |

### The hex format

The simulator reads `.hex` files in `$readmemh` format: one 32-bit word per line, optional `@addr` directives to set the load address, `//` comments allowed anywhere.

```
@0         # start loading at address 0
00000093   # addi x1, x0, 0
00100113   # addi x2, x0, 1
00208133   # add  x2, x1, x2
...
```

The non-demo `.hex` files (`sum_1_to_5`, `coverage_all`, `zicsr_test`, `timer_int_test`, `soft_int_test`) exist only for the testbenches in `dv/`.

---

## How an instruction gets executed

Every instruction in this CPU takes exactly one clock cycle, from fetch to writeback. There is no pipeline.

```
  posedge clk                                                          posedge clk
       │                                                                     │
       │  pc ─▶ imem ─▶ decoder ─▶ regfile.read ─▶ alu/m_unit/branch ─▶ wb  │
       │                  │                │             │             │     │
       │                  ▼                │             ▼             │     │
       │              control              │          dmem/uart        │     │
       │                                   └─────────────┘             │     │
       │                                                               │     │
       │                       all combinational                       │     │
       │                                                               │     │
       │◀────────── regfile.write happens on NEXT edge ────────────────│     │
       │                                                                     │
```

During that one cycle, every module evaluates combinationally. Two things are latched on the next clock edge: the program counter (picks up `next_pc`) and the register file (commits `wb_data` if `reg_write_en` is set and the trap path isn't gating it).

> [!NOTE]
> Single-cycle is the simplest design that actually works. It trades clock frequency for design clarity: the critical path runs through the entire datapath in one tick, which caps Fmax around 30 MHz on typical FPGAs. A pipeline would shorten that path and lift the ceiling, but at the cost of hazard detection, forwarding, and several more wires. For learning and simulation throughput, single-cycle is the right call.

The detailed signal-level wiring is in [`raijin_core.v`](rtl/raijin_core.v), which is heavily commented. The project root [README](../README.md) has the module hierarchy overview.

---

## Revisions

Raijin is developed as a single living codebase; historical snapshots live in git tags, not in parallel folders.

- **`raijin-v1-baseline`** (historic): original single-cycle RV32IM + Zicsr core. No external interrupts, no CLINT, no WFI. 12 RTL modules.
- **`raijin-v1.0`** (current `main`): the polished release. CLINT with `msip` + `mtimecmp` + `mtime`, full `mie`/`mip`/`misa`/identification CSRs, `mhpmcounter3..6`, machine-software and machine-timer interrupt paths, WFI, host-side counter v2 API (exception vs interrupt split, WFI commits, CSR access count), full 251-check testbench suite. 13 RTL modules.

To A/B benchmark two revisions side by side:

```bash
git worktree add ../raijin-old raijin-v1-baseline
cmake -S ../raijin-old/sim -B build/sim-old -G Ninja && cmake --build build/sim-old
cmake -S sim             -B build/sim-new -G Ninja && cmake --build build/sim-new
# two raijin.dll artifacts land in build/sim-{old,new}/bin/
```

The bench harness in [`../tools/bench-harness/`](../tools/bench-harness/) takes a `--dll` path so the same hex file can be timed against either build.
