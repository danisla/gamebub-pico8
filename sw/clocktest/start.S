// clocktest startup: copy the program into block RAM and run it there.
    .section .text.boot, "ax"
    .globl _start
_start:
    la t0, _image_lma
    la t1, _image_start
    la t2, _image_end
1:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    bltu t1, t2, 1b
    la t1, _bss_start
    la t2, _bss_end
2:  bgeu t1, t2, 3f
    sw zero, 0(t1)
    addi t1, t1, 4
    j 2b
3:  // Write the copy back from the (write back) data cache: read 128 KiB
    // elsewhere (4x the cache), then drop stale instruction cache lines.
    li t0, 0x00080000
    li t2, 0x000A0000
4:  lw t3, 0(t0)
    addi t0, t0, 64
    bltu t0, t2, 4b
    fence
    fence.i
    li sp, 0x10010000
    la t0, trap_entry
    csrw mtvec, t0
    call main
5:  j 5b

    .text
    .align 4
    .globl trap_entry
trap_entry:
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    call trap_handler
6:  j 6b
