#!/usr/bin/env python3
"""
rasm.py - minimal RV32I assembler for the Raijin CPU project.

Purpose:
    A standalone, dependency-free Python tool that assembles a subset of
    RV32I assembly into 32-bit hex words (one per line) suitable for
    $readmemh loading in Icarus Verilog.

Usage:
    python tools/rasm.py  INPUT.s  OUTPUT.hex  [--listing OUTPUT.lst]

Supported:
    * all 40 RV32I base instructions
    * register aliases (x0..x31 and ABI names: zero, ra, sp, a0..a7, ...)
    * pseudo-instructions: nop, mv, li, j, jr, ret, beqz, bnez
    * labels, `.org` directive, `#` comments
    * decimal, 0x, 0b, and negative immediates

Not supported (yet):
    * data directives (.word, .byte, etc. - we load only code for now)
    * macros, .include, external symbols
    * RV32M / F / A / C / Zicsr extensions
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# ============================================================================
# Register names (x0..x31 + ABI aliases)
# ============================================================================

_REG_TABLE = {
    'x0': 0, 'zero': 0,
    'x1': 1, 'ra': 1,
    'x2': 2, 'sp': 2,
    'x3': 3, 'gp': 3,
    'x4': 4, 'tp': 4,
    'x5': 5, 't0': 5,
    'x6': 6, 't1': 6,
    'x7': 7, 't2': 7,
    'x8': 8, 's0': 8, 'fp': 8,
    'x9': 9, 's1': 9,
}
_REG_TABLE.update({f'x{i}': i for i in range(10, 32)})
_REG_TABLE.update({
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13,
    'a4': 14, 'a5': 15, 'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21,
    's6': 22, 's7': 23, 's8': 24, 's9': 25,
    's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31,
})


def _reg(tok: str) -> int:
    t = tok.strip().lower()
    if t not in _REG_TABLE:
        raise ValueError(f'unknown register: {tok!r}')
    return _REG_TABLE[t]


def _imm(tok: str, labels: dict[str, int] | None = None,
         pc: int | None = None, rel: bool = False) -> int:
    """Parse an integer immediate or resolve a label.

    When `rel` is True and the token is a label, return (label - pc).
    """
    t = tok.strip()
    # Label?
    if labels is not None and t in labels:
        target = labels[t]
        return (target - pc) if rel else target
    # Numeric forms
    try:
        return int(t, 0)     # supports 0x, 0b, decimal, with optional sign
    except ValueError:
        raise ValueError(f'cannot parse immediate: {tok!r}')


_OFFSET_REG_RE = re.compile(r'^\s*(-?[\w+-]+?)\s*\(\s*(\w+)\s*\)\s*$')


def _offset_reg(tok: str, labels=None, pc=None):
    """Parse 'offset(reg)' -> (offset_int, reg_num)."""
    m = _OFFSET_REG_RE.match(tok)
    if not m:
        raise ValueError(f'expected offset(reg), got: {tok!r}')
    return _imm(m.group(1), labels, pc), _reg(m.group(2))


# ============================================================================
# Field-level encoders
# ============================================================================

def _enc_r(opcode, rd, funct3, rs1, rs2, funct7):
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | \
           ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _enc_i(opcode, rd, funct3, rs1, imm):
    if not (-2048 <= imm <= 2047):
        raise ValueError(f'I-type imm out of range (-2048..2047): {imm}')
    imm &= 0xFFF
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | \
           ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _enc_i_shift(opcode, rd, funct3, rs1, shamt, funct7):
    """I-type shift-immediate - the top 7 bits of imm are a funct7 code."""
    if not (0 <= shamt <= 31):
        raise ValueError(f'shift amount out of range (0..31): {shamt}')
    imm12 = ((funct7 & 0x7F) << 5) | (shamt & 0x1F)
    return (imm12 << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _enc_s(opcode, funct3, rs1, rs2, imm):
    if not (-2048 <= imm <= 2047):
        raise ValueError(f'S-type imm out of range (-2048..2047): {imm}')
    imm &= 0xFFF
    imm_hi = (imm >> 5) & 0x7F
    imm_lo = imm & 0x1F
    return (imm_hi << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | \
           ((funct3 & 0x7) << 12) | (imm_lo << 7) | (opcode & 0x7F)


def _enc_b(opcode, funct3, rs1, rs2, imm):
    if imm & 1:
        raise ValueError(f'B-type imm must be even (branches are 2-byte aligned): {imm}')
    if not (-4096 <= imm <= 4094):
        raise ValueError(f'B-type imm out of range (-4096..4094): {imm}')
    imm &= 0x1FFF
    b12   = (imm >> 12) & 1
    b10_5 = (imm >>  5) & 0x3F
    b4_1  = (imm >>  1) & 0xF
    b11   = (imm >> 11) & 1
    return (b12 << 31) | (b10_5 << 25) | ((rs2 & 0x1F) << 20) | \
           ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           (b4_1 << 8) | (b11 << 7) | (opcode & 0x7F)


def _enc_u(opcode, rd, imm):
    # U-type encodes a 20-bit immediate in the upper 20 bits.
    # Accept either a raw 20-bit value (0..0xFFFFF) OR a 32-bit value
    # whose low 12 bits are zero. `lui x, 0x12345` means imm=0x12345.
    if 0 <= imm <= 0xFFFFF:
        raw20 = imm
    elif (imm & 0xFFF) == 0 and 0 <= imm <= 0xFFFFFFFF:
        raw20 = (imm >> 12) & 0xFFFFF
    else:
        raise ValueError(f'U-type imm cannot be encoded: {imm}')
    return ((raw20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _enc_j(opcode, rd, imm):
    if imm & 1:
        raise ValueError(f'J-type imm must be even: {imm}')
    if not (-(1 << 20) <= imm <= (1 << 20) - 2):
        raise ValueError(f'J-type imm out of range: {imm}')
    imm &= 0x1FFFFF
    b20    = (imm >> 20) & 1
    b10_1  = (imm >>  1) & 0x3FF
    b11    = (imm >> 11) & 1
    b19_12 = (imm >> 12) & 0xFF
    return (b20 << 31) | (b10_1 << 21) | (b11 << 20) | \
           (b19_12 << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


# ============================================================================
# Instruction encoders (one per RV32I mnemonic)
# Each takes (args_list, labels, pc) and returns a 32-bit integer.
# ============================================================================

# Opcode constants (same values as riscv_defs.vh)
_OP_LUI   = 0b0110111
_OP_AUIPC = 0b0010111
_OP_JAL   = 0b1101111
_OP_JALR  = 0b1100111
_OP_BR    = 0b1100011
_OP_LD    = 0b0000011
_OP_ST    = 0b0100011
_OP_IMM   = 0b0010011
_OP_REG   = 0b0110011
_OP_FENCE = 0b0001111
_OP_SYS   = 0b1110011

_F7_DFLT  = 0b0000000
_F7_ALT   = 0b0100000


def _r_type_factory(funct3, funct7):
    def enc(args, labels, pc):
        if len(args) != 3:
            raise ValueError('R-type expects 3 register args: rd, rs1, rs2')
        rd, rs1, rs2 = _reg(args[0]), _reg(args[1]), _reg(args[2])
        return _enc_r(_OP_REG, rd, funct3, rs1, rs2, funct7)
    return enc


def _i_arith_factory(funct3):
    def enc(args, labels, pc):
        if len(args) != 3:
            raise ValueError('I-type arith expects: rd, rs1, imm')
        rd, rs1 = _reg(args[0]), _reg(args[1])
        imm = _imm(args[2], labels, pc)
        return _enc_i(_OP_IMM, rd, funct3, rs1, imm)
    return enc


def _i_shift_factory(funct3, funct7):
    def enc(args, labels, pc):
        if len(args) != 3:
            raise ValueError('I-type shift expects: rd, rs1, shamt')
        rd, rs1 = _reg(args[0]), _reg(args[1])
        shamt = _imm(args[2], labels, pc)
        return _enc_i_shift(_OP_IMM, rd, funct3, rs1, shamt, funct7)
    return enc


def _load_factory(funct3):
    def enc(args, labels, pc):
        if len(args) != 2:
            raise ValueError('load expects: rd, offset(rs1)')
        rd = _reg(args[0])
        imm, rs1 = _offset_reg(args[1], labels, pc)
        return _enc_i(_OP_LD, rd, funct3, rs1, imm)
    return enc


def _store_factory(funct3):
    def enc(args, labels, pc):
        if len(args) != 2:
            raise ValueError('store expects: rs2, offset(rs1)')
        rs2 = _reg(args[0])
        imm, rs1 = _offset_reg(args[1], labels, pc)
        return _enc_s(_OP_ST, funct3, rs1, rs2, imm)
    return enc


def _branch_factory(funct3):
    def enc(args, labels, pc):
        if len(args) != 3:
            raise ValueError('branch expects: rs1, rs2, label_or_offset')
        rs1, rs2 = _reg(args[0]), _reg(args[1])
        imm = _imm(args[2], labels, pc, rel=True)
        return _enc_b(_OP_BR, funct3, rs1, rs2, imm)
    return enc


def _enc_lui(args, labels, pc):
    if len(args) != 2:
        raise ValueError('lui expects: rd, imm20')
    return _enc_u(_OP_LUI, _reg(args[0]), _imm(args[1], labels, pc))


def _enc_auipc(args, labels, pc):
    if len(args) != 2:
        raise ValueError('auipc expects: rd, imm20')
    return _enc_u(_OP_AUIPC, _reg(args[0]), _imm(args[1], labels, pc))


def _enc_jal(args, labels, pc):
    if len(args) != 2:
        raise ValueError('jal expects: rd, label')
    rd = _reg(args[0])
    imm = _imm(args[1], labels, pc, rel=True)
    return _enc_j(_OP_JAL, rd, imm)


def _enc_jalr(args, labels, pc):
    # Two syntaxes allowed:
    #   jalr rd, offset(rs1)
    #   jalr rd, rs1, offset
    if len(args) == 2:
        rd = _reg(args[0])
        imm, rs1 = _offset_reg(args[1], labels, pc)
    elif len(args) == 3:
        rd, rs1 = _reg(args[0]), _reg(args[1])
        imm = _imm(args[2], labels, pc)
    else:
        raise ValueError('jalr expects: rd, offset(rs1) or rd, rs1, offset')
    return _enc_i(_OP_JALR, rd, 0, rs1, imm)


def _enc_fence(args, labels, pc):
    # Minimal form: fence (no args) -> fence iorw, iorw
    # We emit 0x0FF0000F regardless of args for simplicity.
    return 0x0FF0000F


def _enc_ecall(args, labels, pc):  return 0x00000073
def _enc_ebreak(args, labels, pc): return 0x00100073
def _enc_mret(args, labels, pc):   return 0x30200073   # priv-spec MRET encoding


# ---------------------------------------------------------------------------
# Zicsr extension
# ---------------------------------------------------------------------------

_CSR_TABLE = {
    'mstatus':  0x300,
    'misa':     0x301,
    'mie':      0x304,
    'mtvec':    0x305,
    'mscratch': 0x340,
    'mepc':     0x341,
    'mcause':   0x342,
    'mtval':    0x343,
    'mip':      0x344,
    'mhartid':  0xF14,
}


def _csr(tok):
    """Resolve a CSR mnemonic or numeric literal to a 12-bit address."""
    t = tok.strip().lower()
    if t in _CSR_TABLE:
        return _CSR_TABLE[t]
    try:
        v = int(t, 0)
        if not (0 <= v <= 0xFFF):
            raise ValueError(f'CSR address out of range: {v}')
        return v
    except ValueError:
        raise ValueError(f'unknown CSR: {tok!r}')


def _csrr_factory(funct3, imm_variant):
    def enc(args, labels, pc):
        if len(args) != 3:
            raise ValueError('csrr* expects: rd, csr, rs1_or_uimm')
        rd  = _reg(args[0])
        csr = _csr(args[1])
        if imm_variant:
            uimm = _imm(args[2], labels, pc)
            if not (0 <= uimm <= 31):
                raise ValueError(f'CSR uimm must be 0..31: {uimm}')
            source_field = uimm
        else:
            source_field = _reg(args[2])
        return ((csr & 0xFFF) << 20) | ((source_field & 0x1F) << 15) | \
               ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | _OP_SYS
    return enc


# ----------------------------------------------------------------------------
# Pseudo-instructions (expand into one real instruction)
# ----------------------------------------------------------------------------

def _pseudo_nop(args, labels, pc):
    return _enc_i(_OP_IMM, 0, 0, 0, 0)            # addi x0, x0, 0


def _pseudo_mv(args, labels, pc):
    if len(args) != 2:
        raise ValueError('mv expects: rd, rs')
    return _enc_i(_OP_IMM, _reg(args[0]), 0, _reg(args[1]), 0)


def _pseudo_li(args, labels, pc):
    # Limited to immediates fitting in 12 bits (addi from x0).
    # For larger values use lui + addi manually.
    if len(args) != 2:
        raise ValueError('li expects: rd, imm  (only 12-bit range supported)')
    return _enc_i(_OP_IMM, _reg(args[0]), 0, 0, _imm(args[1], labels, pc))


def _pseudo_j(args, labels, pc):
    if len(args) != 1:
        raise ValueError('j expects: label')
    return _enc_j(_OP_JAL, 0, _imm(args[0], labels, pc, rel=True))


def _pseudo_jr(args, labels, pc):
    if len(args) != 1:
        raise ValueError('jr expects: rs')
    return _enc_i(_OP_JALR, 0, 0, _reg(args[0]), 0)


def _pseudo_ret(args, labels, pc):
    if args:
        raise ValueError('ret takes no args')
    return _enc_i(_OP_JALR, 0, 0, 1, 0)            # jalr x0, 0(ra)


def _pseudo_beqz(args, labels, pc):
    if len(args) != 2:
        raise ValueError('beqz expects: rs, label')
    return _enc_b(_OP_BR, 0, _reg(args[0]), 0, _imm(args[1], labels, pc, rel=True))


def _pseudo_bnez(args, labels, pc):
    if len(args) != 2:
        raise ValueError('bnez expects: rs, label')
    return _enc_b(_OP_BR, 1, _reg(args[0]), 0, _imm(args[1], labels, pc, rel=True))


# ----------------------------------------------------------------------------
# Master dispatch table
# ----------------------------------------------------------------------------

_INSTRUCTIONS = {
    # R-type
    'add':  _r_type_factory(0b000, _F7_DFLT),
    'sub':  _r_type_factory(0b000, _F7_ALT),
    'sll':  _r_type_factory(0b001, _F7_DFLT),
    'slt':  _r_type_factory(0b010, _F7_DFLT),
    'sltu': _r_type_factory(0b011, _F7_DFLT),
    'xor':  _r_type_factory(0b100, _F7_DFLT),
    'srl':  _r_type_factory(0b101, _F7_DFLT),
    'sra':  _r_type_factory(0b101, _F7_ALT),
    'or':   _r_type_factory(0b110, _F7_DFLT),
    'and':  _r_type_factory(0b111, _F7_DFLT),

    # I-type arithmetic
    'addi':  _i_arith_factory(0b000),
    'slti':  _i_arith_factory(0b010),
    'sltiu': _i_arith_factory(0b011),
    'xori':  _i_arith_factory(0b100),
    'ori':   _i_arith_factory(0b110),
    'andi':  _i_arith_factory(0b111),
    'slli':  _i_shift_factory(0b001, _F7_DFLT),
    'srli':  _i_shift_factory(0b101, _F7_DFLT),
    'srai':  _i_shift_factory(0b101, _F7_ALT),

    # Loads
    'lb':  _load_factory(0b000),
    'lh':  _load_factory(0b001),
    'lw':  _load_factory(0b010),
    'lbu': _load_factory(0b100),
    'lhu': _load_factory(0b101),

    # Stores
    'sb': _store_factory(0b000),
    'sh': _store_factory(0b001),
    'sw': _store_factory(0b010),

    # Branches
    'beq':  _branch_factory(0b000),
    'bne':  _branch_factory(0b001),
    'blt':  _branch_factory(0b100),
    'bge':  _branch_factory(0b101),
    'bltu': _branch_factory(0b110),
    'bgeu': _branch_factory(0b111),

    # U/J
    'lui':   _enc_lui,
    'auipc': _enc_auipc,
    'jal':   _enc_jal,
    'jalr':  _enc_jalr,

    # Misc
    'fence':  _enc_fence,
    'ecall':  _enc_ecall,
    'ebreak': _enc_ebreak,
    'mret':   _enc_mret,

    # Zicsr
    'csrrw':  _csrr_factory(0b001, imm_variant=False),
    'csrrs':  _csrr_factory(0b010, imm_variant=False),
    'csrrc':  _csrr_factory(0b011, imm_variant=False),
    'csrrwi': _csrr_factory(0b101, imm_variant=True),
    'csrrsi': _csrr_factory(0b110, imm_variant=True),
    'csrrci': _csrr_factory(0b111, imm_variant=True),

    # Pseudo
    'nop':  _pseudo_nop,
    'mv':   _pseudo_mv,
    'li':   _pseudo_li,
    'j':    _pseudo_j,
    'jr':   _pseudo_jr,
    'ret':  _pseudo_ret,
    'beqz': _pseudo_beqz,
    'bnez': _pseudo_bnez,
}


# ============================================================================
# Two-pass assembler
# ============================================================================

def _tokenize(line: str) -> tuple[str, list[str]]:
    """Split a cleaned line into (mnemonic, [arg, ...])."""
    parts = line.split(None, 1)
    mnem = parts[0].lower()
    if len(parts) == 1:
        return mnem, []
    rest = parts[1]
    args = [a.strip() for a in rest.split(',')]
    return mnem, args


def _strip_comment(raw: str) -> str:
    return raw.split('#', 1)[0].rstrip()


def assemble(source: str) -> tuple[list[tuple[int, int, str]], dict[str, int]]:
    """Returns (list_of_(addr, encoding, source_line), labels)."""
    # ------------------------------------------------------------------
    # Pass 1. Record labels and assign an address to each instruction
    # ------------------------------------------------------------------
    pending: list[tuple[int, str]] = []   # (address, instruction_line)
    labels: dict[str, int] = {}
    pc = 0

    for raw in source.splitlines():
        line = _strip_comment(raw).strip()
        if not line:
            continue

        # directive
        if line.startswith('.'):
            parts = line.split()
            if parts[0] == '.org':
                pc = int(parts[1], 0)
            else:
                raise ValueError(f'unsupported directive: {line!r}')
            continue

        # one or more labels at start, possibly followed by an instruction
        while ':' in line:
            head, _, tail = line.partition(':')
            lbl = head.strip()
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', lbl):
                break       # not a label token - fall through to instr
            if lbl in labels:
                raise ValueError(f'duplicate label: {lbl!r}')
            labels[lbl] = pc
            line = tail.strip()
            if not line:
                line = ''
                break
        if not line:
            continue

        pending.append((pc, line))
        pc += 4

    # ------------------------------------------------------------------
    # Pass 2. Encode each instruction now that labels are known
    # ------------------------------------------------------------------
    out: list[tuple[int, int, str]] = []
    for addr, line in pending:
        mnem, args = _tokenize(line)
        if mnem not in _INSTRUCTIONS:
            raise ValueError(f'PC=0x{addr:03x}: unknown mnemonic {mnem!r}')
        try:
            word = _INSTRUCTIONS[mnem](args, labels, addr)
        except Exception as e:
            raise RuntimeError(f'PC=0x{addr:03x} [{line!r}]: {e}') from None
        out.append((addr, word & 0xFFFFFFFF, line))

    return out, labels


# ============================================================================
# CLI
# ============================================================================

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description='Minimal RV32I assembler for Raijin')
    ap.add_argument('input',  type=Path, help='input .s file')
    ap.add_argument('output', type=Path, help='output .hex file')
    ap.add_argument('--listing', type=Path, default=None,
                    help='optional listing file with addresses + source')
    args = ap.parse_args(argv)

    src = args.input.read_text()
    try:
        encoded, labels = assemble(src)
    except (ValueError, RuntimeError) as e:
        print(f'rasm: error: {e}', file=sys.stderr)
        return 1

    # Emit one hex word per line, indexed by address/4. We assume the
    # program starts at address 0 and is contiguous; gaps produce zero
    # fills so $readmemh maps correctly.
    if not encoded:
        print('rasm: warning: no instructions assembled', file=sys.stderr)
        args.output.write_text('')
        return 0

    max_addr = max(a for a, _, _ in encoded)
    words = [0] * ((max_addr // 4) + 1)
    for addr, word, _ in encoded:
        words[addr // 4] = word

    args.output.write_bytes(
        ('\n'.join(f'{w:08x}' for w in words) + '\n').encode('utf-8'))

    if args.listing:
        lines = []
        for addr, word, src_line in encoded:
            lines.append(f'{addr:08x}  {word:08x}    {src_line}')
        if labels:
            lines.append('')
            lines.append('# labels:')
            for lbl, a in sorted(labels.items(), key=lambda kv: kv[1]):
                lines.append(f'# {a:08x}  {lbl}')
        args.listing.write_bytes(
            ('\n'.join(lines) + '\n').encode('utf-8'))

    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
