# Raijin CLI

<div align="center">

**The host-side CLI.** Loads the simulator library, drives the CPU,\
and bridges its UART to your terminal.

</div>

This is what end users actually install and run. Cross-platform Go, no cgo: the CLI uses [purego](https://github.com/ebitengine/purego) to load `raijin.dll` on Windows or `libraijin.so` on Linux at runtime, and binds the C API from [`sim/raijin_api.h`](../../sim/raijin_api.h) to Go function pointers.

---

## What it looks like

Running `raijin` with no arguments opens the interactive menu:

```
  ⚡ RAIJIN   v0.2.4                              RV32IM · single-cycle · 32 MB

  ▸ run doom                                                          ● ready
    run matrix                                                        ● ready
    run snake                                                         ● ready
    run donut                                                         ● ready
    ──────────
    add program                                                       →
    demos                                                             →
    bench                                                             →
    ──────────
    install                                                           →
    info                                                              →

  [↑↓] navigate   [enter] launch   [esc] quit
```

---

## Layout

```
host/Raijin.Cli/
├── main.go            entry point, delegates to cobra
├── go.mod             Go 1.22+ module definition
├── build.sh           builds CLI + installer + release archives
│
├── cmd/               cobra subcommands (run, add, install, ...)
├── internal/          private helper packages
│   ├── sim/           shared library loader + C API bindings
│   ├── pathing/       cross-platform PATH + install directory helpers
│   ├── catalog/       registry of built-in and user-added programs
│   ├── runner/        simulation loop, UART passthrough, key input
│   ├── report/        post-run summary screens (bubbletea TUI)
│   ├── theme/         lipgloss styles (amber-accent dark theme)
│   └── suggest/       fuzzy-match "did you mean" for unknown names
│
└── installer/         raijin-setup.exe, the single-file Windows installer
    └── main.go        bubbletea TUI, go:embed'd zip payload
```

---

## Subcommands

| Command | Purpose |
|---------|---------|
| `raijin` | Open the interactive menu (arrow keys plus enter). |
| `raijin run <name\|file.hex>` | Load a program and run it. Accepts built-in names (doom, matrix, snake, donut), user-registered names, or a direct `.hex` file path. |
| `raijin add <file> --name <n>` | Compile a C or assembly source or import an existing hex or ELF, then register it so `raijin run <n>` works. Uses the compile SDK under `sdk/`. |
| `raijin remove <name>` | Remove a user-added program from the catalog. |
| `raijin demos` | List all registered programs. |
| `raijin bench` | Run the benchmark suite and print MIPS. |
| `raijin install` | Copy the CLI into `~/.raijin/bin` and print the shell or PowerShell one-liner to add it to PATH. |
| `raijin uninstall` | Reverse the install. |
| `raijin info` | Show version, platform, DLL path, and a short card about the project. |
| `raijin version` or `--version` | Just the version card. |
| `raijin help` or `--help` | Command help. |

---

## How it loads the simulator

The OS dynamic loader APIs differ between Windows and Unix, so `internal/sim/` is split by platform.

```
  ┌────────────────────────┐          ┌────────────────────────┐
  │   windows build tag    │          │    !windows build tag  │
  ├────────────────────────┤          ├────────────────────────┤
  │  windows.LoadLibrary   │          │    purego.Dlopen       │
  │  → raijin.dll          │          │    → libraijin.so      │
  │  → errno 126 detection │          │    → dlopen error text │
  └───────────┬────────────┘          └───────────┬────────────┘
              │                                   │
              └─────────────┬─────────────────────┘
                            ▼
              ┌───────────────────────────┐
              │    sim.go (shared)        │
              │  • function pointer table │
              │  • bindAll() via purego   │
              │  • public Go wrappers     │
              └───────────────────────────┘
```

| File | Build tag | What it does |
|------|-----------|--------------|
| [`sim.go`](internal/sim/sim.go) | any | Shared types (`Sim` handle, `CSRSnapshot` struct), function pointer declarations, `bindAll()` helper that registers the 17 C functions via purego, and the public Go wrappers. |
| [`loader_windows.go`](internal/sim/loader_windows.go) | `windows` | Uses `windows.LoadLibrary` to open `raijin.dll`. Looks next to the exe first, then the system PATH. Recognizes Windows error 126 (missing dependency) and prints a clear hint. |
| [`loader_unix.go`](internal/sim/loader_unix.go) | `!windows` | Uses `purego.Dlopen` to open `libraijin.so` on Linux or `libraijin.dylib` on macOS. Similar error diagnostics for missing files or failed loads. |

Once the library is loaded and `bindAll()` has filled in the function pointers, the rest of the CLI is platform-agnostic.

> [!NOTE]
> No cgo means no C toolchain needed to build the Go binary itself. `go build` alone produces a static Go executable. The simulator is a separate `.dll` or `.so` that the CLI loads at runtime, so only the simulator build depends on GCC, Verilator, and CMake.

---

## How it manages PATH

Installing to `~/.raijin/bin` is cross-platform, but editing the user PATH is not. Windows uses `HKCU\Environment` in the registry via PowerShell; Unix uses an appended line in `~/.bashrc` or similar. `internal/pathing/` abstracts this behind a single interface.

| File | Build tag | What it handles |
|------|-----------|-----------------|
| [`pathing.go`](internal/pathing/pathing.go) | any | `UserInstallDirs()`, path list manipulation, `AbsSameFile()`, normalization. |
| [`pathing_windows.go`](internal/pathing/pathing_windows.go) | `windows` | Read and write user PATH through `HKCU\Environment` via PowerShell. `UpdateUserPathDir()` handles idempotent add and remove. |
| [`pathing_unix.go`](internal/pathing/pathing_unix.go) | `!windows` | Detect `$SHELL`, append or remove a marked line in the appropriate rc file (bash, zsh, fish). |

The install and uninstall subcommands both call `pathing.UpdateUserPathDir()` so behavior stays symmetric across platforms.

### Install output (Linux)

```
$ ./raijin install

  ✓  installed

    →  ~/.raijin/bin/raijin
    →  ~/.raijin/bin/libraijin.so
    →  ~/.raijin/programs  (4 built-ins)
    →  ~/.raijin/sdk  (compiler support for `raijin add`)

  !  ~/.raijin/bin  is not on your user PATH yet

  one-time setup  (append to ~/.bashrc):

    echo 'export PATH="$HOME/.raijin/bin:$PATH"' >> ~/.bashrc

  open a fresh terminal afterwards, then:
    raijin
```

---

## Building

The repository ships a `build.sh` that does everything in the right order. Run from this directory:

```bash
./build.sh            # release build (stripped, -s -w)
./build.sh --debug    # keep symbols for profiling or debugging
```

The script auto-detects the host OS via `uname -s` and produces:

| Host | Outputs in `bin/` |
|------|-------------------|
| Windows (MSYS2) | `raijin.exe`, `raijin.dll`, `raijin-cli-windows-x64.zip`, `raijin-setup.exe` |
| Linux x64 | `raijin`, `libraijin.so`, `raijin-cli-linux-x64.tar.gz` |
| macOS arm64 | `raijin`, `libraijin.dylib`, `raijin-cli-macos-arm64.tar.gz` |
| macOS x64 (local build) | `raijin`, `libraijin.dylib`, `raijin-cli-macos-x64.tar.gz` |

The archive name's arch tag (`x64` / `arm64`) comes from `uname -m` on the host. CI publishes the arm64 tarball from a macos-14 runner; GitHub Actions' Intel macOS runner was retired in early 2026, so Intel Mac users run `./build.sh` locally to produce the x64 tarball.

> [!NOTE]
> macOS release tarballs are **not code-signed**. First run requires `xattr -d com.apple.quarantine ./raijin ./libraijin.dylib` to clear the Gatekeeper attribute added by browsers when the file was downloaded. The release `README.txt` inside the tarball walks users through this.

The simulator library must be built first from the repo root. See [`sim/README.md`](../../sim/README.md) for that step.

### Just the Go binary

If you only want `raijin` without rebuilding the DLL:

```bash
go build -o ./bin/raijin .
```

You still need `raijin.dll` or `libraijin.so` next to the binary at runtime. Copy it from `build/sim/bin/` or from a release.

---

## The Windows installer

`raijin-setup.exe` is a standalone Go binary that:

1. Embeds the portable zip as a byte slice at build time via `//go:embed payload.zip`.
2. Presents a small bubbletea TUI (same theme as the CLI) with an install or cancel choice.
3. On install, extracts the embedded zip into `%USERPROFILE%\.raijin\`, offers to add `~/.raijin/bin` to the user PATH, and waits for the user to press Enter so the console window doesn't vanish on double-click.
4. Supports `--silent` for scripted install without the TUI and `--no-path` to skip PATH editing.

> [!TIP]
> The payload zip is committed as a placeholder (`installer/payload.zip` contains just the text `PLACEHOLDER`). `build.sh` overwrites it with the real zip right before `go build ./installer` runs, and a trap restores the placeholder on exit so the working tree stays clean even if the build fails midway.

This file is not produced on Linux builds because the tarball plus `./raijin install` flow is the Unix convention.

---

## See also

* Root [README](../../README.md) for the project overview, quickstart, and architecture
* [`sim/README.md`](../../sim/README.md) for how the shared library is built
* [`raijin/README.md`](../../raijin/README.md) for the CPU itself
