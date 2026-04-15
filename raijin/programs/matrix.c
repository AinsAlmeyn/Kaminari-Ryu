/* matrix.c: monochrome "Matrix rain" effect for Raijin's terminal.
 *
 * Each terminal column owns a falling stream of glyphs. The head moves
 * down one cell per frame; when it leaves the screen the column is
 * re-seeded at a random row with a random length and speed offset.
 * Trail cells are dimmed via ANSI; the head is drawn bold + bright.
 *
 * Press q to quit.
 *
 * Build:
 *   python tools/runners/run_c_program.py raijin/programs/matrix.c \
 *       -I tools/c-runtime/shims --name matrix --march rv32im_zicsr
 */

#include <stdint.h>
#include "util.h"

#define W       80
#define H       28
#define COLS    W

/* Per-column state */
static int     head_y[COLS];     /* current head row */
static int     trail [COLS];     /* trail length */
static uint8_t skip  [COLS];     /* "speed" -- skip this many frames */
static uint8_t skip_ctr[COLS];

static unsigned rng = 0xC0FFEE42u;

/* Glyphs we cycle through. Mix of digits, latin, half-width box bits. */
static const char glyphs[] =
    "0123456789ABCDEF<>/\\|-_=+:;*#%@$&";

static char rand_glyph(void) {
    return glyphs[rng_next_(&rng) % (sizeof(glyphs) - 1)];
}

static void cursor_at(int row, int col) {
    puts_("\x1b[");
    putint_(row);
    putchar_(';');
    putint_(col);
    putchar_('H');
}

static void seed_column(int c) {
    head_y[c]   = -(int)(rng_next_(&rng) % H);   /* start above screen */
    trail[c]    = 4 + (rng_next_(&rng) % (H - 4));
    skip[c]     = (uint8_t)(rng_next_(&rng) % 3);  /* 0..2 extra frames */
    skip_ctr[c] = 0;
}

int main(void) {
    puts_("\x1b[2J\x1b[?25l");

    for (int c = 0; c < COLS; c++) seed_column(c);

    for (;;) {
        int k = uart_rx_poll();
        if (k == 'q') break;

        for (int c = 0; c < COLS; c++) {
            if (skip_ctr[c]) { skip_ctr[c]--; continue; }
            skip_ctr[c] = skip[c];

            /* Erase the cell that just left the trail's tail. */
            int erase_y = head_y[c] - trail[c];
            if (erase_y >= 0 && erase_y < H) {
                cursor_at(erase_y + 1, c + 1);
                putchar_(' ');
            }

            /* Dim the previous head into the body of the trail. */
            int prev_y = head_y[c];
            if (prev_y >= 0 && prev_y < H) {
                cursor_at(prev_y + 1, c + 1);
                puts_("\x1b[2m");
                putchar_(rand_glyph());
                puts_("\x1b[0m");
            }

            /* Advance head. */
            head_y[c]++;
            int hy = head_y[c];
            if (hy >= 0 && hy < H) {
                cursor_at(hy + 1, c + 1);
                puts_("\x1b[1m");
                putchar_(rand_glyph());
                puts_("\x1b[0m");
            }

            /* Re-seed once the entire trail has fallen off the bottom. */
            if (hy - trail[c] >= H) seed_column(c);
        }

        delay_ms_(60);
    }

    puts_("\x1b[?25h\x1b[H\x1b[2J");
    puts_("matrix stopped.\r\n");
    return 0;
}
