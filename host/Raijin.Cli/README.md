# Raijin CLI

This folder contains the canonical Go CLI for Raijin.

## Distribution model

There are two intended ways to get it:

1. Clone the repository and build it yourself.
2. Download a prebuilt release zip from GitHub Releases.

Those two paths have different prerequisites.

## If you clone the repo

The repository should contain the runtime assets that make the CLI usable:

- built-in program payloads under `raijin/programs/*.hex` and `raijin/programs/doom/doom.hex`
- the tiny compile SDK under `tools/c-runtime` and `tools/runners/elf2hex.py`

That means a clone can support `raijin install` and `raijin add` without first regenerating the built-in demos.

What a clone does **not** contain is a prebuilt `raijin.dll`. To build a fresh CLI bundle from source, you still need:

- Go
- CMake
- Ninja or Make
- Verilator
- a C/C++ toolchain suitable for the simulator build

Typical local flow:

```powershell
Set-Location host/Raijin.Cli
go build -o .\bin\raijin.exe .
.\build.sh
.\bin\raijin.exe install
```

`build.sh` expects `build/sim/bin/raijin.dll` to exist, so the simulator must be built first.

## If you download a GitHub Release

The release zip is the end-user path. It should already contain:

- `raijin.exe`
- `raijin.dll`
- `libgcc_s_seh-1.dll`
- `libwinpthread-1.dll`
- `libstdc++-6.dll`
- `programs/` built-in demo payloads
- `sdk/` files needed by `raijin add`

In that mode, the end user does **not** need Go, Verilator, CMake, or the repo checkout.
They also should not need to install the MSYS2/MinGW runtime separately; the release bundle must ship those DLLs next to `raijin.exe`.

They only need extra tools when using specific `raijin add` paths:

- `.hex` import: no extra tools
- `.elf` import: Python
- `.c/.s/.S` compile: Python + `riscv-none-elf-gcc`

## GitHub Releases automation

This repo includes a workflow at `.github/workflows/release-raijin-cli.yml`.

It does the following on Windows:

1. builds `raijin.dll`
2. runs `host/Raijin.Cli/build.sh`
3. assembles `host/Raijin.Cli/bin/` into a zip
4. uploads the zip as a workflow artifact
5. attaches the zip to a GitHub Release when the pushed tag matches `raijin-cli-v*`

Example tag:

```powershell
git tag raijin-cli-v0.3.1
git push origin raijin-cli-v0.3.1
```

That gives you a downloadable Windows CLI bundle so users do not have to clone the repo or package the executable themselves.
