# SDRAM / audio / input hardware test (install as pico8.bin).
T ?= ../../nix/result-toolchain/bin/riscv32-none-elf-
memtest.bin: memtest.c start.S link.ld ../hw.h
	$(T)gcc -march=rv32imc_zicsr -mabi=ilp32 -O2 -nostdlib -ffreestanding -T link.ld start.S memtest.c -o memtest.elf -lgcc
	$(T)objcopy -O binary memtest.elf memtest.bin
	truncate -s %4 memtest.bin
