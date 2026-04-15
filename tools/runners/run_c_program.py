#!/usr/bin/env python3
"""run_c_program.py: compile a C program with the Raijin C runtime and run
it on the simulated CPU.

Pipeline:
  C source(s) --(gcc + crt.S + link.ld)--> ELF
              --(elf2hex)--> hex image
              --(iverilog + vvp)--> stdout containing UART output

Usage:
  python tools/runners/run_c_program.py raijin/programs/hello.c
  python tools/runners/run_c_program.py path/to/main.c [extra1.c extra2.c ...]
                                [--depth WORDS] [--include DIR]

The program is linked against tools/c-runtime/crt.S using
tools/c-runtime/link.ld. UART output (writes to 0x10000000) shows up on
stdout. The return value of main() is forwarded to tohost so the
testbench can detect program completion.
"""

from __future__ import annotations
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT     = Path(__file__).resolve().parent.parent.parent
RUNTIME_DIR   = REPO_ROOT / 'tools' / 'c-runtime'
CRT_S         = RUNTIME_DIR / 'crt.S'
LINK_LD       = RUNTIME_DIR / 'link.ld'
BUILD_DIR     = REPO_ROOT / 'build' / 'c'
TB_FILE       = REPO_ROOT / 'raijin' / 'dv' / 'riscv_test_tb.v'
RTL_FILES = [
    'regfile.v', 'decoder.v', 'control.v', 'alu.v',
    'branch_unit.v', 'pc_reg.v', 'imem.v', 'dmem.v',
    'csr_file.v', 'uart_sim.v', 'm_unit.v', 'raijin_core.v',
]


def compile_program(sources: list[Path], elf: Path, includes: list[Path],
                    march: str = 'rv32i_zicsr') -> None:
    cmd = [
        'riscv-none-elf-gcc',
        f'-march={march}', '-mabi=ilp32', '-mcmodel=medany',
        '-nostdlib', '-nostartfiles', '-static',
        '-ffreestanding', '-O2', '-Wall',
        '-T', str(LINK_LD),
    ]
    for d in includes:
        cmd += ['-I', str(d)]
    cmd.append(str(CRT_S))
    cmd += [str(s) for s in sources]
    cmd += ['-o', str(elf)]
    # libgcc provides software helpers (__divsi3, __mulsi3, etc.) used when
    # the target lacks the M extension. Must come AFTER object files.
    cmd += ['-lgcc']
    proc = subprocess.run(cmd, capture_output=True, text=True)
    # The xPack toolchain warns about RWX segments; that is fine for sim.
    stderr = '\n'.join(l for l in proc.stderr.splitlines()
                       if 'RWX permissions' not in l)
    if stderr:
        print(stderr, file=sys.stderr)
    if proc.returncode != 0:
        raise RuntimeError(f'gcc failed: {proc.stderr.strip()}')


def elf_to_hex(elf: Path, hex_path: Path, depth: int) -> None:
    cmd = [sys.executable, str(REPO_ROOT / 'tools' / 'runners' / 'elf2hex.py'),
           str(elf), str(hex_path), '--depth', str(depth)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f'elf2hex failed: {proc.stderr.strip()}')


def simulate_iverilog(hex_path: Path, name: str, sim_bin: Path) -> int:
    rtl_args = [str(REPO_ROOT / 'raijin' / 'rtl' / f) for f in RTL_FILES]
    compile_cmd = [
        'iverilog',
        '-I', str(REPO_ROOT / 'raijin' / 'rtl'),
        '-D', f'TEST_HEX_FILE="{hex_path.as_posix()}"',
        '-D', f'TEST_NAME="{name}"',
        '-o', str(sim_bin),
        *rtl_args,
        str(TB_FILE),
    ]
    proc = subprocess.run(compile_cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print('iverilog error:', proc.stderr, file=sys.stderr)
        return 1
    proc = subprocess.run(['vvp', str(sim_bin)], text=True)
    return proc.returncode


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('sources', nargs='+', type=Path,
                    help='one or more C source files')
    ap.add_argument('--depth', type=int, default=8192,
                    help='memory depth in 32-bit words (default 8192)')
    ap.add_argument('--include', '-I', action='append', default=[], type=Path,
                    help='additional include directory')
    ap.add_argument('--name', help='override base name for output files')
    ap.add_argument('--simulator', choices=('iverilog',),
                    default='iverilog',
                    help='backend simulator (currently only iverilog)')
    ap.add_argument('--max-cycles', type=int, default=None,
                    help='override MAX_CYCLES inside the testbench')
    ap.add_argument('--march', default='rv32i_zicsr',
                    help='gcc -march flag (e.g. rv32im_zicsr to use M extension)')
    args = ap.parse_args(argv)

    if not shutil.which('riscv-none-elf-gcc'):
        print('error: toolchain not on PATH. '
              'Run `source tools/runners/activate-toolchain.sh` first.', file=sys.stderr)
        return 1

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    name = args.name or args.sources[0].stem
    elf  = BUILD_DIR / f'{name}.elf'
    hexp = BUILD_DIR / f'{name}.hex'
    sim  = BUILD_DIR / f'{name}.sim'

    try:
        compile_program(args.sources, elf, args.include, march=args.march)
        elf_to_hex(elf, hexp, args.depth)
    except RuntimeError as e:
        print(f'error: {e}', file=sys.stderr)
        return 1

    return simulate_iverilog(hexp, name, sim)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
