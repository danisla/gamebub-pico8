//
// SDRAM controller for the PICO-8 core.
//
// A single port controller for a 16-bit SDR SDRAM (32 MiB: 4 banks, 13 bit
// rows, 9 bit columns), serving 32-bit word writes (with byte masks) and
// 8 word (32 byte) line reads for the CPU caches.
//
// * Mode: burst length 8, sequential, CAS latency 2, single location writes.
// * Open page policy: each bank keeps its last row open (until a different row
//   is needed, or a refresh). The CPU's data cache is write-through, so most
//   accesses are word writes, which take 2 cycles when their row is open.
// * A line read is two READ commands (columns c and c+8), giving 16
//   consecutive halfwords.
// * A word read (non-line, host only) is one READ; the remaining beats are
//   discarded.
// * A word write is two WRITE commands.
//
// The command/address/data outputs are registered (packed into the IOBs, see
// pico8.xdc). The SDRAM clock is forwarded from a phase shifted copy of `clk`
// (as in the Game Bub SNES core), and read data is captured 3 cycles after a
// READ command is registered on the pins (CL2).
//
module pico8_sdram #(
	parameter int CLOCK_HZ = 100_000_000
) (
	input  logic        clk,
	input  logic        clk_out,   // clk, phase shifted, forwarded to the SDRAM
	input  logic        reset,

	// Request (held until req_ready)
	input  logic        req_valid,
	output logic        req_ready,
	input  logic        req_write,
	input  logic        req_line,  // read 8 words starting at req_addr (line aligned)
	input  logic [24:2] req_addr,  // word address
	input  logic [31:0] req_wdata,
	input  logic [3:0]  req_wsel,

	// Read data (1 word for a word read, 8 for a line read)
	output logic        rd_valid,
	output logic [31:0] rd_data,
	output logic        rd_last,

	output logic        init_done,

	// SDRAM
	input  logic [15:0] SDRAM_DQ_IN,
	output logic [15:0] SDRAM_DQ_OUT,
	output logic        SDRAM_DQ_OE = 1'b0,
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

	localparam real CLOCK_NS = 1.0e9 / CLOCK_HZ;
	function automatic int cycles(real ns);
		return int'($ceil(ns / CLOCK_NS));
	endfunction

	// Timing (typical -6/-7 SDR SDRAM, with margin)
	localparam int T_INIT = cycles(200_000.0);  // power up pause
	localparam int T_RP   = cycles(20.0);       // precharge
	localparam int T_RC   = cycles(66.0);       // active to active, refresh (tRFC)
	localparam int T_RCD  = cycles(20.0);       // active to read/write
	localparam int T_RAS  = cycles(45.0);       // active to precharge
	localparam int T_WR   = cycles(15.0) + 1;   // write recovery (last write to precharge)
	localparam int T_MRD  = 3;                  // mode register set
	localparam int T_REFI = int'(7_500.0 / CLOCK_NS); // refresh interval (8192 rows / 64 ms, less margin)
	localparam int CAS_LATENCY = 2;
	// Cycles after the READ command is on the pins that the first beat is in rbuf.
	localparam int CAPTURE = CAS_LATENCY + 1;

	// Burst length 8, sequential, CL2, single location write.
	localparam logic [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'(CAS_LATENCY), 1'b0, 3'b011};

	localparam logic [2:0] CMD_NOP       = 3'b111;
	localparam logic [2:0] CMD_ACTIVE    = 3'b011;
	localparam logic [2:0] CMD_READ      = 3'b101;
	localparam logic [2:0] CMD_WRITE     = 3'b100;
	localparam logic [2:0] CMD_PRECHARGE = 3'b010;
	localparam logic [2:0] CMD_REFRESH   = 3'b001;
	localparam logic [2:0] CMD_MODE      = 3'b000;

	typedef enum logic [3:0] {
		S_INIT_WAIT,
		S_INIT_PRECHARGE,
		S_INIT_REFRESH,
		S_INIT_MODE,
		S_IDLE,
		S_PRECHARGE,    // wait for the bank to be precharged, then activate
		S_ACTIVE,       // wait for the row to be active, then read/write
		S_READ2,        // second READ of a line
		S_READ_WAIT,    // wait for the read burst (on the pins) to end
		S_WRITE2,
		S_REFRESH_PRE,  // precharging all banks for a refresh
		S_WAIT
	} state_t;

	state_t state;
	logic [17:0] timer;       // wait counter (cycles left in the current state)
	logic [3:0]  init_count;  // refreshes left during init

	// Latched request
	logic        r_write;
	logic        r_line;
	logic [1:0]  r_bank;
	logic [12:0] r_row;
	logic [8:0]  r_col;
	logic [31:0] r_wdata;
	logic [3:0]  r_wsel;

	// Bank state
	logic        bank_open [0:3];
	logic [12:0] bank_row [0:3];
	/// Cycles until the bank may be precharged (tRAS after ACTIVE, tWR after WRITE).
	logic [3:0]  bank_hold [0:3];

	// Refresh scheduling
	logic [15:0] refresh_timer;
	logic        refresh_pending;

	// Registered outputs (IOB). Initialized to NOP (the FPGA registers start
	// with these values after configuration, before reset).
	logic [2:0]  cmd = 3'b111;
	assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
	assign SDRAM_nCS = 1'b0;
	assign SDRAM_CKE = 1'b1;

	// Read beat tracking (see beat_pipe below).
	localparam int PIPE = CAPTURE;
	logic [PIPE-1:0] beat_pipe;
	logic            beat_start;    // a READ is issued this cycle
	logic [3:0]      beats_left;    // kept beats left to issue for the current read
	logic            reading;       // read data may still be on the bus
	assign reading = beats_left != 0 || beat_pipe != 0;

	wire [1:0]  req_bank = req_addr[24:23];
	wire [12:0] req_row = req_addr[22:10];
	wire        req_hit = bank_open[req_bank] && bank_row[req_bank] == req_row;

	logic any_bank_held;
	always_comb begin
		any_bank_held = 1'b0;
		for (int b = 0; b < 4; b++) if (bank_open[b] && bank_hold[b] != 0) any_bank_held = 1'b1;
	end

	// Requests are accepted in idle. A write must wait for read data to be off
	// the bus (DQ turnaround).
	assign req_ready = state == S_IDLE && init_done && !refresh_pending && !(req_write && reading);

	always_ff @(posedge clk) begin
		beat_start <= 1'b0;
		if (reset) begin
			state <= S_INIT_WAIT;
			timer <= 18'(T_INIT);
			init_done <= 1'b0;
			cmd <= CMD_NOP;
			SDRAM_DQ_OE <= 1'b0;
			SDRAM_DQM <= 2'b11;
			refresh_timer <= 16'(T_REFI);
			refresh_pending <= 1'b0;
			for (int b = 0; b < 4; b++) begin
				bank_open[b] <= 1'b0;
				bank_hold[b] <= '0;
			end
		end else begin
			cmd <= CMD_NOP;
			SDRAM_DQ_OE <= 1'b0;

			if (timer != 0) timer <= timer - 1'b1;
			for (int b = 0; b < 4; b++) if (bank_hold[b] != 0) bank_hold[b] <= bank_hold[b] - 1'b1;

			if (refresh_timer == 0) begin
				refresh_timer <= 16'(T_REFI);
				refresh_pending <= 1'b1;
			end else begin
				refresh_timer <= refresh_timer - 1'b1;
			end

			unique case (state)
				S_INIT_WAIT: if (timer == 0) begin
					cmd <= CMD_PRECHARGE;
					SDRAM_A <= 13'b0_0100_0000_0000; // all banks
					timer <= 18'(T_RP);
					init_count <= 4'd8;
					state <= S_INIT_PRECHARGE;
				end
				S_INIT_PRECHARGE: if (timer == 0) begin
					state <= S_INIT_REFRESH;
				end
				S_INIT_REFRESH: if (timer == 0) begin
					if (init_count == 0) begin
						cmd <= CMD_MODE;
						SDRAM_BA <= 2'b00;
						SDRAM_A <= MODE;
						timer <= 18'(T_MRD);
						state <= S_INIT_MODE;
					end else begin
						cmd <= CMD_REFRESH;
						timer <= 18'(T_RC);
						init_count <= init_count - 1'b1;
					end
				end
				S_INIT_MODE: if (timer == 0) begin
					init_done <= 1'b1;
					SDRAM_DQM <= 2'b00;
					state <= S_IDLE;
				end

				S_IDLE: begin
					if (refresh_pending && init_done) begin
						// Precharge all (open) banks, then refresh.
						if (!reading && !any_bank_held) begin
							cmd <= CMD_PRECHARGE;
							SDRAM_A <= 13'b0_0100_0000_0000; // all banks
							for (int b = 0; b < 4; b++) bank_open[b] <= 1'b0;
							timer <= 18'(T_RP - 1);
							state <= S_REFRESH_PRE;
						end
					end else if (req_valid && req_ready) begin
						r_write <= req_write;
						r_line <= req_line && !req_write;
						// Word address: {bank, row, column[8:1]}
						r_bank <= req_bank;
						r_row <= req_row;
						r_col <= {req_addr[9:2], 1'b0};
						r_wdata <= req_wdata;
						r_wsel <= req_wsel;
						SDRAM_BA <= req_bank;
						if (req_hit) begin
							// Row open: read/write now.
							if (req_write) begin
								cmd <= CMD_WRITE;
								SDRAM_A <= {4'b0000, req_addr[9:2], 1'b0};
								SDRAM_DQ_OUT <= req_wdata[15:0];
								SDRAM_DQ_OE <= 1'b1;
								SDRAM_DQM <= ~req_wsel[1:0];
								state <= S_WRITE2;
							end else begin
								cmd <= CMD_READ;
								SDRAM_A <= {4'b0000, req_addr[9:2], 1'b0};
								SDRAM_DQM <= 2'b00;
								beat_start <= 1'b1;
								timer <= 18'd7;
								state <= (req_line && !req_write) ? S_READ2 : S_READ_WAIT;
							end
						end else if (bank_open[req_bank]) begin
							// Another row is open: precharge it first.
							state <= S_PRECHARGE;
							timer <= '0;
						end else begin
							cmd <= CMD_ACTIVE;
							SDRAM_A <= req_row;
							bank_open[req_bank] <= 1'b1;
							bank_row[req_bank] <= req_row;
							bank_hold[req_bank] <= 4'(T_RAS);
							timer <= 18'(T_RCD - 1);
							state <= S_ACTIVE;
						end
					end
				end

				S_PRECHARGE: begin
					if (bank_open[r_bank]) begin
						// Wait for tRAS/tWR, then precharge.
						if (bank_hold[r_bank] == 0) begin
							cmd <= CMD_PRECHARGE;
							SDRAM_A <= 13'b0;  // this bank only
							bank_open[r_bank] <= 1'b0;
							timer <= 18'(T_RP - 1);
						end
					end else if (timer == 0) begin
						cmd <= CMD_ACTIVE;
						SDRAM_A <= r_row;
						bank_open[r_bank] <= 1'b1;
						bank_row[r_bank] <= r_row;
						bank_hold[r_bank] <= 4'(T_RAS);
						timer <= 18'(T_RCD - 1);
						state <= S_ACTIVE;
					end
				end

				S_ACTIVE: if (timer == 0) begin
					if (r_write) begin
						cmd <= CMD_WRITE;
						SDRAM_A <= {4'b0000, r_col};
						SDRAM_DQ_OUT <= r_wdata[15:0];
						SDRAM_DQ_OE <= 1'b1;
						SDRAM_DQM <= ~r_wsel[1:0];
						state <= S_WRITE2;
					end else begin
						cmd <= CMD_READ;
						SDRAM_A <= {4'b0000, r_col};
						SDRAM_DQM <= 2'b00;
						beat_start <= 1'b1;
						timer <= 18'd7;
						state <= r_line ? S_READ2 : S_READ_WAIT;
					end
				end

				S_READ2: if (timer == 0) begin
					// Second READ right after the first burst of 8.
					cmd <= CMD_READ;
					SDRAM_A <= {4'b0000, r_col + 9'd8};
					timer <= 18'd7;
					state <= S_READ_WAIT;
				end

				S_READ_WAIT: if (timer == 0) begin
					// The last burst has left the pins. (A READ may follow
					// right away; writes wait for the data in `req_ready`.)
					state <= S_IDLE;
				end

				S_WRITE2: begin
					cmd <= CMD_WRITE;
					SDRAM_A <= {4'b0000, r_col + 9'd1};
					SDRAM_DQ_OUT <= r_wdata[31:16];
					SDRAM_DQ_OE <= 1'b1;
					SDRAM_DQM <= ~r_wsel[3:2];
					if (bank_hold[r_bank] < 4'(T_WR)) bank_hold[r_bank] <= 4'(T_WR);
					state <= S_IDLE;
				end

				S_REFRESH_PRE: if (timer == 0) begin
					cmd <= CMD_REFRESH;
					refresh_pending <= 1'b0;
					timer <= 18'(T_RC - 1);
					state <= S_WAIT;
				end

				S_WAIT: if (timer == 0) begin
					state <= S_IDLE;
				end

				default: state <= S_IDLE;
			endcase

			// DQM is low (reads enabled) except for the byte masks of writes.
			if (state != S_WRITE2
					&& !(state == S_IDLE && req_valid && req_ready && req_hit && req_write)
					&& !(state == S_ACTIVE && timer == 0 && r_write)) begin
				SDRAM_DQM <= init_done ? 2'b00 : 2'b11;
			end
		end
	end

	// Beats to keep: 16 for a line read, 2 for a word read. `beat_start` is
	// high the cycle the (first) READ is on the pins, so bit k of beat_pipe is
	// set k + 1 cycles after a beat's READ/burst cycle on the pins.
	always_ff @(posedge clk) begin
		if (reset) begin
			beats_left <= '0;
			beat_pipe <= '0;
		end else begin
			if (beat_start) beats_left <= r_line ? 4'd15 : 4'd1;
			else if (beats_left != 0) beats_left <= beats_left - 1'b1;
			beat_pipe <= {beat_pipe[PIPE-2:0], beat_start || beats_left != 0};
		end
	end

	// Read data capture (in the IOB)
	(* IOB = "TRUE" *) logic [15:0] rbuf;
	always_ff @(posedge clk) rbuf <= SDRAM_DQ_IN;

	// The beat is in rbuf CAPTURE cycles after its cycle on the pins.
	wire beat_valid = beat_pipe[CAPTURE-1];

	logic        half;       // low halfword received
	logic [15:0] low;
	logic [2:0]  word_count;
	logic        cur_line;   // the read being received is a line read
	always_ff @(posedge clk) begin
		rd_valid <= 1'b0;
		rd_last <= 1'b0;
		if (reset) begin
			half <= 1'b0;
			word_count <= '0;
		end else if (beat_valid) begin
			half <= !half;
			if (!half) begin
				low <= rbuf;
			end else begin
				rd_valid <= 1'b1;
				rd_data <= {rbuf, low};
				rd_last <= !cur_line || word_count == 3'd7;
				word_count <= cur_line ? word_count + 1'b1 : 3'd0;
			end
		end
	end
	always_ff @(posedge clk) if (beat_start) cur_line <= r_line;

	// Forward clk_out to the SDRAM.
`ifdef VERILATOR
	assign SDRAM_CLK = clk_out;
`else
	ODDR #(
		.DDR_CLK_EDGE("SAME_EDGE"),
		.INIT(1'b0),
		.SRTYPE("SYNC")
	) sdramclk_ddr (
		.Q(SDRAM_CLK),
		.C(clk_out),
		.CE(1'b1),
		.D1(1'b1),
		.D2(1'b0),
		.R(1'b0),
		.S(1'b0)
	);
`endif

endmodule
