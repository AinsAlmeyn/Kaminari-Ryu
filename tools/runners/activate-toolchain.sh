#!/usr/bin/env bash
# activate.sh: puts the RISC-V toolchain on PATH for this shell session.
# Usage:  source tools/runners/activate-toolchain.sh

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "activate.sh must be sourced, not executed:"
    echo "    source tools/runners/activate-toolchain.sh"
    exit 1
fi

XPACK_ROOT="${XPACK_ROOT:-$HOME/opt/xpack-riscv}"

if [[ ! -d "$XPACK_ROOT/bin" ]]; then
    echo "error: RISC-V toolchain not found at $XPACK_ROOT/bin"
    echo "       set XPACK_ROOT to the real install path before sourcing."
    return 1
fi

case ":$PATH:" in
    *":$XPACK_ROOT/bin:"*) ;;                         # already on PATH
    *) export PATH="$XPACK_ROOT/bin:$PATH" ;;
esac

echo "RISC-V toolchain ready:"
riscv-none-elf-gcc --version | head -1
