// crt.S: minimal startup for a freestanding C program on Raijin.
//
// Responsibilities:
//   1. Initialise the stack pointer to the top of dmem.
//   2. Zero the .bss section.
//   3. Call main().
//   4. Pass main's return value back to the testbench through tohost
//      using the riscv-tests convention:
//          tohost = (return_value << 1) | 1
//      so that a clean exit (return 0) lands as 1 (== PASS) and a non-zero
//      return shows up as a FAIL with the encoded value.
//
// The linker script puts this in .text.init so it lands at address 0.

    .section .text.init, "ax"
    .globl _start
_start:
    // ---- Stack pointer at top of dmem (provided by linker) ----
    la      sp, _stack_top

    // ---- Zero out .bss ----
    la      t0, _bss_start
    la      t1, _bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    // ---- Hand control to main() ----
    jal     ra, main

    // ---- main returned: pack value into tohost format and signal exit ----
    slli    a0, a0, 1
    ori     a0, a0, 1
    la      t0, tohost
    sw      a0, 0(t0)

3:
    j       3b               // park here forever; testbench polls tohost

    // ----- tohost / fromhost cells the testbench polls -----
    .section .tohost, "aw", @progbits
    .align  6
    .globl  tohost
tohost:    .word 0
    .word 0
    .globl  fromhost
fromhost:  .word 0
    .word 0
