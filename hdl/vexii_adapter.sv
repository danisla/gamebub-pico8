//
// VexiiRiscv, with the same bus interface as the VexRiscv used by the SoC: a
// 32-bit Wishbone instruction bus and a 32-bit Wishbone data bus.
//
// * Instruction fetch: VexiiRiscv's 64-bit fetch bus reads whole 64 byte lines
//   (8 beats, from the start of the line). Each 64-bit beat is two 32-bit beats
//   of the same burst (16 words): pairs of words are passed back.
// * Data: the data cache bus (line refills: 16 word reads; write backs: 16 word
//   writes) and the uncached (I/O) bus share the data bus. A master keeps the
//   bus for as long as it holds CYC (a line refill is one CYC cycle).
//
module VexiiAdapter #(
	// Width of the fetch bus: 64 bits (2 decoders) or 32 bits (1 decoder).
	parameter int FETCH64 = 1
) (
	input  logic        clk,
	input  logic        reset,

	output logic        iBusWishbone_CYC,
	output logic        iBusWishbone_STB,
	input  logic        iBusWishbone_ACK,
	output logic        iBusWishbone_WE,
	output logic [29:0] iBusWishbone_ADR,
	input  logic [31:0] iBusWishbone_DAT_MISO,
	output logic [31:0] iBusWishbone_DAT_MOSI,
	output logic [3:0]  iBusWishbone_SEL,
	input  logic        iBusWishbone_ERR,
	output logic [2:0]  iBusWishbone_CTI,
	output logic [1:0]  iBusWishbone_BTE,

	output logic        dBusWishbone_CYC,
	output logic        dBusWishbone_STB,
	input  logic        dBusWishbone_ACK,
	output logic        dBusWishbone_WE,
	output logic [29:0] dBusWishbone_ADR,
	input  logic [31:0] dBusWishbone_DAT_MISO,
	output logic [31:0] dBusWishbone_DAT_MOSI,
	output logic [3:0]  dBusWishbone_SEL,
	input  logic        dBusWishbone_ERR,
	output logic [2:0]  dBusWishbone_CTI,
	output logic [1:0]  dBusWishbone_BTE
);

	// Fetch (64 or 32-bit)
	localparam int FW = FETCH64 ? 64 : 32;
	logic        f_cyc, f_stb, f_ack, f_we, f_err;
	logic [31-$clog2(FW/8):0] f_adr;
	logic [FW-1:0]   f_dat_r, f_dat_w;
	logic [FW/8-1:0] f_sel;
	logic [2:0]  f_cti;
	logic [1:0]  f_bte;
	// Data cache
	logic        l_cyc, l_stb, l_ack, l_we, l_err;
	logic [29:0] l_adr;
	logic [31:0] l_dat_r, l_dat_w;
	logic [3:0]  l_sel;
	logic [2:0]  l_cti;
	logic [1:0]  l_bte;
	// Uncached
	logic        u_cyc, u_stb, u_ack, u_we, u_err;
	logic [29:0] u_adr;
	logic [31:0] u_dat_r, u_dat_w;
	logic [3:0]  u_sel;
	logic [2:0]  u_cti;
	logic [1:0]  u_bte;

	logic [63:0] time_counter;
	always_ff @(posedge clk) time_counter <= reset ? '0 : time_counter + 1'b1;

	VexiiRiscv core (
		.clk(clk),
		.reset(reset),
		.PrivilegedPlugin_logic_rdtime(time_counter),
		.PrivilegedPlugin_logic_harts_0_int_m_timer(1'b0),
		.PrivilegedPlugin_logic_harts_0_int_m_software(1'b0),
		.PrivilegedPlugin_logic_harts_0_int_m_external(1'b0),
		.LsuL1WishbonePlugin_logic_bus_CYC(l_cyc),
		.LsuL1WishbonePlugin_logic_bus_STB(l_stb),
		.LsuL1WishbonePlugin_logic_bus_ACK(l_ack),
		.LsuL1WishbonePlugin_logic_bus_WE(l_we),
		.LsuL1WishbonePlugin_logic_bus_ADR(l_adr),
		.LsuL1WishbonePlugin_logic_bus_DAT_MISO(l_dat_r),
		.LsuL1WishbonePlugin_logic_bus_DAT_MOSI(l_dat_w),
		.LsuL1WishbonePlugin_logic_bus_SEL(l_sel),
		.LsuL1WishbonePlugin_logic_bus_ERR(l_err),
		.LsuL1WishbonePlugin_logic_bus_CTI(l_cti),
		.LsuL1WishbonePlugin_logic_bus_BTE(l_bte),
		.FetchL1WishbonePlugin_logic_bus_CYC(f_cyc),
		.FetchL1WishbonePlugin_logic_bus_STB(f_stb),
		.FetchL1WishbonePlugin_logic_bus_ACK(f_ack),
		.FetchL1WishbonePlugin_logic_bus_WE(f_we),
		.FetchL1WishbonePlugin_logic_bus_ADR(f_adr),
		.FetchL1WishbonePlugin_logic_bus_DAT_MISO(f_dat_r),
		.FetchL1WishbonePlugin_logic_bus_DAT_MOSI(f_dat_w),
		.FetchL1WishbonePlugin_logic_bus_SEL(f_sel),
		.FetchL1WishbonePlugin_logic_bus_ERR(f_err),
		.FetchL1WishbonePlugin_logic_bus_CTI(f_cti),
		.FetchL1WishbonePlugin_logic_bus_BTE(f_bte),
		.LsuCachelessWishbonePlugin_logic_bridge_down_CYC(u_cyc),
		.LsuCachelessWishbonePlugin_logic_bridge_down_STB(u_stb),
		.LsuCachelessWishbonePlugin_logic_bridge_down_ACK(u_ack),
		.LsuCachelessWishbonePlugin_logic_bridge_down_WE(u_we),
		.LsuCachelessWishbonePlugin_logic_bridge_down_ADR(u_adr),
		.LsuCachelessWishbonePlugin_logic_bridge_down_DAT_MISO(u_dat_r),
		.LsuCachelessWishbonePlugin_logic_bridge_down_DAT_MOSI(u_dat_w),
		.LsuCachelessWishbonePlugin_logic_bridge_down_SEL(u_sel),
		.LsuCachelessWishbonePlugin_logic_bridge_down_ERR(u_err),
		.LsuCachelessWishbonePlugin_logic_bridge_down_CTI(u_cti),
		.LsuCachelessWishbonePlugin_logic_bridge_down_BTE(u_bte)
	);

	////////////////////////////////////////////////////////////////////////
	// Fetch: 32-bit beats, or 64-bit beats as pairs of 32-bit beats
	////////////////////////////////////////////////////////////////////////

	assign iBusWishbone_CYC = f_cyc;
	assign iBusWishbone_STB = f_stb;
	assign iBusWishbone_WE = 1'b0;
	assign iBusWishbone_DAT_MOSI = '0;
	assign iBusWishbone_SEL = 4'b1111;
	assign iBusWishbone_BTE = 2'b00;
	if (FETCH64) begin : fetch64
		logic        half;       // second word of the current 64-bit beat
		logic [31:0] low;
		always_ff @(posedge clk) begin
			if (reset || !f_cyc) begin
				half <= 1'b0;
			end else if (iBusWishbone_ACK || iBusWishbone_ERR) begin
				half <= !half;
				if (!half) low <= iBusWishbone_DAT_MISO;
			end
		end
		assign iBusWishbone_ADR = {f_adr, half};
		// Last 32-bit beat of the burst: second half of the last 64-bit beat.
		assign iBusWishbone_CTI = (f_cti == 3'b111 && half) ? 3'b111 : 3'b010;
		assign f_ack = iBusWishbone_ACK && half;
		assign f_err = iBusWishbone_ERR && half;
		assign f_dat_r = {iBusWishbone_DAT_MISO, low};
	end else begin : fetch32
		assign iBusWishbone_ADR = f_adr;
		assign iBusWishbone_CTI = f_cti;
		assign f_ack = iBusWishbone_ACK;
		assign f_err = iBusWishbone_ERR;
		assign f_dat_r = iBusWishbone_DAT_MISO;
	end

	////////////////////////////////////////////////////////////////////////
	// Data: data cache and uncached buses
	////////////////////////////////////////////////////////////////////////

	typedef enum logic [1:0] { OWNER_NONE, OWNER_L1, OWNER_IO } owner_t;
	owner_t owner;
	always_ff @(posedge clk) begin
		if (reset) begin
			owner <= OWNER_NONE;
		end else begin
			unique case (owner)
				OWNER_NONE: begin
					if (l_cyc) owner <= OWNER_L1;
					else if (u_cyc) owner <= OWNER_IO;
				end
				OWNER_L1: if (!l_cyc) owner <= u_cyc ? OWNER_IO : OWNER_NONE;
				OWNER_IO: if (!u_cyc) owner <= l_cyc ? OWNER_L1 : OWNER_NONE;
				default: owner <= OWNER_NONE;
			endcase
		end
	end
	// Combinational grant for the first cycle (no added latency).
	wire grant_l1 = owner == OWNER_L1 || (owner == OWNER_NONE && l_cyc);
	wire grant_io = owner == OWNER_IO || (owner == OWNER_NONE && !l_cyc && u_cyc);

	always_comb begin
		dBusWishbone_CYC = 1'b0;
		dBusWishbone_STB = 1'b0;
		dBusWishbone_WE = 1'b0;
		dBusWishbone_ADR = '0;
		dBusWishbone_DAT_MOSI = '0;
		dBusWishbone_SEL = '0;
		dBusWishbone_CTI = 3'b000;
		dBusWishbone_BTE = 2'b00;
		if (grant_l1) begin
			dBusWishbone_CYC = l_cyc;
			dBusWishbone_STB = l_stb;
			dBusWishbone_WE = l_we;
			dBusWishbone_ADR = l_adr;
			dBusWishbone_DAT_MOSI = l_dat_w;
			dBusWishbone_SEL = l_sel;
			// Writes (line write backs) are done word by word.
			dBusWishbone_CTI = l_we ? 3'b000 : l_cti;
			dBusWishbone_BTE = l_bte;
		end else if (grant_io) begin
			dBusWishbone_CYC = u_cyc;
			dBusWishbone_STB = u_stb;
			dBusWishbone_WE = u_we;
			dBusWishbone_ADR = u_adr;
			dBusWishbone_DAT_MOSI = u_dat_w;
			dBusWishbone_SEL = u_sel;
			dBusWishbone_CTI = 3'b000;
			dBusWishbone_BTE = 2'b00;
		end
	end
	assign l_ack = grant_l1 && dBusWishbone_ACK;
	assign l_err = grant_l1 && dBusWishbone_ERR;
	assign l_dat_r = dBusWishbone_DAT_MISO;
	assign u_ack = grant_io && dBusWishbone_ACK;
	assign u_err = grant_io && dBusWishbone_ERR;
	assign u_dat_r = dBusWishbone_DAT_MISO;

endmodule
