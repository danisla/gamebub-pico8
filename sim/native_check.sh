#!/usr/bin/env bash
# Quick check of a software change (fake-08 / sw/build/fake-08 sources), without
# the RTL simulation: builds fake-08 natively (x86, sim/audiocmp/native_main.cpp)
# and runs carts for a fixed number of VM steps, writing a hash of the PICO-8
# screen after each step and the audio. The runs are deterministic (fixed
# seeds, presses timed in steps), so two builds can be compared exactly:
#
#   sim/native_check.sh before     # with the old sources
#   (change the sources in sw/build/fake-08)
#   sim/native_check.sh after
#   sim/native_check.sh compare before after
#
# NATIVE_BIN=path runs a native-check binary built elsewhere (e.g. from a
# copy of the sources: make -C sim/audiocmp native-check P=copy).
#
# Results go to sim/out/native/NAME/. Takes a minute or so. (It checks the
# emulator's logic, not RISC-V specifics: the accelerator, the CPU's own
# behavior and timing need the RTL simulation.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/sim/out/native"
CARTS="$ROOT/sim/carts"
FRAMES="${FRAMES:-1800}"

# cart, presses (step:PICO-8 button mask:length; 1 left, 2 right, 4 up,
# 8 down, 16 O, 32 X)
RUNS=(
    "dinkykong-0.p8.png|150:16:10,300:2:120,480:1:100,700:2:200,1000:16:10"
    "beckon_the_hellspawn-2.p8.png|120:32:10,300:32:10,400:2:60,600:4:60,800:32:10"
    "celeste-0.p8.png|100:16:10,200:16:10,300:2:100,450:16:10,600:2:60"
    "porklike-2.p8.png|100:16:10,200:16:10,300:2:60,400:4:30,500:16:10"
    "gfxtest.p8|"
    "poom-0.p8.png|120:32:10,200:32:10,300:32:10"
    "praxis_fighter_x-2.p8.png|300:32:10,400:2:60,500:16:30,600:1:60,700:32:10"
)

if [ "${1:-}" = compare ]; then
    a="$OUT/$2" b="$OUT/$3" bad=0
    for r in "${RUNS[@]}"; do
        cart="${r%%|*}"
        name="${cart%%.*}"
        if ! cmp -s "$a/$name.hash" "$b/$name.hash"; then
            first=$(diff "$a/$name.hash" "$b/$name.hash" | sed -n 's/^< \([0-9]*\) .*/\1/p' | head -n1 || true)
            echo "$name: screens differ (first at step $first)"
            bad=1
        elif ! cmp -s "$a/$name.wav" "$b/$name.wav"; then
            echo "$name: audio differs"
            bad=1
        else
            echo "$name: same ($(wc -l < "$a/$name.hash") steps)"
        fi
    done
    exit $bad
fi

name="${1:?usage: native_check.sh NAME | compare NAME1 NAME2}"
dir="$OUT/$name"
mkdir -p "$dir"
# NATIVE_BIN: run that binary instead of building sim/audiocmp/native-check.
BIN="${NATIVE_BIN:-$ROOT/sim/audiocmp/native-check}"
[ -n "${NATIVE_BIN:-}" ] || make -s -C "$ROOT/sim/audiocmp" native-check
for r in "${RUNS[@]}"; do
    cart="${r%%|*}"
    presses="${r#*|}"
    base="${cart%%.*}"
    PRESSES="$presses" FB_HASH="$dir/$base.hash" "$BIN" \
        "$CARTS/$cart" "$FRAMES" "$dir/$base.wav" > "$dir/$base.log" 2>&1 &
done
wait
echo "wrote $dir"
