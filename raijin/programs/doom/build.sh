#!/usr/bin/env bash
# build.sh: stitch our Raijin adapter on top of doomgeneric and build a
# single hex you can hand to the Go raijin CLI.
#
# Prerequisites (see README.md):
#   1. tools/external/doomgeneric/   (cloned)
#   2. raijin/programs/doom/doom1.wad (shareware WAD, ~4 MB)
#   3. xPack RISC-V toolchain on PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DG_DIR="$REPO_ROOT/tools/external/doomgeneric/doomgeneric"
WAD="$SCRIPT_DIR/doom1.wad"
OUT_DIR="$SCRIPT_DIR"
TMP_DIR="$REPO_ROOT/build/builtin-assets/doom"
NAME="doom"

mkdir -p "$OUT_DIR"
mkdir -p "$TMP_DIR"

# ---- sanity checks ----
[[ -d "$DG_DIR" ]] || { echo "missing $DG_DIR (clone doomgeneric, see README)"; exit 1; }
[[ -f "$WAD"   ]] || { echo "missing $WAD (drop DOOM1.WAD shareware here)";       exit 1; }
command -v riscv-none-elf-gcc >/dev/null || {
    echo "riscv-none-elf-gcc not on PATH (source tools/runners/activate-toolchain.sh)";
    exit 1;
}

# ---- collect doomgeneric .c files but exclude its platform shims ----
# Everything that pulls SDL/Xlib/Allegro/POSIX ioctl/emscripten is rejected.
DG_SRCS=$(find "$DG_DIR" -maxdepth 1 -name '*.c' \
  ! -name 'doomgeneric_xlib.c' \
  ! -name 'doomgeneric_sdl.c' \
  ! -name 'doomgeneric_allegro.c' \
  ! -name 'doomgeneric_termcaps.c' \
  ! -name 'doomgeneric_win.c' \
  ! -name 'doomgeneric_emscripten.c' \
  ! -name 'doomgeneric_linuxvt.c' \
  ! -name 'doomgeneric_soso.c' \
  ! -name 'doomgeneric_sosox.c' \
  ! -name 'i_allegromusic.c' \
  ! -name 'i_allegrosound.c' \
  ! -name 'i_sdlmusic.c' \
  ! -name 'i_sdlsound.c')

# ---- our adapter sources ----
OUR_SRCS="$SCRIPT_DIR/raijin_video.c \
          $SCRIPT_DIR/raijin_input.c \
          $SCRIPT_DIR/raijin_time.c \
          $SCRIPT_DIR/raijin_init.c \
          $SCRIPT_DIR/syscalls.c \
          $SCRIPT_DIR/wad_blob.S"

ELF="$TMP_DIR/${NAME}.elf"
HEX="$OUT_DIR/${NAME}.hex"

echo "[1/3] compiling..."
# Link with newlib-nano (small snprintf, malloc, strings, ctype) and the
# nosys spec. Our syscalls.c overrides _write/_read/_sbrk/_open so the tiny
# amount of POSIX surface newlib needs is satisfied, routed to UART and
# the embedded WAD blob.
riscv-none-elf-gcc \
    -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany \
    -nostartfiles -static \
    --specs=nano.specs --specs=nosys.specs \
    -O2 -Wall -Wno-unused-but-set-variable -Wno-unused-variable \
    -DDOOMGENERIC \
    -I"$DG_DIR" \
    -I"$REPO_ROOT/tools/c-runtime/shims" \
    -Wa,-I"$SCRIPT_DIR" \
    -Wl,--no-warn-rwx-segments \
    -T "$SCRIPT_DIR/link.ld" \
    "$REPO_ROOT/tools/c-runtime/crt.S" \
    $DG_SRCS \
    $OUR_SRCS \
    -o "$ELF" \
    -lc -lm -lgcc

echo "[2/3] elf -> hex..."
python "$REPO_ROOT/tools/runners/elf2hex.py" "$ELF" "$HEX" --depth 4194304

echo "[3/3] done.  output: $HEX"
ls -la "$HEX"
