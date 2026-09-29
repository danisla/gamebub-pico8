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
    RAM   (rw)  : ORIGIN = 0x00800000, LENGTH = 0x01600000
    /* The audio core's data and stack (the caches aren't coherent: the main
       CPU never accesses it, not even sharing a cache line). */
    CORE1 (rw)  : ORIGIN = 0x01E00000, LENGTH = 0x00100000
    BRAM  (rw)  : ORIGIN = 0x10000000, LENGTH = 64K
}

STACK_SIZE = 1M;
CORE1_STACK_SIZE = 64K;

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

    /* The audio core's data: the synthesizer's (audio.o) and its main loop's
       (audio_core1.o). Before .data, so that these sections go here. Copied
       and cleared by the audio core (crt0.S). */
    .core1_data : ALIGN(64) {
        */audio.o(.data .data.* .sdata .sdata.*)
        */audio_core1.o(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
    } > CORE1 AT > IMAGE
    __core1_data_start = ADDR(.core1_data);
    __core1_data_end = ADDR(.core1_data) + SIZEOF(.core1_data);
    __core1_data_load = LOADADDR(.core1_data);

    .core1_bss (NOLOAD) : ALIGN(4) {
        __core1_bss_start = .;
        */audio.o(.sbss .sbss.* .bss .bss.* COMMON)
        */audio_core1.o(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __core1_bss_end = .;
    } > CORE1

    .core1_stack (NOLOAD) : {
        . = ALIGN(16);
        . += CORE1_STACK_SIZE;
        __core1_stack_top = .;
    } > CORE1

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
