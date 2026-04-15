/* link.ld: linker script for freestanding C programs running on Raijin.
 *
 * Memory map:
 *   0x0000_0000 .. 0x0000_0FFF   .text.init   (reset vector + crt)
 *   0x0000_1000 .. 0x0000_1FFF   .tohost      (signature word polled by tb)
 *   0x0000_2000 .. 0x0000_3FFF   .text  .rodata
 *   0x0000_4000 .. 0x0000_7FFF   .data  .bss  (heap would grow up here)
 *   ...                          stack grows down from _stack_top (0x8000)
 *
 * The testbench loads the same hex image into both imem (for fetches) and
 * dmem (for loads/stores). Each must therefore cover at least 0x8000 bytes
 * = 8192 32-bit words.
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
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
    }

    . = 0x00004000;
    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    }

    .bss : {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        _bss_end = .;
    }

    /* Top of dmem (matches DEPTH_WORDS in riscv_test_tb.v = 65536 words). */
    _stack_top = 0x00040000;
    _end = .;
}
