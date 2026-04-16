//go:build !windows

package runner

import (
	"context"
	"os"

	"golang.org/x/sys/unix"
)

// flushStdinWindows drops any queued input bytes. On Linux this is a
// tcflush(TCIFLUSH) on stdin, so keystrokes typed during the interactive
// run don't leak into the next bubbletea screen as stale key events.
// (Name is kept for symmetry with the Windows implementation that does the
// more elaborate console-record drain. Both do the same thing from the
// caller's point of view: "return with a clean input buffer".)
func flushStdinWindows() {
	_ = unix.IoctlSetInt(int(os.Stdin.Fd()), unix.TCFLSH, unix.TCIFLUSH)
}

// waitForStdinInput blocks until stdin has data available or ctx is cancelled.
// Uses unix.Poll with a short timeout so the goroutine can check ctx.Done()
// without spinning and without blocking forever on a raw-mode read.
func waitForStdinInput(ctx context.Context) bool {
	fd := int(os.Stdin.Fd())
	fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	for {
		n, err := unix.Poll(fds, 10) // 10 ms timeout
		if err == nil && n > 0 {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		default:
		}
	}
}
