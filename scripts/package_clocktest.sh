#!/usr/bin/env bash
# Assemble the clock test kit (dist/pico8-clocktest.zip) from the bitstreams
# built by scripts/build_clocktest.sh and sw/clocktest/clocktest.bin: one SD
# card core per bitstream ("PICO-8 T<MHz>", /cores/PICO-8-T<MHz>/), each
# running the clock test instead of the emulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="$ROOT/dist/clocktest"
KIT="$ROOT/dist/clocktest-kit"
BIN="$ROOT/sw/clocktest/clocktest.bin"
[ -f "$BIN" ] || { echo "missing $BIN (make -C sw/clocktest)" >&2; exit 1; }
rm -rf "$KIT"
mkdir -p "$KIT/cores"
for bit in "$IN"/pico8_rev4_*.bit; do
    variant=$(basename "$bit" .bit); variant=${variant#pico8_rev4_}  # <MHz>[_p<phase>]
    mhz=${variant%%_p*}
    # The firmware limits the core name to 32 bytes (longer ones are not listed).
    label="T$mhz"
    [ "$variant" != "$mhz" ] && label="$label p${variant##*_p}"
    dir="$KIT/cores/PICO-8-T${variant//./_}"
    mkdir -p "$dir"
    cp "$bit" "$dir/pico8_rev4.bit"
    cp "$BIN" "$dir/pico8.bin"
    cp "$IN/timing_$variant.txt" "$dir/timing.txt"
    cat > "$dir/core.json" <<JSON
{
  "metadata": {
    "id": "PICO-8-T${variant//./_}",
    "name": "PICO-8 $label",
    "author": "fake-08 (RISC-V)"
  },
  "bitstreams": [
    { "target": "gamebub_rev4", "filename": "pico8_rev4.bit" }
  ]
}
JSON
    # The PICO-8 core's files, without the save file.
    python3 - "$ROOT/core/PICO-8/files.json" "$dir/files.json" <<'PY'
import json, sys
files = json.load(open(sys.argv[1]))
files["files"] = [f for f in files["files"] if f.get("label") != "Save"]
json.dump(files, open(sys.argv[2], "w"), indent=2)
PY
    cp "$ROOT/core/PICO-8/settings.json" "$dir/"
done
cp "$ROOT/sw/clocktest/README.txt" "$KIT/README.txt"
(cd "$KIT" && python3 -c "
import os, zipfile
with zipfile.ZipFile('../pico8-clocktest.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    z.write('README.txt')
    for d, _, files in os.walk('cores'):
        for f in sorted(files):
            z.write(os.path.join(d, f))
")
find "$KIT" -type f | sort
ls -la "$ROOT/dist/pico8-clocktest.zip"
