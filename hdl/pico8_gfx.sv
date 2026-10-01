//
// PICO-8 graphics accelerator.
//
// Draws into the PICO-8 RAM (the 64 KiB block RAM, see pico8_soc.sv) from
// commands the CPU pushes into a FIFO, so that drawing runs in parallel with
// the CPU. The CPU does the PICO-8 API's clipping, camera and palette logic
// (sw/gfx.h) and sends commands whose pixels are all on the screen (and, for
// sprites, in the sprite sheet). The SoC holds the CPU's accesses to the
// memory the accelerator uses while it's busy (writes below 0x3100, the
// sprite sheet, map and flags; any access to the screen, 0x6000-0x7FFF), so
// the CPU always sees the memory as if each command ran when it was sent.
//
// Commands (first word: opcode in bits 31:28; the whole command is in the
// FIFO before it runs):
//
//   PAL (1), 3 words: draw palette for SPR.
//     [15:0] transparent colors (bit c: color c is transparent)
//     colors 0-7 (color c in bits 4c+3:4c), colors 8-15
//   SPR (2), 3 words: sprite blit (no color bitmask).
//     [27] flip x, [26] flip y, [13:0] word address of the sprite sheet
//     {h - 1 [30:24], w - 1 [22:16], dst y [14:8], dst x [6:0]}
//     {src y of the first row [14:8], src x of the first column [6:0]}
//     Destination pixel (dst x + i, dst y + j) is source pixel (src x +/- i,
//     src y +/- j) (- when flipped) through the palette, if not transparent.
//   RECT (3), 2 words: fill with a fill pattern (no color bitmask).
//     [27] pattern bits are transparent, [23:20] alt color, [19:16] color,
//     [15:0] fill pattern (PICO-8 fillp: bit 15 - (x & 3) - 4 * (y & 3))
//     {y1 [30:24], y0 [22:16], x1 [14:8], x0 [6:0]} (inclusive)
//   GLYPH (5), 3 words: 8x8 1 bit per pixel bitmap (text), set pixels drawn
//     in one color (not through the palette).
//     [19:16] color, [15:8] y, [7:0] x (signed: the bitmap's top left corner)
//     rows 0-3, rows 4-7 (row r in bits 8r+7:8r, column c in bit c of a row)
//     Only the set pixels have to be on the screen.
//   PRESENT (4), 17 words: copy the screen to the video back buffer, set its
//     display palette and queue it to be shown (the display is triple
//     buffered: up to 2 frames wait to be shown, one per video frame). If
//     no back buffer is free, it waits (in the queue: the CPU goes on).
//     [13:0] word address of the screen
//     16 x display palette RGB888
//
module pico8_gfx #(
	parameter int FIFO_BITS = 9
) (
	input  logic        clk,
	input  logic        reset,

	// Command FIFO
	input  logic        cmd_valid,
	input  logic [31:0] cmd_data,
	output logic        cmd_ready,
	/// Commands queued or running.
	output logic        busy,

	// PICO-8 RAM (block RAM port: read data the cycle after the address)
	output logic        mem_active,
	output logic [13:0] mem_addr,
	output logic        mem_we,
	output logic [31:0] mem_wdata,
	input  logic [31:0] mem_rdata,

	// Video back buffer, its palette and the flip
	output logic        fb_we,
	output logic [10:0] fb_addr,
	output logic [31:0] fb_wdata,
	output logic        pal_we,
	output logic [3:0]  pal_index,
	output logic [23:0] pal_rgb,
	/// No back buffer free (2 frames waiting to be shown)
	input  logic        flip_pending,
	/// Queue the back buffer to be shown
	output logic        flip,
	/// PRESENTs that waited for a free back buffer
	output logic [31:0] present_waits,
	/// PRESENTs done
	output logic [31:0] presents
);

	localparam logic [3:0] OP_PAL = 4'd1, OP_SPR = 4'd2, OP_RECT = 4'd3, OP_PRESENT = 4'd4, OP_GLYPH = 4'd5;
	localparam logic [13:0] SCREEN = 14'h1800;  // 0x6000 / 4

	typedef enum logic [4:0] {
		S_IDLE,
		S_PAL1, S_PAL2,
		S_SPR1, S_SPR2, S_SPR3, S_SPR_A, S_SPR_B, S_SPR_D, S_SPR_W,
		S_RECT1, S_RECT_R, S_RECT_W,
		S_COPY, S_COPY_LAST, S_PALETTE,
		S_GLY1, S_GLY2, S_GLY_R, S_GLY_W
	} state_t;

	////////////////////////////////////////////////////////////////////////
	// Command FIFO (distributed RAM), with the first word in a register
	// (head). For timing, cmd_ready and busy are registered and a little
	// pessimistic: busy may stay set a cycle longer, cmd_ready drops a word
	// early (the CPU can't push on consecutive cycles).
	////////////////////////////////////////////////////////////////////////

	localparam int DEPTH = 1 << FIFO_BITS;
	logic [31:0] fifo [0:DEPTH-1];
	logic [FIFO_BITS:0] wr_ptr, rd_ptr;  // RAM: written at wr_ptr, read into head at rd_ptr
	logic [FIFO_BITS:0] ram_count;      // words in the RAM (not counting head)
	logic [31:0] head;
	logic        head_valid;
	logic        pop;
	logic        ready_q, busy_q;
	wire         push = cmd_valid && cmd_ready;
	wire         ram_empty = ram_count == 0;
	// head is consumed (pop), or empty: load the next word from the RAM.
	wire         load = !ram_empty && (pop || !head_valid);
	state_t      state;

	assign cmd_ready = ready_q;
	assign busy = busy_q;
	always_ff @(posedge clk) begin
		if (push) fifo[wr_ptr[FIFO_BITS-1:0]] <= cmd_data;
		if (load) head <= fifo[rd_ptr[FIFO_BITS-1:0]];
		if (reset) begin
			wr_ptr <= '0;
			rd_ptr <= '0;
			ram_count <= '0;
			head_valid <= 1'b0;
			ready_q <= 1'b0;
			busy_q <= 1'b0;
		end else begin
			if (push) wr_ptr <= wr_ptr + 1'b1;
			if (load) rd_ptr <= rd_ptr + 1'b1;
			ram_count <= ram_count + (FIFO_BITS+1)'(push) - (FIFO_BITS+1)'(load);
			if (load) head_valid <= 1'b1;
			else if (pop) head_valid <= 1'b0;
			ready_q <= ram_count <= (FIFO_BITS+1)'(DEPTH - 2);
			busy_q <= state != S_IDLE || head_valid || !ram_empty || push;
		end
	end

	wire [3:0] head_op = head[31:28];
	// The whole command is in the FIFO (head and the rest in the RAM).
	logic cmd_complete;
	logic [4:0] head_len;
	always_comb begin
		case (head_op)
			OP_PAL, OP_SPR, OP_GLYPH: head_len = 5'd3;
			OP_RECT: head_len = 5'd2;
			OP_PRESENT: head_len = 5'd17;
			default: head_len = 5'd1;
		endcase
		cmd_complete = head_valid && ram_count >= (FIFO_BITS+1)'(head_len - 5'd1);
	end

	////////////////////////////////////////////////////////////////////////
	// Command state
	////////////////////////////////////////////////////////////////////////

	assign mem_active = state != S_IDLE;

	// Draw palette
	logic [3:0]  pal_col [0:15];
	logic [15:0] pal_trans;

	// Command parameters
	logic        fx, fy, pat_trans;
	logic [13:0] base;
	logic [6:0]  dst_x, dst_y, src_x, src_y;
	logic [7:0]  last_x, last_y;  // w - 1, h - 1 (SPR); x1, y1 (RECT)
	logic [3:0]  col0, col1;
	logic [15:0] pattern;

	logic        present_waiting;

	// Iteration: row (j: from 0, SPR; y: RECT) and destination word in the row
	logic [6:0]  j;
	logic [3:0]  wd;
	logic [10:0] copy_i;
	logic        copy_valid;
	logic [10:0] copy_addr;

	////////////////////////////////////////////////////////////////////////
	// SPR datapath
	////////////////////////////////////////////////////////////////////////

	// Destination x range of the current command (x0..x1).
	wire [6:0] spr_x1 = dst_x + last_x[6:0];
	wire [3:0] wd_first = dst_x[6:3];
	wire [3:0] wd_last = spr_x1[6:3];
	// Source pixel of destination pixel 0 of the word, and the source words
	// (spr_addrs):
	//   no flip: sx(p) = wd * 8 + p + (src_x - dst_x): lowest is p = 0
	//   flip:    sx(p) = src_x + dst_x - wd * 8 - p: lowest is p = 7
	// Source words modulo the row: out of row words are for masked pixels.

	// For timing, the addresses of a destination word are computed the state
	// before they're used (S_SPR3 for the first word, S_SPR_W for the next).
	logic [13:0] spr_addr0, spr_addr1, spr_addrd;
	logic [2:0]  spr_shift;
	function automatic logic [44:0] spr_addrs(logic [3:0] w, logic [6:0] r);
		logic signed [9:0] lo;
		logic [6:0] yy, ys;
		logic [13:0] row;
		lo = fx ? $signed({3'b0, src_x}) + $signed({3'b0, dst_x}) - $signed({3'b0, w, 3'b0}) - 10'sd7
		        : $signed({3'b0, w, 3'b0}) + $signed({3'b0, src_x}) - $signed({3'b0, dst_x});
		ys = fy ? src_y - r : src_y + r;
		yy = dst_y + r;
		row = base + {ys, 4'b0};
		return {lo[2:0], row + 14'(lo[6:3]), row + 14'(4'(lo[6:3] + 1'b1)), SCREEN + {yy, 4'b0} + 14'(w)};
	endfunction
	wire [3:0] wd_next = wd != wd_last ? wd + 1'b1 : wd_first;
	wire [6:0] j_next = wd != wd_last ? j : j + 1'b1;

	// Pixel p of the destination word is in the command's x range.
	logic [7:0] x_mask;
	always_comb begin
		for (int p = 0; p < 8; p++) begin
			x_mask[p] = {wd, 3'(p)} >= dst_x && {wd, 3'(p)} <= ((state == S_RECT_R || state == S_RECT_W) ? last_x[6:0] : spr_x1);
		end
	end

	// Source pixels (S_SPR_D: first word read in the last cycle, second word
	// on mem_rdata), mapped through the palette: color and write mask.
	logic [31:0] src_word0_q;
	logic [31:0] spr_col;
	logic [7:0]  spr_wm;
	wire [63:0] src_pair = {mem_rdata, src_word0_q};
	wire [31:0] src_pix = 32'(src_pair >> {spr_shift, 2'b00});

	////////////////////////////////////////////////////////////////////////
	// RECT datapath
	////////////////////////////////////////////////////////////////////////

	// Pattern bits of row y (j), for x & 3 = 0..3: bits 3..0.
	wire [3:0] row_bits = 4'(pattern >> (5'd12 - {j[1:0], 2'b00}));
	logic [31:0] rect_col;
	logic [7:0]  rect_wm;
	always_comb begin
		for (int p = 0; p < 8; p++) begin
			logic alt;
			alt = row_bits[3 - (p & 3)];
			rect_col[p*4 +: 4] = alt ? col1 : col0;
			rect_wm[p] = x_mask[p] && !(alt && pat_trans);
		end
	end
	wire [13:0] rect_word = SCREEN + {j, 4'b0} + wd;
	// All 8 pixels written (&rect_wm, without the comparators: timing): not a
	// partial word at either end of the row, no transparent pattern pixels.
	wire rect_full = (wd != dst_x[6:3] || dst_x[2:0] == 3'd0) && (wd != last_x[6:3] || last_x[2:0] == 3'd7) &&
		!(pat_trans && row_bits != 0);

	////////////////////////////////////////////////////////////////////////
	// GLYPH datapath
	////////////////////////////////////////////////////////////////////////

	logic [63:0] gly_rows;
	logic signed [7:0] gly_x, gly_y;
	logic [2:0]  gly_r;    // row
	logic        gly_w;    // second destination word of the row
	wire [7:0]  gly_bits = gly_rows[{gly_r, 3'b000} +: 8];
	// The row's pixels from the first destination word on: {word 1, word 0}.
	wire [15:0] gly_pixels = {8'b0, gly_bits} << gly_x[2:0];
	wire [7:0]  gly_wm = gly_w ? gly_pixels[15:8] : gly_pixels[7:0];
	wire [7:0]  gly_row_y = gly_y + 8'(gly_r);
	wire [3:0]  gly_word = gly_x[6:3] + 4'(gly_w);
	wire [13:0] gly_addr = SCREEN + {gly_row_y[6:0], 4'b0} + gly_word;
	wire        gly_last = gly_r == 3'd7 && gly_w;

	function automatic logic [31:0] merge(logic [31:0] dst, logic [31:0] src, logic [7:0] wm);
		for (int p = 0; p < 8; p++) merge[p*4 +: 4] = wm[p] ? src[p*4 +: 4] : dst[p*4 +: 4];
	endfunction

	////////////////////////////////////////////////////////////////////////
	// Sequencer
	////////////////////////////////////////////////////////////////////////

	always_comb begin
		pop = 1'b0;
		mem_addr = spr_addrd;
		mem_we = 1'b0;
		mem_wdata = merge(mem_rdata, spr_col, spr_wm);
		case (state)
			// PRESENT waits for a free back buffer (flip_pending counts this
			// PRESENT's flip from 2 cycles after: wait while it's in flight).
			S_IDLE: pop = cmd_complete && !(head_op == OP_PRESENT && (flip_pending || flip));
			S_PAL1, S_PAL2, S_SPR1, S_SPR2, S_RECT1, S_PALETTE, S_GLY1, S_GLY2: pop = 1'b1;
			S_SPR_A: mem_addr = spr_addr0;
			S_SPR_B: mem_addr = spr_addr1;
			S_SPR_D: mem_addr = spr_addrd;
			S_SPR_W: mem_we = 1'b1;
			S_RECT_R: begin
				mem_addr = rect_word;
				// A whole word without transparent pixels: written without a read.
				mem_we = rect_full;
				mem_wdata = rect_col;
			end
			S_RECT_W: begin
				mem_addr = rect_word;
				mem_we = 1'b1;
				mem_wdata = merge(mem_rdata, rect_col, rect_wm);
			end
			S_COPY: mem_addr = base + copy_i;
			S_GLY_R: mem_addr = gly_addr;
			S_GLY_W: begin
				mem_addr = gly_addr;
				mem_we = 1'b1;
				mem_wdata = merge(mem_rdata, {8{col0}}, gly_wm);
			end
			default: ;
		endcase
	end

	assign fb_we = copy_valid;
	assign fb_addr = copy_addr;
	assign fb_wdata = mem_rdata;
	assign pal_we = state == S_PALETTE;
	assign pal_rgb = head[23:0];

	always_ff @(posedge clk) begin
		flip <= 1'b0;
		copy_valid <= 1'b0;
		if (reset) begin
			state <= S_IDLE;
			present_waits <= '0;
			present_waiting <= 1'b0;
			presents <= '0;
			pal_trans <= 16'h0001;
			for (int c = 0; c < 16; c++) pal_col[c] <= 4'(c);
		end else begin
			// Counted once per waiting PRESENT.
			if (state == S_IDLE && cmd_complete && head_op == OP_PRESENT && flip_pending && !flip) begin
				if (!present_waiting) present_waits <= present_waits + 1'b1;
				present_waiting <= 1'b1;
			end
			unique case (state)
				S_IDLE: if (pop) begin
					present_waiting <= 1'b0;
					fx <= head[27];
					fy <= head[26];
					pat_trans <= head[27];
					base <= head[13:0];
					col0 <= head[19:16];
					col1 <= head[23:20];
					pattern <= head[15:0];
					case (head_op)
						OP_PAL: begin
							pal_trans <= head[15:0];
							state <= S_PAL1;
						end
						OP_SPR: state <= S_SPR1;
						OP_RECT: state <= S_RECT1;
						OP_GLYPH: begin
							gly_x <= head[7:0];
							gly_y <= head[15:8];
							state <= S_GLY1;
						end
						OP_PRESENT: begin
							copy_i <= '0;
							pal_index <= '0;
							state <= S_COPY;
						end
						default: ;
					endcase
				end
				S_PAL1: begin
					for (int c = 0; c < 8; c++) pal_col[c] <= head[c*4 +: 4];
					state <= S_PAL2;
				end
				S_PAL2: begin
					for (int c = 0; c < 8; c++) pal_col[8 + c] <= head[c*4 +: 4];
					state <= S_IDLE;
				end
				S_SPR1: begin
					dst_x <= head[6:0];
					dst_y <= head[14:8];
					last_x <= {1'b0, head[22:16]};
					last_y <= {1'b0, head[30:24]};
					state <= S_SPR2;
				end
				S_SPR2: begin
					src_x <= head[6:0];
					src_y <= head[14:8];
					j <= '0;
					wd <= dst_x[6:3];
					state <= S_SPR3;
				end
				S_SPR3: begin
					{spr_shift, spr_addr0, spr_addr1, spr_addrd} <= spr_addrs(wd, j);
					state <= S_SPR_A;
				end
				S_SPR_A: state <= S_SPR_B;
				S_SPR_B: begin
					src_word0_q <= mem_rdata;
					state <= S_SPR_D;
				end
				S_SPR_D: begin
					for (int p = 0; p < 8; p++) begin
						logic [3:0] c;
						c = fx ? src_pix[(7 - p)*4 +: 4] : src_pix[p*4 +: 4];
						spr_col[p*4 +: 4] <= pal_col[c];
						spr_wm[p] <= x_mask[p] && !pal_trans[c];
					end
					state <= S_SPR_W;
				end
				S_SPR_W: begin
					state <= S_SPR_A;
					wd <= wd_next;
					j <= j_next;
					{spr_shift, spr_addr0, spr_addr1, spr_addrd} <= spr_addrs(wd_next, j_next);
					if (wd == wd_last && j == last_y[6:0]) state <= S_IDLE;
				end
				S_RECT1: begin
					dst_x <= head[6:0];
					last_x <= {1'b0, head[14:8]};
					j <= head[22:16];
					last_y <= {1'b0, head[30:24]};
					wd <= head[6:3];
					state <= S_RECT_R;
				end
				S_RECT_R, S_RECT_W: begin
					if (state == S_RECT_R && !rect_full) begin
						state <= S_RECT_W;
					end else begin
						state <= S_RECT_R;
						if (wd != last_x[6:3]) begin
							wd <= wd + 1'b1;
						end else begin
							wd <= dst_x[6:3];
							j <= j + 1'b1;
							if (j == last_y[6:0]) state <= S_IDLE;
						end
					end
				end
				S_COPY: begin
					// Word i is read now, written to the back buffer next cycle.
					copy_valid <= 1'b1;
					copy_addr <= copy_i;
					copy_i <= copy_i + 1'b1;
					if (copy_i == 11'd2047) state <= S_COPY_LAST;
				end
				S_COPY_LAST: state <= S_PALETTE;
				S_PALETTE: begin
					pal_index <= pal_index + 1'b1;
					if (pal_index == 4'd15) begin
						state <= S_IDLE;
						// Shown after the frames already waiting.
						flip <= 1'b1;
						presents <= presents + 1'b1;
					end
				end
				S_GLY1: begin
					gly_rows[31:0] <= head;
					state <= S_GLY2;
				end
				S_GLY2: begin
					gly_rows[63:32] <= head;
					gly_r <= '0;
					gly_w <= 1'b0;
					state <= S_GLY_R;
				end
				// Each destination word with pixels to draw: read, then merge
				// and write.
				S_GLY_R, S_GLY_W: begin
					if (state == S_GLY_R && gly_wm != 0) begin
						state <= S_GLY_W;
					end else begin
						state <= gly_last ? S_IDLE : S_GLY_R;
						gly_w <= !gly_w;
						if (gly_w) gly_r <= gly_r + 1'b1;
					end
				end
				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
