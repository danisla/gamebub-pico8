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
    mv a0, sp
    call trap_handler
2:  j 2b
