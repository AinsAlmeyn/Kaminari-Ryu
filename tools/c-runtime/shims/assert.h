/* assert.h shim: silently disable runtime asserts.
 *
 * Some benchmarks call assert(); without newlib we have no
 * __assert_fail to link against. Treat every assert as a no-op so the
 * program builds and runs as if compiled with -DNDEBUG.
 */

#ifndef RAIJIN_ASSERT_H
#define RAIJIN_ASSERT_H

#define assert(x) ((void)0)

#endif
