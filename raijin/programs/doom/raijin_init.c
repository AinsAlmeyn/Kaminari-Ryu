/* raijin_init.c: top-level entry that hands off to doomgeneric.
 *
 * Everything libc-shaped (malloc, printf, fopen...) now lives in
 * syscalls.c + newlib. This file is just the main loop.
 */

#include <stdint.h>

extern int  doomgeneric_Create(int argc, char **argv);
extern void doomgeneric_Tick(void);

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    static char *fake_argv[] = { "doom", "-iwad", "doom1.wad", 0 };
    doomgeneric_Create(3, fake_argv);
    for (;;) {
        doomgeneric_Tick();
    }
    return 0;
}

/* DG_SetWindowTitle is one of the doomgeneric callbacks; headless. */
void DG_SetWindowTitle(const char *title) { (void)title; }
