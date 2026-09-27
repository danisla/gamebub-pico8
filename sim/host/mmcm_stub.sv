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
