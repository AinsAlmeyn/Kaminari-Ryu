#!/usr/bin/env python3
"""Build the version-controlled built-in Raijin demo hex files.

Outputs:
  raijin/programs/snake.hex
  raijin/programs/matrix.hex
  raijin/programs/donut.hex

Doom remains on its dedicated build script under raijin/programs/doom/build.sh
because it has extra source and WAD packaging steps.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from run_c_program import compile_program, elf_to_hex  # noqa: E402

RUNTIME_INCLUDE = REPO_ROOT / "tools" / "c-runtime" / "shims"
OUT_DIR = REPO_ROOT / "raijin" / "programs"
TMP_DIR = REPO_ROOT / "build" / "builtin-assets"

PROGRAMS = [
    ("snake",  REPO_ROOT / "raijin" / "programs" / "snake.c",  "rv32im_zicsr", 8192),
    ("matrix", REPO_ROOT / "raijin" / "programs" / "matrix.c", "rv32im_zicsr", 8192),
    ("donut",  REPO_ROOT / "raijin" / "programs" / "donut.c",  "rv32im_zicsr", 8192),
]


def build_one(name: str, source: Path, march: str, depth: int) -> None:
    TMP_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    elf = TMP_DIR / f"{name}.elf"
    hex_path = OUT_DIR / f"{name}.hex"
    compile_program([source], elf, [RUNTIME_INCLUDE], march=march)
    elf_to_hex(elf, hex_path, depth)
    print(f"built {hex_path.relative_to(REPO_ROOT)}")


def main() -> int:
    wanted = {arg.lower() for arg in sys.argv[1:]}
    for name, source, march, depth in PROGRAMS:
        if wanted and name not in wanted:
            continue
        build_one(name, source, march, depth)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())