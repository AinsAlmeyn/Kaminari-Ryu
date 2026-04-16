//go:build linux

package runner

import (
	"os"

	"golang.org/x/sys/unix"
)

// flushStdinWindows drops any queued input bytes. On Linux this is the
// TCFLSH ioctl with TCIFLUSH (which is exactly what tcflush(3) does), so
// keystrokes typed during the interactive run don't leak into the next
// bubbletea screen as stale key events.
//
// Function name is kept for symmetry with the Windows implementation that
// does the more elaborate console-record drain. From the caller's point of
// view both do the same thing: "return with a clean input buffer".
func flushStdinWindows() {
	_ = unix.IoctlSetInt(int(os.Stdin.Fd()), unix.TCFLSH, unix.TCIFLUSH)
}
