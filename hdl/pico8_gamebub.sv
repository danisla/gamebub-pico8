// Game Bub wrapper for the PICO-8 SoC: adapts the port names to the Chisel
// HandheldPico8 core's Pico8IO bundle.
module Pico8Gamebub #(
    parameter int CLOCK_HZ = 100_000_000,
    parameter int FRAME_CLOCKS = CLOCK_HZ / 60
) (
    input  logic        clock,
    input  logic        reset,
    input  logic        clockSdramOut,

    input  logic        cpuReset,
    input  logic        focus,
    input  logic [11:0] buttons,
    input  logic [23:0] cartSize,

    input  logic        hostSdramEnable,
    input  logic        hostSdramWrite,
    input  logic [24:0] hostSdramAddress,
    input  logic [31:0] hostSdramDataWrite,
    output logic [31:0] hostSdramDataRead,
    output logic        hostSdramDone,

    input  logic        hostSaveEnable,
    input  logic        hostSaveWrite,
    input  logic [11:0] hostSaveAddress,
    input  logic [31:0] hostSaveDataWrite,
    output logic [31:0] hostSaveDataRead,
    output logic        hostSaveDone,
    output logic [11:0] saveSize,

    input  logic        hostLogEnable,
    input  logic [13:0] hostLogAddress,
    output logic [31:0] hostLogDataRead,
    output logic        hostLogDone,
    output logic [14:0] logSize,

    output logic        sdramReady,

    output logic        pixelValid,
    output logic [7:0]  pixelR,
    output logic [7:0]  pixelG,
    output logic [7:0]  pixelB,
    output logic        hblank,
    output logic        vblank,

    output logic [15:0] audioL,
    output logic [15:0] audioR,

    output logic        sdramClock,
    output logic        sdramCke,
    output logic        sdramCs,
    output logic        sdramRas,
    output logic        sdramCas,
    output logic        sdramWe,
    output logic [1:0]  sdramDqm,
    output logic [1:0]  sdramBank,
    output logic [12:0] sdramAddress,
    input  logic [15:0] sdramDataIn,
    output logic [15:0] sdramDataOut,
    output logic        sdramDataDir
);

    pico8_soc #(
        .CLOCK_HZ(CLOCK_HZ),
        .FRAME_CLOCKS(FRAME_CLOCKS)
    ) soc (
        .clk(clock),
        .clk_sdram_out(clockSdramOut),
        .reset(reset),
        .cpu_reset(cpuReset),
        .focus(focus),
        .buttons(buttons),
        .cart_size(cartSize),
        .host_sdram_enable(hostSdramEnable),
        .host_sdram_write(hostSdramWrite),
        .host_sdram_address(hostSdramAddress),
        .host_sdram_wdata(hostSdramDataWrite),
        .host_sdram_rdata(hostSdramDataRead),
        .host_sdram_done(hostSdramDone),
        .host_save_enable(hostSaveEnable),
        .host_save_write(hostSaveWrite),
        .host_save_address(hostSaveAddress),
        .host_save_wdata(hostSaveDataWrite),
        .host_save_rdata(hostSaveDataRead),
        .host_save_done(hostSaveDone),
        .save_size(saveSize),
        .host_log_enable(hostLogEnable),
        .host_log_address(hostLogAddress),
        .host_log_rdata(hostLogDataRead),
        .host_log_done(hostLogDone),
        .log_size(logSize),
        .sdram_ready(sdramReady),
        .pixel_valid(pixelValid),
        .pixel_r(pixelR),
        .pixel_g(pixelG),
        .pixel_b(pixelB),
        .hblank(hblank),
        .vblank(vblank),
        .audio_l(audioL),
        .audio_r(audioR),
        .SDRAM_DQ_IN(sdramDataIn),
        .SDRAM_DQ_OUT(sdramDataOut),
        .SDRAM_DQ_OE(sdramDataDir),
        .SDRAM_A(sdramAddress),
        .SDRAM_DQM(sdramDqm),
        .SDRAM_BA(sdramBank),
        .SDRAM_nCS(sdramCs),
        .SDRAM_nRAS(sdramRas),
        .SDRAM_nCAS(sdramCas),
        .SDRAM_nWE(sdramWe),
        .SDRAM_CKE(sdramCke),
        .SDRAM_CLK(sdramClock)
    );

endmodule
