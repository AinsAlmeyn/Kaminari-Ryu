//go:build darwin

package runner

import (
	"os"

	"golang.org/x/sys/unix"
)

// flushStdinWindows drops any queued input bytes. On macOS the tcflush(3)
// libc call is built on the TIOCFLUSH ioctl, which takes a bitmask of
// FREAD/FWRITE rather than the Linux-style TCIFLUSH constant. We pass
// FREAD to discard pending input only, leaving any output untouched.
//
// Function name is kept for symmetry with the Windows implementation; both
// give the caller a clean input buffer before the next reader takes over.
func flushStdinWindows() {
	const FREAD = 0x01
	_ = unix.IoctlSetPointerInt(int(os.Stdin.Fd()), unix.TIOCFLUSH, FREAD)
}
