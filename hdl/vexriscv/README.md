# VexRiscv (generated)

`VexRiscv_Pico8.v` is generated from [VexRiscv](https://github.com/SpinalHDL/VexRiscv)
(MIT license, see `LICENSE`) with the `GenCoreDefault` generator of
[pythondata-cpu-vexriscv](https://github.com/litex-hub/pythondata-cpu-vexriscv),
using `scripts/gen_vexriscv.sh`:

```
sbt compile "runMain vexriscv.GenCoreDefault --compressedGen true \
    --iCacheSize 32768 --dCacheSize 32768 --prediction dynamic_target \
    --csrPluginConfig small --outputFile VexRiscv_Pico8"
```

RV32IMC, 32 KiB direct mapped instruction and data caches (32 byte lines),
single cycle multiplier, Wishbone instruction and data buses. Addresses with bit
31 set are uncached (I/O).
