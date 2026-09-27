/* PICO-8 core program: runs from SDRAM (loaded at 0 by the host). */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* Program image, loaded by the host (read only at run time). The .data
       initial values are copied to RAM at startup, so the CPU can be reset
       without reloading the program. */
    IMAGE (rx)  : ORIGIN = 0x00000000, LENGTH = 0x00800000
    /* The top 1 MiB of the SDRAM is reserved for the cart. */
    RAM   (rw)  : ORIGIN = 0x00800000, LENGTH = 0x01700000
    BRAM  (rw)  : ORIGIN = 0x10000000, LENGTH = 64K
}

STACK_SIZE = 1M;

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
    } > IMAGE

    .rodata : {
        *(.rodata .rodata.*)
        *(.gnu.linkonce.r.*)
        *(.srodata .srodata.*)
    } > IMAGE

    .preinit_array : { PROVIDE_HIDDEN(__preinit_array_start = .); KEEP(*(.preinit_array)) PROVIDE_HIDDEN(__preinit_array_end = .); } > IMAGE
    .init_array : {
        PROVIDE_HIDDEN(__init_array_start = .);
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array))
        PROVIDE_HIDDEN(__init_array_end = .);
    } > IMAGE
    .fini_array : { PROVIDE_HIDDEN(__fini_array_start = .); KEEP(*(.fini_array)) PROVIDE_HIDDEN(__fini_array_end = .); } > IMAGE

    .eh_frame_hdr : { *(.eh_frame_hdr) } > IMAGE
    .eh_frame : { __eh_frame_start = .; KEEP(*(.eh_frame)) LONG(0) } > IMAGE
    .gcc_except_table : { *(.gcc_except_table .gcc_except_table.*) . = ALIGN(8); } > IMAGE

    .data : ALIGN(8) {
        *(.data .data.*)
        *(.gnu.linkonce.d.*)
        . = ALIGN(8);
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.*)
        *(.gnu.linkonce.s.*)
        . = ALIGN(4);
    } > RAM AT > IMAGE
    __data_start = ADDR(.data);
    __data_end = ADDR(.data) + SIZEOF(.data);
    __data_load = LOADADDR(.data);

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM

    .stack (NOLOAD) : {
        . = ALIGN(16);
        . += STACK_SIZE;
        __stack_top = .;
    } > RAM

    /* Heap: the rest of the SDRAM (up to the cart). */
    __heap_start = ALIGN(16);
    __heap_end = ORIGIN(RAM) + LENGTH(RAM);

    .fast (NOLOAD) : {
        *(.fast .fast.*)
    } > BRAM
}
