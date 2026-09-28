//
// PICO-8 SoC for Game Bub.
//
// A VexRiscv CPU (RV32IM, 4 KiB I/D caches) runs fake-08 (a PICO-8 emulator)
// from SDRAM. The CPU renders each PICO-8 frame (128x128, 4 bits per pixel,
// plus a 16 color display palette) into a framebuffer here, which is scanned
// out to the Game Bub framework. Audio samples are pushed into a FIFO, played
// at a fixed rate.
//
// CPU memory map:
//   0x0000_0000  SDRAM (32 MiB, cached). The program is loaded at 0 by the
//                host, the cart at CART_BASE.
//   0x1000_0000  Block RAM (64 KiB, cached): stack and fast data.
//   0xF000_0000  I/O registers (uncached)
//   0xF001_0000  Framebuffer back buffer (8 KiB, write only)
//   0xF002_0000  Save buffer (4 KiB)
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
	parameter int CPU_VEXII = 1
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

	logic cpu_rst;
	always_ff @(posedge clk) cpu_rst <= reset || cpu_reset || !sdram_ready;

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

	// Unmapped accesses: bus error (ack'd after a cycle).
	logic ibus_err_r, dbus_err_r;
	always_ff @(posedge clk) begin
		ibus_err_r <= ibus_req && !ibus_sdram && !ibus_bram && !ibus_err_r;
		dbus_err_r <= dbus_req && !dbus_sdram && !dbus_bram && !dbus_io && !dbus_err_r;
	end
	assign ibus_err = ibus_err_r;
	assign dbus_err = dbus_err_r;

	////////////////////////////////////////////////////////////////////////
	// SDRAM (shared by the instruction bus, data bus and host)
	////////////////////////////////////////////////////////////////////////

	logic        sd_req_valid, sd_req_ready, sd_req_line;
	logic        sd_req_write /* verilator public */;
	logic [24:2] sd_req_addr;
	logic [31:0] sd_req_wdata;
	logic [3:0]  sd_req_wsel;
	logic        sd_rd_valid, sd_rd_last;
	logic [31:0] sd_rd_data;

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
		.*
	);

	typedef enum logic [1:0] { M_DBUS, M_IBUS, M_HOST } master_t;
	typedef enum logic [1:0] { A_IDLE, A_REQUEST, A_READ, A_WRITE_ACK } arb_state_t;
	arb_state_t arb_state /* verilator public */;
	master_t    arb_master /* verilator public */;
	logic       host_done_r;

	// Wishbone incrementing bursts are line reads.
	wire dbus_line = dbus_cti == 3'b010;
	wire ibus_line = ibus_cti == 3'b010;

	always_ff @(posedge clk) begin
		host_done_r <= 1'b0;
		if (reset) begin
			arb_state <= A_IDLE;
			sd_req_valid <= 1'b0;
		end else begin
			unique case (arb_state)
				A_IDLE: begin
					// Priority: data, instruction, host.
					if (dbus_sdram) begin
						arb_master <= M_DBUS;
						sd_req_valid <= 1'b1;
						sd_req_write <= dbus_we;
						sd_req_line <= dbus_line && !dbus_we;
						sd_req_addr <= dbus_adr[22:0];
						sd_req_wdata <= dbus_dat_w;
						sd_req_wsel <= dbus_sel;
						arb_state <= A_REQUEST;
					end else if (ibus_sdram) begin
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
	// Block RAM (64 KiB, dual port: instruction and data bus)
	////////////////////////////////////////////////////////////////////////

	logic [31:0] bram [0:16383];
	logic [31:0] bram_i_q, bram_d_q;
	logic        bram_i_ack, bram_d_ack;

	always_ff @(posedge clk) begin
		bram_i_ack <= ibus_bram && !bram_i_ack;
		bram_i_q <= bram[ibus_adr[13:0]];
	end

	always_ff @(posedge clk) begin
		bram_d_ack <= dbus_bram && !bram_d_ack;
		if (dbus_bram && !bram_d_ack && dbus_we) begin
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
	wire         io_access = dbus_io && !io_ack;
	wire         io_write = io_access && dbus_we;
	wire [15:0]  io_addr = {dbus_adr[13:0], 2'b00};
	wire [3:0]   io_block = dbus_adr[17:14]; // 64 KiB blocks

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
	logic        front;        // front buffer index
	logic        flip_pending;
	logic [23:0] palette [0:1][0:15];

	// Framebuffer: 2 x 2048 words (8 pixels per word, pixel 0 in the low nibble)
	logic [31:0] framebuffer [0:4095];
	wire fb_write = io_write && io_block == 4'h1;
	always_ff @(posedge clk) begin
		if (fb_write) framebuffer[{!front, dbus_adr[10:0]}] <= dbus_dat_w;
	end

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
	wire audio_push = io_write && io_block == 4'h0 && io_addr == 16'h0024 && !audio_count[AUDIO_FIFO_BITS];

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

	always_ff @(posedge clk) begin
		if (reset) begin
			flip_pending <= 1'b0;
			save_size <= '0;
			audio_wr_ptr <= '0;
		end else begin
			if (io_write && io_block == 4'h0) begin
				case (io_addr)
					16'h0020: if (dbus_dat_w[0]) flip_pending <= 1'b1;
					16'h0030: save_size <= dbus_dat_w[11:0];
					default: begin
						if (io_addr[15:8] == 8'h01) palette[!front][io_addr[5:2]] <= dbus_dat_w[23:0];
					end
				endcase
			end
			if (audio_push) begin
				audio_fifo[audio_wr_ptr[AUDIO_FIFO_BITS-1:0]] <= dbus_dat_w[15:0];
				audio_wr_ptr <= audio_wr_ptr + 1'b1;
			end
			if (frame_start && flip_pending) flip_pending <= 1'b0;
		end
	end

	logic io_read_save;
	always_ff @(posedge clk) begin
		io_ack <= dbus_io && !io_ack;
		io_read_save <= io_block == 4'h2;
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
				16'h0020: io_rdata <= {30'b0, front, flip_pending};
				16'h0024: io_rdata <= 32'(audio_count);
				16'h0030: io_rdata <= {20'b0, save_size};
				default: io_rdata <= '0;
			endcase
		end
	end

`ifdef VERILATOR
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
			dbus_dat_r = io_read_save ? save_cpu_q : io_rdata;
		end
	end

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

	always_ff @(posedge clk) begin
		if (reset) begin
			frame_timer <= '0;
			front <= 1'b0;
			frame_counter <= '0;
			vid_x <= '0;
			vid_y <= 8'd128;
		end else begin
			frame_timer <= (frame_timer == FRAME_CLOCKS - 1) ? '0 : frame_timer + 1'b1;
			if (frame_start) begin
				if (flip_pending) front <= !front;
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
	always_ff @(posedge clk) begin
		fb_q <= framebuffer[{front, vid_y[6:0], vid_x[6:3]}];
		s1_active <= active;
		s1_hblank <= vid_y < 8'd128 && vid_x >= 8'd128;
		s1_vblank <= vid_y >= 8'd128;
		s1_x <= vid_x[2:0];

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
		end else begin
			if (audio_acc + AUDIO_HZ >= CLOCK_HZ) begin
				audio_acc <= audio_acc + AUDIO_HZ - CLOCK_HZ;
				if (audio_count != 0) begin
					audio_sample <= audio_fifo[audio_rd_ptr[AUDIO_FIFO_BITS-1:0]];
					audio_rd_ptr <= audio_rd_ptr + 1'b1;
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
