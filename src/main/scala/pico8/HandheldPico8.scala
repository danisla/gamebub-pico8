package pico8

import chisel3._
import chisel3.util._
import lib.mem.{MemoryInterface, MemoryMap, RegisterMap}
import net.gamebub.framework.interface._
import net.gamebub.framework.Core

object HandheldPico8 {
  object CommandState extends ChiselEnum {
    val idle, busy, error, done = Value
  }

  /** MMCM VCO frequency: 1000 MHz (50 MHz * 20). */
  val mmcmVcoHz = 1_000_000_000.0
  /**
   * CPU: 0 = VexRiscv, 1 = VexiiRiscv, 2 = dual issue VexiiRiscv (must match
   * hdl/vexiiriscv/VexiiRiscv.v).
   */
  val cpuVexii = 1
  /** Build setting from the environment (for test builds, see sw/clocktest). */
  private def setting(name: String): Option[String] = sys.env.get(name).filter(_.nonEmpty)
  /**
   * System clock (CPU, SDRAM): 111.1 MHz; 90.9 MHz with VexRiscv, 76.9 MHz
   * with dual issue VexiiRiscv. The limit is the CPU: VexiiRiscv is ~0.25 ns
   * short of 111.1 MHz in Vivado's (worst case) timing, and was tested on
   * hardware up to 125 MHz (sw/clocktest). Other builds: PICO8_SYSTEM_DIVIDER
   * (e.g. 8: 125 MHz, the release's "PICO-8 (125 MHz)" core).
   */
  val systemDivider = setting("PICO8_SYSTEM_DIVIDER").map(_.toInt)
    .getOrElse(cpuVexii match { case 0 => 11; case 1 => 9; case _ => 13 })
  /** Host SPI clock: 200 MHz. */
  val spiDivider = 5

  /**
   * Phase (degrees) of the clock forwarded to the SDRAM, relative to the
   * controller clock: the center of the working range measured on hardware
   * with sw/clocktest (about 100-340 degrees at 100-125 MHz, the same in
   * degrees at each clock). Other builds: PICO8_SDRAM_PHASE. (It can also be
   * shifted at run time, for testing.)
   */
  val sdramOutPhase = setting("PICO8_SDRAM_PHASE").map(_.toDouble).getOrElse(225.0)

  /** File IDs, must match core/PICO-8/files.json. */
  val FileCart = 0
  val FileProgram = 1
  val FileSave = 2
  val FileLog = 3

  /** SDRAM address of the cart (must match sw/hw.h). */
  val CartBase = 0x01F00000
  val CartMax = 0x00100000

  /** Video frame period: 60 Hz. */
  val framesPerSecond = 60

  /** Interface of the Pico8Gamebub Verilog module. */
  class Pico8IO extends Bundle {
    val clockSdramOut = Input(Clock())

    val cpuReset = Input(Bool())
    val focus = Input(Bool())
    /** {start, select, r, l, y, x, b, a, up, down, left, right} */
    val buttons = Input(UInt(12.W))
    val cartSize = Input(UInt(24.W))

    val hostSdramEnable = Input(Bool())
    val hostSdramWrite = Input(Bool())
    val hostSdramAddress = Input(UInt(25.W))
    val hostSdramDataWrite = Input(UInt(32.W))
    val hostSdramDataRead = Output(UInt(32.W))
    val hostSdramDone = Output(Bool())

    val hostSaveEnable = Input(Bool())
    val hostSaveWrite = Input(Bool())
    val hostSaveAddress = Input(UInt(12.W))
    val hostSaveDataWrite = Input(UInt(32.W))
    val hostSaveDataRead = Output(UInt(32.W))
    val hostSaveDone = Output(Bool())
    val saveSize = Output(UInt(12.W))

    val hostLogEnable = Input(Bool())
    val hostLogAddress = Input(UInt(14.W))
    val hostLogDataRead = Output(UInt(32.W))
    val hostLogDone = Output(Bool())
    val logSize = Output(UInt(15.W))

    val sdramReady = Output(Bool())
    val sdramPsEn = Output(Bool())
    val sdramPsIncDec = Output(Bool())
    val sdramPsDone = Input(Bool())

    val pixelValid = Output(Bool())
    val pixelR = Output(UInt(8.W))
    val pixelG = Output(UInt(8.W))
    val pixelB = Output(UInt(8.W))
    val hblank = Output(Bool())
    val vblank = Output(Bool())

    val audioL = Output(UInt(16.W))
    val audioR = Output(UInt(16.W))

    val sdramClock = Output(Bool())
    val sdramCke = Output(Bool())
    val sdramCs = Output(Bool())
    val sdramRas = Output(Bool())
    val sdramCas = Output(Bool())
    val sdramWe = Output(Bool())
    val sdramDqm = Output(UInt(2.W))
    val sdramBank = Output(UInt(2.W))
    val sdramAddress = Output(UInt(13.W))
    val sdramDataIn = Input(UInt(16.W))
    val sdramDataOut = Output(UInt(16.W))
    val sdramDataDir = Output(Bool())
  }
}

/**
 * PICO-8 core: a RISC-V SoC running fake-08 (see hdl/pico8_soc.sv and sw/).
 *
 * The host loads the CPU program and the cart into the SDRAM, then releases
 * the CPU from reset.
 */
class HandheldPico8 extends Module with Core {
  import HandheldPico8._

  val clockSystemHz = (mmcmVcoHz / systemDivider).toInt
  val clockDisplayRange = ClocksV0.getClockDisplayHz(1.0 / framesPerSecond)
  val displayDivider = (mmcmVcoHz / clockDisplayRange._1).floor.toInt
  val frameClocks = clockSystemHz / framesPerSecond

  val io = IO(new Bundle {
    val clocks = new ClocksV0(
      clockSystemHz = clockSystemHz,
      clockDisplayHz = (mmcmVcoHz / displayDivider).toInt,
      clockSpiHz = (mmcmVcoHz / spiDivider).toInt,
    )
    val video = new VideoV0(
      videoWidth = 128,
      videoHeight = 128,
      colorDepthR = 8,
      colorDepthG = 8,
      colorDepthB = 8,
      framePeriod = frameClocks.toDouble / clockSystemHz,
    )
    val audio = new AudioV0()
    val host = new HostV0()
    val input = new InputV0()
    val sdram = new SdramV0()
  })

  // Main MMCM
  val mmcm = Module(new Mmcm(
    clockInHz = 50_000_000,
    divide = 1,
    multiply = mmcmVcoHz / 50_000_000,
    outputs = Seq(
      (systemDivider, 0.0),           // System (CPU, SDRAM controller)
      (displayDivider, 0.0),          // Display
      (spiDivider, 0.0),              // Host SPI
      (systemDivider, sdramOutPhase), // Forwarded to the SDRAM
    ),
    finePhaseOutput = Some(3),
  ))
  mmcm.io.clockIn := io.clocks.clockIn50M
  mmcm.io.psClock := mmcm.io.clockOuts(0)
  io.clocks.clockOutSystem := mmcm.io.clockOuts(0)
  io.clocks.clockOutDisplay := mmcm.io.clockOuts(1)
  io.clocks.clockOutSpi := mmcm.io.clockOuts(2)
  io.clocks.locked := mmcm.io.locked

  val regCoreSetup = RegInit(false.B)
  val regCoreReset = RegInit(true.B)
  val regCoreFocus = RegInit(false.B)
  val regCoreResetOnce = RegInit(false.B)
  /** Size of the loaded cart. */
  val regCartSize = RegInit(0.U(24.W))
  /** Whether the program was loaded. */
  val regProgramLoaded = RegInit(false.B)

  val pico8 = Wire(new Pico8IO)
  bindExtModule("Pico8Gamebub", pico8, Map(
    "CLOCK_HZ" -> IntParam(clockSystemHz),
    "FRAME_CLOCKS" -> IntParam(frameClocks),
    "CPU_VEXII" -> IntParam(cpuVexii),
  ))
  pico8.clockSdramOut := mmcm.io.clockOuts(3)
  // Dynamic SDRAM clock phase (for testing, see REG_SDRAM_PHASE)
  mmcm.io.psEn := pico8.sdramPsEn
  mmcm.io.psIncDec := pico8.sdramPsIncDec
  pico8.sdramPsDone := mmcm.io.psDone
  pico8.focus := regCoreFocus
  pico8.cartSize := regCartSize

  // "Reset" setting: hold the CPU in reset for a moment, restarting the cart.
  val regResetTimer = RegInit(0.U(8.W))
  when (regCoreResetOnce) {
    regResetTimer := 255.U
  } .elsewhen (regResetTimer =/= 0.U) {
    regResetTimer := regResetTimer - 1.U
  }
  regCoreResetOnce := false.B
  pico8.cpuReset := regCoreReset || regResetTimer =/= 0.U

  // Host memory map
  val registerInterface = Wire(new MemoryInterface(addressWidth = 16, dataWidth = 32))
  val programInterface = Wire(new MemoryInterface(addressWidth = 25, dataWidth = 32))
  val cartInterface = Wire(new MemoryInterface(addressWidth = 20, dataWidth = 32))
  val saveInterface = Wire(new MemoryInterface(addressWidth = 12, dataWidth = 32))
  val logInterface = Wire(new MemoryInterface(addressWidth = 14, dataWidth = 32))
  val commandInterface = Wire(new MemoryInterface(addressWidth = 16, dataWidth = 32))
  val memoryMap = MemoryMap(
    addressWidth = 32,
    dataWidth = 32,
    entries = Seq(
      0x0.U(4.W) -> registerInterface,
      0x1.U(4.W) -> programInterface,
      0x2.U(4.W) -> cartInterface,
      0x4.U(4.W) -> saveInterface,
      0x5.U(4.W) -> logInterface,
      0xF0.U(8.W) -> commandInterface,
    ))
  io.host.mem.unsafe :<>= memoryMap.unsafe
  memoryMap.writeStrobe := "b1111".U

  registerInterface <> RegisterMap(
    addressWidth = 16,
    dataWidth = 32,
    entries = Seq(
      0x0000 -> RegisterMap.Entry.r(Cat(regProgramLoaded, pico8.sdramReady)),
      0x0004 -> RegisterMap.Entry.r(pico8.saveSize),
      0x2000 -> RegisterMap.Entry.w(regCoreResetOnce),
    )
  )

  // Program and cart: written to the SDRAM (32-bit words).
  pico8.hostSdramEnable := programInterface.enable || cartInterface.enable
  pico8.hostSdramWrite := Mux(programInterface.enable, programInterface.write, cartInterface.write)
  pico8.hostSdramAddress := Mux(programInterface.enable,
    programInterface.address,
    CartBase.U(25.W) | cartInterface.address)
  pico8.hostSdramDataWrite := Mux(programInterface.enable, programInterface.dataWrite, cartInterface.dataWrite)
  programInterface.dataRead := pico8.hostSdramDataRead
  cartInterface.dataRead := pico8.hostSdramDataRead
  programInterface.done := pico8.hostSdramDone
  cartInterface.done := pico8.hostSdramDone

  // Save buffer
  pico8.hostSaveEnable := saveInterface.enable
  pico8.hostSaveWrite := saveInterface.write
  pico8.hostSaveAddress := saveInterface.address
  pico8.hostSaveDataWrite := saveInterface.dataWrite
  saveInterface.dataRead := pico8.hostSaveDataRead
  saveInterface.done := pico8.hostSaveDone

  // Log buffer (read only)
  pico8.hostLogEnable := logInterface.enable && !logInterface.write
  pico8.hostLogAddress := logInterface.address
  logInterface.dataRead := pico8.hostLogDataRead
  logInterface.done := Mux(logInterface.write, RegNext(logInterface.enable), pico8.hostLogDone)

  // Command interface
  val commandHostState = RegInit(CommandState.idle)
  val regCommandHost = Reg(Vec(4, UInt(32.W)))
  commandInterface <> RegisterMap(
    addressWidth = 16,
    dataWidth = 32,
    entries =
      regCommandHost.zipWithIndex.map { case (reg, i) => (0x0000 + (4 * i) -> RegisterMap.Entry.rw(reg)) }
  )
  // Host -> Core commands
  io.host.commandHost.busy := commandHostState === CommandState.busy
  io.host.commandHost.done := commandHostState === CommandState.done
  io.host.commandHost.error := commandHostState === CommandState.error
  when (io.host.commandHost.request) {
    when (commandHostState === CommandState.idle) {
      val command = regCommandHost(0)(15, 0)
      val argument = regCommandHost(1)
      val argument2 = regCommandHost(2)
      for (reg <- regCommandHost) {
        reg := 0.U
      }
      commandHostState := CommandState.done

      when (command === HostV0.CommandGetStatus.U) {
        when (regCoreSetup && pico8.sdramReady) {
          regCommandHost(0) := Mux(regCoreReset, HostV0.StatusCoreHalt.U, HostV0.StatusCoreRun.U)
        } .elsewhen (pico8.sdramReady) {
          regCommandHost(0) := HostV0.StatusSetup.U
        } .otherwise {
          // The SDRAM is being initialized.
          regCommandHost(0) := HostV0.StatusInitialize.U
        }
      } .elsewhen (command === HostV0.CommandSetupComplete.U) {
        regCoreSetup := true.B
      } .elsewhen (command === HostV0.CommandCoreRun.U) {
        when (regProgramLoaded) {
          regCoreReset := false.B
        } .otherwise {
          commandHostState := CommandState.error
        }
      } .elsewhen (command === HostV0.CommandCoreHalt.U) {
        regCoreReset := true.B
      } .elsewhen (command === HostV0.CommandNotifyFocus.U) {
        regCoreFocus := argument(0)
      } .elsewhen (command === HostV0.CommandFileWriteStart.U) {
        // Files are written while the CPU is held in reset.
      } .elsewhen (command === HostV0.CommandFileWriteEnd.U) {
        when (argument === FileCart.U) {
          regCartSize := Mux(argument2 > CartMax.U, 0.U, argument2)
        } .elsewhen (argument === FileProgram.U) {
          regProgramLoaded := argument2 =/= 0.U
        }
      } .elsewhen (command === HostV0.CommandFileReadStart.U) {
        when (argument === FileSave.U) {
          regCommandHost(0) := pico8.saveSize
        } .elsewhen (argument === FileLog.U) {
          regCommandHost(0) := pico8.logSize
        }
      } .elsewhen (command === HostV0.CommandFileReadEnd.U) {
        // Nothing to do.
      } .otherwise {
        // Unknown command
        commandHostState := CommandState.error
      }
    }
  } .otherwise {
    commandHostState := CommandState.idle
  }
  // Core -> Host commands
  io.host.commandCore.request := false.B

  // Input
  val buttons = io.input.buttons
  pico8.buttons := Cat(
    buttons.start,
    buttons.select,
    buttons.r,
    buttons.l,
    buttons.y,
    buttons.x,
    buttons.b,
    buttons.a,
    buttons.up,
    buttons.down,
    buttons.left,
    buttons.right,
  )

  // Audio
  io.audio.left := pico8.audioL.asSInt
  io.audio.right := pico8.audioR.asSInt

  // Video
  io.video.dataEnable := pico8.pixelValid
  io.video.data.r := pico8.pixelR
  io.video.data.g := pico8.pixelG
  io.video.data.b := pico8.pixelB
  io.video.hblank := pico8.hblank
  io.video.vblank := pico8.vblank

  // SDRAM (driven directly by the SoC's SDRAM controller)
  io.sdram.clock := pico8.sdramClock.asClock
  io.sdram.cke := pico8.sdramCke
  io.sdram.cs := pico8.sdramCs.asUInt
  io.sdram.ras := pico8.sdramRas
  io.sdram.cas := pico8.sdramCas
  io.sdram.we := pico8.sdramWe
  io.sdram.dqm := pico8.sdramDqm
  io.sdram.bank := pico8.sdramBank
  io.sdram.address := pico8.sdramAddress
  pico8.sdramDataIn := io.sdram.dataIn
  io.sdram.dataOut := pico8.sdramDataOut
  io.sdram.dataDir := pico8.sdramDataDir
}
