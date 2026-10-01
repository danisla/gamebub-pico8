"""
Prepare rtl/ for the Game Bub framework build.

The framework build (build_core.py) compiles every file in rtl/, choosing the
file type by extension. This copies the PICO-8 SoC sources and constraints
from hdl/ (including the generated VexRiscv CPU).
"""

import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HDL_DIR = ROOT / "hdl"
RTL_DIR = ROOT / "rtl"

SOURCES = [
    "pico8_gamebub.sv",
    "pico8_soc.sv",
    "pico8_sdram.sv",
    "pico8_gfx.sv",
    "pico8.xdc",
    "vexriscv/VexRiscv_Pico8.v",
    "vexii_adapter.sv",
    "vexiiriscv/VexiiRiscv.v",
]


def main() -> None:
    if RTL_DIR.exists():
        shutil.rmtree(RTL_DIR)
    RTL_DIR.mkdir()
    for rel in SOURCES:
        shutil.copy2(HDL_DIR / rel, RTL_DIR / Path(rel).name)
    print(f"Prepared {len(SOURCES)} files in {RTL_DIR}")


if __name__ == "__main__":
    main()
