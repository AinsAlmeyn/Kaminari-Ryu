/* wad_blob.S: embed the Doom shareware WAD as a raw binary blob in .rodata.
 *
 * The blob is exposed as two symbols:
 *   doom_wad_data  : pointer to the first byte
 *   doom_wad_size  : 4-byte length (size_t)
 *
 * vfs.c uses these to satisfy fopen("doom1.wad") + fread(...).
 *
 * The .incbin path is relative to where the assembler is invoked, which
 * build.sh arranges to be raijin/programs/doom/. Drop your DOOM1.WAD here as
 * `doom1.wad` (lowercase) before running build.sh.
 */

    .section .wad_blob, "a"
    .globl doom_wad_data
    .globl doom_wad_size

    .align 4
doom_wad_data:
    .incbin "doom1.wad"
doom_wad_end:

    .align 4
doom_wad_size:
    .word doom_wad_end - doom_wad_data
