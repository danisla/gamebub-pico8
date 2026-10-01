// Simulation top: the PICO-8 SoC with an SDRAM model.
module sim_top #(
	parameter int CLOCK_HZ = 90_909_090,
	/// Graphics accelerator (0 to compare with the CPU drawing)
	parameter int GFX = 1
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        cpu_reset,
	input  logic        focus,
	input  logic [11:0] buttons,
	input  logic [1:0]  rotation,
	input  logic [23:0] cart_size,
	output logic        sdram_ready,
	output logic        pixel_valid,
	output logic [7:0]  pixel_r,
	output logic [7:0]  pixel_g,
	output logic [7:0]  pixel_b,
	output logic        hblank,
	output logic        vblank,
	output logic [15:0] audio_l,
	output logic [15:0] audio_r,
	output logic [11:0] save_size
);
	logic [15:0] dq_to_sdram, dq_from_sdram;
	logic        dq_oe;
	logic [12:0] a;
	logic [1:0]  dqm, ba;
	logic        cs_n, ras_n, cas_n, we_n, cke, sdram_clk;

	// MMCM phase shift: done 12 cycles after the request (no actual shift).
	logic        psen, psdone;
	logic [11:0] ps_pipe = '0;
	always_ff @(posedge clk) ps_pipe <= {ps_pipe[10:0], psen};
	assign psdone = ps_pipe[11];

`ifdef PICO8_VEXII
	localparam int CPU_VEXII = `PICO8_VEXII;
`else
	localparam int CPU_VEXII = 0;
`endif
`ifdef PICO8_AUDIO_CORE
	localparam int AUDIO_CORE = `PICO8_AUDIO_CORE;
`else
	localparam int AUDIO_CORE = 1;
`endif
	pico8_soc #(.CLOCK_HZ(CLOCK_HZ), .CPU_VEXII(CPU_VEXII), .AUDIO_CORE(AUDIO_CORE), .GFX(GFX)) soc (
		.clk(clk),
		.clk_sdram_out(clk),
		.reset(reset),
		.cpu_reset(cpu_reset),
		.focus(focus),
		.buttons(buttons),
		.rotation(rotation),
		.cart_size(cart_size),
		.host_sdram_enable(1'b0),
		.host_sdram_write(1'b0),
		.host_sdram_address('0),
		.host_sdram_wdata('0),
		.host_sdram_rdata(),
		.host_sdram_done(),
		.host_save_enable(1'b0),
		.host_save_write(1'b0),
		.host_save_address('0),
		.host_save_wdata('0),
		.host_save_rdata(),
		.host_save_done(),
		.save_size(save_size),
		.host_log_enable(1'b0),
		.host_log_address('0),
		.host_log_rdata(),
		.host_log_done(),
		.log_size(),
		.sdram_ready(sdram_ready),
		.sdram_psen(psen),
		.sdram_psincdec(),
		.sdram_psdone(psdone),
		.pixel_valid(pixel_valid),
		.pixel_r(pixel_r),
		.pixel_g(pixel_g),
		.pixel_b(pixel_b),
		.hblank(hblank),
		.vblank(vblank),
		.audio_l(audio_l),
		.audio_r(audio_r),
		.SDRAM_DQ_IN(dq_from_sdram),
		.SDRAM_DQ_OUT(dq_to_sdram),
		.SDRAM_DQ_OE(dq_oe),
		.SDRAM_A(a),
		.SDRAM_DQM(dqm),
		.SDRAM_BA(ba),
		.SDRAM_nCS(cs_n),
		.SDRAM_nRAS(ras_n),
		.SDRAM_nCAS(cas_n),
		.SDRAM_nWE(we_n),
		.SDRAM_CKE(cke),
		.SDRAM_CLK(sdram_clk)
	);

	sdram_model sdram (
		.clk(clk),
		.dq_in(dq_to_sdram),
		.dq_out(dq_from_sdram),
		.a(a),
		.ba(ba),
		.dqm(dqm),
		.cs_n(cs_n),
		.ras_n(ras_n),
		.cas_n(cas_n),
		.we_n(we_n)
	);
endmodule
