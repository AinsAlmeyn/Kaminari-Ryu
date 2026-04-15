/* link.ld for Doom on Raijin.
 *
 * Memory layout (16 MB IMEM + 16 MB DMEM, both loaded with the same image):
 *
 *   0x0000_0000 .. 0x0000_0FFF   .text.init  (reset vector + crt)
 *   0x0000_1000 .. 0x0000_1FFF   .tohost
 *   0x0000_2000 .. 0x004F_FFFF   .text  .rodata  (Doom code + WAD blob)
 *   0x0050_0000 .. 0x00FF_FFFF   .data  .bss  heap
 *   stack grows down from _stack_top = 0x0100_0000
 */

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
    . = 0x00000000;
    .text.init : { *(.text.init) }

    . = 0x00001000;
    .tohost : { *(.tohost) }

    . = 0x00002000;
    .text : {
        *(.text)
        *(.text.*)
    }
    .rodata : {
        *(.rodata)
        *(.rodata.*)
        /* WAD binary blob lives here. */
        *(.wad_blob)
    }

    . = 0x00500000;
    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    }
    _bss_start = .;
    .bss : {
        *(.sbss)
        *(.sbss.*)
        *(.bss)
        *(.bss.*)
        *(COMMON)
    }
    . = ALIGN(4);
    _bss_end = .;

    /* Stack grows down from _stack_top toward _bss_end. */
    _stack_top = 0x01000000;

    /DISCARD/ : {
        *(.comment)
        *(.note)
        *(.note.*)
        *(.eh_frame)
        *(.eh_frame_hdr)
    }
}
