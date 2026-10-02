PICO-8 core clock test
======================

Tests how fast the PICO-8 core's system clock (CPU and SDRAM) can run on
your Game Bub, by running a test program instead of the emulator.

Install, either:
* The clock test kit (pico8-clocktest.zip): each folder in cores/ is a
  separate core with the PICO-8 hardware at one clock ("PICO-8 T100",
  ...). Copy them to /cores/ on the SD card (next to /cores/PICO-8/, which is
  not changed).
* Or this pico8.bin (extras/clocktest/ in the PICO-8 core zip): replace
  pico8.bin in a PICO-8 core folder with it (keep the original), to test that
  core's bitstream.

Start the test core with any cart (the cart isn't used). Leave it running for
at least 5 minutes, then exit.

The screen:

  SDRAM PHASE SWEEP: the SDRAM clock phase is swept over one clock period
    (56 points, left to right), for CAS latency 2 and 3 ("2+0" and "3+0")
    and 1 or 2 cycles of extra read delay ("+1", "+2"). Green = the SDRAM
    test passed at that point, red = it failed. The yellow tick is the phase
    built into the bitstream, used by the PICO-8 core with CL2 +0 (top row).
    A wide green area around the tick means good margin.
  BUILT-IN: whether the built-in phase passed, and the width of the passing
    window (points) around it.
  STRESS: time since the stress test started. It runs at the built-in
    configuration:
    MEM: passes / errors of a 30 MiB SDRAM test (4 patterns)
    CPU: passes / errors of CPU test programs (multiply, divide, branches,
      sorting, an interpreter loop, byte/halfword/word memory access), run
      from block RAM and from SDRAM. Any failing test program is listed
      (B = errors running from block RAM, S = from SDRAM).
  A: sweep again.

A clock is good if the built-in phase passes with a few points of margin on
each side, and MEM and CPU show 0 errors after several minutes. Vivado's
timing report for each bitstream is in timing.txt (it's worst case: a
bitstream can work on hardware although timing isn't met, but it may fail
when the device is hot, so test after the device has warmed up too).

The test writes its results to the log file, saved next to the cart as
<cart>.p8.log when the core exits (the same file for every test core: copy
it before starting the next one, or use a different cart for each).

If the screen freezes or shows TRAP, the CPU failed at that clock.
