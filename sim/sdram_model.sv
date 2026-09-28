//
// Behavioral model of a 16-bit SDR SDRAM (32 MiB), for simulation.
//
// Commands are sampled on the rising edge of `clk` (the controller's outputs,
// registered on the previous edge). Read data is driven CL - 1 edges after
// the READ edge (valid on the next one), so a controller capturing on the
// CL + 1'th edge after it registers READ on the pins gets it, as with the real
// part and the forwarded clock. The CAS latency (2 or 3) is set by the mode
// register.
//
// Supports what pico8_sdram uses: burst length 8 reads (with auto precharge
// and read interruption), single location writes, byte masks. Row/bank state
// is checked.
//
module sdram_model (
	input  logic        clk,
	input  logic [15:0] dq_in,     // from the controller
	output logic [15:0] dq_out,    // to the controller
	input  logic [12:0] a,
	input  logic [1:0]  ba,
	input  logic [1:0]  dqm,
	input  logic        cs_n,
	input  logic        ras_n,
	input  logic        cas_n,
	input  logic        we_n
);
	// Linear halfword index: {bank, row, column}
	logic [15:0] mem [0:(1 << 24) - 1] /* verilator public */;

	logic [12:0] open_row [0:3];
	logic        row_open [0:3];

	logic [3:0]  burst_left;
	logic [1:0]  burst_bank;
	logic [12:0] burst_row;
	logic [8:0]  burst_col;
	logic        burst_ap;
	logic        mode_set;
	logic        cl3;
	// CL3: a READ starts its burst one edge later.
	logic        read_delayed;
	logic [1:0]  delayed_bank;
	logic [12:0] delayed_row;
	logic [8:0]  delayed_col;
	logic        delayed_ap;

	wire [2:0] cmd = {ras_n, cas_n, we_n};

	// Timing checks, in cycles (at 90.9 MHz, 11 ns): tRCD, tRP 20 ns, tRAS 42 ns,
	// tWR 2 clocks, tRC / tRFC 63 ns.
	localparam int T_RCD = 2, T_RP = 2, T_RAS = 4, T_WR = 2, T_RC = 6;
	longint now = 0;
	longint t_act [0:3];
	longint t_pre [0:3];
	longint t_wr [0:3];
	longint t_ref = -100;
	always_ff @(posedge clk) now <= now + 1;
	initial for (int i = 0; i < 4; i++) begin t_act[i] = -100; t_pre[i] = -100; t_wr[i] = -100; end
	localparam logic [2:0] CMD_NOP = 3'b111, CMD_ACTIVE = 3'b011, CMD_READ = 3'b101,
		CMD_WRITE = 3'b100, CMD_TERMINATE = 3'b110, CMD_PRECHARGE = 3'b010,
		CMD_REFRESH = 3'b001, CMD_MODE = 3'b000;

	function automatic int idx(logic [1:0] b, logic [12:0] r, logic [8:0] c);
		return {b, r, c};
	endfunction

	initial begin
		for (int i = 0; i < 4; i++) row_open[i] = 1'b0;
		burst_left = 0;
		mode_set = 1'b0;
		cl3 = 1'b0;
		read_delayed = 1'b0;
	end

	always_ff @(posedge clk) begin
		// Output the current read burst.
		read_delayed <= 1'b0;
		if (burst_left != 0) begin
			dq_out <= mem[idx(burst_bank, burst_row, burst_col)];
			burst_col <= {burst_col[8:3], burst_col[2:0] + 3'd1};
			burst_left <= burst_left - 1'b1;
			if (burst_left == 1 && burst_ap) row_open[burst_bank] <= 1'b0;
		end else begin
			dq_out <= 16'hXXXX;
		end
		// (After the burst output, so a delayed READ chained to the end of a
		// burst replaces it.)
		if (read_delayed) begin
			burst_left <= 4'd8;
			burst_bank <= delayed_bank;
			burst_row <= delayed_row;
			burst_col <= delayed_col;
			burst_ap <= delayed_ap;
		end

		if (!cs_n) begin
			unique case (cmd)
				CMD_ACTIVE: begin
					if (row_open[ba]) $error("[sdram] ACTIVE on open bank %0d", ba);
					if (now - t_pre[ba] < T_RP) $error("[sdram] tRP violated (bank %0d)", ba);
					if (now - t_act[ba] < T_RC) $error("[sdram] tRC violated (bank %0d)", ba);
					if (now - t_ref < T_RC) $error("[sdram] tRFC violated");
					t_act[ba] <= now;
					row_open[ba] <= 1'b1;
					open_row[ba] <= a;
				end
				CMD_READ: begin
					if (!row_open[ba]) $error("[sdram] READ on closed bank %0d", ba);
					if (now - t_act[ba] < T_RCD) $error("[sdram] tRCD violated (read, bank %0d)", ba);
					if (!mode_set) $error("[sdram] READ before mode set");
					if (cl3) begin
						// CL3: first beat driven two edges later.
						read_delayed <= 1'b1;
						delayed_bank <= ba;
						delayed_row <= open_row[ba];
						delayed_col <= a[8:0];
						delayed_ap <= a[10];
					end else begin
						// CL2: first beat driven on the next edge.
						burst_left <= 4'd8;
						burst_bank <= ba;
						burst_row <= open_row[ba];
						burst_col <= a[8:0];
						burst_ap <= a[10];
					end
				end
				CMD_WRITE: begin
					if (!row_open[ba]) $error("[sdram] WRITE on closed bank %0d", ba);
					if (now - t_act[ba] < T_RCD) $error("[sdram] tRCD violated (write, bank %0d)", ba);
					if (burst_left > 1) $error("[sdram] WRITE during a read burst (bus contention)");
					t_wr[ba] <= now;
					if (!dqm[0]) mem[idx(ba, open_row[ba], a[8:0])][7:0] <= dq_in[7:0];
					if (!dqm[1]) mem[idx(ba, open_row[ba], a[8:0])][15:8] <= dq_in[15:8];
					if (a[10]) row_open[ba] <= 1'b0;
					burst_left <= 0; // a write interrupts a read burst
				end
				CMD_PRECHARGE: begin
					for (int i = 0; i < 4; i++) begin
						if ((a[10] || ba == 2'(i)) && row_open[i]) begin
							if (now - t_act[i] < T_RAS) $error("[sdram] tRAS violated (bank %0d)", i);
							if (now - t_wr[i] <= T_WR) $error("[sdram] tWR violated (bank %0d)", i);
						end
						if (a[10] || ba == 2'(i)) t_pre[i] <= now;
					end
					if (a[10]) for (int i = 0; i < 4; i++) row_open[i] <= 1'b0;
					else row_open[ba] <= 1'b0;
				end
				CMD_REFRESH: begin
					for (int i = 0; i < 4; i++) if (now - t_pre[i] < T_RP) $error("[sdram] tRP violated before REFRESH");
					if (now - t_ref < T_RC) $error("[sdram] tRFC violated (refresh)");
					t_ref <= now;
					for (int i = 0; i < 4; i++) if (row_open[i]) $error("[sdram] REFRESH with open bank %0d", i);
				end
				CMD_MODE: begin
					mode_set <= 1'b1;
					cl3 <= a[6:4] == 3'd3;
					if ((a[6:4] != 3'd2 && a[6:4] != 3'd3) || a[2:0] != 3'b011 || a[9] != 1'b1)
						$error("[sdram] unexpected mode %h", a);
				end
				default: ;
			endcase
		end
	end
endmodule
