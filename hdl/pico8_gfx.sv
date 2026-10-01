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

	////////////////////////////////////////////////////////////////////////
	// Command FIFO (distributed RAM)
	////////////////////////////////////////////////////////////////////////

	localparam int DEPTH = 1 << FIFO_BITS;
	logic [31:0] fifo [0:DEPTH-1];
	logic [FIFO_BITS:0] wr_ptr, rd_ptr;
	wire [FIFO_BITS:0] count = wr_ptr - rd_ptr;
	wire [31:0] head = fifo[rd_ptr[FIFO_BITS-1:0]];
	logic pop;

	assign cmd_ready = count != DEPTH;
	always_ff @(posedge clk) begin
		if (cmd_valid && cmd_ready) fifo[wr_ptr[FIFO_BITS-1:0]] <= cmd_data;
		if (reset) begin
			wr_ptr <= '0;
			rd_ptr <= '0;
		end else begin
			if (cmd_valid && cmd_ready) wr_ptr <= wr_ptr + 1'b1;
			if (pop) rd_ptr <= rd_ptr + 1'b1;
		end
	end

	wire [3:0] head_op = head[31:28];
	logic [4:0] head_len;
	always_comb begin
		case (head_op)
			OP_PAL, OP_SPR, OP_GLYPH: head_len = 5'd3;
			OP_RECT: head_len = 5'd2;
			OP_PRESENT: head_len = 5'd17;
			default: head_len = 5'd1;
		endcase
	end

	////////////////////////////////////////////////////////////////////////
	// Command state
	////////////////////////////////////////////////////////////////////////

	typedef enum logic [4:0] {
		S_IDLE,
		S_PAL1, S_PAL2,
		S_SPR1, S_SPR2, S_SPR_A, S_SPR_B, S_SPR_D, S_SPR_W,
		S_RECT1, S_RECT_R, S_RECT_W,
		S_COPY, S_COPY_LAST, S_PALETTE,
		S_GLY1, S_GLY2, S_GLY_R, S_GLY_W
	} state_t;
	state_t state;

	assign busy = state != S_IDLE || count != 0;
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
	wire [6:0] dy = dst_y + j;
	wire [6:0] sy = fy ? src_y - j : src_y + j;
	wire [3:0] wd_first = dst_x[6:3];
	wire [3:0] wd_last = spr_x1[6:3];
	// Source pixel of destination pixel 0 of the word, and the source words.
	//   no flip: sx(p) = wd * 8 + p + (src_x - dst_x): lowest is p = 0
	//   flip:    sx(p) = src_x + dst_x - wd * 8 - p: lowest is p = 7
	wire signed [9:0] sx_lo = fx ? $signed({3'b0, src_x}) + $signed({3'b0, dst_x}) - $signed({3'b0, wd, 3'b0}) - 10'sd7
	                               : $signed({3'b0, wd, 3'b0}) + $signed({3'b0, src_x}) - $signed({3'b0, dst_x});
	wire [3:0] src_word0 = sx_lo[6:3];       // modulo the row: out of row words are for masked pixels
	wire [3:0] src_word1 = src_word0 + 1'b1;
	wire [2:0] src_shift = sx_lo[2:0];
	wire [13:0] src_row = base + {sy, 4'b0};
	wire [13:0] dst_word = SCREEN + {dy, 4'b0} + wd;

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
	wire [31:0] src_pix = 32'(src_pair >> {src_shift, 2'b00});

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
		mem_addr = dst_word;
		mem_we = 1'b0;
		mem_wdata = merge(mem_rdata, spr_col, spr_wm);
		case (state)
			// PRESENT waits for a free back buffer (flip_pending counts this
			// PRESENT's flip from 2 cycles after: wait while it's in flight).
			S_IDLE: pop = count != 0 && count >= head_len && !(head_op == OP_PRESENT && (flip_pending || flip));
			S_PAL1, S_PAL2, S_SPR1, S_SPR2, S_RECT1, S_PALETTE, S_GLY1, S_GLY2: pop = 1'b1;
			S_SPR_A: mem_addr = src_row + src_word0;
			S_SPR_B: mem_addr = src_row + src_word1;
			S_SPR_D: mem_addr = dst_word;
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
			if (state == S_IDLE && count != 0 && count >= head_len && head_op == OP_PRESENT && flip_pending && !flip) begin
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
					if (wd != wd_last) begin
						wd <= wd + 1'b1;
					end else begin
						wd <= wd_first;
						j <= j + 1'b1;
						if (j == last_y[6:0]) state <= S_IDLE;
					end
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
