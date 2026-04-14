# coverage_all.s: exercises every RV32I instruction our core implements.
#
# Layout of expected results in data memory:
#   0x100 .. 0x120  R-type arithmetic   (SUB, AND, OR, XOR, SLT, SLTU, SLL, SRL, SRA)
#   0x124 .. 0x144  I-type arithmetic   (SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI)
#   0x148 .. 0x14C  U-type              (LUI, AUIPC)
#   0x150           Branch counter      (incremented by taken branches)
#   0x154 .. 0x164  Load variants       (LB signed/unsigned, LH signed/unsigned, LW)
#   0x168 .. 0x170  Store-byte / store-halfword readback
#   0x174 .. 0x178  JAL / JALR function-call results
#
# ADDI, ADD, BNE, SW, JAL pseudo 'j' are already covered by sum_1_to_5.

.org 0x000

# ============================================================================
# Section 1: R-type arithmetic
# Prepare two operands and write each operation's result to memory.
# ============================================================================
    addi x5, x0, 100             # x5 = 100
    addi x6, x0, 30              # x6 = 30

    sub  x7, x5, x6              # 100 - 30 = 70
    sw   x7, 0x100(x0)

    addi x8,  x0, 0xF0           # 240
    addi x9,  x0, 0x33           # 51
    and  x10, x8, x9             # 0xF0 & 0x33 = 0x30
    sw   x10, 0x104(x0)

    or   x11, x8, x9             # 0xF0 | 0x33 = 0xF3
    sw   x11, 0x108(x0)

    xor  x12, x8, x9             # 0xF0 ^ 0x33 = 0xC3
    sw   x12, 0x10C(x0)

    addi x13, x0, -1             # 0xFFFFFFFF (signed -1)
    addi x14, x0, 1
    slt  x15, x13, x14           # signed: -1 < 1 -> 1
    sw   x15, 0x110(x0)

    sltu x16, x13, x14           # unsigned: 0xFFFFFFFF < 1 -> 0
    sw   x16, 0x114(x0)

    addi x17, x0, 64
    sll  x18, x17, x14           # 64 << 1 = 128
    sw   x18, 0x118(x0)

    srl  x19, x17, x14           # 64 >> 1 = 32
    sw   x19, 0x11C(x0)

    sra  x20, x13, x14           # 0xFFFFFFFF >>> 1 = 0xFFFFFFFF (sign-fill)
    sw   x20, 0x120(x0)

# ============================================================================
# Section 2: I-type arithmetic (immediate variants)
# ============================================================================
    addi x5, x0, 10

    slti  x6, x5, 20             # 10 < 20 -> 1
    sw    x6, 0x124(x0)

    slti  x7, x5, 5              # 10 < 5  -> 0
    sw    x7, 0x128(x0)

    addi  x8, x0, -1
    slti  x9, x8, 0              # -1 < 0 (signed) -> 1
    sw    x9, 0x12C(x0)

    sltiu x10, x8, 1             # 0xFFFFFFFF < 1 (unsigned) -> 0
    sw    x10, 0x130(x0)

    xori  x11, x5, 0xF           # 10 ^ 15 = 5
    sw    x11, 0x134(x0)

    ori   x12, x5, 0xF           # 10 | 15 = 15
    sw    x12, 0x138(x0)

    andi  x13, x5, 6             # 10 & 6 = 2
    sw    x13, 0x13C(x0)

    slli  x14, x5, 3             # 10 << 3 = 80
    sw    x14, 0x140(x0)

    # SRLI / SRAI: negative-valued source to see the difference
    addi  x15, x0, -16           # 0xFFFFFFF0
    srli  x16, x15, 4            # logical: 0x0FFFFFFF
    sw    x16, 0x144(x0)

# Note: 0x144 is the last I-type. Next section starts at 0x148 (U-type).

# ============================================================================
# Section 3: U-type
# ============================================================================
    lui  x5, 0x12345             # x5 = 0x12345000
    addi x5, x5, 0x678           # x5 = 0x12345678 (positive 12-bit imm, no sign issue)
    sw   x5, 0x148(x0)

    # AUIPC x6, 0 writes the current PC into x6. We need a known PC for
    # the check to be deterministic. Jump to a fixed label.
    j auipc_site

.org 0x200
auipc_site:
    auipc x6, 0                  # x6 = 0x200 (our PC)
    sw    x6, 0x14C(x0)

# ============================================================================
# Section 4: Branches (BEQ/BLT/BGE/BLTU/BGEU). Each taken branch skips an
# ADDI that would corrupt x7. Final value of x7 = number of passed branches.
# ============================================================================
    addi x7, x0, 0

    addi x8, x0, 5
    addi x9, x0, 5
    beq  x8, x9, beq_ok
    addi x7, x7, 100             # must not execute
beq_ok:
    addi x7, x7, 1

    addi x8, x0, -1
    addi x9, x0, 1
    blt  x8, x9, blt_ok          # signed: -1 < 1 -> taken
    addi x7, x7, 100
blt_ok:
    addi x7, x7, 1

    addi x8, x0, 10
    addi x9, x0, 5
    bge  x8, x9, bge_ok          # 10 >= 5 -> taken
    addi x7, x7, 100
bge_ok:
    addi x7, x7, 1

    addi x8, x0, 1
    addi x9, x0, -1
    bge  x8, x9, bge_signed_ok   # signed: 1 >= -1 -> taken
    addi x7, x7, 100
bge_signed_ok:
    addi x7, x7, 1

    addi x8, x0, 1
    addi x9, x0, -1              # as unsigned: 0xFFFFFFFF
    bltu x8, x9, bltu_ok         # 1 < 0xFFFFFFFF -> taken
    addi x7, x7, 100
bltu_ok:
    addi x7, x7, 1

    addi x8, x0, -1
    addi x9, x0, 1
    bgeu x8, x9, bgeu_ok         # 0xFFFFFFFF >= 1 -> taken
    addi x7, x7, 100
bgeu_ok:
    addi x7, x7, 1

    # A NOT-taken branch: falls through, does NOT skip the addi.
    addi x8, x0, 5
    addi x9, x0, 10
    beq  x8, x9, branch_fail_sentinel
    addi x7, x7, 1               # must execute
branch_fail_sentinel:

    sw   x7, 0x150(x0)           # expect 7

# ============================================================================
# Section 5: Loads (LB/LBU/LH/LHU/LW)
# First stash a known pattern in memory, then read it back in all forms.
# ============================================================================
    lui  x5, 0x12345
    addi x5, x5, 0x678           # x5 = 0x12345678
    sw   x5, 0x300(x0)           # put pattern at mem[0x300]

    lb   x6, 0x300(x0)           # byte at offset 0 = 0x78 -> +120
    sw   x6, 0x154(x0)

    lb   x7, 0x303(x0)           # byte at offset 3 = 0x12 -> +18
    sw   x7, 0x158(x0)

    # Write a byte with the sign bit set, verify sign vs zero extension
    addi x8, x0, 0x80            # 128
    sb   x8, 0x310(x0)
    lb   x9,  0x310(x0)          # signed -> 0xFFFFFF80
    sw   x9,  0x15C(x0)
    lbu  x10, 0x310(x0)          # unsigned -> 0x00000080
    sw   x10, 0x160(x0)

    # Halfwords with sign bit set
    lui  x11, 0x80000            # 0x80000000
    sw   x11, 0x320(x0)
    lh   x12, 0x322(x0)          # upper half = 0x8000, signed -> 0xFFFF8000
    sw   x12, 0x164(x0)
    lhu  x13, 0x322(x0)          # unsigned -> 0x00008000
    sw   x13, 0x168(x0)

# ============================================================================
# Section 6: Stores (SB/SH)
# Write sub-word, then read full word to verify it overlays correctly.
# Start from a clean word.
# ============================================================================
    sw   x0, 0x330(x0)           # zero the word
    addi x5, x0, 0xAB
    sb   x5, 0x332(x0)           # byte 2 = 0xAB, rest zero -> 0x00AB0000
    lw   x6, 0x330(x0)
    sw   x6, 0x16C(x0)

    sw   x0, 0x340(x0)
    addi x7, x0, 0x7FF           # 2047, fits 12-bit
    sh   x7, 0x342(x0)           # upper halfword = 0x07FF -> word = 0x07FF0000
    lw   x8, 0x340(x0)
    sw   x8, 0x170(x0)

# ============================================================================
# Section 7: JAL / JALR (function call pattern)
# ============================================================================
    addi x10, x0, 5              # a0 = 5
    jal  ra, add_one_f           # expected to return a0+1 = 6
    sw   x10, 0x174(x0)

    addi x10, x0, 20
    jal  ra, add_one_f           # a0 = 21
    sw   x10, 0x178(x0)

# ============================================================================
# Section 8: SRAI sanity check (unit-tested but not yet seen end-to-end)
# ============================================================================
    addi x11, x0, -16            # 0xFFFFFFF0
    srai x12, x11, 4             # arithmetic: 0xFFFFFFFF (sign-fill)
    sw   x12, 0x17C(x0)

halt:
    j halt

# ---------------------------------------------------------------------------
# add_one_f :  a0 = a0 + 1 ; return to ra
# ---------------------------------------------------------------------------
add_one_f:
    addi x10, x10, 1
    jalr x0, 0(ra)               # ret
