ENTRY(_start)
SECTIONS {
    . = 0;
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*) }
    .data : { *(.data*) *(.sdata*) *(.bss*) *(.sbss*) }
}
