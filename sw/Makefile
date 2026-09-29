# PICO-8 core program (fake-08 for the VexRiscv CPU).
#
# Requires the RISC-V toolchain from nix/toolchain.nix:
#   nix build --impure -f nix/toolchain.nix -o nix/result-toolchain

ROOT := $(abspath ..)
TOOLCHAIN ?= $(ROOT)/nix/result-toolchain/bin
CROSS := $(TOOLCHAIN)/riscv32-none-elf-
CC := $(CROSS)gcc
CXX := $(CROSS)g++
OBJCOPY := $(CROSS)objcopy
SIZE := $(CROSS)size

BUILD := build
# fake-08 is built from a copy with sw/fake08.patch applied.
FAKE08_ORIG := $(ROOT)/third_party/fake-08
FAKE08 := $(BUILD)/fake-08
FAKE08_STAMP := $(FAKE08)/.patched

ARCH := -march=rv32imc_zicsr -mabi=ilp32
OPT ?= -O3
DEFINES := -DMINIZ_NO_TIME -DMINIZ_NO_STDIO -D__GAMEBUB__
# newlib defines int32_t as long on RISC-V, which makes z8lua's fix32(int)
# ambiguous. Both are 32 bits (ilp32): use int, as on Linux.
DEFINES += -U__INT32_TYPE__ -D__INT32_TYPE__=int -U__UINT32_TYPE__ -D'__UINT32_TYPE__=unsigned int'
# Lua errors and coroutine yields with setjmp/longjmp instead of C++
# exceptions: fake-08 yields every frame, and unwinding is slow. (A Lua error
# raised in a fake-08 API function skips its destructors: a small leak.)
DEFINES += -DLUA_USE_LONGJMP
# z8lua: direct threaded instruction dispatch (sw/fake08.patch)
DEFINES += -DZ8_COMPUTED_GOTO
# The synthesizer runs on the audio core (audio_core.h), when the SoC has one.
DEFINES += -DAUDIO_CORE
INCLUDES := -I. -I$(FAKE08)/source -I$(FAKE08)/libs/z8lua -I$(FAKE08)/libs/lodepng \
	-I$(FAKE08)/libs/miniz -I$(FAKE08)/libs/simpleini
COMMON := $(ARCH) $(OPT) -g -ffunction-sections -fdata-sections -MMD -MP $(DEFINES) $(INCLUDES)
CFLAGS := $(COMMON) -std=gnu11 -Wall
CXXFLAGS := $(COMMON) -std=gnu++17 -fno-rtti -Wall -Wno-unused-variable -Wno-unused-but-set-variable \
	-Wno-sign-compare -Wno-unused-function -Wno-misleading-indentation
LDFLAGS := $(ARCH) -nostartfiles -T link.ld -Wl,--gc-sections -Wl,-Map,$(BUILD)/pico8.map

Z8LUA := eris lapi lauxlib lbaselib lbitlib lcode lcorolib lctype ldblib ldebug ldo ldump lfunc \
	lgc linit liolib llex lmem loadlib lobject lopcodes loslib lparser lpico8lib lstate lstring \
	lstrlib ltable ltablib ltests ltm lundump lvm lzio
FAKE08_SRC := Input cart emojiconversion filehelpers filter fontdata graphics \
	hostCommonFunctions logger mathhelpers nibblehelpers picoluaapi printHelper \
	stringToDataHelpers vm
# Audio.cpp and synth.cpp are replaced by audio.cpp (fixed point).

# z8lua is compiled as C++ (like the other fake-08 platforms).
OBJS := $(BUILD)/crt0.o $(BUILD)/syscalls.o $(BUILD)/gamebub.o $(BUILD)/audio.o \
	$(BUILD)/audio_core.o $(BUILD)/audio_core1.o \
	$(addprefix $(BUILD)/z8lua/,$(addsuffix .o,$(Z8LUA))) \
	$(addprefix $(BUILD)/fake08/,$(addsuffix .o,$(FAKE08_SRC))) \
	$(BUILD)/libs/lodepng.o $(BUILD)/libs/miniz.o $(BUILD)/libs/ConvertUTF.o

# The patched fake-08 copy is prepared first (its sources are then used by
# the pattern rules).
all:
	$(MAKE) $(FAKE08_STAMP)
	$(MAKE) $(BUILD)/pico8.bin

$(FAKE08_STAMP): fake08.patch
	rm -rf $(FAKE08)
	mkdir -p $(FAKE08)
	cp -r $(FAKE08_ORIG)/source $(FAKE08_ORIG)/libs $(FAKE08)/
	patch -p1 --quiet -d $(FAKE08) -i $(abspath fake08.patch)
	touch $@

$(BUILD)/gamebub.o $(BUILD)/audio.o $(BUILD)/audio_core.o $(BUILD)/audio_core1.o: $(FAKE08_STAMP)

$(BUILD)/pico8.elf: $(OBJS) link.ld
	$(CXX) $(LDFLAGS) -o $@ $(OBJS) -lstdc++ -lm -lc -lgcc
	$(SIZE) $@

# Padded to a multiple of 4 bytes: the host transfers whole 32-bit words only.
$(BUILD)/pico8.bin: $(BUILD)/pico8.elf
	$(OBJCOPY) -O binary $< $@
	truncate -s %4 $@

$(BUILD)/crt0.o: crt0.S
	@mkdir -p $(dir $@)
	$(CC) $(ARCH) -c -o $@ $<

$(BUILD)/syscalls.o: syscalls.c hw.h syscalls.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/gamebub.o: gamebub.cpp hw.h syscalls.h
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD)/audio.o: audio.cpp audio_core.h hw.h
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD)/audio_core.o: audio_core.cpp audio_core.h hw.h
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD)/audio_core1.o: audio_core1.cpp audio_core.h hw.h
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD)/z8lua/%.o: $(FAKE08)/libs/z8lua/%.c $(FAKE08_STAMP)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -x c++ -c -o $@ $<

$(BUILD)/fake08/%.o: $(FAKE08)/source/%.cpp $(FAKE08_STAMP)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD)/libs/lodepng.o: $(FAKE08)/libs/lodepng/lodepng.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD)/libs/miniz.o: $(FAKE08)/libs/miniz/miniz.c
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -x c++ -c -o $@ $<

$(BUILD)/libs/ConvertUTF.o: $(FAKE08)/libs/simpleini/ConvertUTF.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

-include $(OBJS:.o=.d)

clean:
	rm -rf $(BUILD)

.PHONY: all clean
