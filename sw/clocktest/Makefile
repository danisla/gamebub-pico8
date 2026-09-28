# SDRAM / CPU clock and timing test (install as pico8.bin, see README.txt).
T ?= ../../nix/result-toolchain/bin/riscv32-none-elf-
HOSTCC ?= cc
CFLAGS := -march=rv32imc_zicsr_zifencei -mabi=ilp32 -O2 -nostdlib -ffreestanding \
	-fno-builtin -fno-tree-loop-distribute-patterns -fno-strict-aliasing -mno-relax \
	-Wall -Wextra

clocktest.bin: clocktest.elf
	$(T)objcopy -O binary $< $@
	truncate -s %4 $@

clocktest.elf: clocktest.c kernels.c seeds.h expected.h start.S link.ld ../hw.h
	$(T)gcc $(CFLAGS) -c -o kernels_bram.o kernels.c
	$(T)gcc $(CFLAGS) -DKERNEL_SDRAM -c -o kernels_sdram.o kernels.c
	$(T)gcc $(CFLAGS) -Wl,--no-warn-rwx-segments -T link.ld -o $@ start.S clocktest.c kernels_bram.o kernels_sdram.o -lgcc
	$(T)size $@

# For the simulation: smaller test areas.
sim: clocktest_sim.bin
clocktest_sim.bin: clocktest.elf
	$(T)gcc $(CFLAGS) -DCLOCKTEST_SIM -Wl,--no-warn-rwx-segments -T link.ld -o clocktest_sim.elf start.S clocktest.c kernels_bram.o kernels_sdram.o -lgcc
	$(T)objcopy -O binary clocktest_sim.elf $@
	truncate -s %4 $@

expected.h: gen_expected.c kernels.c seeds.h
	$(HOSTCC) -O2 -fno-strict-aliasing -o gen_expected gen_expected.c
	./gen_expected > $@

clean:
	rm -f *.o *.elf *.bin gen_expected expected.h
