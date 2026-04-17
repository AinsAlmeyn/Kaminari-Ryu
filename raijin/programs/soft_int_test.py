"""
Build raijin/programs/soft_int_test.hex.

Demonstrates Raijin v2's machine-software interrupt path (mip.MSIP):
  - Installs a trap handler at 0x400.
  - Enables mie.MSIE and mstatus.MIE.
  - Main: writes 1 to CLINT msip (0x0200_0000) to raise a pending soft
    interrupt, then spins until the handler sets the done flag.
  - Handler: clears msip (writes 0), increments an interrupt counter,
    re-raises msip if the target count is not yet reached. After the
    target writes 1 to tohost (mem[0x1000]) to stop the sim.

Expected outcome on v2:
  mem[0x1000] == 1         (tohost)
  mem[0x1004] == 5         (interrupt count)
  trap_cause at halt == 0x80000003 (machine software interrupt)

On v1 this program hangs (no msip register in that sim).
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "runners"))

from asm_mini import (
    ADDI, BGE, BNE, CSRRS, CSRRW, JAL, LI, LW, MRET, SW, emit_hex,
)

CSR_MSTATUS = 0x300
CSR_MIE     = 0x304
CSR_MTVEC   = 0x305

CLINT_MSIP  = 0x02000000
DATA_TOHOST = 0x1000
DATA_INTR   = 0x1004

TARGET = 5

words = []

# ======================================================
# MAIN
# ======================================================
# mtvec = 0x400
words.extend(LI(1, 0x400))
words.append(CSRRW(0, CSR_MTVEC, 1))

# mie = 0x8 (MSIE: bit 3)
words.extend(LI(4, 0x8))
words.append(CSRRW(0, CSR_MIE, 4))

# mstatus |= 0x8 (MIE)
words.extend(LI(8, 0x8))
words.append(CSRRS(0, CSR_MSTATUS, 8))

# Raise the first soft interrupt: *CLINT_MSIP = 1
words.extend(LI(3, CLINT_MSIP))
words.extend(LI(9, 1))
words.append(SW(9, 3, 0))

# x5 = data base
words.extend(LI(5, DATA_TOHOST))

loop = len(words)
words.append(LW(7, 5, 0))               # load tohost
halt_slot = len(words)
words.append(0)                         # BNE x7, x0, halt
back = (loop - len(words)) * 4
words.append(JAL(0, back))

halt = len(words)
words.append(JAL(0, 0))                 # spin after tohost set
words[halt_slot] = BNE(7, 0, (halt - halt_slot) * 4)

# ======================================================
# HANDLER at 0x400
# ======================================================
HANDLER = 0x400 // 4
while len(words) < HANDLER:
    words.append(0)

# Clear msip (*CLINT_MSIP = 0) so this interrupt is not re-taken.
words.extend(LI(18, CLINT_MSIP))
words.append(SW(0, 18, 0))

# intr count ++ at mem[0x1004]
words.extend(LI(15, DATA_TOHOST))
words.append(LW(16, 15, DATA_INTR - DATA_TOHOST))
words.append(ADDI(16, 16, 1))
words.append(SW(16, 15, DATA_INTR - DATA_TOHOST))

# if count >= TARGET, set tohost and return (no re-arm)
words.extend(LI(17, TARGET))
done_slot = len(words)
words.append(0)

# Re-arm: *CLINT_MSIP = 1 then MRET
words.extend(LI(19, 1))
words.append(SW(19, 18, 0))
words.append(MRET())

done = len(words)
words.extend(LI(20, 1))
words.append(SW(20, 15, 0))   # tohost = 1
words.append(MRET())

words[done_slot] = BGE(16, 17, (done - done_slot) * 4)

# ======================================================
out = REPO_ROOT / "raijin" / "programs" / "soft_int_test.hex"
emit_hex(words, str(out))
print(f"built {out.relative_to(REPO_ROOT)} ({len(words)} words)")
