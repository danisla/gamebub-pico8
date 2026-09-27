// Hardware registers of the PICO-8 core SoC (see hdl/pico8_soc.sv).
#pragma once

#include <stdint.h>

#define IO_BASE 0xF0000000u
#define IO_REG(offset) (*(volatile uint32_t *)(IO_BASE + (offset)))

#define REG_ID            IO_REG(0x0000)
#define REG_CLOCK_HZ      IO_REG(0x0004)
#define REG_CYCLE_LO      IO_REG(0x0008) // Reading latches REG_CYCLE_HI
#define REG_CYCLE_HI      IO_REG(0x000C)
#define REG_BUTTONS       IO_REG(0x0010)
#define REG_STATUS        IO_REG(0x0014)
#define REG_CART_SIZE     IO_REG(0x0018)
#define REG_FRAME_COUNT   IO_REG(0x001C)
#define REG_VIDEO_CTRL    IO_REG(0x0020)
#define REG_AUDIO         IO_REG(0x0024) // Write: push sample. Read: samples queued.
#define REG_CONSOLE       IO_REG(0x0028)
#define REG_SIM_EXIT      IO_REG(0x002C)
#define REG_SAVE_SIZE     IO_REG(0x0030)
#define REG_PALETTE(i)    IO_REG(0x0100 + 4 * (i)) // Back buffer display palette, RGB888

#define FRAMEBUFFER       ((volatile uint32_t *)(IO_BASE + 0x10000)) // Back buffer, 2048 words
#define SAVE_BUFFER       ((volatile uint32_t *)(IO_BASE + 0x20000)) // 1024 words
#define SAVE_BUFFER_SIZE  4096

#define STATUS_FOCUS      (1u << 0)

#define VIDEO_CTRL_FLIP_PENDING (1u << 0)

#define AUDIO_FIFO_SIZE   4096
#define AUDIO_RATE        22050

// Button bits: {start, select, r, l, y, x, b, a, up, down, left, right}
#define BTN_RIGHT   (1u << 0)
#define BTN_LEFT    (1u << 1)
#define BTN_DOWN    (1u << 2)
#define BTN_UP      (1u << 3)
#define BTN_A       (1u << 4)
#define BTN_B       (1u << 5)
#define BTN_X       (1u << 6)
#define BTN_Y       (1u << 7)
#define BTN_L       (1u << 8)
#define BTN_R       (1u << 9)
#define BTN_SELECT  (1u << 10)
#define BTN_START   (1u << 11)

// The cart is loaded here by the host.
#define CART_BASE   0x01F00000u
#define CART_MAX    0x00100000u

static inline uint64_t hw_cycles(void) {
    uint32_t lo = REG_CYCLE_LO;
    uint32_t hi = REG_CYCLE_HI;
    return ((uint64_t)hi << 32) | lo;
}
