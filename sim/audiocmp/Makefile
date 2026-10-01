# Native audio comparison: fake-08's audio (ref) vs sw/audio.cpp (fixed).
ROOT := $(abspath ../..)
F := $(ROOT)/third_party/fake-08
CXX ?= g++
FLAGS := -O2 -std=gnu++17 -w -DMINIZ_NO_TIME -I$(F)/source -I$(F)/libs/z8lua -I$(F)/libs/lodepng \
	-I$(F)/libs/miniz -I$(F)/libs/simpleini -I$(F)/platform/libretro
Z8 := eris lapi lauxlib lbaselib lbitlib lcode lcorolib lctype ldblib ldebug ldo ldump lfunc lgc linit \
	liolib llex lmem loadlib lobject lopcodes loslib lparser lpico8lib lstate lstring lstrlib ltable \
	ltablib ltests ltm lundump lvm lzio
COMMON_SRC := $(addprefix $(F)/libs/z8lua/,$(addsuffix .c,$(Z8))) $(F)/libs/miniz/miniz.c \
	$(F)/libs/lodepng/lodepng.cpp $(F)/libs/simpleini/ConvertUTF.c \
	$(addprefix $(F)/source/,Input.cpp cart.cpp emojiconversion.cpp filehelpers.cpp filter.cpp \
	fontdata.cpp graphics.cpp hostCommonFunctions.cpp logger.cpp mathhelpers.cpp nibblehelpers.cpp \
	picoluaapi.cpp printHelper.cpp stringToDataHelpers.cpp vm.cpp) \
	$(F)/platform/libretro/libretrohost.cpp native_main.cpp

all: ref fixed patched

ref: $(COMMON_SRC)
	$(CXX) $(FLAGS) -x c++ $(COMMON_SRC) $(F)/source/Audio.cpp $(F)/source/synth.cpp -o $@

fixed: $(COMMON_SRC) $(ROOT)/sw/audio.cpp
	$(CXX) $(FLAGS) -x c++ $(COMMON_SRC) $(ROOT)/sw/audio.cpp -o $@

# fixed audio + the patched fake-08 (sw/fake08.patch), to check graphics changes
P := $(ROOT)/sw/build/fake-08
PFLAGS := -O2 -std=gnu++17 -w -DMINIZ_NO_TIME -I$(P)/source -I$(P)/libs/z8lua -I$(P)/libs/lodepng \
	-I$(P)/libs/miniz -I$(P)/libs/simpleini -I$(F)/platform/libretro
PATCHED_SRC := $(addprefix $(P)/libs/z8lua/,$(addsuffix .c,$(Z8))) $(P)/libs/miniz/miniz.c \
	$(P)/libs/lodepng/lodepng.cpp $(P)/libs/simpleini/ConvertUTF.c \
	$(addprefix $(P)/source/,Input.cpp cart.cpp emojiconversion.cpp filehelpers.cpp filter.cpp \
	fontdata.cpp graphics.cpp hostCommonFunctions.cpp logger.cpp mathhelpers.cpp nibblehelpers.cpp \
	picoluaapi.cpp printHelper.cpp stringToDataHelpers.cpp vm.cpp) \
	$(F)/platform/libretro/libretrohost.cpp native_main.cpp

patched: $(PATCHED_SRC) $(ROOT)/sw/audio.cpp
	$(CXX) $(PFLAGS) -x c++ $(PATCHED_SRC) $(ROOT)/sw/audio.cpp -o $@

# The patched fake-08 with fixed seeds, for sim/native_check.sh (always rebuilt).
native-check: $(PATCHED_SRC) $(ROOT)/sw/audio.cpp
	$(CXX) $(PFLAGS) -g -DZ8_FIXED_SEED -include z8hooks.h -x c++ $(PATCHED_SRC) $(ROOT)/sw/audio.cpp -o $@

.PHONY: native-check

# original fake-08 graphics with the fixed audio (same audio as patched)
fixed-orig: $(COMMON_SRC) $(ROOT)/sw/audio.cpp
	$(CXX) $(FLAGS) -x c++ $(COMMON_SRC) $(ROOT)/sw/audio.cpp -o $@

# Reproducible comparisons of VM changes: fixed string hash seed, with and
# without computed goto dispatch (both from the patched tree).
seed-switch: $(PATCHED_SRC) $(ROOT)/sw/audio.cpp
	$(CXX) $(PFLAGS) -DZ8_FIXED_SEED -x c++ $(PATCHED_SRC) $(ROOT)/sw/audio.cpp -o $@
seed-goto: $(PATCHED_SRC) $(ROOT)/sw/audio.cpp
	$(CXX) $(PFLAGS) -DZ8_FIXED_SEED -DZ8_COMPUTED_GOTO -x c++ $(PATCHED_SRC) $(ROOT)/sw/audio.cpp -o $@
nofast-spr: $(PATCHED_SRC) $(ROOT)/sw/audio.cpp
	$(CXX) $(PFLAGS) -DZ8_NO_FAST_SPR -x c++ $(PATCHED_SRC) $(ROOT)/sw/audio.cpp -o $@
nofast-text: $(PATCHED_SRC) $(ROOT)/sw/audio.cpp
	$(CXX) $(PFLAGS) -DZ8_NO_FAST_TEXT -x c++ $(PATCHED_SRC) $(ROOT)/sw/audio.cpp -o $@
