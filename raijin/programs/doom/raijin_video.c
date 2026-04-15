/* raijin_video.c: doomgeneric DG_DrawFrame implementation.
 *
 * Output format is a 160x50 grid of terminal cells, where each cell uses
 * the U+2584 "lower half block" (▄) character plus two ANSI 256-color
 * attributes:
 *
 *   - background color  -> the top half of the cell (a "pixel")
 *   - foreground color  -> the bottom half of the cell (a "pixel")
 *
 * That gives 160x100 effective pixels from a 640x400 source framebuffer
 * (doomgeneric's default — it auto-scales Doom's 320x200 internal buffer
 * 2x on both axes). Each half-cell averages a 4x4 block of source pixels.
 * Colors are matched to the 6x6x6 ANSI cube (indices 16..231).
 *
 * Per-cell we only emit the SGR fields that actually changed since the
 * previous cell, so runs of sky/floor collapse to bare glyphs.
 */

#include <stdint.h>
#include "doomgeneric.h"

#include "../../../tools/c-runtime/shims/util.h"   /* putchar_, puts_ */

#define OUT_W  160
#define OUT_H  50

#define IN_W   DOOMGENERIC_RESX             /* 640 */
#define IN_H   DOOMGENERIC_RESY             /* 400 */
#define BLK_W  (IN_W / OUT_W)               /* 4 */
#define BLK_H  (IN_H / (OUT_H * 2))         /* 4 — two half-cells per cell row */

extern int raijin_frame_owns_uart;

void DG_Init(void) {
    /* Clear + hide cursor. Frames afterwards just home the cursor. */
    puts_("\x1b[2J\x1b[?25l\x1b[H");
    raijin_frame_owns_uart = 1;
}

/* Map an 8-bit channel to the 6x6x6 color cube's 0..5 axis. */
static inline int ch6(unsigned v) {
    if (v <  48) return 0;
    if (v < 115) return 1;
    if (v < 155) return 2;
    if (v < 195) return 3;
    if (v < 235) return 4;
    return 5;
}

/* Average a BLK_W x BLK_H block of BGRA pixels starting at (ix, iy) and
 * return the corresponding ANSI 256 color cube index. */
static inline int block_color(const uint32_t *fb, int ix, int iy) {
    uint32_t rsum = 0, gsum = 0, bsum = 0;
    const uint32_t *row = fb + iy * IN_W + ix;
    for (int dy = 0; dy < BLK_H; dy++) {
        for (int dx = 0; dx < BLK_W; dx++) {
            uint32_t px = row[dx];
            bsum += (px      ) & 0xFFu;
            gsum += (px >>  8) & 0xFFu;
            rsum += (px >> 16) & 0xFFu;
        }
        row += IN_W;
    }
    const int div = BLK_W * BLK_H;
    unsigned r = rsum / div;
    unsigned g = gsum / div;
    unsigned b = bsum / div;
    return 16 + 36 * ch6(r) + 6 * ch6(g) + ch6(b);
}

static inline void emit_u8(unsigned v) {
    if (v >= 100) { putchar_('0' + v / 100); v %= 100; putchar_('0' + v / 10); putchar_('0' + v % 10); return; }
    if (v >=  10) { putchar_('0' + v / 10);  putchar_('0' + v % 10); return; }
    putchar_('0' + v);
}

/* U+2584 "lower half block" — 3 bytes UTF-8. */
static inline void emit_halfblock(void) {
    putchar_((char)0xE2);
    putchar_((char)0x96);
    putchar_((char)0x84);
}

void DG_DrawFrame(void) {
    puts_("\x1b[H\x1b[0m");

    uint32_t *fb = (uint32_t *)DG_ScreenBuffer;
    int last_top = -1, last_bot = -1;

    for (int oy = 0; oy < OUT_H; oy++) {
        /* Each terminal row covers 2 * BLK_H = 8 source rows. Top half is
         * the first BLK_H rows, bottom half is the next BLK_H rows. */
        int iy_top = oy * (BLK_H * 2);
        int iy_bot = iy_top + BLK_H;

        last_top = -1; last_bot = -1;

        for (int ox = 0; ox < OUT_W; ox++) {
            int ix  = ox * BLK_W;
            int top = block_color(fb, ix, iy_top);
            int bot = block_color(fb, ix, iy_bot);

            int need_top = (top != last_top);
            int need_bot = (bot != last_bot);

            if (need_top && need_bot) {
                putchar_('\x1b'); putchar_('[');
                putchar_('4'); putchar_('8'); putchar_(';'); putchar_('5'); putchar_(';');
                emit_u8((unsigned)top);
                putchar_(';');
                putchar_('3'); putchar_('8'); putchar_(';'); putchar_('5'); putchar_(';');
                emit_u8((unsigned)bot);
                putchar_('m');
            } else if (need_top) {
                putchar_('\x1b'); putchar_('[');
                putchar_('4'); putchar_('8'); putchar_(';'); putchar_('5'); putchar_(';');
                emit_u8((unsigned)top);
                putchar_('m');
            } else if (need_bot) {
                putchar_('\x1b'); putchar_('[');
                putchar_('3'); putchar_('8'); putchar_(';'); putchar_('5'); putchar_(';');
                emit_u8((unsigned)bot);
                putchar_('m');
            }
            emit_halfblock();

            last_top = top;
            last_bot = bot;
        }
        puts_("\x1b[0m");
        putchar_('\n');
    }
    /* Clear anything below our 50 rows so old text/frames don't bleed. */
    puts_("\x1b[J");
}
