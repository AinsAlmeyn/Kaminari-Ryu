/* link_raijin.ld  --  linker script for running riscv-tests on Raijin.
 *
 * The stock env/p/link.ld places code at 0x80000000, which would force us
 * to mirror high addresses through imem. We start at 0 instead because the
 * Raijin PC also resets to 0.
 *
 * Memory layout:
 *   0x0000 .. 0x0FFF   .text.init   reset / trap-vector / test code start
 *   0x1000 .. 0x1FFF   .tohost      signature word the harness polls
 *   0x2000 .. 0x2FFF   .text        any extra code
 *   0x3000 .. ....     .data .bss   test data
 *
 * The testbench will load the assembled hex into BOTH imem and dmem so that
 * instruction fetches AND data loads see the same image.
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
    .text : { *(.text) }

    . = 0x00003000;
    .data : {
        *(.data)
        *(.data.*)
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
        *(.sdata)
        *(.sdata.*)
    }

    .bss : {
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
    }

    _end = .;
}
