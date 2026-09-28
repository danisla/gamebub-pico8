// Seeds of the clocktest CPU kernel runs.
#pragma once
#include <stdint.h>

#define NUM_SEEDS 8

static inline uint32_t seed_of(int i) { return (uint32_t)i * 0x9E3779B9u + 0x12345u; }
