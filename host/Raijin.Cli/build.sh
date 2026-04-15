#!/usr/bin/env bash
# build.sh: compile the Go CLI and drop raijin.dll, built-in programs, and
# the tiny add/compile SDK next to the exe.
#
# Usage: ./build.sh            (release, stripped)
#        ./build.sh --debug    (no -s -w, keep DWARF)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$SCRIPT_DIR/bin"
DLL_SRC="$REPO_ROOT/build/sim/bin/raijin.dll"
PROG_DIR="$OUT_DIR/programs"
SDK_DIR="$OUT_DIR/sdk"

mkdir -p "$OUT_DIR"
mkdir -p "$PROG_DIR" "$SDK_DIR"

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo dev)"
LDFLAGS="-X github.com/AinsAlmeyn/raijin-cli/cmd.GitSHA=$GIT_SHA"

if [[ "${1:-}" != "--debug" ]]; then
    LDFLAGS="$LDFLAGS -s -w"
fi

echo "[1/4] go build  (ldflags: $LDFLAGS)"
( cd "$SCRIPT_DIR" && go build -ldflags "$LDFLAGS" -o "$OUT_DIR/raijin.exe" . )

echo "[2/4] deploy raijin.dll"
if [[ -f "$DLL_SRC" ]]; then
    if cp "$DLL_SRC" "$OUT_DIR/raijin.dll"; then
        echo "     $OUT_DIR/raijin.dll  ($(stat -c %s "$OUT_DIR/raijin.dll" 2>/dev/null || wc -c <"$OUT_DIR/raijin.dll") bytes)"
    else
        echo "     warning: could not overwrite $OUT_DIR/raijin.dll (likely locked by a running process)"
    fi
else
    echo "     warning: $DLL_SRC not found — build sim/ first"
fi

echo "[3/4] package built-in programs"
for rel in \
    "raijin/programs/snake.hex" \
    "raijin/programs/matrix.hex" \
    "raijin/programs/donut.hex" \
    "raijin/programs/doom/doom.hex"
do
    src="$REPO_ROOT/$rel"
    if [[ -f "$src" ]]; then
        cp "$src" "$PROG_DIR/$(basename "$src")"
        echo "     copied $(basename "$src")"
    else
        echo "     warning: missing $src"
    fi
done

echo "[4/4] package compile SDK"
rm -rf "$SDK_DIR/c-runtime" "$SDK_DIR/runners"
mkdir -p "$SDK_DIR"
cp -R "$REPO_ROOT/tools/c-runtime" "$SDK_DIR/c-runtime"
mkdir -p "$SDK_DIR/runners"
cp "$REPO_ROOT/tools/runners/elf2hex.py" "$SDK_DIR/runners/elf2hex.py"

ls -la "$OUT_DIR/raijin.exe"
