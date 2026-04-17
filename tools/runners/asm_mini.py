"""
asm_mini.py: tiny RV32IM+Zicsr assembler used to hand-build
test programs when the cross-compiler is not installed.

Only the instructions we actually need are covered. Each helper
returns a 32-bit little-endian integer.

Encoding reference: RISC-V Unprivileged ISA v2.2, tables in 2.3-2.5.
"""

from typing import List


def _check(val: int, bits: int, signed: bool = False) -> None:
    if signed:
        lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    else:
        lo, hi = 0, (1 << bits) - 1
    if not (lo <= val <= hi):
        raise ValueError(f"value {val} out of range for {bits} bits (signed={signed})")


def _r_type(opcode: int, rd: int, funct3: int, rs1: int, rs2: int, funct7: int) -> int:
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
         | ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _i_type(opcode: int, rd: int, funct3: int, rs1: int, imm: int) -> int:
    _check(imm, 12, signed=True)
    imm &= 0xFFF
    return (imm << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) \
         | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _s_type(opcode: int, funct3: int, rs1: int, rs2: int, imm: int) -> int:
    _check(imm, 12, signed=True)
    imm &= 0xFFF
    imm_hi = (imm >> 5) & 0x7F
    imm_lo = imm & 0x1F
    return (imm_hi << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
         | ((funct3 & 0x7) << 12) | (imm_lo << 7) | (opcode & 0x7F)


def _b_type(opcode: int, funct3: int, rs1: int, rs2: int, imm: int) -> int:
    if imm & 1:
        raise ValueError("branch imm must be even")
    _check(imm, 13, signed=True)
    imm &= 0x1FFF
    b12   = (imm >> 12) & 1
    b10_5 = (imm >> 5)  & 0x3F
    b4_1  = (imm >> 1)  & 0xF
    b11   = (imm >> 11) & 1
    return (b12 << 31) | (b10_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
         | ((funct3 & 0x7) << 12) | (b4_1 << 8) | (b11 << 7) | (opcode & 0x7F)


def _u_type(opcode: int, rd: int, imm: int) -> int:
    return ((imm & 0xFFFFF000)) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _j_type(opcode: int, rd: int, imm: int) -> int:
    if imm & 1:
        raise ValueError("jal imm must be even")
    _check(imm, 21, signed=True)
    imm &= 0x1FFFFF
    b20    = (imm >> 20) & 1
    b10_1  = (imm >> 1)  & 0x3FF
    b11    = (imm >> 11) & 1
    b19_12 = (imm >> 12) & 0xFF
    enc_imm = (b20 << 19) | (b19_12 << 11) | (b11 << 10) | b10_1
    return (enc_imm << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


# ----- R-type -----
def ADD(rd, rs1, rs2):  return _r_type(0x33, rd, 0, rs1, rs2, 0)
def SUB(rd, rs1, rs2):  return _r_type(0x33, rd, 0, rs1, rs2, 0x20)
def AND(rd, rs1, rs2):  return _r_type(0x33, rd, 7, rs1, rs2, 0)
def OR (rd, rs1, rs2):  return _r_type(0x33, rd, 6, rs1, rs2, 0)
def MUL(rd, rs1, rs2):  return _r_type(0x33, rd, 0, rs1, rs2, 1)

# ----- I-type arith -----
def ADDI(rd, rs1, imm): return _i_type(0x13, rd, 0, rs1, imm)
def ANDI(rd, rs1, imm): return _i_type(0x13, rd, 7, rs1, imm)
def ORI (rd, rs1, imm): return _i_type(0x13, rd, 6, rs1, imm)
def SLLI(rd, rs1, sh):
    if not (0 <= sh <= 31): raise ValueError
    return _r_type(0x13, rd, 1, rs1, sh, 0)
def SRLI(rd, rs1, sh):
    if not (0 <= sh <= 31): raise ValueError
    return _r_type(0x13, rd, 5, rs1, sh, 0)
def SRAI(rd, rs1, sh):
    if not (0 <= sh <= 31): raise ValueError
    return _r_type(0x13, rd, 5, rs1, sh, 0x20)

# ----- loads / stores -----
def LW(rd, rs1, imm):   return _i_type(0x03, rd, 2, rs1, imm)
def LB(rd, rs1, imm):   return _i_type(0x03, rd, 0, rs1, imm)
def SW(rs2, rs1, imm):  return _s_type(0x23, 2, rs1, rs2, imm)
def SB(rs2, rs1, imm):  return _s_type(0x23, 0, rs1, rs2, imm)

# ----- branches -----
def BEQ(rs1, rs2, imm): return _b_type(0x63, 0, rs1, rs2, imm)
def BNE(rs1, rs2, imm): return _b_type(0x63, 1, rs1, rs2, imm)
def BLT(rs1, rs2, imm): return _b_type(0x63, 4, rs1, rs2, imm)
def BGE(rs1, rs2, imm): return _b_type(0x63, 5, rs1, rs2, imm)

# ----- jumps -----
def JAL (rd, imm):           return _j_type(0x6F, rd, imm)
def JALR(rd, rs1, imm):      return _i_type(0x67, rd, 0, rs1, imm)

# ----- upper imms -----
def LUI  (rd, imm): return _u_type(0x37, rd, imm & 0xFFFFF000)
def AUIPC(rd, imm): return _u_type(0x17, rd, imm & 0xFFFFF000)

# ----- system / Zicsr -----
def ECALL():   return 0x00000073
def EBREAK():  return 0x00100073
def MRET():    return 0x30200073
def WFI():     return 0x10500073

def CSRRW (rd, csr, rs1): return _i_type(0x73, rd, 1, rs1, csr & 0xFFF)
def CSRRS (rd, csr, rs1): return _i_type(0x73, rd, 2, rs1, csr & 0xFFF)
def CSRRC (rd, csr, rs1): return _i_type(0x73, rd, 3, rs1, csr & 0xFFF)
def CSRRWI(rd, csr, zimm): return _i_type(0x73, rd, 5, zimm & 0x1F, csr & 0xFFF)
def CSRRSI(rd, csr, zimm): return _i_type(0x73, rd, 6, zimm & 0x1F, csr & 0xFFF)
def CSRRCI(rd, csr, zimm): return _i_type(0x73, rd, 7, zimm & 0x1F, csr & 0xFFF)


# Helpers for loading a 32-bit constant: LI rd, imm
def LI(rd, imm):
    """Returns a list of 1 or 2 instructions loading imm into rd."""
    imm &= 0xFFFFFFFF
    if -2048 <= (imm if imm < 0x80000000 else imm - 0x100000000) <= 2047:
        simm = imm if imm < 0x80000000 else imm - 0x100000000
        return [ADDI(rd, 0, simm)]
    lo = imm & 0xFFF
    hi = (imm + (0x1000 if lo & 0x800 else 0)) & 0xFFFFF000
    if lo & 0x800:
        lo_s = lo - 0x1000
    else:
        lo_s = lo
    return [LUI(rd, hi), ADDI(rd, rd, lo_s)]


def emit_hex(words: List[int], path: str, pad_to: int = 0) -> None:
    """Write a list of 32-bit words as 8-hex-char lines per word."""
    lines = [f"{(w & 0xFFFFFFFF):08x}\n" for w in words]
    while len(lines) < pad_to:
        lines.append("00000000\n")
    with open(path, "w") as fh:
        fh.writelines(lines)
