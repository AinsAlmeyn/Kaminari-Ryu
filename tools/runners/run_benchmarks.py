#!/usr/bin/env python3
"""run_benchmarks.py: run the riscv-tests integer benchmarks on Raijin.

Each benchmark is built unmodified from tools/riscv-tests/benchmarks/<name>/
using our minimal C runtime (crt.S + link.ld). The libc shims under
tools/c-runtime/shims/ replace the heavyweight originals with our
UART-friendly stand-ins.

Benchmarks omitted by default need extensions Raijin lacks (FPU for mm,
spmv; multi-hart for mt-*; vector for vec-*).
"""

from __future__ import annotations
import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT  = Path(__file__).resolve().parent.parent.parent
BENCH_ROOT = REPO_ROOT / 'tools' / 'riscv-tests' / 'benchmarks'
SHIM_DIR   = REPO_ROOT / 'tools' / 'c-runtime' / 'shims'
RUN_C      = REPO_ROOT / 'tools' / 'runners' / 'run_c_program.py'

# (benchmark name, list of source files relative to its dir)
BENCHMARKS = [
    ('vvadd',     ['vvadd_main.c']),
    ('median',    ['median_main.c', 'median.c']),
    ('multiply',  ['multiply_main.c', 'multiply.c']),
    ('qsort',     ['qsort_main.c']),
    ('rsort',     ['rsort.c']),
    ('towers',    ['towers_main.c']),
    ('memcpy',    ['memcpy_main.c']),
]


@dataclass
class Result:
    name: str
    status: str
    cycles: int | None
    extra: str = ''


def run_one(name: str, srcs: list[str], wall_timeout: int,
            simulator: str, max_cycles: int) -> Result:
    bdir = BENCH_ROOT / name
    if not bdir.exists():
        return Result(name, 'MISSING', None)
    args = [
        sys.executable, str(RUN_C),
        *[str(bdir / s) for s in srcs],
        '-I', str(SHIM_DIR),
        '-I', str(bdir),
        '--name', name,
        '--simulator', simulator,
        '--max-cycles', str(max_cycles),
    ]
    try:
        proc = subprocess.run(args, capture_output=True, text=True,
                              timeout=wall_timeout)
    except subprocess.TimeoutExpired:
        return Result(name, 'TIMEOUT', None,
                      f'killed after {wall_timeout}s wall time')
    out = proc.stdout + '\n' + proc.stderr
    m = re.search(r'TEST\s+\S+:\s*(PASS|FAIL|TIMEOUT)', out)
    if not m:
        msg = out.strip().splitlines()[-1] if out.strip() else 'no output'
        return Result(name, 'BUILD_ERROR', None, msg)
    status = m.group(1)
    m_cyc = re.search(r'cycles=(\d+)', out)
    cycles = int(m_cyc.group(1)) if m_cyc else None
    return Result(name, status, cycles)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--bench', help='run a single benchmark by name')
    ap.add_argument('--timeout', type=int, default=120,
                    help='per-benchmark wall-clock cap in seconds (default 120)')
    ap.add_argument('--simulator', choices=('iverilog', 'verilator'),
                    default='verilator',
                    help='backend simulator (default verilator)')
    ap.add_argument('--max-cycles', type=int, default=100_000_000,
                    help='cycle cap inside the testbench (default 100M)')
    args = ap.parse_args()

    if not shutil.which('riscv-none-elf-gcc'):
        print('error: toolchain not on PATH. '
              'Run `source tools/runners/activate-toolchain.sh` first.', file=sys.stderr)
        return 1

    selected = (
        [(args.bench, dict(BENCHMARKS).get(args.bench, []))]
        if args.bench else BENCHMARKS
    )

    results = []
    print(f'Running {len(selected)} benchmark(s) on Raijin')
    print('=' * 60)
    for name, srcs in selected:
        r = run_one(name, srcs, args.timeout, args.simulator, args.max_cycles)
        results.append(r)
        cyc = f'{r.cycles:>8} cyc' if r.cycles else 'n/a       '
        marker = {
            'PASS': '[PASS]', 'FAIL': '[FAIL]', 'TIMEOUT': '[TIME]',
            'BUILD_ERROR': '[ERR ]', 'MISSING': '[MISS]',
        }[r.status]
        print(f'  {marker}  {name:<12}  {cyc}  {r.extra}')

    counts = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    print('=' * 60)
    print('Summary: ' + '  '.join(f'{k}={v}' for k, v in sorted(counts.items())))
    return 0 if all(r.status == 'PASS' for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
