#!/usr/bin/env bash
# Regenerate hdl/vexriscv/VexRiscv_Pico8.v (requires nix, for sbt and a JDK).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/third_party/pythondata-cpu-vexriscv/pythondata_cpu_vexriscv/verilog"
if [ ! -d "$GEN/ext/VexRiscv/src" ]; then
    git -C "$GEN" submodule update --init --depth 1 ext/VexRiscv
fi
JDK=$(nix build --no-link --print-out-paths nixpkgs#jdk11_headless)
SBT=$(nix build --no-link --print-out-paths nixpkgs#sbt)
export JAVA_HOME=$JDK/lib/openjdk PATH=$JDK/bin:$SBT/bin:$PATH
cd "$GEN"
sbt -batch compile "runMain vexriscv.GenCoreDefault --compressedGen true \
    --iCacheSize 32768 --dCacheSize 32768 --prediction dynamic_target \
    --csrPluginConfig small --outputFile VexRiscv_Pico8"
cp VexRiscv_Pico8.v VexRiscv_Pico8.yaml "$ROOT/hdl/vexriscv/"
