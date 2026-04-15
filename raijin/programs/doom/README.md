# Doom on Raijin

> **Status: BOOTS + RENDERS TITLE SCREEN.** Doom shareware runs on the
> Raijin RV32IM+Zicsr single-cycle CPU, inside our Verilator-backed
> simulator, with the 4 MB WAD embedded in the binary.

```
raijin run doom                    # resolves from the demo catalog
raijin run raijin/programs/doom/doom.hex        # or point at the file directly
```

## What this is

A port of [doomgeneric](https://github.com/ozkl/doomgeneric) (the standard
"Doom on anything" framework) to Raijin's UART-only environment. Output is
ASCII rendered from Doom's 320×200 framebuffer. Input is polled from UART RX
and translated to Doom's key codes.

## Honest expectation

- **Will it run?** Yes, it boots, loads the WAD, and renders the title screen
  as ASCII art.
- **Will it be playable?** The sim runs at ~1.3 MIPS, so each Doom tick is
  slow. Treat it as a working slideshow, not a fragfest.
- **The point.** "Look — this CPU I designed runs the actual Doom binary
  loaded from the actual shareware WAD." That justifies the slowness.

## Dependencies (already satisfied in-repo)

1. **doomgeneric source** at `tools/external/doomgeneric/`
   (`git clone https://github.com/ozkl/doomgeneric.git` there).
2. **DOOM1.WAD** (shareware, ~4 MB) at `raijin/programs/doom/doom1.wad`.
3. **xPack RISC-V toolchain** on PATH (`source tools/runners/activate-toolchain.sh`).

## Files

| File | Purpose |
|------|---------|
| `raijin_video.c`  | `DG_DrawFrame()` — BGRA 320×200 → ASCII 80×40 via 4×5 block luminance averaging and a 12-glyph ramp. |
| `raijin_input.c`  | `DG_GetKey()` — polls UART RX, maps WASD/arrows/space/ctrl to Doom keycodes. |
| `raijin_time.c`   | `DG_GetTicksMs()` / `DG_SleepMs()` — uses the `mcycle`/`mcycleh` CSRs to derive a millisecond clock. |
| `raijin_init.c`   | `main()` that hands off to `doomgeneric_Create` + `doomgeneric_Tick` loop. |
| `syscalls.c`      | newlib syscall layer: `_write`→UART, `_read`→UART RX, `_sbrk`→heap between `_bss_end` and `_stack_top`, `_open`/`_read` intercept `doom1.wad`. |
| `wad_blob.S`      | Embeds `doom1.wad` via `.incbin` in the `.wad_blob` section. |
| `link.ld`         | 16 MB layout: code + rodata (with the 4 MB WAD) up to 0x500000, data + bss + heap above, stack at 0x1000000. |
| `build.sh`        | One-shot build: compiles doomgeneric + our adapters against newlib-nano, links with `--specs=nano.specs --specs=nosys.specs`, produces `raijin/programs/doom/doom.hex`. |

## Building

```bash
source tools/runners/activate-toolchain.sh
bash raijin/programs/doom/build.sh
```

Produces `raijin/programs/doom/doom.hex` (~36 MB hex, since the 4 MB WAD expands to
ASCII hex words, 9 chars per 4 bytes of program).

## Running

```bash
cd host/Raijin.Cli
./bin/raijin.exe run doom                             # via catalog
./bin/raijin.exe run ../../raijin/programs/doom/doom.hex -c 200000000
```

Browser works too but DLL load + 36 MB hex upload is slow. Use CLI.

## What got us here

The port required five real changes to the platform:

1. **Memory.** Bumped IMEM + DMEM from 256 KB each to 16 MB each
   (`sim/CMakeLists.txt` `-GIMEM_DEPTH_WORDS=4194304`). Doom's Z_Init
   wants ~5 MB on top of the 4 MB WAD.
2. **`mcycle` / `mcycleh` CSRs** added to `raijin/rtl/csr_file.v` as a
   free-running 64-bit counter. Doom reads these to pace frames.
3. **newlib-nano.** Dropped the tiny hand-rolled `printf`/`strlen` shims and
   linked against newlib-nano via `--specs=nano.specs --specs=nosys.specs`.
   Doom uses `snprintf`, `strdup`, `ctype`, `malloc`, `fopen`, `fprintf`,
   `strcasecmp`, `strncasecmp`, `memmove`, `atoi`, `abs` — all provided by
   newlib for free.
4. **Syscalls.** `raijin/programs/doom/syscalls.c` wires `_write` to UART TX, `_read`
   to UART RX, `_sbrk` to a linker-defined heap between `_bss_end` and
   `_stack_top - 256K`, `_open` to a WAD intercept.
5. **Linker script** that puts the WAD blob inside `.rodata` and sweeps up
   newlib's `.sdata` + `.sbss` + `_impure_ptr` into our `.data` / `.bss`
   output sections so crt.S zeroes them.

## What it looks like

After ~100 M cycles the UART stream shows the Doom init chatter:

```
Doom Generic 0.1
Z_Init: Init zone memory allocation daemon.
zone memory: 0x644c60, 600000 allocated for zone
Using . for configuration and saves
V_Init: allocate screens.
M_LoadDefaults: Load system defaults.
W_Init: Init WADfiles.
 adding doom1.wad
===========================================================================
                            DOOM Shareware
===========================================================================
I_Init: Setting up machine state.
R_Init: Init DOOM refresh daemon - ...................
I_InitGraphics: framebuffer: x_res: 640, y_res: 400, bpp: 32
I_InitGraphics: DOOM screen size: w x h: 320 x 200
```

Followed by the title screen rendered as ASCII.
