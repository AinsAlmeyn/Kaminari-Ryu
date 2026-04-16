//go:build windows

package runner

import (
	"golang.org/x/term"
)

// enterRawMode delegates to golang.org/x/term on Windows. The stock
// MakeRaw/Restore pair already does the right thing on the Windows
// console (LF→CRLF output translation is handled by ENABLE_PROCESSED_OUTPUT
// regardless of our input-side mode, so there is no staircase to avoid).
func enterRawMode(fd int) (restore func() error, err error) {
	state, err := term.MakeRaw(fd)
	if err != nil {
		return nil, err
	}
	return func() error { return term.Restore(fd, state) }, nil
}
