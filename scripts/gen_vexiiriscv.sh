#!/usr/bin/env bash
# Generate hdl/vexiiriscv/VexiiRiscv.v from third_party/VexiiRiscv (SpinalHDL;
# needs a JDK 17 and sbt, e.g. from nixpkgs).
#
# Single issue (HandheldPico8 cpuVexii = 1), meets timing at 90.9 MHz. Dual
# issue (--lanes=2 --decoders=2, cpuVexii = 2) is barely faster per clock
# (~4% on Dinky Kong) and only meets timing at ~75 MHz.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/third_party/VexiiRiscv"
sbt -batch "Test/runMain vexiiriscv.Generate --xlen=32 --with-rvm --with-rvc \
  --lanes=1 --decoders=1 --with-late-alu --regfile-async --relaxed-branch --relaxed-btb \
  --with-gshare --with-btb --with-ras --with-aligner-buffer --with-dispatcher-buffer \
  --without-mmu --reset-vector 0 \
  --with-fetch-l1 --fetch-l1-sets=128 --fetch-l1-ways=4 \
  --with-lsu-l1 --lsu-l1-sets=128 --lsu-l1-ways=4 \
  --fetch-wishbone --lsu-l1-wishbone --lsu-wishbone \
  --region base=0,size=2000000,main=1,exe=1 \
  --region base=10000000,size=10000,main=1,exe=1 \
  --region base=F0000000,size=10000000,main=0,exe=0"
mkdir -p "$ROOT/hdl/vexiiriscv"
cp VexiiRiscv.v "$ROOT/hdl/vexiiriscv/VexiiRiscv.v"
