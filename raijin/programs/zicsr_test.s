# zicsr_test.s: exercise the Zicsr extension + ECALL trap + MRET return.
#
# Layout of expected results in data memory:
#   0x100  CSRRW x3, mscratch, x2   -> x3 was the OLD mscratch (0)
#   0x104  CSRRW x4, mscratch, x0   -> x4 = 0x1234 (previous)
#   0x108  CSRRS read of mscratch after write of 0xF0                -> 0xF0
#   0x10C  CSRRS with rs1=x0 (pure read)                             -> 0xFF
#   0x110  CSRRC result                                              -> 0xFF
#   0x114  mscratch after CSRRC                                      -> 0xF0
#   0x118  CSRRWI: zimm=5, previous mscratch was 0xF0                -> 0xF0
#   0x11C  CSRRSI: zimm=2, previous mscratch was 5                   -> 5
#   0x120  CSRRCI: zimm=1, previous mscratch was 7                   -> 7
#   0x124  pre-ECALL sentinel                                        -> 100
#   0x128  post-MRET resume                                          -> 42
#   0x12C  trap counter (incremented by handler)                     -> 1
#
# Trap handler lives at address 0x200 (low 2 bits reserved by mtvec).

.org 0x000

    # ---- Install trap handler address in mtvec ----
    addi  x1, x0, 0x200
    csrrw x0, mtvec, x1              # mtvec = 0x200 (rd=x0 discards old)

    # ---- Test 1: CSRRW swaps rd and csr ----
    addi  x2, x0, 0x123              # 0x123 (12-bit safe)
    slli  x2, x2, 4                  # x2 = 0x1230
    addi  x2, x2, 4                  # x2 = 0x1234
    csrrw x3, mscratch, x2           # mscratch <- 0x1234, x3 <- old (0)
    sw    x3, 0x100(x0)

    csrrw x4, mscratch, x0           # mscratch <- 0, x4 <- 0x1234
    sw    x4, 0x104(x0)

    # ---- Test 2: CSRRS sets bits ----
    addi  x2, x0, 0x0F0              # 240
    csrrw x0, mscratch, x2           # mscratch = 0xF0
    addi  x5, x0, 0x00F              # 15
    csrrs x6, mscratch, x5           # mscratch |= 0xF -> 0xFF ; x6 = old 0xF0
    sw    x6, 0x108(x0)

    csrrs x7, mscratch, x0           # pure read (rs1=x0, no write); x7 = 0xFF
    sw    x7, 0x10C(x0)

    # ---- Test 3: CSRRC clears bits ----
    csrrc x8, mscratch, x5           # mscratch &= ~0xF -> 0xF0 ; x8 = 0xFF
    sw    x8, 0x110(x0)

    csrrs x9, mscratch, x0           # read current = 0xF0
    sw    x9, 0x114(x0)

    # ---- Test 4: Immediate variants ----
    csrrwi x10, mscratch, 5          # mscratch = 5 ; x10 = 0xF0
    sw     x10, 0x118(x0)

    csrrsi x11, mscratch, 2          # mscratch = 5|2 = 7 ; x11 = 5
    sw     x11, 0x11C(x0)

    csrrci x12, mscratch, 1          # mscratch = 7 & ~1 = 6 ; x12 = 7
    sw     x12, 0x120(x0)

    # ---- Test 5: ECALL -> handler -> MRET -> resume ----
    addi  x20, x0, 100
    sw    x20, 0x124(x0)             # pre-ecall sentinel

    ecall                            # mepc captures this PC; handler advances it

    # Execution resumes here after MRET.
    addi  x21, x0, 42
    sw    x21, 0x128(x0)

halt:
    j halt

# ===========================================================================
# Trap handler at 0x200.
#   1. Bump the trap-count at mem[0x12C].
#   2. Advance mepc by 4 so MRET returns to the instruction AFTER ecall.
#   3. MRET.
# ===========================================================================
.org 0x200
trap_handler:
    lw    x15, 0x12C(x0)
    addi  x15, x15, 1
    sw    x15, 0x12C(x0)

    csrrs x16, mepc, x0              # read mepc (pure read, rs1=x0)
    addi  x16, x16, 4                # skip the ecall instruction
    csrrw x0,  mepc, x16             # write mepc back

    mret                             # PC <- mepc, MIE <- MPIE
