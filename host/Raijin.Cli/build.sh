#!/usr/bin/env bash
# build.sh: compile the Go CLI and drop the simulator library, built-in
# programs, and the tiny add/compile SDK next to the binary. Auto-detects
# the host OS (Windows MSYS2 vs Linux vs macOS) and produces a portable
# archive plus, on Windows, a single-file installer.
#
# Usage: ./build.sh            (release, stripped)
#        ./build.sh --debug    (no -s -w, keep DWARF)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$SCRIPT_DIR/bin"
PROG_DIR="$OUT_DIR/programs"
SDK_DIR="$OUT_DIR/sdk"
INSTALLER_DIR="$SCRIPT_DIR/installer"
PAYLOAD_PATH="$INSTALLER_DIR/payload.zip"
PAYLOAD_PLACEHOLDER="PLACEHOLDER"

# ----------------------------------------------------------------------------
# Host detection. We map uname -s to short tags used throughout the script
# for naming and conditional steps:
#   windows  MSYS2/MINGW/Cygwin bash on a Windows host
#   linux    any Linux distribution
#   darwin   macOS (untested in CI, included for completeness)
# ----------------------------------------------------------------------------
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;;
    Linux*)               HOST_OS=linux   ;;
    Darwin*)              HOST_OS=darwin  ;;
    *)                    HOST_OS=unknown ;;
esac

if [[ "$HOST_OS" == "windows" ]]; then
    EXE_SUFFIX=".exe"
    LIB_NAME="raijin.dll"
    ARCHIVE_NAME="raijin-cli-windows-x64.zip"
elif [[ "$HOST_OS" == "darwin" ]]; then
    EXE_SUFFIX=""
    LIB_NAME="libraijin.dylib"
    ARCHIVE_NAME="raijin-cli-macos-x64.tar.gz"
else
    EXE_SUFFIX=""
    LIB_NAME="libraijin.so"
    ARCHIVE_NAME="raijin-cli-linux-x64.tar.gz"
fi

CLI_NAME="raijin${EXE_SUFFIX}"
LIB_SRC="$REPO_ROOT/build/sim/bin/$LIB_NAME"
ARCHIVE_PATH="$OUT_DIR/$ARCHIVE_NAME"

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

# How many steps total. Windows builds the installer too, so it has one
# extra step.
if [[ "$HOST_OS" == "windows" ]]; then
    TOTAL=7
else
    TOTAL=6
fi

echo "[1/$TOTAL] go build $CLI_NAME  (host=$HOST_OS, ldflags: $CLI_LDFLAGS)"
( cd "$SCRIPT_DIR" && go build -ldflags "$CLI_LDFLAGS" -o "$OUT_DIR/$CLI_NAME" . )

echo "[2/$TOTAL] deploy $LIB_NAME"
if [[ -f "$LIB_SRC" ]]; then
    if cp "$LIB_SRC" "$OUT_DIR/$LIB_NAME"; then
        echo "     $OUT_DIR/$LIB_NAME  ($(stat -c %s "$OUT_DIR/$LIB_NAME" 2>/dev/null || wc -c <"$OUT_DIR/$LIB_NAME") bytes)"
    else
        echo "     warning: could not overwrite $OUT_DIR/$LIB_NAME (likely locked by a running process)"
    fi
else
    echo "     warning: $LIB_SRC not found  build sim/ first (cmake -S sim -B build/sim && cmake --build build/sim)"
fi

echo "[3/$TOTAL] package built-in programs"
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

echo "[4/$TOTAL] write README.txt"
if [[ "$HOST_OS" == "windows" ]]; then
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
else
    cat > "$OUT_DIR/README.txt" <<EOF
Raijin CLI  ${HOST_OS} x64
========================

This tarball is the portable bundle: raijin + ${LIB_NAME} + demo programs
+ compile SDK. Run things from this directory with ./raijin ...

Want raijin available from any terminal?
  ./raijin install
  (drops a copy into ~/.raijin/bin and prints the one-liner you can paste
  into your shell rc to put ~/.raijin/bin on \$PATH)

Quickstart:
  ./raijin --help
  ./raijin run matrix
  ./raijin run snake
  ./raijin run donut
  ./raijin run doom

Controls:
  Ctrl+C    quit
  stdin     forwarded to the simulator's UART RX
  stdout    receives UART TX

Compile your own program:
  See sdk/c-runtime/ and sdk/runners/elf2hex.py

If ./raijin reports "cannot load ${LIB_NAME}":
  Make sure raijin and ${LIB_NAME} live in the SAME directory.
  On Linux, run \`ldd ${LIB_NAME}\` to see if a system library is missing.
EOF
fi
echo "     wrote $OUT_DIR/README.txt"

echo "[5/$TOTAL] package compile SDK"
rm -rf "$SDK_DIR/c-runtime" "$SDK_DIR/runners"
mkdir -p "$SDK_DIR"
cp -R "$REPO_ROOT/tools/c-runtime" "$SDK_DIR/c-runtime"
mkdir -p "$SDK_DIR/runners"
cp "$REPO_ROOT/tools/runners/elf2hex.py" "$SDK_DIR/runners/elf2hex.py"

echo "[6/$TOTAL] archive portable bundle  $ARCHIVE_NAME"
rm -f "$ARCHIVE_PATH"
if [[ "$HOST_OS" == "windows" ]]; then
    # PowerShell's Compress-Archive matches what CI produces on windows-latest
    # so power users see the same layout. PowerShell wants native Windows
    # paths, hence cygpath.
    if command -v powershell >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        SRC_WIN="$(cygpath -w "$OUT_DIR")"
        DST_WIN="$(cygpath -w "$ARCHIVE_PATH")"
        powershell -NoProfile -Command "Compress-Archive -Path '$SRC_WIN\\*' -DestinationPath '$DST_WIN' -Force" >/dev/null
    else
        ( cd "$OUT_DIR" && zip -qr "$ARCHIVE_PATH" "$CLI_NAME" "$LIB_NAME" programs sdk README.txt )
    fi
else
    # Unix tar.gz. We tar the bundle's contents (not the parent dir) so
    # extracting puts files in the user's chosen directory directly,
    # matching the Windows zip's flat layout.
    ( cd "$OUT_DIR" && tar -czf "$ARCHIVE_PATH" "$CLI_NAME" "$LIB_NAME" programs sdk README.txt )
fi
echo "     wrote $ARCHIVE_PATH  ($(stat -c %s "$ARCHIVE_PATH" 2>/dev/null || wc -c <"$ARCHIVE_PATH") bytes)"

if [[ "$HOST_OS" == "windows" ]]; then
    echo "[7/$TOTAL] go build raijin-setup.exe (with embedded payload)"
    cp "$ARCHIVE_PATH" "$PAYLOAD_PATH"
    ( cd "$SCRIPT_DIR" && go build -ldflags "$SETUP_LDFLAGS" -o "$OUT_DIR/raijin-setup.exe" ./installer )
    # trap (set above) restores the placeholder so the working tree is clean.
    ls -la "$OUT_DIR/$CLI_NAME" "$OUT_DIR/raijin-setup.exe"
else
    # No installer .exe on Linux/macOS  the tarball + `./raijin install`
    # is the standard pattern.
    ls -la "$OUT_DIR/$CLI_NAME"
fi
