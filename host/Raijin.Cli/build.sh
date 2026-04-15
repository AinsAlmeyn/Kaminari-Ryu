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
INSTALLER_DIR="$SCRIPT_DIR/installer"
PAYLOAD_PATH="$INSTALLER_DIR/payload.zip"
PAYLOAD_PLACEHOLDER="PLACEHOLDER"

mkdir -p "$OUT_DIR"
mkdir -p "$PROG_DIR" "$SDK_DIR"

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo dev)"
VERSION="$(grep -E 'Version[[:space:]]*=' "$SCRIPT_DIR/cmd/version.go" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
CLI_LDFLAGS="-X github.com/AinsAlmeyn/raijin-cli/cmd.GitSHA=$GIT_SHA"
SETUP_LDFLAGS="-X main.GitSHA=$GIT_SHA -X main.Version=$VERSION"

if [[ "${1:-}" != "--debug" ]]; then
    CLI_LDFLAGS="$CLI_LDFLAGS -s -w"
    SETUP_LDFLAGS="$SETUP_LDFLAGS -s -w"
fi

# Restore the payload.zip placeholder on exit so the working tree is clean
# regardless of whether this script succeeded or failed mid-way through.
restore_placeholder() {
    if [[ -f "$PAYLOAD_PATH" ]]; then
        echo "$PAYLOAD_PLACEHOLDER" > "$PAYLOAD_PATH"
    fi
}
trap restore_placeholder EXIT

echo "[1/7] go build raijin.exe  (ldflags: $CLI_LDFLAGS)"
( cd "$SCRIPT_DIR" && go build -ldflags "$CLI_LDFLAGS" -o "$OUT_DIR/raijin.exe" . )

echo "[2/7] deploy raijin.dll"
if [[ -f "$DLL_SRC" ]]; then
    if cp "$DLL_SRC" "$OUT_DIR/raijin.dll"; then
        echo "     $OUT_DIR/raijin.dll  ($(stat -c %s "$OUT_DIR/raijin.dll" 2>/dev/null || wc -c <"$OUT_DIR/raijin.dll") bytes)"
    else
        echo "     warning: could not overwrite $OUT_DIR/raijin.dll (likely locked by a running process)"
    fi
else
    echo "     warning: $DLL_SRC not found — build sim/ first"
fi

echo "[3/7] package built-in programs"
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

echo "[4/7] write README.txt"
cat > "$OUT_DIR/README.txt" <<'EOF'
Raijin CLI  Windows x64
========================

This zip is the portable bundle: raijin.exe + raijin.dll + demo programs
+ compile SDK. Run things from this directory with .\raijin.exe ...

Want raijin available from any terminal without the .\ prefix?
  raijin.exe install
  (or download raijin-setup.exe from the same release)

Quickstart:
  raijin.exe --help
  raijin.exe run matrix
  raijin.exe run snake
  raijin.exe run donut
  raijin.exe run doom

Controls:
  Ctrl+C    quit
  stdin     forwarded to the simulator's UART RX
  stdout    receives UART TX

Compile your own program:
  See sdk/c-runtime/ and sdk/runners/elf2hex.py

If raijin.exe reports "cannot load raijin.dll":
  Extract the zip again so raijin.exe and raijin.dll live in the SAME
  directory. Some archive tools split files across subfolders.
EOF
echo "     wrote $OUT_DIR/README.txt"

echo "[5/7] package compile SDK"
rm -rf "$SDK_DIR/c-runtime" "$SDK_DIR/runners"
mkdir -p "$SDK_DIR"
cp -R "$REPO_ROOT/tools/c-runtime" "$SDK_DIR/c-runtime"
mkdir -p "$SDK_DIR/runners"
cp "$REPO_ROOT/tools/runners/elf2hex.py" "$SDK_DIR/runners/elf2hex.py"

echo "[6/7] zip portable bundle"
ZIP_PATH="$OUT_DIR/raijin-cli-windows-x64.zip"
rm -f "$ZIP_PATH"
# Use PowerShell's Compress-Archive when available so the layout matches
# what CI produces. PowerShell wants native Windows paths, hence cygpath.
if command -v powershell >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    SRC_WIN="$(cygpath -w "$OUT_DIR")"
    DST_WIN="$(cygpath -w "$ZIP_PATH")"
    powershell -NoProfile -Command "Compress-Archive -Path '$SRC_WIN\\*' -DestinationPath '$DST_WIN' -Force" >/dev/null
else
    ( cd "$OUT_DIR" && zip -qr "$ZIP_PATH" raijin.exe raijin.dll programs sdk README.txt )
fi
echo "     wrote $ZIP_PATH  ($(stat -c %s "$ZIP_PATH" 2>/dev/null || wc -c <"$ZIP_PATH") bytes)"

echo "[7/7] go build raijin-setup.exe (with embedded payload)"
cp "$ZIP_PATH" "$PAYLOAD_PATH"
( cd "$SCRIPT_DIR" && go build -ldflags "$SETUP_LDFLAGS" -o "$OUT_DIR/raijin-setup.exe" ./installer )
# trap (set above) restores the placeholder so the working tree is clean.

ls -la "$OUT_DIR/raijin.exe" "$OUT_DIR/raijin-setup.exe"
