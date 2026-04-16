//go:build !windows

package runner

import (
	"context"
	"os"

	"golang.org/x/sys/unix"
)

// waitForStdinInput blocks until stdin has data available or ctx is cancelled.
// Uses unix.Poll with a short timeout so the goroutine can check ctx.Done()
// without spinning and without blocking forever on a raw-mode read.
// poll(2) is portable across Linux, macOS, and the BSDs.
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
