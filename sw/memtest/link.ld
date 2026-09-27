ENTRY(_start)
SECTIONS {
    . = 0;
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) }
    . = 0x00080000;
    .data : { *(.data*) *(.sdata*) *(.bss*) *(.sbss*) *(COMMON) }
}
