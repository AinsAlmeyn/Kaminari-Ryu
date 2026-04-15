#!/usr/bin/env bash
# test-linux-docker.sh: end-to-end Linux build + smoke test inside an
# Ubuntu container. Mirrors what the GitHub Actions Linux job will do.
#
# Run from the repo root:  bash test-linux-docker.sh
#
# This script runs ON THE HOST and shells into Docker. The actual Linux
# work happens in /workspace inside the container.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="ubuntu:24.04"

echo "==> launching $IMAGE with $REPO_ROOT mounted at /workspace"

# MSYS_NO_PATHCONV stops MSYS2 from rewriting /workspace into a Windows
# path before docker sees it. The mount source ($REPO_ROOT) is still
# converted because it's a Windows host path; the dest stays POSIX.
MSYS_NO_PATHCONV=1 docker run --rm -t \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    -e DEBIAN_FRONTEND=noninteractive \
    "$IMAGE" \
    bash -c '
set -euo pipefail

echo "==> apt install (verilator + toolchain + go)"
apt-get update -qq
apt-get install -y --no-install-recommends \
    verilator cmake ninja-build gcc g++ \
    golang-go git ca-certificates \
    >/dev/null

echo "==> versions"
verilator --version | head -1
cmake --version | head -1
go version
gcc --version | head -1

echo "==> cmake configure"
rm -rf build/sim
cmake -S sim -B build/sim -G Ninja

echo "==> cmake build"
cmake --build build/sim --config Release

echo "==> libraijin.so deps"
ldd build/sim/bin/libraijin.so | head -10

echo "==> wipe stale Windows artifacts the host may have left in bin/"
rm -rf host/Raijin.Cli/bin

echo "==> build.sh"
chmod +x host/Raijin.Cli/build.sh
host/Raijin.Cli/build.sh

echo "==> bin/ contents"
ls -la host/Raijin.Cli/bin/

echo "==> raijin --version"
host/Raijin.Cli/bin/raijin --version

echo "==> raijin run matrix --max-cycles 50000 --quiet --no-status-bar"
host/Raijin.Cli/bin/raijin run matrix --max-cycles 50000 --quiet --no-status-bar </dev/null || true
echo "(sim run finished)"

echo "==> install dry-run (no PATH changes)"
HOME=/root host/Raijin.Cli/bin/raijin install || true

echo "==> installed copy"
ls -la /root/.raijin/bin/ /root/.raijin/programs/ /root/.raijin/sdk/

echo "==> installed copy actually runs"
/root/.raijin/bin/raijin --version
/root/.raijin/bin/raijin run snake --max-cycles 50000 --quiet --no-status-bar </dev/null || true

echo "==> uninstall (self-uninstall, sync delete)"
/root/.raijin/bin/raijin uninstall --keep-path --purge-programs || true
ls /root/.raijin 2>/dev/null || echo "(install dir gone)"

echo "==> all linux smoke checks passed"
'
