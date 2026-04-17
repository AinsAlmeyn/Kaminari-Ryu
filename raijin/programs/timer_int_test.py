"""
Build raijin/programs/timer_int_test.hex.

Demonstrates Raijin v2's machine-timer interrupt path:
  - Programs CLINT mtimecmp to fire every `DELTA` cycles.
  - Enables mie.MTIE and mstatus.MIE.
  - Main loop counts iterations and busy-waits for the handler to set the
    'done' flag after N interrupts have fired.
  - Handler increments an interrupt counter, schedules the next tick, and
    after N ticks writes 1 to tohost (mem[0x1000]) to stop the simulator.

Expected outcome when loaded into Raijin v2:
  mem[0x1000] == 1            (tohost: success)
  mem[0x1004] == N            (interrupt count)
  mem[0x1008] >= 1            (main-loop iterations - at least one)

If this program is loaded into Raijin v1 (no interrupts), it will hang
in the main busy-wait loop because no interrupts will fire. The harness
will time out rather than halt - that is the expected divergence.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "runners"))

from asm_mini import (
    ADD, ADDI, AND, BGE, BNE, CSRRS, CSRRW, JAL, LI, LUI, LW, MRET,
    SB, SRLI, SW, WFI, emit_hex,
)

# CSR addresses
CSR_MSTATUS  = 0x300
CSR_MIE      = 0x304
CSR_MTVEC    = 0x305
CSR_MEPC     = 0x341
CSR_MCAUSE   = 0x342

# MMIO addresses
CLINT_MTIMECMP_LO = 0x02004000
CLINT_MTIMECMP_HI = 0x02004004
CLINT_MTIME_LO    = 0x0200BFF8
CLINT_MTIME_HI    = 0x0200BFFC
UART_TX           = 0x10000000

# Data layout (word-aligned)
DATA_TOHOST       = 0x1000
DATA_INTR_COUNT   = 0x1004
DATA_LOOP_COUNT   = 0x1008

# How many timer ticks we want to take before halting.
TARGET_TICKS = 10
# Delta in cycles between consecutive timer ticks. Chosen small so the
# whole test runs inside the harness' short cycle budget.
TICK_DELTA   = 200

# ------------------------------------------------------------------
# Register assignments (stable across main vs handler to avoid save/restore)
# ------------------------------------------------------------------
# Main:    x5 data_base (0x1000)
#          x6 loop counter
#          x7 temp (done flag)
# Handler: x15 data_base
#          x16 intr count
#          x17 target (TARGET_TICKS)
#          x18 mtimecmp base
#          x19 temp mtimecmp
#          x20 temp
#          x21 uart addr
#          x22 temp

words = []

# ======================================================
# MAIN (starts at address 0 == word 0)
# ======================================================

# 1. Install trap-handler address (0x400) into mtvec
words.extend(LI(1, 0x400))                # x1 = 0x400
words.append(CSRRW(0, CSR_MTVEC, 1))      # mtvec = 0x400

# 2. Program mtimecmp = TICK_DELTA (mtime starts at 0 after reset)
words.extend(LI(2, TICK_DELTA))           # x2 = TICK_DELTA
words.extend(LI(3, CLINT_MTIMECMP_LO))    # x3 = 0x0200_4000
words.append(SW(2, 3, 0))                 # mtimecmp_lo = TICK_DELTA
words.append(SW(0, 3, 4))                 # mtimecmp_hi = 0

# 3. Enable machine-timer interrupt (mie.MTIE = bit 7 -> 0x80)
words.extend(LI(4, 0x80))                 # x4 = 0x80
words.append(CSRRW(0, CSR_MIE, 4))        # mie = 0x80

# 4. Enable global interrupts (mstatus.MIE = bit 3 -> 0x8)
words.extend(LI(8, 0x8))                  # x8 = 0x8
words.append(CSRRS(0, CSR_MSTATUS, 8))    # mstatus |= 0x8

# 5. Set up main-loop working registers
words.extend(LI(5, DATA_TOHOST))          # x5 = data base = 0x1000
words.append(ADDI(6, 0, 0))               # x6 = 0 (loop counter)

# 6. Main busy-wait loop: increment loop counter, check done flag.
#    addr of done flag = 0 (x5 + 0) ; we'll read DATA_TOHOST here.
loop_start = len(words)  # instruction index of the loop head
words.append(ADDI(6, 6, 1))               # x6++
words.append(SW(6, 5, DATA_LOOP_COUNT - DATA_TOHOST))  # mem[0x1008] = x6
words.append(LW(7, 5, 0))                 # x7 = mem[DATA_TOHOST]
# branch to halt if x7 != 0
halt_placeholder = len(words)
words.append(0)  # placeholder for BNE x7, x0, halt_target
# jump back to loop_start
back_offset = (loop_start - len(words)) * 4
words.append(JAL(0, back_offset))

# halt: endless loop (tohost writer was the handler)
halt_target = len(words)
words.append(JAL(0, 0))  # spin here (handler already wrote tohost=1)

# Now patch the BNE to jump to halt_target
offset = (halt_target - halt_placeholder) * 4
words[halt_placeholder] = BNE(7, 0, offset)

# ======================================================
# TRAP HANDLER (must land at address 0x400 = word 0x100)
# ======================================================
HANDLER_WORD_INDEX = 0x400 // 4
while len(words) < HANDLER_WORD_INDEX:
    words.append(0)  # pad with zeros (treated as illegal, but unreachable)

# Handler uses x15..x22 exclusively; main uses x1..x8.
words.extend(LI(15, DATA_TOHOST))               # x15 = 0x1000
words.append(LW(16, 15, DATA_INTR_COUNT - DATA_TOHOST))  # x16 = intr count
words.append(ADDI(16, 16, 1))                   # ++count
words.append(SW(16, 15, DATA_INTR_COUNT - DATA_TOHOST))  # store

# Schedule next tick: mtimecmp += TICK_DELTA
words.extend(LI(18, CLINT_MTIMECMP_LO))         # x18 = mtimecmp base
words.append(LW(19, 18, 0))                     # x19 = current mtimecmp_lo
words.append(ADDI(19, 19, TICK_DELTA))          # next deadline
words.append(SW(19, 18, 0))                     # write back (clears MTIP)

# If count < TARGET_TICKS, return; else set done flag and halt
words.extend(LI(17, TARGET_TICKS))              # x17 = target
handler_branch_placeholder = len(words)
words.append(0)  # BGE x16, x17, handler_done
words.append(MRET())                            # return to main

handler_done = len(words)
# Write 1 to tohost (0x1000) to halt the simulator
words.extend(LI(20, 1))                         # x20 = 1
words.append(SW(20, 15, 0))                     # mem[0x1000] = 1  (tohost)
# Also arm far-future mtimecmp so no more interrupts fire
words.extend(LI(22, -1))                        # x22 = 0xFFFFFFFF
words.append(SW(22, 18, 0))                     # mtimecmp_lo = -1
words.append(SW(22, 18, 4))                     # mtimecmp_hi = -1
words.append(MRET())                            # return; main will see tohost

# Patch handler branch
offset = (handler_done - handler_branch_placeholder) * 4
words[handler_branch_placeholder] = BGE(16, 17, offset)

# ======================================================
# Emit
# ======================================================
out = REPO_ROOT / "raijin" / "programs" / "timer_int_test.hex"
emit_hex(words, str(out))
print(f"built {out.relative_to(REPO_ROOT)} ({len(words)} words)")
print(f"  main ends at word {HANDLER_WORD_INDEX - 1}, handler at word {HANDLER_WORD_INDEX}")
print(f"  target ticks = {TARGET_TICKS}, tick delta = {TICK_DELTA}")
