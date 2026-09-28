package pico8

import chisel3._

/**
 * Xilinx 7-series MMCM (MMCME2_ADV), with internal feedback, and optionally
 * dynamic (fine) phase shift of one output.
 *
 * @param divide input divider (DIVCLK_DIVIDE)
 * @param multiply VCO multiplier (CLKFBOUT_MULT_F)
 * @param outputs (divider, phase in degrees) for each of CLKOUT0 onwards
 * @param finePhaseOutput the output (1-6) with dynamic phase shift: each
 *   `psEn` pulse (on `psClock`) shifts it by 1/56 of the VCO period, done
 *   when `psDone` pulses
 */
class Mmcm(
  clockInHz: Int,
  divide: Int,
  multiply: Double,
  outputs: Seq[(Int, Double)],
  finePhaseOutput: Option[Int] = None,
) extends RawModule {
  require(outputs.length <= 7)
  require(finePhaseOutput.forall(i => i >= 1 && i < outputs.length))

  val io = IO(new Bundle {
    val clockIn = Input(Clock())
    val clockOuts = Output(Vec(outputs.length, Clock()))
    val locked = Output(Bool())

    val psClock = Input(Clock())
    val psEn = Input(Bool())
    val psIncDec = Input(Bool())
    val psDone = Output(Bool())
  })

  private val params: Map[String, Param] = Map(
    "CLKIN1_PERIOD" -> DoubleParam(1e9 / clockInHz),
    "DIVCLK_DIVIDE" -> IntParam(divide),
    "CLKFBOUT_MULT_F" -> DoubleParam(multiply),
  ) ++ outputs.zipWithIndex.flatMap { case ((outDivide, phase), i) =>
    val divideParam =
      if (i == 0) s"CLKOUT0_DIVIDE_F" -> DoubleParam(outDivide.toDouble)
      else s"CLKOUT${i}_DIVIDE" -> IntParam(outDivide)
    Seq(divideParam, s"CLKOUT${i}_PHASE" -> DoubleParam(phase))
  } ++ finePhaseOutput.map(i => s"CLKOUT${i}_USE_FINE_PS" -> StringParam("TRUE"))

  private val mmcm = Module(new MMCME2_ADV(params))
  mmcm.io.CLKFBIN := mmcm.io.CLKFBOUT
  mmcm.io.CLKIN1 := io.clockIn
  mmcm.io.CLKIN2 := false.B.asClock
  mmcm.io.CLKINSEL := true.B
  mmcm.io.PWRDWN := false.B
  mmcm.io.RST := false.B
  mmcm.io.DCLK := false.B.asClock
  mmcm.io.DEN := false.B
  mmcm.io.DWE := false.B
  mmcm.io.DADDR := 0.U
  mmcm.io.DI := 0.U
  mmcm.io.PSCLK := io.psClock
  mmcm.io.PSEN := io.psEn && finePhaseOutput.isDefined.B
  mmcm.io.PSINCDEC := io.psIncDec
  io.psDone := mmcm.io.PSDONE
  io.locked := mmcm.io.LOCKED

  private val allOuts = Seq(
    mmcm.io.CLKOUT0, mmcm.io.CLKOUT1, mmcm.io.CLKOUT2, mmcm.io.CLKOUT3,
    mmcm.io.CLKOUT4, mmcm.io.CLKOUT5, mmcm.io.CLKOUT6,
  )
  io.clockOuts := VecInit(allOuts.take(outputs.length))
}

private class MMCME2_ADV(params: Map[String, Param]) extends ExtModule(params) {
  val io = FlatIO(new Bundle {
    val CLKIN1 = Input(Clock())
    val CLKIN2 = Input(Clock())
    val CLKINSEL = Input(Bool())
    val CLKFBIN = Input(Clock())
    val PWRDWN = Input(Bool())
    val RST = Input(Bool())
    val DCLK = Input(Clock())
    val DEN = Input(Bool())
    val DWE = Input(Bool())
    val DADDR = Input(UInt(7.W))
    val DI = Input(UInt(16.W))
    val DO = Output(UInt(16.W))
    val DRDY = Output(Bool())
    val PSCLK = Input(Clock())
    val PSEN = Input(Bool())
    val PSINCDEC = Input(Bool())
    val PSDONE = Output(Bool())
    val CLKFBOUT = Output(Clock())
    val CLKFBOUTB = Output(Clock())
    val CLKFBSTOPPED = Output(Bool())
    val CLKINSTOPPED = Output(Bool())
    val CLKOUT0 = Output(Clock())
    val CLKOUT0B = Output(Clock())
    val CLKOUT1 = Output(Clock())
    val CLKOUT1B = Output(Clock())
    val CLKOUT2 = Output(Clock())
    val CLKOUT2B = Output(Clock())
    val CLKOUT3 = Output(Clock())
    val CLKOUT3B = Output(Clock())
    val CLKOUT4 = Output(Clock())
    val CLKOUT5 = Output(Clock())
    val CLKOUT6 = Output(Clock())
    val LOCKED = Output(Bool())
  })
}
