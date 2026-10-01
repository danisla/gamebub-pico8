#!/usr/bin/env python3
"""Lua VM microbenchmarks: x86 instructions per loop iteration (callgrind)
for z8lua (fake-08's Lua, the native-check build, run as a cart) and stock
Lua 5.2 (nixpkgs), for each kind of operation, to find where z8lua is
slower. Each benchmark runs N iterations and 0 iterations: the difference
divided by N is the cost of one iteration (the loop itself included).

    nix-shell -p gcc gnumake --run "make -C sim/audiocmp native-check"
    python3 sim/audiocmp/vmbench.py [name...]

Needs valgrind and lua5_2 from nixpkgs (nix shell nixpkgs#valgrind
nixpkgs#lua5_2), and runs the benchmarks in parallel."""
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
NATIVE = HERE / "native-check"
N = 20000

# name: (setup, loop body), plain Lua 5.2 (also valid for z8lua). The loop
# variable is i; globals are g, t, arr, obj.
BENCHES = {
    "empty":        ("", ""),
    "local_add":    ("local x=0", "x=x+i"),
    "local_mul":    ("local x=1", "x=x*1"),
    "local_div":    ("local x=1", "x=x/1"),
    "global_get":   ("g=1 local x", "x=g"),
    "global_set":   ("g=1", "g=i"),
    "global_inc":   ("g=1", "g=g+1"),
    "field_get":    ("local t={a=1,b=2} local x", "x=t.a"),
    "field_set":    ("local t={a=1,b=2}", "t.a=i"),
    "array_get":    ("local a={1,2,3,4} local x", "x=a[2]"),
    "array_set":    ("local a={1,2,3,4}", "a[2]=i"),
    "call":         ("local function f(v) return v end local x", "x=f(i)"),
    "method":       ("local o={v=1} function o:m() return self.v end local x", "x=o:m()"),
    "compare":      ("local x=0", "if x<i then x=x+1 end"),
    "closure":      ("local x", "x=function() return i end"),
    "table_new":    ("local x", "x={i}"),
    "concat":       ("local x", "x='a'..'b'"),
}

def lua_source(setup, body, n):
    return f"{setup}\nfor i=1,{n} do\n{body}\nend\n"

def cart(src):
    return "pico-8 cartridge // http://www.pico-8.com\nversion 41\n__lua__\n" + \
        "function _init()\n" + src + "end\nfunction _update() end\n"

def callgrind_total(cmd, cwd):
    out = Path(cwd) / f"cg.{os.getpid()}.{abs(hash(tuple(cmd)))}"
    subprocess.run(["valgrind", "--tool=callgrind", f"--callgrind-out-file={out}"] + cmd,
                   cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ann = subprocess.run(["callgrind_annotate", str(out)], capture_output=True, text=True).stdout
    for line in ann.splitlines():
        if "PROGRAM TOTALS" in line:
            return int(line.split()[0].replace(",", ""))
    raise RuntimeError(f"no callgrind total for {cmd}")

def run(name, tmp):
    setup, body = BENCHES[name]
    res = {}
    for impl in ("z8lua", "lua5.2"):
        totals = []
        for n in (0, N):
            src = lua_source(setup, body, n)
            if impl == "z8lua":
                p = Path(tmp) / f"{name}-{n}.p8"
                p.write_text(cart(src))
                cmd = [str(NATIVE), str(p), "3", os.devnull]
            else:
                cmd = ["lua", "-e", src]
            totals.append(callgrind_total(cmd, tmp))
        res[impl] = (totals[1] - totals[0]) / N
    return name, res

def main():
    names = sys.argv[1:] or list(BENCHES)
    with tempfile.TemporaryDirectory() as tmp, ThreadPoolExecutor(8) as ex:
        results = dict(ex.map(lambda n: run(n, tmp), names))
    base = results.get("empty")
    print(f"{'benchmark':<12} {'z8lua':>8} {'lua5.2':>8} {'ratio':>6}   (x86 instructions per iteration"
          + (", minus the empty loop" if base else "") + ")")
    for name in names:
        z, s = results[name]["z8lua"], results[name]["lua5.2"]
        if base and name != "empty":
            z -= base["z8lua"]
            s -= base["lua5.2"]
        print(f"{name:<12} {z:8.1f} {s:8.1f} {z / s if s > 0 else float('nan'):6.2f}")

if __name__ == "__main__":
    main()
