# RISC-V cross toolchain for the PICO-8 core's CPU (VexRiscv RV32IMC, no FPU).
#   nix build -f nix/toolchain.nix
let
  nixpkgs = builtins.getFlake "nixpkgs";
  pkgs = import nixpkgs {
    localSystem = "x86_64-linux";
    crossSystem = {
      config = "riscv32-none-elf";
      libc = "newlib";
      gcc = {
        arch = "rv32imc_zicsr";
        abi = "ilp32";
      };
    };
  };
in
pkgs.buildPackages.gcc
