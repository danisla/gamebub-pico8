# Verilator simulation of the PICO-8 SoC.
#   make            build obj_dir/Vsim_top
#   make run CART=path/to/cart.p8.png

ROOT := $(abspath ..)
VERILATOR ?= verilator
PROGRAM ?= $(ROOT)/sw/build/pico8.bin
CART ?=
ARGS ?=

SOURCES := sim_top.sv sdram_model.sv \
	$(ROOT)/hdl/pico8_soc.sv $(ROOT)/hdl/pico8_sdram.sv $(ROOT)/hdl/pico8_gfx.sv $(ROOT)/hdl/vexriscv/VexRiscv_Pico8.v

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

# The SoC with VexiiRiscv instead of VexRiscv: obj_dir_vexii/Vsim_top
# VexiiRiscv lanes (hdl/vexiiriscv/VexiiRiscv.v must match) and clock.
# VEXII_GFX=0: without the graphics accelerator (e.g. VEXII_DIR=obj_dir_vexii_nogfx,
# to compare frames). VERILATOR='verilator -DTRACE_VIDEO': print the display
# buffers' state (flips, PRESENT copies) on the console.
VEXII_LANES ?= 1
VEXII_GFX ?= 1
VEXII_CLOCK_HZ ?= 111111111
VEXII_DIR ?= obj_dir_vexii
VEXII_SOURCES := sim_top.sv sdram_model.sv \
	$(ROOT)/hdl/pico8_soc.sv $(ROOT)/hdl/pico8_sdram.sv $(ROOT)/hdl/pico8_gfx.sv $(ROOT)/hdl/vexii_adapter.sv $(ROOT)/hdl/vexiiriscv/VexiiRiscv.v

$(VEXII_DIR)/Vsim_top: $(VEXII_SOURCES) main.cpp
	$(VERILATOR) --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast --Mdir $(VEXII_DIR) \
		-DPICO8_VEXII=$(VEXII_LANES) -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
		-Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
		--top-module sim_top -GCLOCK_HZ=$(VEXII_CLOCK_HZ) -GGFX=$(VEXII_GFX) -CFLAGS "-O2 -std=c++17 -DPICO8_VEXII" \
		$(VEXII_SOURCES) main.cpp

vexii: $(VEXII_DIR)/Vsim_top
