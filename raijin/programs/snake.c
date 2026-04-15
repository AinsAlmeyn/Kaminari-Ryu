/* snake.c: classic snake on Raijin's UART terminal.
 *
 * Design notes
 * ────────────
 * - Terminal cells are roughly 2:1 (taller than wide), so vertical motion
 *   *looks* twice as fast as horizontal at the same step rate. We fix that
 *   by painting every game cell as TWO characters wide ("##" body, "()"
 *   head, "<>" food). The board logical grid is 30×16 but it occupies
 *   60×16 terminal columns, which is visually square.
 *
 * - Top-left margin keeps the game from hugging the corner.
 *
 * - State machine: title screen ─Space→ playing ─collision→ game-over
 *   ─R→ playing ─Q→ exit. No need to press Reset on the dashboard between
 *   rounds; press R inside the game.
 *
 * Build:
 *   python tools/runners/run_c_program.py raijin/programs/snake.c \
 *       -I tools/c-runtime/shims --name snake --march rv32im_zicsr
 */

#include <stdint.h>
#include "util.h"

/* Logical board (each cell is 2 terminal chars wide). */
#define BW 30
#define BH 16

/* Where the playfield sits on the terminal (1-indexed, ANSI rows/cols). */
#define MARGIN_ROW  3
#define MARGIN_COL  4

/* Painted width of the game on screen (border + cells × 2). */
#define VIS_W  (BW * 2 + 2)

#define MAX_LEN (BW * BH)

static int sx[MAX_LEN], sy[MAX_LEN];
static int head, tail;
static int dx, dy;
static int food_x, food_y;
static int score;
static unsigned rng = 0xCAFEBABEu;

/* ────── ANSI helpers ────── */
static void ansi_clear(void)       { puts_("\x1b[2J\x1b[H\x1b[?25l"); }
static void ansi_show_cursor(void) { puts_("\x1b[?25h"); }

static void cursor_at(int row, int col) {
    puts_("\x1b[");
    putint_(row);
    putchar_(';');
    putint_(col);
    putchar_('H');
}

/* Convert game (gx, gy) to terminal (row, col) for the LEFT char of the cell. */
static void cell_at(int gx, int gy) {
    cursor_at(MARGIN_ROW + 1 + gy, MARGIN_COL + 1 + gx * 2);
}

static void draw_pair(const char *s) { putchar_(s[0]); putchar_(s[1]); }

/* ────── Drawing primitives ────── */
static void draw_border(void) {
    /* Top edge */
    cursor_at(MARGIN_ROW, MARGIN_COL);
    putchar_('+');
    for (int i = 0; i < BW * 2; i++) putchar_('-');
    putchar_('+');

    /* Sides */
    for (int r = 0; r < BH; r++) {
        cursor_at(MARGIN_ROW + 1 + r, MARGIN_COL);
        putchar_('|');
        cursor_at(MARGIN_ROW + 1 + r, MARGIN_COL + 1 + BW * 2);
        putchar_('|');
    }

    /* Bottom edge */
    cursor_at(MARGIN_ROW + 1 + BH, MARGIN_COL);
    putchar_('+');
    for (int i = 0; i < BW * 2; i++) putchar_('-');
    putchar_('+');
}

static void clear_inside(void) {
    for (int r = 0; r < BH; r++) {
        cursor_at(MARGIN_ROW + 1 + r, MARGIN_COL + 1);
        for (int c = 0; c < BW * 2; c++) putchar_(' ');
    }
}

static void status_line(int row_offset) {
    cursor_at(MARGIN_ROW + 1 + BH + row_offset, MARGIN_COL);
    /* Erase the line first to avoid leftover characters. */
    for (int i = 0; i < VIS_W; i++) putchar_(' ');
    cursor_at(MARGIN_ROW + 1 + BH + row_offset, MARGIN_COL);
}

static void draw_status(void) {
    status_line(1);
    puts_("score \x1b[1m");
    putint_(score);
    puts_("\x1b[0m");
    status_line(2);
    puts_("\x1b[2mwasd to move   space pause   q quit\x1b[0m");
}

/* ────── Game logic ────── */
static int snake_hits(int x, int y) {
    int i = tail;
    while (i != head) {
        if (sx[i] == x && sy[i] == y) return 1;
        i = (i + 1) % MAX_LEN;
    }
    return 0;
}

static void place_food(void) {
    for (;;) {
        food_x = (int)(rng_next_(&rng) % BW);
        food_y = (int)(rng_next_(&rng) % BH);
        if (!snake_hits(food_x, food_y)) {
            cell_at(food_x, food_y);
            draw_pair("<>");
            return;
        }
    }
}

static void init_round(void) {
    int cx = BW / 2, cy = BH / 2;
    head = 0; tail = 0;
    for (int i = 0; i < 4; i++) {
        sx[head] = cx - 3 + i;
        sy[head] = cy;
        head = (head + 1) % MAX_LEN;
    }
    dx = 1; dy = 0;
    score = 0;

    clear_inside();
    /* Paint initial body */
    int it = tail;
    int last = (head + MAX_LEN - 1) % MAX_LEN;
    while (it != head) {
        cell_at(sx[it], sy[it]);
        if (it == last) draw_pair("()");
        else            draw_pair("##");
        it = (it + 1) % MAX_LEN;
    }
    place_food();
    draw_status();
}

/* ────── Title + game-over screens ────── */
static void center_text(int row, const char *s) {
    int len = 0;
    for (const char *p = s; *p; p++) len++;
    int col = MARGIN_COL + 1 + (BW * 2 - len) / 2;
    if (col < MARGIN_COL + 1) col = MARGIN_COL + 1;
    cursor_at(row, col);
    puts_(s);
}

static void show_title(void) {
    clear_inside();
    int mid = MARGIN_ROW + 1 + BH / 2;
    center_text(mid - 3, "\x1b[1mS N A K E\x1b[0m");
    center_text(mid - 1, "\x1b[2mwasd to move\x1b[0m");
    center_text(mid    , "\x1b[2mspace pause   q quit\x1b[0m");
    center_text(mid + 2, "press \x1b[1mSPACE\x1b[0m to start");
}

static void show_game_over(void) {
    int mid = MARGIN_ROW + 1 + BH / 2;
    /* Black-out a 5-line ribbon in the middle so the corpse is hidden. */
    for (int r = mid - 2; r <= mid + 2; r++) {
        cursor_at(r, MARGIN_COL + 1);
        for (int c = 0; c < BW * 2; c++) putchar_(' ');
    }
    center_text(mid - 1, "\x1b[1mG A M E   O V E R\x1b[0m");
    char buf[40];
    int n = 0;
    const char *pre = "final score ";
    for (const char *p = pre; *p; p++) buf[n++] = *p;
    int s = score, start = n;
    if (s == 0) buf[n++] = '0';
    else {
        char tmp[12]; int t = 0;
        while (s > 0) { tmp[t++] = (char)('0' + (s % 10)); s /= 10; }
        while (t--) buf[n++] = tmp[t];
    }
    (void)start;
    buf[n] = '\0';
    center_text(mid + 1, buf);
    status_line(1);
    puts_("\x1b[2mR\x1b[0m play again   \x1b[2mQ\x1b[0m quit         ");
    status_line(2);
    puts_("                                                           ");
}

/* Wait for a specific key; ignore everything else. Returns the key. */
static int wait_keys(const char *accept) {
    for (;;) {
        int k = uart_rx_poll();
        if (k > 0) {
            for (const char *p = accept; *p; p++)
                if (k == *p) return k;
        }
        delay_ms_(20);
    }
}

/* ────── Main loop ────── */
int main(void) {
    ansi_clear();
    draw_border();

restart:
    show_title();
    {
        int k = wait_keys(" q");
        if (k == 'q') goto quit;
    }
    init_round();

    int paused = 0;
    for (;;) {
        delay_ms_(140);

        for (;;) {
            int k = uart_rx_poll();
            if (k < 0) break;
            if (k == 'w' && dy ==  0) { dx =  0; dy = -1; }
            if (k == 's' && dy ==  0) { dx =  0; dy =  1; }
            if (k == 'a' && dx ==  0) { dx = -1; dy =  0; }
            if (k == 'd' && dx ==  0) { dx =  1; dy =  0; }
            if (k == ' ') paused = !paused;
            if (k == 'q') goto quit;
        }

        if (paused) continue;

        int prev_head = (head + MAX_LEN - 1) % MAX_LEN;
        int nx = sx[prev_head] + dx;
        int ny = sy[prev_head] + dy;

        /* wall hit */
        if (nx < 0 || nx >= BW || ny < 0 || ny >= BH) goto game_over;
        /* self hit */
        if (snake_hits(nx, ny)) goto game_over;

        int ate = (nx == food_x && ny == food_y);

        /* Demote previous head from "()" to "##" body. */
        cell_at(sx[prev_head], sy[prev_head]);
        draw_pair("##");

        /* Push new head. */
        sx[head] = nx;
        sy[head] = ny;
        cell_at(nx, ny);
        draw_pair("()");
        head = (head + 1) % MAX_LEN;

        if (!ate) {
            cell_at(sx[tail], sy[tail]);
            draw_pair("  ");
            tail = (tail + 1) % MAX_LEN;
        } else {
            score += 10;
            place_food();
            draw_status();
        }
    }

game_over:
    show_game_over();
    {
        int k = wait_keys("rRqQ");
        if (k == 'r' || k == 'R') goto restart;
    }

quit:
    cursor_at(MARGIN_ROW + 1 + BH + 4, MARGIN_COL);
    puts_("thanks for playing.\r\n");
    ansi_show_cursor();
    return 0;
}
