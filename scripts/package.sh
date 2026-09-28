#!/usr/bin/env bash
# Assemble the SD card core folder (dist/cores/PICO-8/) and a zip of it, from
# the built bitstream and program:
#   ./framework/mill root.buildCore --target gamebub_rev4
#   make -C sw
# BIT overrides the bitstream. FAST_BIT (and FAST_NAME) add a second core,
# /cores/PICO-8-Fast/, with another bitstream (e.g. a faster clock).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIT="${BIT:-$ROOT/build/pico8.HandheldPico8-gamebub_rev4/pico8.HandheldPico8-gamebub_rev4.bit}"
BIN="$ROOT/sw/build/pico8.bin"
OUT="$ROOT/dist/cores/PICO-8"
for f in "$BIT" "$BIN"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
rm -rf "$ROOT/dist/cores" "$ROOT/dist/extras" "$ROOT/dist/pico8-gamebub.zip"
mkdir -p "$OUT"
cp "$ROOT"/core/PICO-8/*.json "$OUT/"
cp "$BIT" "$OUT/pico8_rev4.bit"
cp "$BIN" "$OUT/pico8.bin"
if [ -n "${FAST_BIT:-}" ]; then
    FAST="$ROOT/dist/cores/PICO-8-Fast"
    mkdir -p "$FAST"
    cp "$ROOT"/core/PICO-8/*.json "$FAST/"
    cp "$FAST_BIT" "$FAST/pico8_rev4.bit"
    cp "$BIN" "$FAST/pico8.bin"
    python3 - "$FAST/core.json" "${FAST_NAME:-PICO-8 (fast)}" <<'PY'
import json, sys
core = json.load(open(sys.argv[1]))
core["metadata"]["id"] = "PICO-8-Fast"
core["metadata"]["name"] = sys.argv[2]
json.dump(core, open(sys.argv[1], "w"), indent=2)
PY
fi
# Clock / SDRAM timing test (sw/clocktest): replaces pico8.bin to use it.
if [ -f "$ROOT/sw/clocktest/clocktest.bin" ]; then
    mkdir -p "$ROOT/dist/extras/clocktest"
    cp "$ROOT/sw/clocktest/clocktest.bin" "$ROOT/dist/extras/clocktest/pico8.bin"
    cp "$ROOT/sw/clocktest/README.txt" "$ROOT/dist/extras/clocktest/README.txt"
fi
# Hardware test program (SDRAM, audio, input): replaces pico8.bin to use it.
if [ -f "$ROOT/sw/memtest/memtest.bin" ]; then
    mkdir -p "$ROOT/dist/extras/memtest"
    cp "$ROOT/sw/memtest/memtest.bin" "$ROOT/dist/extras/memtest/pico8.bin"
    cat > "$ROOT/dist/extras/memtest/README.txt" <<'TXT'
Hardware test for the PICO-8 core. Replace /cores/PICO-8/pico8.bin with this
pico8.bin (keep the original), then start PICO-8 with any cart.

Green background: no SDRAM errors so far. Red: errors.
  row 1: completed test passes (one pass takes a few seconds)
  row 2: error count
  rows 3-5: last error address, expected value, value read
  row 6: buttons (hex)
A 440 Hz tone plays; it goes up to 880 Hz while A is held.
TXT
fi
(cd "$ROOT/dist" && python3 -c "
import os, zipfile
with zipfile.ZipFile('pico8-gamebub.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for d, _, files in list(os.walk('cores')) + list(os.walk('extras')):
        for f in sorted(files):
            z.write(os.path.join(d, f))
")
ls -la "$OUT" "$ROOT/dist/pico8-gamebub.zip"
