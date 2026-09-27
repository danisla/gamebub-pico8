// Host interface test: loads the program and a cart through the Chisel core's
// host memory map and command channel (as the Game Bub firmware does), runs
// the core, then reads back the save file.
//
// Usage: Vhost_top pico8.bin cart [frames] [save_in|-] [save_out]

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <memory>
#include <string>
#include <vector>

#include "Vhost_top.h"
#include "verilated.h"

namespace {

// Commands (HostV0)
constexpr uint32_t CMD_GET_STATUS = 0x0000;
constexpr uint32_t CMD_CORE_RUN = 0x0100;
constexpr uint32_t CMD_SETUP_COMPLETE = 0x0102;
constexpr uint32_t CMD_NOTIFY_FOCUS = 0x0200;
constexpr uint32_t CMD_FILE_WRITE_START = 0x0300;
constexpr uint32_t CMD_FILE_WRITE_END = 0x0301;
constexpr uint32_t CMD_FILE_READ_START = 0x0302;
constexpr uint32_t CMD_FILE_READ_END = 0x0303;
constexpr uint32_t STATUS_SETUP = 2;
constexpr uint32_t STATUS_CORE_HALT = 3;
constexpr uint32_t STATUS_CORE_RUN = 4;
constexpr uint32_t REG_CMD_HOST_BASE = 0xF0000000;

std::unique_ptr<Vhost_top> top;
uint64_t cycle = 0;
int failures = 0;

void tick() {
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
    cycle++;
}

void idle(int n) {
    for (int i = 0; i < n; i++) tick();
}

/// A host memory access: held until done (done is ignored in the first cycle).
uint32_t access(bool write, uint32_t address, uint32_t data) {
    top->mem_enable = 1;
    top->mem_write = write;
    top->mem_address = address;
    top->mem_wdata = data;
    tick();
    int timeout = 10000;
    while (!top->mem_done) {
        tick();
        if (--timeout == 0) {
            printf("FAIL: access timeout at %08x\n", address);
            exit(1);
        }
    }
    uint32_t result = top->mem_rdata;
    top->mem_enable = 0;
    top->mem_write = 0;
    tick();
    // The SPI receiver is much slower than the core clock.
    idle(4);
    return result;
}

void write32(uint32_t address, uint32_t data) { access(true, address, data); }
uint32_t read32(uint32_t address) { return access(false, address, 0); }

/// Run a command; returns response word 0. `expectError` inverts the check.
uint32_t command(std::vector<uint32_t> args, bool expectError = false) {
    for (size_t i = 0; i < 4; i++) write32(REG_CMD_HOST_BASE + 4 * i, i < args.size() ? args[i] : 0);
    top->cmd_request = 1;
    int timeout = 100000;
    while (!top->cmd_done && !top->cmd_error) {
        tick();
        if (--timeout == 0) {
            printf("FAIL: command %04x timeout\n", args[0]);
            exit(1);
        }
    }
    bool error = top->cmd_error;
    top->cmd_request = 0;
    tick();
    uint32_t result = read32(REG_CMD_HOST_BASE);
    if (error != expectError) {
        printf("FAIL: command %04x %s\n", args[0], error ? "error" : "no error");
        failures++;
    }
    return result;
}

void pollStatus(uint32_t want) {
    for (int i = 0; i < 1000; i++) {
        uint32_t status = command({CMD_GET_STATUS});
        if (status == want) return;
        idle(1000);
    }
    printf("FAIL: status never became %u\n", want);
    exit(1);
}

std::vector<uint8_t> readFile(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(1);
    }
    std::vector<uint8_t> data;
    int c;
    while ((c = fgetc(f)) != EOF) data.push_back(c);
    fclose(f);
    return data;
}

void loadFile(uint32_t id, uint32_t address, const std::vector<uint8_t> &data) {
    command({CMD_FILE_WRITE_START, id});
    // Like the firmware and the FPGA's SPI receiver: a partial last word
    // (file size not a multiple of 4) is never written.
    for (size_t i = 0; i + 4 <= data.size(); i += 4) {
        uint32_t word = 0;
        for (size_t j = 0; j < 4 && i + j < data.size(); j++) word |= (uint32_t)data[i + j] << (8 * j);
        write32(address + i, word);
    }
    command({CMD_FILE_WRITE_END, id, (uint32_t)data.size(), 0});
}

} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) {
        fprintf(stderr, "usage: %s pico8.bin cart [frames]\n", argv[0]);
        return 1;
    }
    int frames = argc > 3 ? atoi(argv[3]) : 60;
    top = std::make_unique<Vhost_top>();
    top->reset = 1;
    idle(10);
    top->reset = 0;
    idle(10);

    // CoreRun before the program is loaded must fail.
    pollStatus(STATUS_SETUP);
    printf("[host] status: setup (cycle %lu)\n", (unsigned long)cycle);
    command({CMD_CORE_RUN}, true);

    auto program = readFile(argv[1]);
    auto cart = readFile(argv[2]);
    // files.json order: cart (0), program (1), save (2: missing, cleared to 0xFF)
    loadFile(0, 0x20000000, cart);
    printf("[host] cart loaded (%zu bytes, cycle %lu)\n", cart.size(), (unsigned long)cycle);
    loadFile(1, 0x10000000, program);
    printf("[host] program loaded (%zu bytes, cycle %lu)\n", program.size(), (unsigned long)cycle);
    const char *saveIn = argc > 4 ? argv[4] : "-";
    const char *saveOut = argc > 5 ? argv[5] : nullptr;
    FILE *sf = strcmp(saveIn, "-") ? fopen(saveIn, "rb") : nullptr;
    if (sf) {
        fclose(sf);
        auto save = readFile(saveIn);
        loadFile(2, 0x40000000, save);
        printf("[host] save loaded (%zu bytes)\n", save.size());
    } else {
        // Missing file: the firmware clears the slot (initialize).
        loadFile(2, 0x40000000, std::vector<uint8_t>(0x1000, 0xFF));
    }

    // Read back a few words of the program through the host interface.
    for (uint32_t off : {0u, 4u, 0x1000u, (uint32_t)(program.size() & ~3u) - 4}) {
        uint32_t want = 0;
        for (int j = 0; j < 4; j++) want |= (uint32_t)program[off + j] << (8 * j);
        uint32_t got = read32(0x10000000 + off);
        if (got != want) {
            printf("FAIL: program readback @%x: %08x != %08x\n", off, got, want);
            failures++;
        }
    }

    command({CMD_SETUP_COMPLETE});
    pollStatus(STATUS_CORE_HALT);
    command({CMD_CORE_RUN});
    command({CMD_NOTIFY_FOCUS, 1});
    if (command({CMD_GET_STATUS}) != STATUS_CORE_RUN) {
        printf("FAIL: not running\n");
        failures++;
    }
    printf("[host] running (cycle %lu)\n", (unsigned long)cycle);

    int n = 0;
    bool prev = false;
    while (n < frames) {
        tick();
        if (top->vblank && !prev) {
            n++;
            if (n % 30 == 0) printf("[host] frame %d\n", n), fflush(stdout);
        }
        prev = top->vblank;
    }

    // Save file
    uint32_t saveSize = command({CMD_FILE_READ_START, 2});
    printf("[host] save size %u\n", saveSize);
    if (saveSize > 0x1000) {
        printf("FAIL: save size\n");
        failures++;
    }
    uint32_t magic = read32(0x40000000);
    printf("[host] save[0] = %08x\n", magic);
    if (saveOut && saveSize <= 0x1000) {
        FILE *f = fopen(saveOut, "wb");
        for (uint32_t i = 0; i < saveSize; i += 4) {
            uint32_t w = read32(0x40000000 + i);
            fwrite(&w, 1, std::min<uint32_t>(4, saveSize - i), f);
        }
        fclose(f);
        printf("[host] save written to %s\n", saveOut);
    }
    command({CMD_FILE_READ_END, 2});

    // Log file
    uint32_t logSize = command({CMD_FILE_READ_START, 3});
    std::string log;
    for (uint32_t i = 0; i < logSize && i < 0x4000; i += 4) {
        uint32_t w = read32(0x50000000 + i);
        for (int j = 0; j < 4 && i + j < logSize; j++) log += (char)(w >> (8 * j));
    }
    command({CMD_FILE_READ_END, 3});
    printf("[host] log size %u, starts with: %.60s\n", logSize, log.c_str());
    if (logSize == 0 || log.find("PICO-8 core") == std::string::npos) {
        printf("FAIL: log\n");
        failures++;
    }

    // Unknown command
    command({0x7777}, true);

    printf(failures ? "[host] FAILED (%d)\n" : "[host] PASSED\n", failures);
    top->final();
    return failures ? 1 : 0;
}
