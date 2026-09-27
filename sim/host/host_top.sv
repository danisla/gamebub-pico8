// Host interface test: the generated Chisel core (HandheldPico8) with an SDRAM
// model, driven like the Game Bub firmware drives it over SPI.
module host_top (
	input  logic        clk,
	input  logic        reset,
	input  logic        mem_enable,
	input  logic        mem_write,
	input  logic [31:0] mem_address,
	input  logic [31:0] mem_wdata,
	output logic [31:0] mem_rdata,
	output logic        mem_done,
	input  logic        cmd_request,
	output logic        cmd_busy,
	output logic        cmd_done,
	output logic        cmd_error,
	input  logic [11:0] buttons,
	output logic        vblank
);
	logic [15:0] dq_to_sdram, dq_from_sdram;
	logic [12:0] a;
	logic [1:0]  dqm, ba;
	logic        cs, ras, cas, we;

	HandheldPico8 core (
		.clock(clk),
		.reset(reset),
		.io_clocks_clockIn50M(clk),
		.io_clocks_clockOutSystem(),
		.io_clocks_clockOutDisplay(),
		.io_clocks_clockOutSpi(),
		.io_clocks_locked(),
		.io_video_data_r(), .io_video_data_g(), .io_video_data_b(),
		.io_video_dataEnable(),
		.io_video_vblank(vblank),
		.io_video_hblank(),
		.io_audio_left(), .io_audio_right(),
		.io_host_mem_enable(mem_enable),
		.io_host_mem_write(mem_write),
		.io_host_mem_done(mem_done),
		.io_host_mem_address(mem_address),
		.io_host_mem_dataRead(mem_rdata),
		.io_host_mem_dataWrite(mem_wdata),
		.io_host_commandHost_request(cmd_request),
		.io_host_commandHost_busy(cmd_busy),
		.io_host_commandHost_done(cmd_done),
		.io_host_commandHost_error(cmd_error),
		.io_input_buttons_right(buttons[0]),
		.io_input_buttons_left(buttons[1]),
		.io_input_buttons_down(buttons[2]),
		.io_input_buttons_up(buttons[3]),
		.io_input_buttons_a(buttons[4]),
		.io_input_buttons_b(buttons[5]),
		.io_input_buttons_x(buttons[6]),
		.io_input_buttons_y(buttons[7]),
		.io_input_buttons_l(buttons[8]),
		.io_input_buttons_r(buttons[9]),
		.io_input_buttons_select(buttons[10]),
		.io_input_buttons_start(buttons[11]),
		.io_sdram_clock(),
		.io_sdram_cke(),
		.io_sdram_cs(cs),
		.io_sdram_ras(ras),
		.io_sdram_cas(cas),
		.io_sdram_we(we),
		.io_sdram_dqm(dqm),
		.io_sdram_bank(ba),
		.io_sdram_address(a),
		.io_sdram_dataIn(dq_from_sdram),
		.io_sdram_dataOut(dq_to_sdram),
		.io_sdram_dataDir()
	);

	sdram_model sdram (
		.clk(clk),
		.dq_in(dq_to_sdram),
		.dq_out(dq_from_sdram),
		.a(a), .ba(ba), .dqm(dqm),
		.cs_n(cs), .ras_n(ras), .cas_n(cas), .we_n(we)
	);
endmodule
