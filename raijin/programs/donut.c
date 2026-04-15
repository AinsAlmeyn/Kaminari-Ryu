/* donut.c: Andy Sloane's rotating-torus ASCII demo, ported to Raijin.
 *
 * No math library, no floats, no sine table either: the trigonometric
 * iteration uses a fixed-point rotation matrix (R macro), with periodic
 * length renormalisation so the (sin, cos) pair never drifts off the
 * unit circle. Multiplications are heavy here, which makes this a perfect
 * showcase for the M extension we just added. Runs forever; press
 * Pause/Reset on the dashboard to stop.
 *
 * Original article: https://www.a1k0n.net/2021/01/13/optimizing-donut.html
 *
 * Build:
 *   python tools/runners/run_c_program.py raijin/programs/donut.c \
 *       -I tools/c-runtime/shims --name donut --march rv32im_zicsr
 */

#include <stdint.h>
#include "util.h"

/* R(mul, shift, x, y): rotate the (x, y) Q10 vector by a tiny angle whose
 * tangent is mul/2^shift, then renormalise so x*x + y*y stays around 2^20.
 * The constant 3145728 = 3 << 20 is the "leash" that pulls (x, y) back
 * onto the unit circle if rounding has nudged them off. */
#define R(mul, shift, x, y)            \
    tmp = (x);                         \
    (x) -= (mul) * (y) >> (shift);     \
    (y) += (mul) * tmp >> (shift);     \
    tmp = 3145728 - (x) * (x) - (y) * (y) >> 11; \
    (x) = (x) * tmp >> 10;             \
    (y) = (y) * tmp >> 10;

static int8_t b[1760];   /* 80 cols * 22 rows screen buffer */
static int8_t z[1760];   /* signed 8-bit z-buffer (smaller value = closer) */

static const char shades[] = ".,-~:;=!*#$@";

static void fill(int8_t *p, int8_t v, int n) {
    for (int i = 0; i < n; i++) p[i] = v;
}

int main(void) {
    /* (cA, sA) = rotation around X axis. (cB, sB) = rotation around Z axis.
     * Initial values: angle 0, so cos=1024 (Q10 = 1.0), sin=0. We start with
     * sA=1024 and cA=0 to match Andy's setup (90° offset). */
    int cA = 0, sA = 1024;
    int cB = 0, sB = 1024;
    int tmp;

    /* Hide cursor, clear screen once. Subsequent frames just home-cursor. */
    puts_("\x1b[2J\x1b[?25l");

    for (;;) {
        fill(b, ' ',  1760);
        fill(z, 127,  1760);

        /* j sweeps the big ring (phi). 60 steps = 6° apart.
         * i sweeps the small ring (theta). 200 steps.
         * The original article uses 90 / 324 for buttery smooth at 60 FPS;
         * we trim to 60 / 200 (~2.4x fewer points) so the simulator can
         * push out a recognisable frame every second or so. */
        int cj = 1024, sj = 0;
        for (int j = 0; j < 60; j++) {
            int ci = 1024, si = 0;
            for (int i = 0; i < 200; i++) {
                int R1 = 1, R2 = 2048, K2 = 5120 * 1024;

                int x0 = R1 * cj + R2;
                int x1 = ci * x0 >> 10;
                int x2 = cA * sj >> 10;
                int x3 = si * x0 >> 10;
                int x4 = R1 * x2 - (sA * x3 >> 10);
                int x5 = sA * sj >> 10;
                int x6 = K2 + R1 * 1024 * x5 + cA * x3;
                int x7 = cj * si >> 10;

                int x = 40 + 30 * (cB * x1 - sB * x4) / x6;
                int y = 12 + 15 * (cB * x4 + sB * x1) / x6;

                int N = (-cA * x7
                         - cB * ((-sA * x7 >> 10) + x2)
                         - ci * (cj * sB >> 10)
                         >> 10)
                        - x5 >> 7;

                int o = x + 80 * y;
                int8_t zz = (x6 - K2) >> 15;

                if (y > 0 && y < 22 && x > 0 && x < 80 && zz < z[o]) {
                    z[o] = zz;
                    b[o] = shades[N > 0 ? N : 0];
                }

                /* 8/256 rad per step * 200 steps = 6.28 rad = 2*pi */
                R(8, 8, ci, si)
            }
            /* 13/128 rad per step * 60 steps = 6.09 rad ~ 2*pi */
            R(13, 7, cj, sj)
        }

        /* Move cursor home and emit the frame as 22 rows of 80 chars. */
        puts_("\x1b[H");
        for (int row = 0; row < 22; row++) {
            for (int col = 0; col < 80; col++) putchar_(b[col + 80 * row]);
            putchar_('\n');
        }

        /* Advance the global rotation angles for next frame. */
        R(5, 7, cA, sA);
        R(5, 8, cB, sB);
    }

    /* unreachable */
    return 0;
}
