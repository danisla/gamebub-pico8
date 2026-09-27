########################################
# PICO-8 core
########################################

set sdram_ctrl handheld_top/core/extModule/soc/sdram

# Pack SDRAM signal registers into the I/O blocks for consistent timing.
set_property IOB TRUE [get_cells -hier -filter "NAME =~ $sdram_ctrl/SDRAM_A_reg[*]"]
set_property IOB TRUE [get_cells -hier -filter "NAME =~ $sdram_ctrl/SDRAM_BA_reg[*]"]
set_property IOB TRUE [get_cells -hier -filter "NAME =~ $sdram_ctrl/SDRAM_DQM_reg[*]"]
set_property IOB TRUE [get_cells -hier -filter "NAME =~ $sdram_ctrl/cmd_reg[*]"]
set_property IOB TRUE [get_cells -hier -filter "NAME =~ $sdram_ctrl/SDRAM_DQ_OUT_reg[*]"]
set_property IOB TRUE [get_cells -hier -filter "NAME =~ $sdram_ctrl/rbuf_reg[*]"]

########################################
# SDRAM I/O timing
########################################
# The SDRAM clock is forwarded (ODDR) from a copy of the controller clock,
# shifted by 270 degrees (as in the Game Bub SNES core). These constraints
# check that its phase leaves margin for typical SDR SDRAM timing (CL2):
# command setup/hold (tIS/tIH) 1.5/0.8 ns, read data access/hold time
# (tAC/tOH) 6.0/2.5 ns, plus ~0.5 ns board delay.
create_generated_clock -name sdram_clk_out \
    -source [get_pins $sdram_ctrl/sdramclk_ddr/C] -divide_by 1 \
    [get_ports sdram_clk]

set_output_delay -clock sdram_clk_out -max 2.0 [get_ports {sdram_a[*] sdram_bs[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm sdram_dq[*]}]
set_output_delay -clock sdram_clk_out -min -1.3 [get_ports {sdram_a[*] sdram_bs[*] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm sdram_dq[*]}]

set_input_delay -clock sdram_clk_out -max 6.5 [get_ports {sdram_dq[*]}]
set_input_delay -clock sdram_clk_out -min 2.5 [get_ports {sdram_dq[*]}]

# With CAS latency 2, data launched by an SDRAM clock edge is captured on the
# second following controller clock edge, 3 cycles after the READ command is on
# the pins (see pico8_sdram.sv).
set_multicycle_path -setup 2 -from [get_clocks sdram_clk_out] \
    -to [get_cells -hier -filter "NAME =~ $sdram_ctrl/rbuf_reg*"]
