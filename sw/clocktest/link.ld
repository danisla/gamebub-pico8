/*
 * clocktest: the host loads the image at SDRAM 0. The boot code copies the
 * program into block RAM and runs it from there (with its data and stack),
 * so that it survives SDRAM timing failures. .sdram_text (the SDRAM copy of
 * the CPU test kernels) stays in SDRAM.
 */
ENTRY(_start)
MEMORY {
    SDRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x00010000
    BRAM  (rwx) : ORIGIN = 0x10000000, LENGTH = 0x0000E000  /* stack: the last 8 KiB */
}
SECTIONS {
    .boot : { KEEP(*(.text.boot)) } > SDRAM
    .sdram_text : ALIGN(64) {
        _sdram_text_start = .;
        *(.sdram_text*)
        . = ALIGN(4);
        _sdram_text_end = .;
    } > SDRAM
    .text : ALIGN(64) {
        _image_start = .;
        *(.text*) *(.rodata*) *(.srodata*) *(.data*) *(.sdata*)
        . = ALIGN(4);
        _image_end = .;
    } > BRAM AT > SDRAM
    _image_lma = LOADADDR(.text);
    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.bss*) *(.sbss*) *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > BRAM
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) *(.note*) }
}
