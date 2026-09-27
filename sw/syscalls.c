// Newlib system calls for the PICO-8 core.
//
// There is no real file system: files are kept in RAM. Files under "cdata/"
// (PICO-8 cart data, written by fake-08) are persisted in the save buffer,
// which the host saves next to the cart.

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <unistd.h>

#include "hw.h"
#include "syscalls.h"

#undef errno
extern int errno;

////////////////////////////////////////////////////////////////////////////
// Console
////////////////////////////////////////////////////////////////////////////

void console_write(const char *buf, size_t len) {
    for (size_t i = 0; i < len; i++) {
        REG_CONSOLE = (uint8_t)buf[i];
    }
}

void console_puts(const char *s) {
    console_write(s, strlen(s));
}

static void console_hex(uint32_t v) {
    char buf[11] = "0x";
    for (int i = 0; i < 8; i++) {
        buf[2 + i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 0xF];
    }
    buf[10] = 0;
    console_puts(buf);
}

static uint32_t misaligned_traps;

uint32_t misaligned_trap_count(void) {
    return misaligned_traps;
}

static uint32_t load_bytes(uint32_t addr, int size, int is_signed) {
    uint32_t v = 0;
    for (int i = 0; i < size; i++) v |= (uint32_t)((volatile uint8_t *)addr)[i] << (8 * i);
    if (is_signed && size == 2) v = (uint32_t)(int32_t)(int16_t)v;
    return v;
}

static void store_bytes(uint32_t addr, int size, uint32_t v) {
    for (int i = 0; i < size; i++) ((volatile uint8_t *)addr)[i] = v >> (8 * i);
}

/// Emulate a misaligned load or store (VexRiscv traps on them). Returns the
/// instruction length, or 0 if the instruction isn't handled.
static int emulate_misaligned(uint32_t *regs, uint32_t mepc, uint32_t addr) {
    uint16_t lo = *(volatile uint16_t *)mepc;
    if ((lo & 3) != 3) {
        // Compressed: C.LW, C.SW, C.LWSP, C.SWSP
        uint32_t op = ((lo >> 13) << 2) | (lo & 3);
        uint32_t rd_p = 8 + ((lo >> 2) & 7);
        uint32_t rs2_p = 8 + ((lo >> 2) & 7);
        switch (op) {
            case 0x08: regs[rd_p] = load_bytes(addr, 4, 0); return 2;          // C.LW
            case 0x18: store_bytes(addr, 4, regs[rs2_p]); return 2;             // C.SW
            case 0x0A: {                                                        // C.LWSP
                uint32_t rd = (lo >> 7) & 31;
                if (rd) regs[rd] = load_bytes(addr, 4, 0);
                return 2;
            }
            case 0x1A: store_bytes(addr, 4, regs[(lo >> 2) & 31]); return 2;   // C.SWSP
            default: return 0;
        }
    }
    uint32_t insn = lo | ((uint32_t)*(volatile uint16_t *)(mepc + 2) << 16);
    uint32_t opcode = insn & 0x7F;
    uint32_t funct3 = (insn >> 12) & 7;
    uint32_t rd = (insn >> 7) & 31;
    uint32_t rs2 = (insn >> 20) & 31;
    if (opcode == 0x03) {
        uint32_t v;
        switch (funct3) {
            case 1: v = load_bytes(addr, 2, 1); break; // LH
            case 2: v = load_bytes(addr, 4, 0); break; // LW
            case 5: v = load_bytes(addr, 2, 0); break; // LHU
            default: return 0;
        }
        if (rd) regs[rd] = v;
        return 4;
    }
    if (opcode == 0x23) {
        switch (funct3) {
            case 1: store_bytes(addr, 2, regs[rs2]); return 4; // SH
            case 2: store_bytes(addr, 4, regs[rs2]); return 4; // SW
            default: return 0;
        }
    }
    return 0;
}

/// Trap handler (called from crt0.S with the saved registers x0..x31).
void trap_handler(uint32_t *regs) {
    uint32_t mcause, mepc, mtval;
    __asm__ volatile("csrr %0, mcause" : "=r"(mcause));
    __asm__ volatile("csrr %0, mepc" : "=r"(mepc));
    __asm__ volatile("csrr %0, mtval" : "=r"(mtval));

    if (mcause == 4 || mcause == 6) {
        int len = emulate_misaligned(regs, mepc, mtval);
        if (len) {
            misaligned_traps++;
            mepc += len;
            __asm__ volatile("csrw mepc, %0" :: "r"(mepc));
            return;
        }
    }

    console_puts("\n*** trap: mcause=");
    console_hex(mcause);
    console_puts(" mepc=");
    console_hex(mepc);
    console_puts(" mtval=");
    console_hex(mtval);
    console_puts(" ra=");
    console_hex(regs[1]);
    console_puts(" sp=");
    console_hex(regs[2]);
    console_puts("\n");
    REG_SIM_EXIT = 0x100 | (mcause & 0xFF);
    for (;;) {}
}

/// Byte-wise memcmp: newlib's compares words without checking alignment.
int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *pa = a, *pb = b;
    if ((((uintptr_t)pa | (uintptr_t)pb) & 3) == 0) {
        while (n >= 4 && *(const uint32_t *)pa == *(const uint32_t *)pb) {
            pa += 4;
            pb += 4;
            n -= 4;
        }
    }
    for (; n; n--, pa++, pb++) {
        if (*pa != *pb) return *pa - *pb;
    }
    return 0;
}

////////////////////////////////////////////////////////////////////////////
// Memory
////////////////////////////////////////////////////////////////////////////

/// Used by C++ static destructor registration (normally from crtbegin.o).
void *__dso_handle = 0;

extern char __heap_start[];
extern char __heap_end[];
static char *heap_top = __heap_start;

void *_sbrk(ptrdiff_t incr) {
    char *prev = heap_top;
    if (heap_top + incr > __heap_end || heap_top + incr < __heap_start) {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_top += incr;
    return prev;
}

size_t heap_used(void) {
    return (size_t)(heap_top - __heap_start);
}

////////////////////////////////////////////////////////////////////////////
// RAM file system
////////////////////////////////////////////////////////////////////////////

#define MAX_FILES 32
#define MAX_FDS 16
#define FD_FIRST 3
#define SAVE_MAGIC 0x56533850u // "P8SV"
#define SAVE_DIR "cdata/"

struct ram_file {
    char *name;
    char *data;
    size_t size;
    size_t capacity;
};

struct fd_entry {
    int file;       // index into files, or -1 for the console
    size_t pos;
    int flags;
    int dirty;
    int used;
};

static struct ram_file files[MAX_FILES];
static struct fd_entry fds[MAX_FDS];

static int is_console_path(const char *name) {
    size_t len = strlen(name);
    return len >= 4 && strcmp(name + len - 4, ".log") == 0;
}

static int is_save_path(const char *name) {
    return strstr(name, SAVE_DIR) != NULL;
}

static int find_file(const char *name) {
    for (int i = 0; i < MAX_FILES; i++) {
        if (files[i].name && strcmp(files[i].name, name) == 0) return i;
    }
    return -1;
}

static int create_file(const char *name) {
    for (int i = 0; i < MAX_FILES; i++) {
        if (!files[i].name) {
            files[i].name = strdup(name);
            files[i].data = NULL;
            files[i].size = 0;
            files[i].capacity = 0;
            return i;
        }
    }
    return -1;
}

static int file_reserve(struct ram_file *f, size_t size) {
    if (size <= f->capacity) return 0;
    size_t capacity = f->capacity ? f->capacity : 256;
    while (capacity < size) capacity *= 2;
    char *data = realloc(f->data, capacity);
    if (!data) return -1;
    f->data = data;
    f->capacity = capacity;
    return 0;
}

/// Write all save files to the save buffer.
static void save_flush(void) {
    uint8_t buf[SAVE_BUFFER_SIZE];
    size_t pos = 8;
    uint32_t count = 0;
    for (int i = 0; i < MAX_FILES; i++) {
        struct ram_file *f = &files[i];
        if (!f->name || !is_save_path(f->name)) continue;
        size_t name_len = strlen(f->name);
        if (pos + 4 + name_len + f->size > sizeof(buf)) {
            console_puts("save buffer full, not saving ");
            console_puts(f->name);
            console_puts("\n");
            continue;
        }
        buf[pos++] = name_len & 0xFF;
        buf[pos++] = name_len >> 8;
        buf[pos++] = f->size & 0xFF;
        buf[pos++] = f->size >> 8;
        memcpy(buf + pos, f->name, name_len);
        pos += name_len;
        memcpy(buf + pos, f->data, f->size);
        pos += f->size;
        count++;
    }
    uint32_t magic = SAVE_MAGIC;
    memcpy(buf, &magic, 4);
    memcpy(buf + 4, &count, 4);
    pos = (pos + 3) & ~3u;
    for (size_t i = 0; i < pos / 4; i++) {
        uint32_t word;
        memcpy(&word, buf + 4 * i, 4);
        SAVE_BUFFER[i] = word;
    }
    REG_SAVE_SIZE = pos;
}

void fs_init(void) {
    // Load save files from the save buffer (initialized to 0xFF by the host
    // when there's no save file).
    if (SAVE_BUFFER[0] != SAVE_MAGIC) return;
    uint8_t buf[SAVE_BUFFER_SIZE];
    for (size_t i = 0; i < SAVE_BUFFER_SIZE / 4; i++) {
        uint32_t word = SAVE_BUFFER[i];
        memcpy(buf + 4 * i, &word, 4);
    }
    uint32_t count;
    memcpy(&count, buf + 4, 4);
    size_t pos = 8;
    for (uint32_t n = 0; n < count; n++) {
        if (pos + 4 > sizeof(buf)) break;
        size_t name_len = buf[pos] | (buf[pos + 1] << 8);
        size_t size = buf[pos + 2] | (buf[pos + 3] << 8);
        pos += 4;
        if (pos + name_len + size > sizeof(buf) || name_len == 0 || name_len > 255) break;
        char name[256];
        memcpy(name, buf + pos, name_len);
        name[name_len] = 0;
        pos += name_len;
        int i = create_file(name);
        if (i < 0 || file_reserve(&files[i], size) < 0) break;
        memcpy(files[i].data, buf + pos, size);
        files[i].size = size;
        pos += size;
    }
    REG_SAVE_SIZE = (pos + 3) & ~3u;
}

int _open(const char *name, int flags, int mode) {
    (void)mode;
    int fd;
    for (fd = FD_FIRST; fd < MAX_FDS; fd++) {
        if (!fds[fd].used) break;
    }
    if (fd == MAX_FDS) {
        errno = EMFILE;
        return -1;
    }

    int file;
    if (is_console_path(name)) {
        file = -1;
    } else {
        file = find_file(name);
        if (file < 0) {
            if (!(flags & O_CREAT)) {
                errno = ENOENT;
                return -1;
            }
            file = create_file(name);
            if (file < 0) {
                errno = ENOSPC;
                return -1;
            }
        }
        if (flags & O_TRUNC) {
            files[file].size = 0;
        }
    }

    fds[fd].used = 1;
    fds[fd].file = file;
    fds[fd].flags = flags;
    fds[fd].dirty = (flags & O_TRUNC) != 0;
    fds[fd].pos = (file >= 0 && (flags & O_APPEND)) ? files[file].size : 0;
    return fd;
}

static struct fd_entry *get_fd(int fd) {
    if (fd < FD_FIRST || fd >= MAX_FDS || !fds[fd].used) {
        errno = EBADF;
        return NULL;
    }
    return &fds[fd];
}

int _close(int fd) {
    if (fd < FD_FIRST) return 0;
    struct fd_entry *e = get_fd(fd);
    if (!e) return -1;
    if (e->dirty && e->file >= 0 && is_save_path(files[e->file].name)) {
        save_flush();
    }
    e->used = 0;
    return 0;
}

int _write(int fd, const char *buf, int len) {
    if (fd == 1 || fd == 2) {
        console_write(buf, len);
        return len;
    }
    struct fd_entry *e = get_fd(fd);
    if (!e) return -1;
    if (e->file < 0) {
        // Log files (fake-08's logger also prints everything to stdout).
        return len;
    }
    struct ram_file *f = &files[e->file];
    if (e->flags & O_APPEND) e->pos = f->size;
    if (file_reserve(f, e->pos + len) < 0) {
        errno = ENOSPC;
        return -1;
    }
    if (e->pos > f->size) memset(f->data + f->size, 0, e->pos - f->size);
    memcpy(f->data + e->pos, buf, len);
    e->pos += len;
    if (e->pos > f->size) f->size = e->pos;
    e->dirty = 1;
    return len;
}

int _read(int fd, char *buf, int len) {
    if (fd < FD_FIRST) return 0;
    struct fd_entry *e = get_fd(fd);
    if (!e) return -1;
    if (e->file < 0) return 0;
    struct ram_file *f = &files[e->file];
    if (e->pos >= f->size) return 0;
    size_t n = f->size - e->pos;
    if (n > (size_t)len) n = len;
    memcpy(buf, f->data + e->pos, n);
    e->pos += n;
    return n;
}

int _lseek(int fd, int offset, int whence) {
    if (fd < FD_FIRST) return 0;
    struct fd_entry *e = get_fd(fd);
    if (!e) return -1;
    size_t size = e->file >= 0 ? files[e->file].size : 0;
    long pos;
    switch (whence) {
        case SEEK_SET: pos = offset; break;
        case SEEK_CUR: pos = (long)e->pos + offset; break;
        case SEEK_END: pos = (long)size + offset; break;
        default: errno = EINVAL; return -1;
    }
    if (pos < 0) {
        errno = EINVAL;
        return -1;
    }
    e->pos = pos;
    return pos;
}

int _fstat(int fd, struct stat *st) {
    memset(st, 0, sizeof(*st));
    if (fd < FD_FIRST) {
        st->st_mode = S_IFCHR;
        return 0;
    }
    struct fd_entry *e = get_fd(fd);
    if (!e) return -1;
    if (e->file < 0) {
        st->st_mode = S_IFCHR;
    } else {
        st->st_mode = S_IFREG;
        st->st_size = files[e->file].size;
    }
    return 0;
}

int _stat(const char *name, struct stat *st) {
    memset(st, 0, sizeof(*st));
    int file = find_file(name);
    if (file < 0) {
        errno = ENOENT;
        return -1;
    }
    st->st_mode = S_IFREG;
    st->st_size = files[file].size;
    return 0;
}

int _isatty(int fd) {
    return fd < FD_FIRST;
}

int _unlink(const char *name) {
    int file = find_file(name);
    if (file < 0) {
        errno = ENOENT;
        return -1;
    }
    int save = is_save_path(name);
    free(files[file].name);
    free(files[file].data);
    memset(&files[file], 0, sizeof(files[file]));
    if (save) save_flush();
    return 0;
}

int _link(const char *old, const char *new) {
    (void)old;
    (void)new;
    errno = EMLINK;
    return -1;
}

int mkdir(const char *path, mode_t mode) {
    (void)path;
    (void)mode;
    return 0;
}

////////////////////////////////////////////////////////////////////////////
// Process and time
////////////////////////////////////////////////////////////////////////////

void abort(void) {
    console_puts("\n[abort] caller=");
    console_hex((uint32_t)__builtin_return_address(0));
    console_puts("\n");
    REG_SIM_EXIT = 0x200;
    for (;;) {}
}

void _exit(int code) {
    console_puts("\n[exit] caller=");
    console_hex((uint32_t)__builtin_return_address(0));
    console_puts("\n");
    REG_SIM_EXIT = code;
    for (;;) {}
}

int _kill(int pid, int sig) {
    (void)pid;
    (void)sig;
    errno = EINVAL;
    return -1;
}

int _getpid(void) {
    return 1;
}

int _gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    uint64_t cycles = hw_cycles();
    uint32_t hz = REG_CLOCK_HZ;
    tv->tv_sec = cycles / hz;
    tv->tv_usec = (cycles % hz) / (hz / 1000000);
    return 0;
}

clock_t _times(struct tms *buf) {
    uint64_t ticks = hw_cycles() / (REG_CLOCK_HZ / CLOCKS_PER_SEC);
    buf->tms_utime = ticks;
    buf->tms_stime = 0;
    buf->tms_cutime = 0;
    buf->tms_cstime = 0;
    return ticks;
}
