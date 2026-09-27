// Platform functions provided by syscalls.c.
#pragma once

#include <stddef.h>
#include <stdint.h>

void console_write(const char *buf, size_t len);
void console_puts(const char *s);
/// Load the save files from the save buffer.
void fs_init(void);
/// Number of emulated misaligned accesses.
uint32_t misaligned_trap_count(void);
/// Bytes of heap in use.
size_t heap_used(void);
