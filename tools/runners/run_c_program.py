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
    'csr_file.v', 'uart_sim.v', 'raijin_core.v',
]


def compile_program(sources: list[Path], elf: Path, includes: list[Path]) -> None:
    cmd = [
        'riscv-none-elf-gcc',
        '-march=rv32i_zicsr', '-mabi=ilp32', '-mcmodel=medany',
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


# Repo root in the format Docker on Windows expects when bind-mounting.
# We use the literal Windows path (with backslashes); `docker run -v ...`
# accepts that form on Docker Desktop / Windows.
def _docker_repo_path() -> str:
    return str(REPO_ROOT)


VERILATOR_IMAGE = 'verilator/verilator:latest'

VERILATOR_SUPPRESS = [
    '-Wno-TIMESCALEMOD', '-Wno-WIDTHTRUNC', '-Wno-WIDTHEXPAND',
    '-Wno-UNUSEDSIGNAL', '-Wno-UNUSEDPARAM', '-Wno-CASEINCOMPLETE',
]


def simulate_verilator(hex_path: Path, name: str, build_subdir: str,
                       max_cycles: int | None) -> int:
    """Build the testbench with Verilator inside the official Docker image,
    then exec the resulting binary. Stdout is forwarded to our stdout."""
    rtl_args_in = ['raijin/rtl/' + f for f in RTL_FILES]
    tb_in       = 'raijin/dv/riscv_test_tb.v'
    # Path the testbench will see for $readmemh. Inside the container we
    # mount the repo at /work, so the hex's repo-relative path is the same.
    hex_in_container = hex_path.relative_to(REPO_ROOT).as_posix()
    binary_name = f'{name}_sim'
    mdir_in     = f'build/verilator/{build_subdir}'
    (REPO_ROOT / mdir_in).mkdir(parents=True, exist_ok=True)

    common_env = {**os.environ, 'MSYS_NO_PATHCONV': '1'}

    build_cmd = [
        'docker', 'run', '--rm',
        '-v', f'{_docker_repo_path()}:/work', '-w', '/work',
        VERILATOR_IMAGE,
        '--binary', '--top-module', 'riscv_test_tb',
        f'-DTEST_HEX_FILE="{hex_in_container}"',
        f'-DTEST_NAME="{name}"',
    ]
    if max_cycles is not None:
        build_cmd.append(f'-DMAX_CYCLES={max_cycles}')
    build_cmd += VERILATOR_SUPPRESS
    build_cmd += ['-Iraijin/rtl', '--Mdir', mdir_in, '-o', binary_name]
    build_cmd += rtl_args_in + [tb_in]

    proc = subprocess.run(build_cmd, env=common_env, capture_output=True, text=True)
    if proc.returncode != 0:
        print('verilator build error:\n' + proc.stderr, file=sys.stderr)
        return 1

    # Step 2: run the built binary inside the same image (it ships with libstdc++)
    run_cmd = [
        'docker', 'run', '--rm',
        '-v', f'{_docker_repo_path()}:/work', '-w', '/work',
        '--entrypoint', f'/work/{mdir_in}/{binary_name}',
        VERILATOR_IMAGE,
    ]
    proc = subprocess.run(run_cmd, env=common_env, text=True)
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
    ap.add_argument('--simulator', choices=('iverilog', 'verilator'),
                    default='iverilog',
                    help='backend simulator (default iverilog)')
    ap.add_argument('--max-cycles', type=int, default=None,
                    help='override MAX_CYCLES inside the testbench')
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
        compile_program(args.sources, elf, args.include)
        elf_to_hex(elf, hexp, args.depth)
    except RuntimeError as e:
        print(f'error: {e}', file=sys.stderr)
        return 1

    if args.simulator == 'verilator':
        if not shutil.which('docker'):
            print('error: docker not on PATH; needed for the verilator backend.',
                  file=sys.stderr)
            return 1
        return simulate_verilator(hexp, name, name, args.max_cycles)
    return simulate_iverilog(hexp, name, sim)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
