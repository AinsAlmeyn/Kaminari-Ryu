# sum_1_to_5.s: compute 1+2+3+4+5 and store the result at mem[0x100].
#
# Expected final state:
#   x1  = 15          (running sum)
#   x2  = 6           (loop counter on exit)
#   x3  = 6           (loop limit)
#   x10 = 15          (return value in a0)
#   mem[0x100] = 15   (stored result)
#   PC stuck at `halt` label

.org 0x000

    addi x1, x0, 0          # sum     = 0
    addi x2, x0, 1          # counter = 1
    addi x3, x0, 6          # limit   = 6

loop:
    add  x1, x1, x2         # sum += counter
    addi x2, x2, 1          # counter++
    bne  x2, x3, loop       # if counter != limit, back to loop

    mv   x10, x1            # a0 = sum
    sw   x10, 0x100(x0)     # mem[0x100] = sum

halt:
    j    halt               # spin forever
