// Simulation stand-in for the Xilinx MMCM: all outputs are the input clock.
module MMCME2_BASE #(
	parameter real CLKIN1_PERIOD = 0.0,
	parameter int DIVCLK_DIVIDE = 1,
	parameter real CLKFBOUT_MULT_F = 1.0,
	parameter real CLKOUT0_DIVIDE_F = 1.0,
	parameter real CLKOUT0_PHASE = 0.0,
	parameter int CLKOUT1_DIVIDE = 1,
	parameter real CLKOUT1_PHASE = 0.0,
	parameter int CLKOUT2_DIVIDE = 1,
	parameter real CLKOUT2_PHASE = 0.0,
	parameter int CLKOUT3_DIVIDE = 1,
	parameter real CLKOUT3_PHASE = 0.0
) (
	input  logic CLKIN1, CLKFBIN, PWRDWN, RST,
	output logic CLKFBOUT, CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6,
	output logic LOCKED
);
	assign {CLKFBOUT, CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6} = {8{CLKIN1}};
	assign LOCKED = 1'b1;
endmodule

// The same for MMCME2_ADV (the core's MMCM, with the fine phase shift of the
// SDRAM clock: PSDONE answers PSEN a cycle later, nothing shifts).
module MMCME2_ADV #(
	parameter real CLKIN1_PERIOD = 0.0,
	parameter int DIVCLK_DIVIDE = 1,
	parameter real CLKFBOUT_MULT_F = 1.0,
	parameter real CLKOUT0_DIVIDE_F = 1.0,
	parameter real CLKOUT0_PHASE = 0.0,
	parameter int CLKOUT1_DIVIDE = 1,
	parameter real CLKOUT1_PHASE = 0.0,
	parameter int CLKOUT2_DIVIDE = 1,
	parameter real CLKOUT2_PHASE = 0.0,
	parameter int CLKOUT3_DIVIDE = 1,
	parameter real CLKOUT3_PHASE = 0.0,
	parameter string CLKOUT3_USE_FINE_PS = "FALSE"
) (
	input  logic CLKIN1, CLKIN2, CLKINSEL, CLKFBIN, PWRDWN, RST,
	input  logic DCLK, DEN, DWE,
	input  logic [6:0] DADDR,
	input  logic [15:0] DI,
	output logic [15:0] DO,
	output logic DRDY,
	input  logic PSCLK, PSEN, PSINCDEC,
	output logic PSDONE,
	output logic CLKFBOUT, CLKFBOUTB, CLKFBSTOPPED, CLKINSTOPPED,
	output logic CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B,
	output logic CLKOUT4, CLKOUT5, CLKOUT6,
	output logic LOCKED
);
	assign {CLKFBOUT, CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6} = {8{CLKIN1}};
	assign {CLKFBOUTB, CLKOUT0B, CLKOUT1B, CLKOUT2B, CLKOUT3B} = '0;
	assign {CLKFBSTOPPED, CLKINSTOPPED, DRDY} = '0;
	assign DO = '0;
	assign LOCKED = 1'b1;
	always_ff @(posedge PSCLK) PSDONE <= PSEN;
endmodule
