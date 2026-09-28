// CPU test kernels for clocktest: deterministic integer workloads (ALU,
// shifts, multiply, divide, branches, indirect jumps, byte/halfword/word
// loads and stores), each returning a checksum.
//
// Compiled three times: natively (gen_expected.c, for the expected results),
// and for the soft CPU once in block RAM and once in SDRAM (KERNEL_SDRAM),
// so that both instruction fetch paths are tested. Built with
// -fno-strict-aliasing: the scratch memory is accessed as bytes, halfwords
// and words.
#include <stdint.h>

#ifdef KERNEL_SDRAM
#define KERNEL_NAME(n) n##_sdram
#define KERNEL_SECTION __attribute__((section(".sdram_text")))
#else
#define KERNEL_NAME(n) n
#define KERNEL_SECTION
#endif
#define KERNEL(n) KERNEL_SECTION __attribute__((noinline)) uint32_t KERNEL_NAME(n)

/// Scratch memory used by the kernels (bytes).
#define KERNEL_SCRATCH 8192

static inline __attribute__((always_inline)) uint32_t xs(uint32_t x) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

// Bitwise CRC-32 of 4 KiB of pseudo random data.
KERNEL(k_crc)(uint32_t seed, uint32_t *scratch) {
    uint32_t x = seed;
    for (int i = 0; i < 1024; i++) scratch[i] = x = xs(x);
    const uint8_t *p = (const uint8_t *)scratch;
    uint32_t crc = 0xFFFFFFFFu;
    for (int i = 0; i < 4096; i++) {
        crc ^= p[i];
        for (int b = 0; b < 8; b++) crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
    }
    return ~crc;
}

// Multiplies: 32x32 -> 64 bit (mul, mulh, mulhu, mulhsu).
KERNEL(k_mul)(uint32_t seed, uint32_t *scratch) {
    (void)scratch;
    uint32_t a = seed, b = seed ^ 0x5bd1e995u;
    uint64_t acc = 0;
    for (int i = 0; i < 4096; i++) {
        a = xs(a);
        b = xs(b);
        acc += (uint64_t)a * b;
        acc ^= (uint64_t)((int64_t)(int32_t)a * (int32_t)b) >> 7;
        acc += (uint64_t)((int64_t)(int32_t)a * (int64_t)(uint64_t)b) >> 3;
        acc = (acc << 1) | (acc >> 63);
    }
    return (uint32_t)acc ^ (uint32_t)(acc >> 32);
}

// Divides and remainders, unsigned and signed.
KERNEL(k_div)(uint32_t seed, uint32_t *scratch) {
    (void)scratch;
    uint32_t a = seed, acc = 0;
    for (int i = 0; i < 2048; i++) {
        a = xs(a);
        uint32_t d = (a >> (a & 15)) | 1;
        acc = acc * 31 + a / d + a % d;
        int32_t sa = (int32_t)a;
        int32_t sd = (int32_t)((d >> 1) | 1);
        if (a & 0x100) sd = sd == 1 ? -3 : -sd; // (not INT_MIN / -1)
        acc = acc * 17 + (uint32_t)(sa / sd) + (uint32_t)(sa % sd);
    }
    return acc;
}

// Shell sort of 1024 words (branches, loads/stores), then a checksum.
KERNEL(k_sort)(uint32_t seed, uint32_t *scratch) {
    uint32_t x = seed;
    const int n = 1024;
    for (int i = 0; i < n; i++) scratch[i] = x = xs(x);
    static const int gaps[] = { 701, 301, 132, 57, 23, 10, 4, 1 };
    for (int g = 0; g < 8; g++) {
        int gap = gaps[g];
        for (int i = gap; i < n; i++) {
            uint32_t v = scratch[i];
            int j = i;
            while (j >= gap && scratch[j - gap] > v) {
                scratch[j] = scratch[j - gap];
                j -= gap;
            }
            scratch[j] = v;
        }
    }
    uint32_t sum = 0;
    for (int i = 0; i < n; i++) {
        if (i > 0 && scratch[i - 1] > scratch[i]) sum += 0x80000000u; // unsorted
        sum = sum * 33 + scratch[i];
    }
    return sum;
}

// A small bytecode interpreter with computed goto dispatch (like the Lua VM).
KERNEL(k_interp)(uint32_t seed, uint32_t *scratch) {
    uint8_t *code = (uint8_t *)scratch;
    uint32_t x = seed;
    const int len = 256;
    for (int i = 0; i < len - 1; i++) {
        x = xs(x);
        code[i] = (uint8_t)(x % 7);
    }
    code[len - 1] = 7; // loop
    static const void *const ops[] = {
        &&op_add, &&op_xor, &&op_shl, &&op_mul, &&op_load, &&op_store, &&op_branch, &&op_loop,
    };
    uint32_t r0 = seed, r1 = ~seed, r2 = 0x9E3779B9u;
    uint32_t *mem = scratch + 128;  // 64 words after the code
    int pc = 0, iterations = 0;
#define NEXT goto *ops[code[pc++]]
    NEXT;
op_add:    r0 += r1; NEXT;
op_xor:    r1 ^= r0 >> 3; NEXT;
op_shl:    { uint32_t s = r0 & 7; if (s) r2 = (r2 << s) | (r2 >> (32 - s)); } NEXT;
op_mul:    r0 = r0 * r2 + 1; NEXT;
op_load:   r1 += mem[r0 & 63]; NEXT;
op_store:  mem[r1 & 63] = r0 ^ r2; NEXT;
op_branch: if (r0 & 1) r2 += r1; else r1 -= r2; NEXT;
op_loop:
    pc = 0;
    if (++iterations < 64) NEXT;
#undef NEXT
    return r0 ^ r1 ^ r2;
}

// Byte, halfword and word stores and loads (sign and zero extension).
KERNEL(k_mem)(uint32_t seed, uint32_t *scratch) {
    uint8_t *b = (uint8_t *)scratch;
    uint16_t *h = (uint16_t *)scratch;
    uint32_t x = seed, acc = 0;
    for (int i = 0; i < KERNEL_SCRATCH / 4; i++) scratch[i] = 0;
    for (int i = 0; i < 4096; i++) {
        x = xs(x);
        uint32_t o = x & (KERNEL_SCRATCH - 1);
        switch ((x >> 13) & 3) {
        case 0: b[o] = (uint8_t)x; break;
        case 1: h[o >> 1] = (uint16_t)(x >> 8); break;
        case 2: scratch[o >> 2] = x; break;
        default:
            acc += (uint32_t)(int8_t)b[o] + h[o >> 1] + (uint32_t)(int16_t)h[(o >> 1) ^ 1] + scratch[o >> 2];
            break;
        }
    }
    for (int i = 0; i < KERNEL_SCRATCH / 4; i++) acc = acc * 7 + scratch[i];
    return acc;
}
