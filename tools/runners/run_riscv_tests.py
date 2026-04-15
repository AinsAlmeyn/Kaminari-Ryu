#!/usr/bin/env python3
"""run_riscv_tests.py: build + run one or more riscv-tests on Raijin.

Pipeline for each test:
  .S  -->(riscv-none-elf-gcc)-->  .elf
      -->(elf2hex.py        )-->  .hex
      -->(iverilog + vvp    )-->  PASS / FAIL / TIMEOUT

Usage:
  python tools/runners/run_riscv_tests.py --test add
  python tools/runners/run_riscv_tests.py --all
  python tools/runners/run_riscv_tests.py --list       # show tests and exit

The script expects the toolchain on PATH (run `source tools/runners/activate-toolchain.sh`
first) and the riscv-tests repo cloned under tools/riscv-tests/.
"""

from __future__ import annotations
import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT        = Path(__file__).resolve().parent.parent.parent
TESTS_ROOT       = REPO_ROOT / 'tools' / 'riscv-tests'
ISA_RV32UI       = TESTS_ROOT / 'isa' / 'rv32ui'
ISA_RV32UM       = TESTS_ROOT / 'isa' / 'rv32um'
ENV_P            = TESTS_ROOT / 'env' / 'p'
MACROS_SCALAR    = TESTS_ROOT / 'isa' / 'macros' / 'scalar'
LINKER_SCRIPT    = REPO_ROOT / 'tools' / 'isa-runtime' / 'link.ld'
BUILD_DIR        = REPO_ROOT / 'build' / 'riscv-tests'
TB_FILE          = REPO_ROOT / 'raijin' / 'dv' / 'riscv_test_tb.v'
RTL_FILES = [
    'regfile.v', 'decoder.v', 'control.v', 'alu.v',
    'branch_unit.v', 'pc_reg.v', 'imem.v', 'dmem.v',
    'csr_file.v', 'uart_sim.v', 'm_unit.v', 'raijin_core.v',
]

# Map test name -> (source dir, gcc -march flag).
RV32UI_TESTS = {p.stem: (ISA_RV32UI, 'rv32i_zicsr')  for p in ISA_RV32UI.glob('*.S')}
RV32UM_TESTS = {p.stem: (ISA_RV32UM, 'rv32im_zicsr') for p in ISA_RV32UM.glob('*.S')} if ISA_RV32UM.exists() else {}


# Tests that cannot pass on our core (need features we haven't built).
SKIP_LIST = {
    'fence_i',    # requires instruction-fetch fence semantics (Zifencei)
    'ma_data',    # misaligned data access, we don't trap on these
    'ld_st',      # labeled benchmark, not a compliance test
    'lrsc',       # load-reserved / store-conditional (A extension)
    'st_ld',      # benchmark
    'breakpoint', # EBREAK debug handling
}


@dataclass
class Result:
    name: str
    status: str        # 'PASS', 'FAIL', 'TIMEOUT', 'BUILD_ERROR', 'SKIP'
    detail: str = ''
    cycles: int | None = None


def list_tests() -> list[str]:
    return sorted({*RV32UI_TESTS.keys(), *RV32UM_TESTS.keys()})


def _resolve_test(test_name: str) -> tuple[Path, str]:
    if test_name in RV32UM_TESTS:
        src_dir, march = RV32UM_TESTS[test_name]
    else:
        src_dir, march = RV32UI_TESTS.get(test_name, (ISA_RV32UI, 'rv32i_zicsr'))
    return src_dir / f'{test_name}.S', march


def build_elf(test_name: str) -> Path:
    src, march = _resolve_test(test_name)
    elf = BUILD_DIR / f'{test_name}.elf'
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [
        'riscv-none-elf-gcc',
        f'-march={march}', '-mabi=ilp32', '-mcmodel=medany',
        '-nostdlib', '-nostartfiles', '-static',
        '-T', str(LINKER_SCRIPT),
        '-I', str(ENV_P),
        '-I', str(MACROS_SCALAR),
        str(src),
        '-o', str(elf),
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    return elf


def build_hex(elf: Path, test_name: str) -> Path:
    hex_path = BUILD_DIR / f'{test_name}.hex'
    cmd = [
        sys.executable, str(REPO_ROOT / 'tools' / 'runners' / 'elf2hex.py'),
        str(elf), str(hex_path), '--depth', '4096',
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    return hex_path


def simulate(hex_path: Path, test_name: str) -> Result:
    sim_bin = BUILD_DIR / f'{test_name}.sim'
    # Pass hex path + test name into testbench via define macros
    hex_define = f'TEST_HEX_FILE="{hex_path.as_posix()}"'
    name_define = f'TEST_NAME="{test_name}"'
    rtl_args = [str(REPO_ROOT / 'raijin' / 'rtl' / f) for f in RTL_FILES]
    compile_cmd = [
        'iverilog',
        '-I', str(REPO_ROOT / 'raijin' / 'rtl'),
        '-D', hex_define,
        '-D', name_define,
        '-o', str(sim_bin),
        *rtl_args,
        str(TB_FILE),
    ]
    proc = subprocess.run(compile_cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return Result(test_name, 'BUILD_ERROR',
                      f'iverilog: {proc.stderr.strip()}')
    proc = subprocess.run(['vvp', str(sim_bin)], capture_output=True, text=True)
    stdout = proc.stdout
    # Parse the single "TEST ...:" line our harness emits
    m = re.search(r'TEST\s+\S+:\s*(PASS|FAIL|TIMEOUT)\b(.*)', stdout)
    if not m:
        return Result(test_name, 'BUILD_ERROR',
                      f'unexpected sim output: {stdout!r}')
    status = m.group(1)
    tail = m.group(2).strip()
    m_cyc = re.search(r'cycles=(\d+)', tail)
    cycles = int(m_cyc.group(1)) if m_cyc else None
    return Result(test_name, status, tail, cycles)


def run_one(test_name: str) -> Result:
    if test_name in SKIP_LIST:
        return Result(test_name, 'SKIP', 'in SKIP_LIST')
    src, _ = _resolve_test(test_name)
    if not src.exists():
        return Result(test_name, 'BUILD_ERROR', f'no source: {src}')
    try:
        elf = build_elf(test_name)
    except subprocess.CalledProcessError as e:
        return Result(test_name, 'BUILD_ERROR',
                      f'gcc: {e.stderr.strip() if e.stderr else str(e)}')
    try:
        hex_path = build_hex(elf, test_name)
    except subprocess.CalledProcessError as e:
        return Result(test_name, 'BUILD_ERROR',
                      f'elf2hex: {e.stderr.strip() if e.stderr else str(e)}')
    return simulate(hex_path, test_name)


def format_result(r: Result) -> str:
    marker = {
        'PASS': '[PASS]',
        'FAIL': '[FAIL]',
        'TIMEOUT': '[TIME]',
        'BUILD_ERROR': '[ERR ]',
        'SKIP': '[SKIP]',
    }[r.status]
    cyc = f' {r.cycles:>7} cyc' if r.cycles is not None else ' ' * 12
    prefix = 'rv32um-p' if r.name in RV32UM_TESTS else 'rv32ui-p'
    name = f'{prefix}-{r.name}'
    extra = r.detail if r.status in ('FAIL', 'TIMEOUT', 'BUILD_ERROR') else ''
    return f'  {marker}  {name:<26}{cyc}  {extra}'


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--test', metavar='NAME', help='run a single test')
    ap.add_argument('--all', action='store_true', help='run every test')
    ap.add_argument('--list', action='store_true',
                    help='list available tests and exit')
    args = ap.parse_args(argv)

    if not shutil.which('riscv-none-elf-gcc'):
        print('error: RISC-V toolchain not on PATH. '
              'Run `source tools/runners/activate-toolchain.sh` first.', file=sys.stderr)
        return 1

    if args.list:
        for t in list_tests():
            tag = '  (skip)' if t in SKIP_LIST else ''
            print(f'  {t}{tag}')
        return 0

    if args.test:
        r = run_one(args.test)
        print(format_result(r))
        return 0 if r.status == 'PASS' else 1

    if not args.all:
        ap.error('use --test NAME, --all, or --list')

    tests = list_tests()
    results = []
    print(f'Running {len(tests)} rv32ui tests on Raijin')
    print('=' * 60)
    for t in tests:
        r = run_one(t)
        results.append(r)
        print(format_result(r))

    # Summary
    counts = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    print('=' * 60)
    summary = '  '.join(f'{k}={v}' for k, v in sorted(counts.items()))
    print(f'Summary: {summary}')
    return 0 if counts.get('FAIL', 0) + counts.get('TIMEOUT', 0) + \
                counts.get('BUILD_ERROR', 0) == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
