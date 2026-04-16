//go:build !windows

package runner

import (
	"golang.org/x/sys/unix"
)

// enterRawMode puts stdin into cooked-input-off mode (no canonical, no echo,
// no signal-generating key translation) but deliberately keeps OPOST|ONLCR
// on the output side. term.MakeRaw on Linux clears OPOST, which disables
// LF→CRLF translation. That causes programs emitting bare '\n' (e.g. the
// donut demo's per-row putchar_('\n')) to staircase across the screen.
// Keeping output post-processing intact gives parity with the Windows
// console's implicit LF→CRLF handling.
func enterRawMode(fd int) (restore func() error, err error) {
	old, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	if err != nil {
		return nil, err
	}
	n := *old
	n.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK |
		unix.ISTRIP | unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON
	n.Lflag &^= unix.ECHO | unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN
	n.Cflag &^= unix.CSIZE | unix.PARENB
	n.Cflag |= unix.CS8
	n.Cc[unix.VMIN] = 1
	n.Cc[unix.VTIME] = 0
	if err := unix.IoctlSetTermios(fd, unix.TCSETS, &n); err != nil {
		return nil, err
	}
	return func() error { return unix.IoctlSetTermios(fd, unix.TCSETS, old) }, nil
}
