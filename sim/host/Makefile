# Host interface test of the generated Chisel core (build the core first).
ROOT := $(abspath ../..)
GEN := $(ROOT)/build/pico8.HandheldPico8-gamebub_rev4/generated

obj_dir/Vhost_top: host_top.sv mmcm_stub.sv host_main.cpp ../sdram_model.sv $(GEN)/HandheldPico8.sv
	verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast --noassert \
		-Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
		-Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-DECLFILENAME \
		--top-module host_top -CFLAGS "-O2 -std=c++17" \
		host_top.sv mmcm_stub.sv ../sdram_model.sv $(GEN)/HandheldPico8.sv $(GEN)/Mmcm.sv \
		$(ROOT)/hdl/pico8_gamebub.sv $(ROOT)/hdl/pico8_soc.sv $(ROOT)/hdl/pico8_sdram.sv \
		$(ROOT)/hdl/vexriscv/VexRiscv_Pico8.v host_main.cpp
