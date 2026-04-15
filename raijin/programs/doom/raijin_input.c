/* raijin_input.c: DG_GetKey implementation. UART RX -> Doom keycode.
 *
 * Doom's movement model is *held-key* driven: G_BuildTiccmd checks
 * gamekeydown[KEY_*] each tic, so a key must read as "still pressed" for
 * at least a few tics before any motion happens. Emitting press+release
 * back-to-back inside a single tic leaves gamekeydown at 0 when the
 * ticcmd is built, i.e. no forward motion, no firing, nothing.
 *
 * Strategy:
 *   - A UART byte produces an immediate "press" event.
 *   - We remember the key as currently-held and count the number of
 *     DG_GetKey idle returns since. Once that hits HOLD_TICS we emit a
 *     "release" event and clear the held slot.
 *   - I_GetEvent calls DG_GetKey in a `while()` loop per tic until it
 *     returns 0, so each tic bumps our counter exactly once. That makes
 *     HOLD_TICS a direct "tics held" knob.
 *
 * Limitations:
 *   - Only one held key at a time. Tapping a second key before the first
 *     releases implicitly releases the first. Good enough for UART-style
 *     single-stream input; strafe-while-walking isn't on the table.
 */

#include "doomgeneric.h"
#include "doomkeys.h"

#include "../../../tools/c-runtime/shims/util.h"

/* Ring buffer for pending events we emit one-per-call. Sized small on
 * purpose; we only ever queue a handful of events at a time. */
#define Q_LEN 16
static struct { int pressed; unsigned char key; } q[Q_LEN];
static int q_head = 0, q_tail = 0;

static void q_push(int pressed, unsigned char key) {
    int n = (q_head + 1) % Q_LEN;
    if (n == q_tail) return;        /* drop on overflow */
    q[q_head].pressed = pressed;
    q[q_head].key     = key;
    q_head = n;
}

static int q_pop(int *pressed, unsigned char *key) {
    if (q_head == q_tail) return 0;
    *pressed = q[q_tail].pressed;
    *key     = q[q_tail].key;
    q_tail   = (q_tail + 1) % Q_LEN;
    return 1;
}

/* Number of DG_GetKey "nothing to do" returns a key stays held for after
 * its last UART arrival. Each idle return corresponds to one game tic.
 * 4 tics at Doom's 35 Hz is ~115 ms of effective hold — enough for a
 * noticeable forward step, a shot, or a menu cursor advance. */
#define HOLD_TICS 4

static unsigned char held_key  = 0;
static int           idle_tics = 0;

static unsigned char ascii_to_doom(int c) {
    switch (c) {
        case 'w': case 'W': return KEY_UPARROW;
        case 's': case 'S': return KEY_DOWNARROW;
        case 'a': case 'A': return KEY_LEFTARROW;
        case 'd': case 'D': return KEY_RIGHTARROW;
        case ' ':           return KEY_USE;
        case 13:            return KEY_ENTER;
        case 27:            return KEY_ESCAPE;
        case 'q': case 'Q': return KEY_FIRE;          /* ctrl stand-in */
        case '\t':          return KEY_TAB;
        case 'y': case 'Y': return 'y';
        case 'n': case 'N': return 'n';
        /* Doom weapon hotkeys pass through as ASCII. */
        case '1': case '2': case '3': case '4':
        case '5': case '6': case '7':
                            return (unsigned char)c;
        default:            return 0;
    }
}

int DG_GetKey(int *pressed, unsigned char *doomKey) {
    /* 1. Drain any UART bytes that arrived since the last call. Each byte
     *    becomes a press event and extends the held-key window. If the
     *    user switches keys we implicitly release the previous one first. */
    int c;
    while ((c = uart_rx_poll()) >= 0) {
        unsigned char k = ascii_to_doom(c);
        if (!k) continue;
        if (held_key && held_key != k) {
            /* Key switch: release old first so Doom sees a clean handoff. */
            q_push(0, held_key);
        }
        q_push(1, k);
        held_key  = k;
        idle_tics = 0;
    }

    /* 2. Pop any queued event (press from UART or pending release). */
    if (q_pop(pressed, doomKey)) return 1;

    /* 3. Idle tic: the i_input while-loop is exiting. Age the held key
     *    and, if it's timed out, schedule its release to be picked up on
     *    the next DG_GetKey call (which will be part of the next tic). */
    if (held_key) {
        idle_tics++;
        if (idle_tics >= HOLD_TICS) {
            *pressed  = 0;
            *doomKey  = held_key;
            held_key  = 0;
            idle_tics = 0;
            return 1;
        }
    }
    return 0;
}
