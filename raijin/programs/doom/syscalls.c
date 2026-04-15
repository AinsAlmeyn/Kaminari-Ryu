/* syscalls.c: newlib syscall layer for Doom on Raijin.
 *
 * Replaces the old freestanding approach. We now link against newlib
 * (via --specs=nano.specs) so we get snprintf, strdup, ctype, malloc,
 * fopen/fread machinery, etc. for free. In return we provide the tiny
 * POSIX surface newlib needs at the bottom.
 *
 * Surface:
 *   _write    -> UART (stdout/stderr)
 *   _read     -> UART RX (blocking poll)
 *   _sbrk     -> bump allocator over a 3 MB pool
 *   _open     -> recognises "doom1.wad", fails every other path
 *   _close,_lseek,_fstat,_isatty,_read over our WAD fd
 *   _exit     -> tohost handshake
 *   _kill,_getpid,__errno -> stubs
 */

#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>

#include "../../../tools/c-runtime/shims/util.h"

extern unsigned char doom_wad_data[];
extern unsigned int  doom_wad_size;

extern volatile uint32_t tohost;

/* ------------------------------------------------------------------ */
/* Heap: grow from _bss_end upward, stop short of the stack.           */
/* The linker script leaves ~3 MB between _bss_end and _stack_top;     */
/* we reserve 256 KB of stack headroom at the top.                     */
/* ------------------------------------------------------------------ */
extern char _bss_end;        /* linker symbol */
extern char _stack_top;      /* linker symbol */
#define STACK_RESERVE (256u * 1024u)

static char *heap_ptr = 0;

void *_sbrk(int incr) {
    if (!heap_ptr) heap_ptr = &_bss_end;
    char *limit = &_stack_top - STACK_RESERVE;
    if (heap_ptr + incr > limit) {
        errno = ENOMEM;
        return (void *)-1;
    }
    char *prev = heap_ptr;
    heap_ptr += incr;
    return prev;
}

/* ------------------------------------------------------------------ */
/* File table: fd 0/1/2 = stdin/stdout/stderr (UART); fd 3 = the WAD. */
/* ------------------------------------------------------------------ */
#define FD_WAD 3
static int      wad_open = 0;
static uint32_t wad_pos  = 0;

static int path_matches_wad(const char *p) {
    int n = 0; while (p[n]) n++;
    if (n < 9) return 0;
    const char *t = p + (n - 9);
    static const char want[] = "doom1.wad";
    for (int i = 0; i < 9; i++) {
        char a = t[i]; if (a >= 'A' && a <= 'Z') a += 32;
        if (a != want[i]) return 0;
    }
    return 1;
}

int _open(const char *path, int flags, int mode) {
    (void)flags; (void)mode;
    if (!path_matches_wad(path)) { errno = ENOENT; return -1; }
    wad_open = 1;
    wad_pos  = 0;
    return FD_WAD;
}

int _close(int fd) {
    if (fd == FD_WAD) { wad_open = 0; return 0; }
    return 0;
}

off_t _lseek(int fd, off_t off, int whence) {
    if (fd != FD_WAD || !wad_open) { errno = EBADF; return -1; }
    long base = (whence == 0) ? 0 : (whence == 1 ? (long)wad_pos : (long)doom_wad_size);
    long np = base + off;
    if (np < 0) np = 0;
    if (np > (long)doom_wad_size) np = doom_wad_size;
    wad_pos = (uint32_t)np;
    return wad_pos;
}

int _read(int fd, char *buf, int len) {
    if (fd == 0) {
        /* stdin: block until a byte is there. Doom rarely reads stdin. */
        while (!uart_rx_poll()) { /* spin */ }
        buf[0] = (char)uart_rx_get();
        return 1;
    }
    if (fd != FD_WAD || !wad_open) { errno = EBADF; return -1; }
    uint32_t left = doom_wad_size - wad_pos;
    uint32_t want = (uint32_t)len;
    if (want > left) want = left;
    for (uint32_t i = 0; i < want; i++) buf[i] = (char)doom_wad_data[wad_pos + i];
    wad_pos += want;
    return (int)want;
}

/* Set to 1 by DG_Init the moment Doom takes the screen. Boot chatter before
 * that point prints normally; after that, stdout/stderr traffic is dropped
 * so it stops interleaving with the ASCII framebuffer. */
int raijin_frame_owns_uart = 0;

int _write(int fd, const char *buf, int len) {
    if (raijin_frame_owns_uart && fd != 99) return len;  /* swallow */
    for (int i = 0; i < len; i++) putchar_(buf[i]);
    return len;
}

int _fstat(int fd, struct stat *st) {
    if (fd == FD_WAD) { st->st_mode = S_IFREG; st->st_size = doom_wad_size; return 0; }
    st->st_mode = S_IFCHR;  /* tty-like */
    return 0;
}

int _isatty(int fd) { return (fd == 0 || fd == 1 || fd == 2); }

int _stat(const char *path, struct stat *st) {
    if (path_matches_wad(path)) {
        st->st_mode = S_IFREG;
        st->st_size = doom_wad_size;
        return 0;
    }
    errno = ENOENT;
    return -1;
}

int access(const char *path, int mode) {
    (void)mode;
    return path_matches_wad(path) ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* Process / signal stubs                                              */
/* ------------------------------------------------------------------ */
int _getpid(void) { return 1; }
int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }

__attribute__((noreturn)) void _exit(int code) {
    tohost = ((uint32_t)code << 1) | 1u;
    for (;;) { __asm__ volatile ("nop"); }
}

/* Doom calls these but we don't actually need them to do anything.   */
int system(const char *cmd) { (void)cmd; return -1; }
int rename(const char *a, const char *b) { (void)a; (void)b; return -1; }
int remove(const char *a) { (void)a; return -1; }
int mkdir(const char *p, mode_t m) { (void)p; (void)m; return 0; }

/* Newlib reentrancy: single-threaded, so point everything at one impure. */
int *__errno(void) { static int e = 0; return &e; }
