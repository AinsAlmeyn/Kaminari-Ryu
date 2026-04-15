#!/usr/bin/env python3
"""elf2hex.py: convert a RISC-V ELF file into the 32-bit-per-line hex
format our testbenches load with $readmemh.

Pipeline:
  ELF --(objcopy -O verilog)--> byte-level Verilog hex (with @addr markers)
      --(pack little-endian into 32-bit words)--> one 8-hex-digit word per line

Usage:
  python tools/runners/elf2hex.py INPUT.elf OUTPUT.hex [--depth WORDS]

--depth pads the output to a fixed number of 32-bit words (useful when
your testbench declares a specific IMEM_DEPTH_WORDS). If omitted, we emit
exactly as many words as the program needs.
"""

from __future__ import annotations
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


def elf_to_byte_map(elf_path: Path) -> dict[int, int]:
    """Run objcopy -O verilog, then parse the resulting byte stream into
    {byte_address: byte_value}.  Gaps stay absent from the dict."""
    with tempfile.NamedTemporaryFile(suffix='.vhex', delete=False, mode='w') as f:
        vhex_path = Path(f.name)
    try:
        subprocess.run(
            ['riscv-none-elf-objcopy', '-O', 'verilog', str(elf_path), str(vhex_path)],
            check=True,
        )
        text = vhex_path.read_text()
    finally:
        vhex_path.unlink(missing_ok=True)

    bytes_map: dict[int, int] = {}
    cur = 0
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('@'):
            cur = int(line[1:], 16)
            continue
        for tok in line.split():
            bytes_map[cur] = int(tok, 16)
            cur += 1
    return bytes_map


def pack_words(bytes_map: dict[int, int], depth_words: int | None) -> list[int]:
    """Little-endian pack 4 bytes per word, zero-fill gaps."""
    if not bytes_map:
        return [0] * (depth_words or 0)
    max_byte = max(bytes_map.keys())
    min_depth = (max_byte // 4) + 1
    if depth_words is None:
        depth_words = min_depth
    elif depth_words < min_depth:
        print(f'warning: depth {depth_words} < program reach {min_depth}',
              file=sys.stderr)
    words = [0] * depth_words
    for byte_addr, byte_val in bytes_map.items():
        widx = byte_addr // 4
        bpos = byte_addr % 4
        if 0 <= widx < depth_words:
            words[widx] |= (byte_val & 0xFF) << (bpos * 8)
    return words


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description='RISC-V ELF to 32-bit hex converter')
    ap.add_argument('input',  type=Path, help='input .elf file')
    ap.add_argument('output', type=Path, help='output .hex file')
    ap.add_argument('--depth', type=int, default=None,
                    help='pad output to this many 32-bit words')
    args = ap.parse_args(argv)

    try:
        bytes_map = elf_to_byte_map(args.input)
    except subprocess.CalledProcessError as e:
        print(f'elf2hex: objcopy failed: {e}', file=sys.stderr)
        return 1
    except FileNotFoundError:
        print('elf2hex: riscv-none-elf-objcopy not found on PATH. '
              'Run `source tools/runners/activate-toolchain.sh` first.', file=sys.stderr)
        return 1

    words = pack_words(bytes_map, args.depth)
    text = '\n'.join(f'{w:08x}' for w in words) + '\n'
    args.output.write_bytes(text.encode('utf-8'))
    print(f'  {len(words)} words written to {args.output}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
