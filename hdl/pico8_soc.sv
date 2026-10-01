//
// PICO-8 SoC for Game Bub.
//
// A VexiiRiscv CPU (RV32IMC) runs fake-08 (a PICO-8 emulator) from SDRAM. The
// CPU renders each PICO-8 frame (128x128, 4 bits per pixel, plus a 16 color
// display palette) into a framebuffer here, which is scanned out to the Game
// Bub framework. Audio samples are pushed into a FIFO, played at a fixed rate.
//
// A second CPU (the audio core, AUDIO_CORE) runs the PICO-8 synthesizer and
// fills the audio FIFO. It runs the same program from SDRAM, and is held in
// reset until the main CPU starts it (REG_CORE1_CTRL). The caches aren't
// coherent: the CPUs exchange data through the shared RAM (uncached), and
// each keeps its own data in the SDRAM apart from the other's (sw/link.ld).
//
// CPU memory map:
//   0x0000_0000  SDRAM (32 MiB, cached). The program is loaded at 0 by the
//                host, the cart at CART_BASE.
//   0x1000_0000  Block RAM (64 KiB, cached): stack and fast data (sw/clocktest).
//   0xF000_0000  I/O registers (uncached)
//   0xF001_0000  Framebuffer back buffer (8 KiB, write only)
//   0xF002_0000  Save buffer (4 KiB)
//   0xF003_0000  Shared RAM (8 KiB), also mapped for the audio core
//   0xF004_0000  The block RAM again, uncached: the PICO-8 RAM, which the
//                graphics accelerator (GFX, pico8_gfx.sv) draws in. Accesses
//                that could see or change what queued commands use wait
//                until it's idle.
//
// Audio core memory map: SDRAM at 0, I/O registers at 0xF000_0000 (a subset,
// see io1_*), shared RAM at 0xF003_0000.
//
// The host (Game Bub MCU) accesses the SDRAM and the save buffer while the CPU
// is held in reset.
//
module pico8_soc #(
	parameter int CLOCK_HZ = 90_909_090,
	/// Clock cycles per video frame
	parameter int FRAME_CLOCKS = CLOCK_HZ / 60,
	/// Audio sample rate
	parameter int AUDIO_HZ = 22050,
	/// CPU: 0 = VexRiscv, 1 = VexiiRiscv, 2 = dual issue VexiiRiscv
	parameter int CPU_VEXII = 1,
	/// Second CPU for audio (a VexiiRiscv like the main CPU; not with VexRiscv)
	parameter int AUDIO_CORE = 1,
	/// Graphics accelerator (pico8_gfx), drawing in the block RAM
	parameter int GFX = 1
) (
	input  logic        clk,
	input  logic        clk_sdram_out,
	input  logic        reset,

	/// Holds the CPU in reset.
	input  logic        cpu_reset,
	/// The core is focused (not paused by the menu).
	input  logic        focus,
	/// {start, select, r, l, y, x, b, a, up, down, left, right}
	input  logic [11:0] buttons,
	/// Screen rotation (for a device held in portrait): 0 = none, 1 = the
	/// image turned 90 degrees clockwise, 2 = counterclockwise.
	input  logic [1:0]  rotation,
	input  logic [23:0] cart_size,

	// Host access to the SDRAM: byte address, 32-bit words.
	input  logic        host_sdram_enable,
	input  logic        host_sdram_write,
	input  logic [24:0] host_sdram_address,
	input  logic [31:0] host_sdram_wdata,
	output logic [31:0] host_sdram_rdata,
	output logic        host_sdram_done,

	// Host access to the save buffer.
	input  logic        host_save_enable,
	input  logic        host_save_write,
	input  logic [11:0] host_save_address,
	input  logic [31:0] host_save_wdata,
	output logic [31:0] host_save_rdata,
	output logic        host_save_done,
	output logic [11:0] save_size,

	// Host access to the log buffer (the CPU's console output).
	input  logic        host_log_enable,
	input  logic [13:0] host_log_address,
	output logic [31:0] host_log_rdata,
	output logic        host_log_done,
	output logic [14:0] log_size,

	output logic        sdram_ready,

	// Dynamic phase shift of clk_sdram_out (MMCM fine phase shift, clocked
	// by clk): a psen pulse moves it by 1/56 of the VCO period, done by psdone.
	output logic        sdram_psen,
	output logic        sdram_psincdec,
	input  logic        sdram_psdone,

	// Video
	output logic        pixel_valid,
	output logic [7:0]  pixel_r,
	output logic [7:0]  pixel_g,
	output logic [7:0]  pixel_b,
	output logic        hblank,
	output logic        vblank,

	// Audio
	output logic [15:0] audio_l,
	output logic [15:0] audio_r,

	// SDRAM
	input  logic [15:0] SDRAM_DQ_IN,
	output logic [15:0] SDRAM_DQ_OUT,
	output logic        SDRAM_DQ_OE,
	output logic [12:0] SDRAM_A,
	output logic [1:0]  SDRAM_DQM,
	output logic [1:0]  SDRAM_BA,
	output logic        SDRAM_nCS,
	output logic        SDRAM_nRAS,
	output logic        SDRAM_nCAS,
	output logic        SDRAM_nWE,
	output logic        SDRAM_CKE,
	output logic        SDRAM_CLK
);

	////////////////////////////////////////////////////////////////////////
	// CPU
	////////////////////////////////////////////////////////////////////////

	logic        ibus_cyc, ibus_stb, ibus_ack, ibus_we, ibus_err;
	logic [29:0] ibus_adr;
	logic [31:0] ibus_dat_r, ibus_dat_w;
	logic [3:0]  ibus_sel;
	logic [2:0]  ibus_cti;
	logic [1:0]  ibus_bte;

	logic        dbus_cyc, dbus_stb, dbus_ack, dbus_we, dbus_err;
	logic [29:0] dbus_adr;
	logic [31:0] dbus_dat_r, dbus_dat_w;
	logic [3:0]  dbus_sel;
	logic [2:0]  dbus_cti;
	logic [1:0]  dbus_bte;

	// The CPU starts after the SDRAM's first initialization (not held in
	// reset by a reinit, see REG_SDRAM_CFG).
	logic sdram_started;
	always_ff @(posedge clk) sdram_started <= reset ? 1'b0 : sdram_started || sdram_ready;
	logic cpu_rst;
	always_ff @(posedge clk) cpu_rst <= reset || cpu_reset || !sdram_started;

	// VexiiRiscv: dual issue, write back data cache, 64 byte lines.
	// VexRiscv: 32 byte lines.
	localparam int LINE_WORDS = CPU_VEXII ? 16 : 8;
	generate
		if (CPU_VEXII) begin : vexii
			VexiiAdapter #(.FETCH64(CPU_VEXII == 2)) cpu (
			.clk(clk),
			.reset(cpu_rst),
			.iBusWishbone_CYC(ibus_cyc),
			.iBusWishbone_STB(ibus_stb),
			.iBusWishbone_ACK(ibus_ack),
			.iBusWishbone_WE(ibus_we),
			.iBusWishbone_ADR(ibus_adr),
			.iBusWishbone_DAT_MISO(ibus_dat_r),
			.iBusWishbone_DAT_MOSI(ibus_dat_w),
			.iBusWishbone_SEL(ibus_sel),
			.iBusWishbone_ERR(ibus_err),
			.iBusWishbone_CTI(ibus_cti),
			.iBusWishbone_BTE(ibus_bte),
			.dBusWishbone_CYC(dbus_cyc),
			.dBusWishbone_STB(dbus_stb),
			.dBusWishbone_ACK(dbus_ack),
			.dBusWishbone_WE(dbus_we),
			.dBusWishbone_ADR(dbus_adr),
			.dBusWishbone_DAT_MISO(dbus_dat_r),
			.dBusWishbone_DAT_MOSI(dbus_dat_w),
			.dBusWishbone_SEL(dbus_sel),
			.dBusWishbone_ERR(dbus_err),
			.dBusWishbone_CTI(dbus_cti),
			.dBusWishbone_BTE(dbus_bte)
		);
`ifdef VERILATOR
			// PC of the instruction in the execute stage, sampled by the
			// simulation's profiler (sim/main.cpp --profile).
			wire [31:0] profile_pc /* verilator public */ = cpu.core.execute_ctrl2_down_PC_lane0;
`endif
		end else begin : vex
			VexRiscv cpu (
			.clk(clk),
			.reset(cpu_rst),
			.externalResetVector(32'h0000_0000),
			.timerInterrupt(1'b0),
			.softwareInterrupt(1'b0),
			.externalInterruptArray(32'h0),
			.iBusWishbone_CYC(ibus_cyc),
			.iBusWishbone_STB(ibus_stb),
			.iBusWishbone_ACK(ibus_ack),
			.iBusWishbone_WE(ibus_we),
			.iBusWishbone_ADR(ibus_adr),
			.iBusWishbone_DAT_MISO(ibus_dat_r),
			.iBusWishbone_DAT_MOSI(ibus_dat_w),
			.iBusWishbone_SEL(ibus_sel),
			.iBusWishbone_ERR(ibus_err),
			.iBusWishbone_CTI(ibus_cti),
			.iBusWishbone_BTE(ibus_bte),
			.dBusWishbone_CYC(dbus_cyc),
			.dBusWishbone_STB(dbus_stb),
			.dBusWishbone_ACK(dbus_ack),
			.dBusWishbone_WE(dbus_we),
			.dBusWishbone_ADR(dbus_adr),
			.dBusWishbone_DAT_MISO(dbus_dat_r),
			.dBusWishbone_DAT_MOSI(dbus_dat_w),
			.dBusWishbone_SEL(dbus_sel),
			.dBusWishbone_ERR(dbus_err),
			.dBusWishbone_CTI(dbus_cti),
			.dBusWishbone_BTE(dbus_bte)
		);
		end
	endgenerate

	// Audio core
	localparam bit HAS_CORE1 = CPU_VEXII != 0 && AUDIO_CORE != 0;

	logic        ibus1_cyc, ibus1_stb, ibus1_ack, ibus1_err;
	logic [29:0] ibus1_adr;
	logic [31:0] ibus1_dat_r;
	logic [2:0]  ibus1_cti;

	logic        dbus1_cyc, dbus1_stb, dbus1_ack, dbus1_we, dbus1_err;
	logic [29:0] dbus1_adr;
	logic [31:0] dbus1_dat_r, dbus1_dat_w;
	logic [3:0]  dbus1_sel;
	logic [2:0]  dbus1_cti;

	// Started by the main CPU (REG_CORE1_CTRL), stopped with it.
	logic core1_run;
	logic cpu1_rst;
	always_ff @(posedge clk) cpu1_rst <= cpu_rst || !core1_run;

	generate
		if (HAS_CORE1) begin : core1
			VexiiAdapter #(.FETCH64(CPU_VEXII == 2)) cpu (
			.clk(clk),
			.reset(cpu1_rst),
			.iBusWishbone_CYC(ibus1_cyc),
			.iBusWishbone_STB(ibus1_stb),
			.iBusWishbone_ACK(ibus1_ack),
			.iBusWishbone_WE(),
			.iBusWishbone_ADR(ibus1_adr),
			.iBusWishbone_DAT_MISO(ibus1_dat_r),
			.iBusWishbone_DAT_MOSI(),
			.iBusWishbone_SEL(),
			.iBusWishbone_ERR(ibus1_err),
			.iBusWishbone_CTI(ibus1_cti),
			.iBusWishbone_BTE(),
			.dBusWishbone_CYC(dbus1_cyc),
			.dBusWishbone_STB(dbus1_stb),
			.dBusWishbone_ACK(dbus1_ack),
			.dBusWishbone_WE(dbus1_we),
			.dBusWishbone_ADR(dbus1_adr),
			.dBusWishbone_DAT_MISO(dbus1_dat_r),
			.dBusWishbone_DAT_MOSI(dbus1_dat_w),
			.dBusWishbone_SEL(dbus1_sel),
			.dBusWishbone_ERR(dbus1_err),
			.dBusWishbone_CTI(dbus1_cti),
			.dBusWishbone_BTE()
		);
		end else begin : no_core1
			assign ibus1_cyc = 1'b0;
			assign ibus1_stb = 1'b0;
			assign ibus1_adr = '0;
			assign ibus1_cti = '0;
			assign dbus1_cyc = 1'b0;
			assign dbus1_stb = 1'b0;
			assign dbus1_we = 1'b0;
			assign dbus1_adr = '0;
			assign dbus1_dat_w = '0;
			assign dbus1_sel = '0;
			assign dbus1_cti = '0;
		end
	endgenerate

	// Address decoding (by the top 4 address bits)
	wire [3:0] ibus_region = ibus_adr[29:26];
	wire [3:0] dbus_region = dbus_adr[29:26];
	wire ibus_req = ibus_cyc && ibus_stb;
	wire dbus_req = dbus_cyc && dbus_stb;

	wire ibus_sdram = ibus_req && ibus_region == 4'h0;
	wire ibus_bram  = ibus_req && ibus_region == 4'h1;
	wire dbus_sdram = dbus_req && dbus_region == 4'h0;
	wire dbus_bram  = dbus_req && dbus_region == 4'h1;
	wire dbus_io    = dbus_req && dbus_region == 4'hF;

	// Audio core: SDRAM and I/O only.
	wire ibus1_req = ibus1_cyc && ibus1_stb;
	wire dbus1_req = dbus1_cyc && dbus1_stb;
	wire ibus1_sdram = ibus1_req && ibus1_adr[29:26] == 4'h0;
	wire dbus1_sdram = dbus1_req && dbus1_adr[29:26] == 4'h0;
	wire dbus1_io    = dbus1_req && dbus1_adr[29:26] == 4'hF;

	// Unmapped accesses: bus error (ack'd after a cycle).
	logic ibus_err_r, dbus_err_r, ibus1_err_r, dbus1_err_r;
	always_ff @(posedge clk) begin
		ibus_err_r <= ibus_req && !ibus_sdram && !ibus_bram && !ibus_err_r;
		dbus_err_r <= dbus_req && !dbus_sdram && !dbus_bram && !dbus_io && !dbus_err_r;
		ibus1_err_r <= ibus1_req && !ibus1_sdram && !ibus1_err_r;
		dbus1_err_r <= dbus1_req && !dbus1_sdram && !dbus1_io && !dbus1_err_r;
	end
	assign ibus_err = ibus_err_r;
	assign dbus_err = dbus_err_r;
	assign ibus1_err = ibus1_err_r;
	assign dbus1_err = dbus1_err_r;

	////////////////////////////////////////////////////////////////////////
	// SDRAM (shared by the CPUs' instruction and data buses, and the host)
	////////////////////////////////////////////////////////////////////////

	logic        sd_req_valid, sd_req_ready, sd_req_line;
	logic        sd_req_write /* verilator public */;
	logic [24:2] sd_req_addr;
	logic [31:0] sd_req_wdata;
	logic [3:0]  sd_req_wsel;
	logic        sd_rd_valid, sd_rd_last;
	logic [31:0] sd_rd_data;

	// SDRAM test controls (sw/clocktest): configuration, reinit, clock phase
	// (registers at 0x0040, 0x0044).
	logic        sdram_cfg_cl3;
	logic [1:0]  sdram_cfg_capture_extra;
	logic        sdram_reinit;
	logic        sdram_reinit_pending;  // requested, waiting for the SDRAM to be idle
	logic        sdram_idle;
	logic        ps_busy;
	logic [15:0] ps_position;   // phase steps from the static phase (signed)

	pico8_sdram #(.CLOCK_HZ(CLOCK_HZ), .LINE_WORDS(LINE_WORDS)) sdram (
		.clk(clk),
		.clk_out(clk_sdram_out),
		.reset(reset),
		.req_valid(sd_req_valid),
		.req_ready(sd_req_ready),
		.req_write(sd_req_write),
		.req_line(sd_req_line),
		.req_addr(sd_req_addr),
		.req_wdata(sd_req_wdata),
		.req_wsel(sd_req_wsel),
		.rd_valid(sd_rd_valid),
		.rd_data(sd_rd_data),
		.rd_last(sd_rd_last),
		.init_done(sdram_ready),
		.cfg_cl3(sdram_cfg_cl3),
		.cfg_capture_extra(sdram_cfg_capture_extra),
		.reinit(sdram_reinit),
		.idle(sdram_idle),
		.*
	);

	typedef enum logic [2:0] { M_DBUS, M_IBUS, M_HOST, M_DBUS1, M_IBUS1 } master_t;
	typedef enum logic [1:0] { A_IDLE, A_REQUEST, A_READ, A_WRITE_ACK } arb_state_t;
	arb_state_t arb_state /* verilator public */;
	master_t    arb_master /* verilator public */;
	logic       host_done_r;
	// The CPUs take turns when both are waiting (the last one served waits).
	logic       arb_last_core1;

	// Wishbone incrementing bursts are line reads.
	wire dbus_line = dbus_cti == 3'b010;
	wire ibus_line = ibus_cti == 3'b010;
	wire dbus1_line = dbus1_cti == 3'b010;
	wire ibus1_line = ibus1_cti == 3'b010;
	wire core0_sdram = dbus_sdram || ibus_sdram;
	wire core1_sdram = dbus1_sdram || ibus1_sdram;
	wire serve_core1 = core1_sdram && (!core0_sdram || !arb_last_core1);

	always_ff @(posedge clk) begin
		host_done_r <= 1'b0;
		if (reset) begin
			arb_state <= A_IDLE;
			sd_req_valid <= 1'b0;
			arb_last_core1 <= 1'b0;
		end else begin
			unique case (arb_state)
				A_IDLE: begin
					// Priority: CPUs (data, then instruction), host.
					if (serve_core1) begin
						arb_last_core1 <= 1'b1;
						sd_req_valid <= 1'b1;
						arb_state <= A_REQUEST;
						if (dbus1_sdram) begin
							arb_master <= M_DBUS1;
							sd_req_write <= dbus1_we;
							sd_req_line <= dbus1_line && !dbus1_we;
							sd_req_addr <= dbus1_adr[22:0];
							sd_req_wdata <= dbus1_dat_w;
							sd_req_wsel <= dbus1_sel;
						end else begin
							arb_master <= M_IBUS1;
							sd_req_write <= 1'b0;
							sd_req_line <= ibus1_line;
							sd_req_addr <= ibus1_adr[22:0];
						end
					end else if (dbus_sdram) begin
						arb_last_core1 <= 1'b0;
						arb_master <= M_DBUS;
						sd_req_valid <= 1'b1;
						sd_req_write <= dbus_we;
						sd_req_line <= dbus_line && !dbus_we;
						sd_req_addr <= dbus_adr[22:0];
						sd_req_wdata <= dbus_dat_w;
						sd_req_wsel <= dbus_sel;
						arb_state <= A_REQUEST;
					end else if (ibus_sdram) begin
						arb_last_core1 <= 1'b0;
						arb_master <= M_IBUS;
						sd_req_valid <= 1'b1;
						sd_req_write <= 1'b0;
						sd_req_line <= ibus_line;
						sd_req_addr <= ibus_adr[22:0];
						arb_state <= A_REQUEST;
					end else if (host_sdram_enable && !host_done_r) begin
						arb_master <= M_HOST;
						sd_req_valid <= 1'b1;
						sd_req_write <= host_sdram_write;
						sd_req_line <= 1'b0;
						sd_req_addr <= host_sdram_address[24:2];
						sd_req_wdata <= host_sdram_wdata;
						sd_req_wsel <= 4'b1111;
						arb_state <= A_REQUEST;
					end
				end
				A_REQUEST: if (sd_req_ready) begin
					sd_req_valid <= 1'b0;
					arb_state <= sd_req_write ? A_WRITE_ACK : A_READ;
					if (sd_req_write && arb_master == M_HOST) host_done_r <= 1'b1;
				end
				A_READ: if (sd_rd_valid) begin
					if (arb_master == M_HOST) host_done_r <= 1'b1;
					if (sd_rd_last) arb_state <= A_IDLE;
				end
				A_WRITE_ACK: arb_state <= A_IDLE;
				default: arb_state <= A_IDLE;
			endcase
		end
	end

	// Write acks are given the cycle after the controller accepts the write.
	wire sd_write_ack = arb_state == A_WRITE_ACK;
	wire sd_read_ack = arb_state == A_READ && sd_rd_valid;

	always_ff @(posedge clk) if (sd_read_ack && arb_master == M_HOST) host_sdram_rdata <= sd_rd_data;
	assign host_sdram_done = host_done_r;

	////////////////////////////////////////////////////////////////////////
	// Block RAM (64 KiB, dual port). Port A: the data bus (cached at
	// 0x1000_0000, uncached as the PICO-8 RAM at 0xF004_0000). Port B: the
	// graphics accelerator while it runs a command, else the instruction bus.
	////////////////////////////////////////////////////////////////////////

	logic [31:0] bram [0:16383];
	logic [31:0] bram_i_q, bram_d_q;
	logic        bram_i_ack, bram_d_ack;

	logic        gfx_mem_active, gfx_mem_we;
	logic [13:0] gfx_mem_addr;
	logic [31:0] gfx_mem_wdata;

	wire [13:0] bram_b_addr = gfx_mem_active ? gfx_mem_addr : ibus_adr[13:0];
	wire        bram_b_we = gfx_mem_active && gfx_mem_we;
	always_ff @(posedge clk) begin
		bram_i_ack <= ibus_bram && !bram_i_ack && !gfx_mem_active;
		if (bram_b_we) begin
			for (int i = 0; i < 4; i++) bram[bram_b_addr][i*8 +: 8] <= gfx_mem_wdata[i*8 +: 8];
		end
		bram_i_q <= bram[bram_b_addr];
	end

	// PICO-8 RAM writes (declared with the I/O).
	logic p8_write;
	always_ff @(posedge clk) begin
		bram_d_ack <= dbus_bram && !bram_d_ack;
		if ((dbus_bram && !bram_d_ack && dbus_we) || p8_write) begin
			for (int i = 0; i < 4; i++) begin
				if (dbus_sel[i]) bram[dbus_adr[13:0]][i*8 +: 8] <= dbus_dat_w[i*8 +: 8];
			end
		end
		bram_d_q <= bram[dbus_adr[13:0]];
	end

	////////////////////////////////////////////////////////////////////////
	// I/O
	////////////////////////////////////////////////////////////////////////

	logic        io_ack;
	logic [31:0] io_rdata;
	logic        io_wait;  // the access waits for the graphics accelerator
	wire         io_access = dbus_io && !io_ack && !io_wait;
	wire         io_write = io_access && dbus_we;
	wire [15:0]  io_addr = {dbus_adr[13:0], 2'b00};
	wire [3:0]   io_block = dbus_adr[17:14]; // 64 KiB blocks

	// Graphics accelerator
	logic        gfx_busy, gfx_cmd_ready, gfx_flip;
	logic        gfx_fb_we, gfx_pal_we;
	logic [10:0] gfx_fb_addr;
	logic [31:0] gfx_fb_wdata;
	logic [3:0]  gfx_pal_index;
	logic [23:0] gfx_pal_rgb;
	logic [31:0] gfx_present_waits, gfx_presents;
	wire gfx_cmd_write = io_write && io_block == 4'h0 && io_addr == 16'h0060;

	// PICO-8 RAM (the block RAM, uncached). While the accelerator is busy:
	// no writes to what it reads (0x0000-0x30FF), no access to the screen
	// (0x6000-0x7FFF).
	wire p8_access = dbus_io && io_block == 4'h4;
	wire p8_hazard = (dbus_we && io_addr < 16'h3100) || io_addr[15:13] == 3'b011;
	assign p8_write = io_write && io_block == 4'h4;

	always_comb begin
		io_wait = 1'b0;
		if (GFX != 0) begin
			if (p8_access && p8_hazard && gfx_busy) io_wait = 1'b1;
			// The back buffer: the accelerator's PRESENT writes it.
			if (dbus_io && io_block == 4'h1 && gfx_busy) io_wait = 1'b1;
			if (dbus_io && dbus_we && io_block == 4'h0 && io_addr == 16'h0060 && !gfx_cmd_ready) io_wait = 1'b1;
		end
	end

	// Audio core
	logic        io1_ack;
	wire         io1_access = dbus1_io && !io1_ack;
	wire         io1_write = io1_access && dbus1_we;
	wire [15:0]  io1_addr = {dbus1_adr[13:0], 2'b00};
	wire [3:0]   io1_block = dbus1_adr[17:14];

	logic [63:0] cycle_counter;
	logic [31:0] cycle_hi_latch;
	logic [31:0] frame_counter;
	always_ff @(posedge clk) begin
		if (reset) cycle_counter <= '0;
		else cycle_counter <= cycle_counter + 1'b1;
	end

	// Video state
	logic [$clog2(FRAME_CLOCKS)-1:0] frame_timer;
	wire         frame_start = frame_timer == 0;
	// Triple buffered: the front buffer (shown), up to 2 frames waiting to be
	// shown (one per video frame, in order), and the back buffer after them,
	// written by the CPU or PRESENT (frames aren't dropped while the next one
	// is drawn).
	logic [1:0]  front;        // front buffer index (0-2)
	logic [1:0]  queued;       // frames waiting to be shown (0-2)
	wire         flip_pending = queued == 2'd2;  // no back buffer free
	logic [1:0]  back;
	always_comb begin
		case (3'(front) + 3'(queued))
			3'd0, 3'd3: back = 2'd1;
			3'd1, 3'd4: back = 2'd2;
			default: back = 2'd0;
		endcase
	end
	logic [23:0] palette [0:2][0:15];

	// Framebuffer: 3 x 2048 words (8 pixels per word, pixel 0 in the low nibble)
	logic [31:0] framebuffer [0:6143];
	wire fb_write = io_write && io_block == 4'h1;
	// One write port (the accelerator's PRESENT or the CPU), muxed before the
	// RAM so that it stays a block RAM. The CPU's writes are registered first
	// (timing; the CPU doesn't read the framebuffer, and doesn't write it
	// while the accelerator is busy).
	logic        fb_cpu_we;
	logic [10:0] fb_cpu_addr;
	logic [31:0] fb_cpu_wdata;
	always_ff @(posedge clk) begin
		fb_cpu_we <= fb_write;
		fb_cpu_addr <= dbus_adr[10:0];
		fb_cpu_wdata <= dbus_dat_w;
	end
	wire        fb_we = gfx_fb_we || fb_cpu_we;
	wire [10:0] fb_waddr = gfx_fb_we ? gfx_fb_addr : fb_cpu_addr;
	wire [31:0] fb_wdata = gfx_fb_we ? gfx_fb_wdata : fb_cpu_wdata;
	always_ff @(posedge clk) begin
		if (fb_we) framebuffer[{back, fb_waddr}] <= fb_wdata;
	end

	generate
		if (GFX != 0) begin : gfx
			pico8_gfx gfx (
				.clk(clk),
				.reset(cpu_rst),
				.cmd_valid(gfx_cmd_write),
				.cmd_data(dbus_dat_w),
				.cmd_ready(gfx_cmd_ready),
				.busy(gfx_busy),
				.mem_active(gfx_mem_active),
				.mem_addr(gfx_mem_addr),
				.mem_we(gfx_mem_we),
				.mem_wdata(gfx_mem_wdata),
				.mem_rdata(bram_i_q),
				.fb_we(gfx_fb_we),
				.fb_addr(gfx_fb_addr),
				.fb_wdata(gfx_fb_wdata),
				.pal_we(gfx_pal_we),
				.pal_index(gfx_pal_index),
				.pal_rgb(gfx_pal_rgb),
				.flip_pending(flip_pending),
				.flip(gfx_flip),
				.present_waits(gfx_present_waits),
				.presents(gfx_presents)
			);
		end else begin : no_gfx
			assign gfx_busy = 1'b0;
			assign gfx_cmd_ready = 1'b1;
			assign gfx_mem_active = 1'b0;
			assign gfx_mem_addr = '0;
			assign gfx_mem_we = 1'b0;
			assign gfx_mem_wdata = '0;
			assign gfx_fb_we = 1'b0;
			assign gfx_fb_addr = '0;
			assign gfx_fb_wdata = '0;
			assign gfx_pal_we = 1'b0;
			assign gfx_pal_index = '0;
			assign gfx_pal_rgb = '0;
			assign gfx_flip = 1'b0;
			assign gfx_present_waits = '0;
			assign gfx_presents = '0;
		end
	endgenerate

	// Save buffer
	logic [31:0] save_buffer [0:1023];
	logic [31:0] save_cpu_q;
	wire save_cpu_write = io_write && io_block == 4'h2;
	always_ff @(posedge clk) begin
		if (save_cpu_write) save_buffer[dbus_adr[9:0]] <= dbus_dat_w;
		save_cpu_q <= save_buffer[dbus_adr[9:0]];
	end

	logic save_host_pending;
	always_ff @(posedge clk) begin
		host_save_done <= 1'b0;
		save_host_pending <= 1'b0;
		if (host_save_enable && !host_save_done && !save_host_pending) begin
			if (host_save_write) save_buffer[host_save_address[11:2]] <= host_save_wdata;
			save_host_pending <= 1'b1;
		end
		if (save_host_pending) host_save_done <= 1'b1;
		host_save_rdata <= save_buffer[host_save_address[11:2]];
	end

	// Audio FIFO
	localparam int AUDIO_FIFO_BITS = 12;
	logic [15:0] audio_fifo [0:(1 << AUDIO_FIFO_BITS) - 1];
	logic [AUDIO_FIFO_BITS:0] audio_wr_ptr, audio_rd_ptr;
	wire [AUDIO_FIFO_BITS:0] audio_count = audio_wr_ptr - audio_rd_ptr;
	// Samples are pushed by either CPU (by one at a time, see sw/audio_core.cpp).
	wire audio_push0 = io_write && io_block == 4'h0 && io_addr == 16'h0024;
	wire audio_push1 = io1_write && io1_block == 4'h0 && io1_addr == 16'h0024;
	wire audio_push = (audio_push0 || audio_push1) && !audio_count[AUDIO_FIFO_BITS];
	wire [15:0] audio_push_data = audio_push1 ? dbus1_dat_w[15:0] : dbus_dat_w[15:0];
	// Samples played while the FIFO was empty (while the core runs).
	logic [31:0] audio_underruns;

	// Console / simulation control
	wire console_write = io_write && io_block == 4'h0 && io_addr == 16'h0028;

	// Log buffer: the first 16 KiB of console output since the core was
	// loaded, saved by the host as a file. (Not cleared when the CPU is held in
	// reset: the host halts the core before saving the files.)
	logic [7:0] log_buffer [0:16383];
	always_ff @(posedge clk) begin
		if (reset) begin
			log_size <= '0;
		end else if (console_write && !log_size[14]) begin
			log_buffer[log_size[13:0]] <= dbus_dat_w[7:0];
			log_size <= log_size + 1'b1;
		end
	end
	logic log_host_pending;
	always_ff @(posedge clk) begin
		host_log_done <= 1'b0;
		log_host_pending <= 1'b0;
		if (host_log_enable && !host_log_done && !log_host_pending) log_host_pending <= 1'b1;
		if (log_host_pending) host_log_done <= 1'b1;
		host_log_rdata <= {log_buffer[{host_log_address[13:2], 2'd3}], log_buffer[{host_log_address[13:2], 2'd2}],
			log_buffer[{host_log_address[13:2], 2'd1}], log_buffer[{host_log_address[13:2], 2'd0}]};
	end
	wire sim_exit_write = io_write && io_block == 4'h0 && io_addr == 16'h002C;

	// Shared RAM (8 KiB, dual port: the main CPU and the audio core, uncached)
	logic [31:0] shared_ram [0:2047];
	logic [31:0] shared0_q, shared1_q;
	wire shared0_write = io_write && io_block == 4'h3;
	always_ff @(posedge clk) begin
		if (shared0_write) begin
			for (int i = 0; i < 4; i++) begin
				if (dbus_sel[i]) shared_ram[dbus_adr[10:0]][i*8 +: 8] <= dbus_dat_w[i*8 +: 8];
			end
		end
		shared0_q <= shared_ram[dbus_adr[10:0]];
	end

	// SDRAM test controls (declared with the SDRAM controller).
	always_ff @(posedge clk) begin
		sdram_reinit <= 1'b0;
		sdram_psen <= 1'b0;
		if (reset) begin
			sdram_reinit_pending <= 1'b0;
			sdram_cfg_cl3 <= 1'b0;
			sdram_cfg_capture_extra <= '0;
			ps_busy <= 1'b0;
			ps_position <= '0;
			sdram_psincdec <= 1'b0;
		end else begin
			if (io_write && io_block == 4'h0 && io_addr == 16'h0040) begin
				sdram_cfg_cl3 <= dbus_dat_w[0];
				sdram_cfg_capture_extra <= dbus_dat_w[2:1];
				if (dbus_dat_w[31]) sdram_reinit_pending <= 1'b1;
			end
			// No request is registered in A_IDLE (a new one reaches the
			// controller the next cycle, and waits for the initialization).
			if (sdram_reinit_pending && arb_state == A_IDLE && sdram_idle && !sdram_reinit) begin
				sdram_reinit <= 1'b1;
				sdram_reinit_pending <= 1'b0;
			end
			if (io_write && io_block == 4'h0 && io_addr == 16'h0044 && !ps_busy) begin
				sdram_psen <= 1'b1;
				sdram_psincdec <= dbus_dat_w[0];
				ps_busy <= 1'b1;
				ps_position <= dbus_dat_w[0] ? ps_position + 1'b1 : ps_position - 1'b1;
			end
			if (sdram_psdone) ps_busy <= 1'b0;
		end
	end

	always_ff @(posedge clk) begin
		if (cpu_rst) core1_run <= 1'b0;
		else if (io_write && io_block == 4'h0 && io_addr == 16'h004C) core1_run <= dbus_dat_w[0] && HAS_CORE1;
	end

	wire cpu_flip = io_write && io_block == 4'h0 && io_addr == 16'h0020 && dbus_dat_w[0];
	always_ff @(posedge clk) begin
		if (reset) begin
			queued <= '0;
			save_size <= '0;
			audio_wr_ptr <= '0;
		end else begin
			if (io_write && io_block == 4'h0) begin
				case (io_addr)
					16'h0030: save_size <= dbus_dat_w[11:0];
					default: begin
						if (io_addr[15:8] == 8'h01) palette[back][io_addr[5:2]] <= dbus_dat_w[23:0];
					end
				endcase
			end
			if (gfx_pal_we) palette[back][gfx_pal_index] <= gfx_pal_rgb;
			// A frame is queued (by the CPU or PRESENT, only with a back
			// buffer free), the oldest one is shown at the start of a video
			// frame (the back buffer stays the same).
			queued <= queued + 2'((cpu_flip || gfx_flip) && !flip_pending) - 2'(frame_start && queued != 0);
			if (audio_push) begin
				audio_fifo[audio_wr_ptr[AUDIO_FIFO_BITS-1:0]] <= audio_push_data;
				audio_wr_ptr <= audio_wr_ptr + 1'b1;
			end
		end
	end

	logic io_read_save, io_read_shared, io_read_p8;
	always_ff @(posedge clk) begin
		io_ack <= io_access;
		io_read_save <= io_block == 4'h2;
		io_read_shared <= io_block == 4'h3;
		io_read_p8 <= io_block == 4'h4;
		if (io_access && io_block == 4'h0) begin
			case (io_addr)
				16'h0000: io_rdata <= 32'h4742_3850; // "P8BG"
				16'h0004: io_rdata <= CLOCK_HZ;
				16'h0008: begin
					io_rdata <= cycle_counter[31:0];
					cycle_hi_latch <= cycle_counter[63:32];
				end
				16'h000C: io_rdata <= cycle_hi_latch;
				16'h0010: io_rdata <= {20'b0, buttons};
				16'h0014: io_rdata <= {31'b0, focus};
				16'h0018: io_rdata <= {8'b0, cart_size};
				16'h001C: io_rdata <= frame_counter;
				16'h0020: io_rdata <= {28'b0, queued, 1'b0, flip_pending};
				16'h0024: io_rdata <= 32'(audio_count);
				16'h0030: io_rdata <= {20'b0, save_size};
				16'h0040: io_rdata <= {1'b0, sdram_ready && !sdram_reinit_pending && !sdram_reinit, 27'b0,
					sdram_cfg_capture_extra, sdram_cfg_cl3};
				16'h0044: io_rdata <= {ps_position, 15'b0, ps_busy};
				16'h0048: io_rdata <= 32'd0;  // CPU number
				16'h004C: io_rdata <= {HAS_CORE1, 30'b0, core1_run};
				16'h0050: io_rdata <= audio_underruns;
				16'h0064: io_rdata <= {GFX != 0, 30'b0, gfx_busy};
				16'h0068: io_rdata <= gfx_present_waits;
				16'h006C: io_rdata <= gfx_presents;
				default: io_rdata <= '0;
			endcase
		end
	end

	// Audio core I/O: identification, clock, cycle counter, status, audio FIFO,
	// shared RAM.
	logic [31:0] io1_rdata;
	logic [31:0] cycle1_hi_latch;
	logic        io1_read_shared;

	always_ff @(posedge clk) begin
		if (io1_write && io1_block == 4'h3) begin
			for (int i = 0; i < 4; i++) begin
				if (dbus1_sel[i]) shared_ram[dbus1_adr[10:0]][i*8 +: 8] <= dbus1_dat_w[i*8 +: 8];
			end
		end
		shared1_q <= shared_ram[dbus1_adr[10:0]];
	end

	always_ff @(posedge clk) begin
		io1_ack <= dbus1_io && !io1_ack;
		io1_read_shared <= io1_block == 4'h3;
		if (io1_access && io1_block == 4'h0) begin
			case (io1_addr)
				16'h0000: io1_rdata <= 32'h4742_3850; // "P8BG"
				16'h0004: io1_rdata <= CLOCK_HZ;
				16'h0008: begin
					io1_rdata <= cycle_counter[31:0];
					cycle1_hi_latch <= cycle_counter[63:32];
				end
				16'h000C: io1_rdata <= cycle1_hi_latch;
				16'h0014: io1_rdata <= {31'b0, focus};
				16'h0024: io1_rdata <= 32'(audio_count);
				16'h0048: io1_rdata <= 32'd1;  // CPU number
				16'h0050: io1_rdata <= audio_underruns;
				default: io1_rdata <= '0;
			endcase
		end
	end

`ifdef VERILATOR
`ifdef TRACE_VIDEO
	always_ff @(posedge clk) begin
		if (frame_start) $display("[video] frame_start front %0d queued %0d back %0d", front, queued, back);
		if (cpu_flip) $display("[video] cpu flip queued %0d back %0d", queued, back);
		if (gfx_flip) $display("[video] gfx flip queued %0d back %0d", queued, back);
		if (fb_cpu_we && fb_cpu_addr == 0) $display("[video] cpu fb write back %0d", back);
		if (gfx_fb_we && gfx_fb_addr == 0) $display("[video] gfx copy start back %0d front %0d queued %0d", back, front, queued);
	end
`endif
	always_ff @(posedge clk) begin
		if (console_write) $write("%c", dbus_dat_w[7:0]);
		if (sim_exit_write) begin
			$display("[sim] exit code %0d at cycle %0d", dbus_dat_w, cycle_counter);
			$finish;
		end
	end
`endif

	////////////////////////////////////////////////////////////////////////
	// Data bus response
	////////////////////////////////////////////////////////////////////////

	always_comb begin
		dbus_ack = 1'b0;
		dbus_dat_r = 32'h0;
		if (arb_master == M_DBUS && (sd_read_ack || sd_write_ack)) begin
			dbus_ack = 1'b1;
			dbus_dat_r = sd_rd_data;
		end else if (bram_d_ack) begin
			dbus_ack = 1'b1;
			dbus_dat_r = bram_d_q;
		end else if (io_ack) begin
			dbus_ack = 1'b1;
			dbus_dat_r = io_read_p8 ? bram_d_q : io_read_shared ? shared0_q : io_read_save ? save_cpu_q : io_rdata;
		end
	end

	always_comb begin
		dbus1_ack = 1'b0;
		dbus1_dat_r = 32'h0;
		if (arb_master == M_DBUS1 && (sd_read_ack || sd_write_ack)) begin
			dbus1_ack = 1'b1;
			dbus1_dat_r = sd_rd_data;
		end else if (io1_ack) begin
			dbus1_ack = 1'b1;
			dbus1_dat_r = io1_read_shared ? shared1_q : io1_rdata;
		end
	end

	assign ibus1_ack = arb_master == M_IBUS1 && sd_read_ack;
	assign ibus1_dat_r = sd_rd_data;

	always_comb begin
		ibus_ack = 1'b0;
		ibus_dat_r = 32'h0;
		if (arb_master == M_IBUS && sd_read_ack) begin
			ibus_ack = 1'b1;
			ibus_dat_r = sd_rd_data;
		end else if (bram_i_ack) begin
			ibus_ack = 1'b1;
			ibus_dat_r = bram_i_q;
		end
	end

	////////////////////////////////////////////////////////////////////////
	// Video output
	////////////////////////////////////////////////////////////////////////
	//
	// Each frame: 128 lines of 128 pixels (1 per clock) followed by an
	// hblank, then vblank for the rest of the frame.

	localparam int H_TOTAL = 128 + 32;
	logic [7:0] vid_x;
	logic [7:0] vid_y;
	/// Rotation of the current frame (changes between frames only).
	logic [1:0] vid_rotation;

	always_ff @(posedge clk) begin
		if (reset) begin
			frame_timer <= '0;
			front <= '0;
			frame_counter <= '0;
			vid_x <= '0;
			vid_y <= 8'd128;
			vid_rotation <= '0;
		end else begin
			frame_timer <= (frame_timer == FRAME_CLOCKS - 1) ? '0 : frame_timer + 1'b1;
			if (frame_start) begin
				if (queued != 0) front <= front == 2'd2 ? 2'd0 : front + 1'b1;
				vid_rotation <= rotation;
				frame_counter <= frame_counter + 1'b1;
				vid_x <= '0;
				vid_y <= '0;
			end else if (vid_y < 8'd128) begin
				if (vid_x == H_TOTAL - 1) begin
					vid_x <= '0;
					vid_y <= vid_y + 1'b1;
				end else begin
					vid_x <= vid_x + 1'b1;
				end
			end
		end
	end

	// Pipeline: framebuffer read, palette lookup.
	logic [31:0] fb_q;
	logic        s1_active, s2_active;
	logic        s1_hblank, s2_hblank;
	logic        s1_vblank, s2_vblank;
	logic [2:0]  s1_x;
	wire active = vid_y < 8'd128 && vid_x < 8'd128;
	// PICO-8 pixel shown at (vid_x, vid_y). Rotated, each output pixel is in
	// a different framebuffer word (a column of the PICO-8 screen).
	logic [6:0] src_x, src_y;
	always_comb begin
		case (vid_rotation)
			2'd1: begin  // Clockwise: the top row of the image on the right.
				src_x = vid_y[6:0];
				src_y = ~vid_x[6:0];
			end
			2'd2: begin  // Counterclockwise: the top row on the left.
				src_x = ~vid_y[6:0];
				src_y = vid_x[6:0];
			end
			default: begin
				src_x = vid_x[6:0];
				src_y = vid_y[6:0];
			end
		endcase
	end
	always_ff @(posedge clk) begin
		fb_q <= framebuffer[{front, src_y, src_x[6:3]}];
		s1_active <= active;
		s1_hblank <= vid_y < 8'd128 && vid_x >= 8'd128;
		s1_vblank <= vid_y >= 8'd128;
		s1_x <= src_x[2:0];

		s2_active <= s1_active;
		s2_hblank <= s1_hblank;
		s2_vblank <= s1_vblank;
		{pixel_r, pixel_g, pixel_b} <= palette[front][fb_q[s1_x*4 +: 4]];
	end
	assign pixel_valid = s2_active;
	assign hblank = s2_hblank;
	assign vblank = s2_vblank;

	////////////////////////////////////////////////////////////////////////
	// Audio output
	////////////////////////////////////////////////////////////////////////

	logic [31:0] audio_acc;
	logic [15:0] audio_sample;
	always_ff @(posedge clk) begin
		if (reset) begin
			audio_acc <= '0;
			audio_rd_ptr <= '0;
			audio_sample <= '0;
			audio_underruns <= '0;
		end else begin
			if (audio_acc + AUDIO_HZ >= CLOCK_HZ) begin
				audio_acc <= audio_acc + AUDIO_HZ - CLOCK_HZ;
				if (audio_count != 0) begin
					audio_sample <= audio_fifo[audio_rd_ptr[AUDIO_FIFO_BITS-1:0]];
					audio_rd_ptr <= audio_rd_ptr + 1'b1;
				end else if (focus && !cpu_rst) begin
					audio_underruns <= audio_underruns + 1'b1;
				end
			end else begin
				audio_acc <= audio_acc + AUDIO_HZ;
			end
			if (!focus || cpu_reset) audio_sample <= '0;
		end
	end
	assign audio_l = audio_sample;
	assign audio_r = audio_sample;

endmodule
