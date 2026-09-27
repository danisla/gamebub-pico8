    .section .text.start, "ax"
    .globl _start
_start:
    li sp, 0x10010000
    la t0, trap_entry
    csrw mtvec, t0
    call main
1:  j 1b
    .align 4
trap_entry:
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    call trap_handler
2:  j 2b
