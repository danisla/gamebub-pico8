package pico8

import chisel3._

/**
 * Xilinx 7-series MMCM (MMCME2_BASE), with internal feedback.
 *
 * @param divide input divider (DIVCLK_DIVIDE)
 * @param multiply VCO multiplier (CLKFBOUT_MULT_F)
 * @param outputs (divider, phase in degrees) for each of CLKOUT0 onwards
 */
class Mmcm(
  clockInHz: Int,
  divide: Int,
  multiply: Double,
  outputs: Seq[(Int, Double)],
) extends RawModule {
  require(outputs.length <= 7)

  val io = IO(new Bundle {
    val clockIn = Input(Clock())
    val clockOuts = Output(Vec(outputs.length, Clock()))
    val locked = Output(Bool())
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
  }

  private val mmcm = Module(new MMCME2_BASE(params))
  mmcm.io.CLKFBIN := mmcm.io.CLKFBOUT
  mmcm.io.CLKIN1 := io.clockIn
  mmcm.io.PWRDWN := false.B
  mmcm.io.RST := false.B
  io.locked := mmcm.io.LOCKED

  private val allOuts = Seq(
    mmcm.io.CLKOUT0, mmcm.io.CLKOUT1, mmcm.io.CLKOUT2, mmcm.io.CLKOUT3,
    mmcm.io.CLKOUT4, mmcm.io.CLKOUT5, mmcm.io.CLKOUT6,
  )
  io.clockOuts := VecInit(allOuts.take(outputs.length))
}

private class MMCME2_BASE(params: Map[String, Param]) extends ExtModule(params) {
  val io = FlatIO(new Bundle {
    val CLKIN1 = Input(Clock())
    val CLKFBIN = Input(Clock())
    val PWRDWN = Input(Bool())
    val RST = Input(Bool())
    val CLKFBOUT = Output(Clock())
    val CLKOUT0 = Output(Clock())
    val CLKOUT1 = Output(Clock())
    val CLKOUT2 = Output(Clock())
    val CLKOUT3 = Output(Clock())
    val CLKOUT4 = Output(Clock())
    val CLKOUT5 = Output(Clock())
    val CLKOUT6 = Output(Clock())
    val LOCKED = Output(Bool())
  })
}
