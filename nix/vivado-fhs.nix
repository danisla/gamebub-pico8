# FHS environment for running Vivado on NixOS:
#   $(nix build --impure -f nix/vivado-fhs.nix --print-out-paths)/bin/vivado-env -c "<command>"
let
  nixpkgs = builtins.getFlake "nixpkgs";
  pkgs = import nixpkgs { system = "x86_64-linux"; };
in
pkgs.buildFHSEnv {
  name = "vivado-env";
  targetPkgs = pkgs: with pkgs; [
    bash coreutils gnumake gnugrep gnused gawk findutils which procps git python3 perl
    ncurses5 ncurses zlib libxcrypt-legacy libuuid glib freetype fontconfig
    stdenv.cc.cc.lib gcc
    xorg.libX11 xorg.libXext xorg.libXrender xorg.libXtst xorg.libXi xorg.libXft xorg.libxcb
    gtk3 nss nspr alsa-lib pixman cairo libpng libjpeg expat libxml2 libdrm libGL dbus
    xorg.libXrandr xorg.libXcursor xorg.libXinerama xorg.libSM xorg.libICE xorg.libXau xorg.libXdmcp
  ];
  profile = ''
    export PATH=$HOME/Xilinx/2026.1/Vivado/bin:$PATH
    export LC_ALL=C
    # Vivado's loader doesn't find libraries via the FHS ld.so cache.
    export LD_LIBRARY_PATH=/usr/lib64''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  '';
  runScript = "bash";
}
