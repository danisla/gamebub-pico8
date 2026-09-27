# Verilator simulation of the PICO-8 SoC.
#   make            build obj_dir/Vsim_top
#   make run CART=path/to/cart.p8.png

ROOT := $(abspath ..)
VERILATOR ?= verilator
PROGRAM ?= $(ROOT)/sw/build/pico8.bin
CART ?=
ARGS ?=

SOURCES := sim_top.sv sdram_model.sv \
	$(ROOT)/hdl/pico8_soc.sv $(ROOT)/hdl/pico8_sdram.sv $(ROOT)/hdl/vexriscv/VexRiscv_Pico8.v

obj_dir/Vsim_top: $(SOURCES) main.cpp
	$(VERILATOR) --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast \
		-Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
		-Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
		--top-module sim_top -CFLAGS "-O2 -std=c++17" \
		$(SOURCES) main.cpp

run: obj_dir/Vsim_top
	./obj_dir/Vsim_top $(ARGS) $(PROGRAM) $(CART)

clean:
	rm -rf obj_dir out

.PHONY: run clean
