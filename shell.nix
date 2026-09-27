# Development shell: RISC-V toolchain (see nix/toolchain.nix), Verilator.
#   nix-shell   (or: nix develop --impure -f shell.nix)
let
  nixpkgs = builtins.getFlake "nixpkgs";
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  riscv = import ./nix/toolchain.nix;
in
pkgs.mkShell {
  packages = [ riscv pkgs.verilator pkgs.gnumake pkgs.python3 ];
}
