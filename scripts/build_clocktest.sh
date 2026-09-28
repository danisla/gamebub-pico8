#!/usr/bin/env bash
# Build test bitstreams at several system clocks (1000 MHz VCO / divider),
# for testing on hardware with sw/clocktest, into dist/clocktest/:
#   pico8_rev4_<MHz>.bit, timing_<MHz>.txt (Vivado timing summary)
# Usage: scripts/build_clocktest.sh [divider...]   (default: 10 9 8)
# PICO8_SDRAM_PHASE sets the SDRAM clock phase (degrees, default 270); the
# outputs are then named pico8_rev4_<MHz>_p<phase>.bit etc.
# On NixOS, set VIVADO_ENV to the Vivado FHS environment (nix/vivado-fhs.nix).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIVIDERS=("$@")
[ $# -eq 0 ] && DIVIDERS=(10 9 8)
RUN=(bash -c)
[ -n "${VIVADO_ENV:-}" ] && RUN=("$VIVADO_ENV" -c)
BUILD="$ROOT/build/pico8.HandheldPico8-gamebub_rev4"
OUT="$ROOT/dist/clocktest"
mkdir -p "$OUT"
python3 scripts/prepare_rtl.py
for d in "${DIVIDERS[@]}"; do
    mhz=$(python3 -c "print(f'{1000 / $d:.1f}'.rstrip('0').rstrip('.'))")${PICO8_SDRAM_PHASE:+_p$PICO8_SDRAM_PHASE}
    echo "== $mhz (divider $d)"
    "${RUN[@]}" "cd '$ROOT' && PICO8_SYSTEM_DIVIDER=$d PICO8_SDRAM_PHASE=${PICO8_SDRAM_PHASE:-} ./framework/mill --no-daemon root.buildCore --target gamebub_rev4" \
        > "$OUT/build_$mhz.log" 2>&1 || { echo "build failed, see $OUT/build_$mhz.log"; continue; }
    cp "$BUILD/pico8.HandheldPico8-gamebub_rev4.bit" "$OUT/pico8_rev4_$mhz.bit"
    report="$BUILD/pico8.HandheldPico8-gamebub_rev4.runs/impl_1/top_handheld_timing_summary_routed.rpt"
    {
        echo "Clocks (period ns, MHz):"
        grep -E "^\s+(clk_sys|sdram_clk_out)\s+\{" "$report" || true
        echo
        echo "WNS (ns), failing endpoints: clk_sys, and the SDRAM I/O (clk_sys -> sdram_clk_out: outputs, back: read data):"
        grep -E "^\s*clk_sys\s+-?[0-9]|^(clk_sys|sdram_clk_out)\s+(clk_sys|sdram_clk_out)\s" "$report" || true
        echo
        grep -m 5 -A 3 "Slack (VIOLATED)" "$report" | grep -E "Slack|Source|Destination" || echo "Timing met."
    } > "$OUT/timing_$mhz.txt"
    grep -E "^\s*clk_sys " "$OUT/timing_$mhz.txt" | head -2
done
