//go:build !windows

package runner

import (
	"context"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// readKeys runs in a goroutine, reading stdin byte-by-byte under raw mode
// and writing meaningful bytes to ch. It filters out ANSI escape sequences
// (arrow keys, function keys, late terminal-reply bytes) so only the
// printable ASCII a UART target would understand makes it through.
//
// It uses waitForStdinInput before each blocking Read so that context
// cancellation is detected promptly — without requiring the user to press
// an extra key to unblock a pending ReadFile/read(2).
func readKeys(ctx context.Context, ch chan<- byte) {
	buf := make([]byte, 1)
	stdin := os.Stdin

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		// Block until stdin has data OR ctx is cancelled.
		// This replaces the unconditional blocking stdin.Read so the
		// goroutine can exit cleanly when the context is cancelled
		// (e.g. user pressed Enter on the pause screen) without the
		// caller having to press another key just to unblock the goroutine.
		if !waitForStdinInput(ctx) {
			return
		}

		n, err := stdin.Read(buf)
		if err != nil {
			// stdin closed or raw mode exited — we're done.
			return
		}
		if n == 0 {
			time.Sleep(10 * time.Millisecond)
			continue
		}
		b := buf[0]

		// ESC is ambiguous: it can be a lone Esc key press (the user wants to
		// quit from the pause screen) OR the first byte of a CSI/SS3 sequence
		// (arrow key, function key, terminal reply). Peek for a follow-up
		// byte with a short deadline. If nothing arrives within ~40 ms it
		// was a real Esc; otherwise swallow the whole sequence so CSI digits
		// don't leak into the key channel.
		if b == 0x1B {
			fds := []unix.PollFd{{Fd: int32(stdin.Fd()), Events: unix.POLLIN}}
			n, _ := unix.Poll(fds, 40)
			if n > 0 {
				swallowEscape(stdin)
			} else {
				send(ctx, ch, 0x1B)
			}
			continue
		}

		// Forward Ctrl+C verbatim so the outer loop can cancel.
		if b == 0x03 {
			send(ctx, ch, b)
			continue
		}

		// Let Tab/CR/LF/BS through plus printable ASCII.
		switch {
		case b == '\t' || b == '\r' || b == '\n' || b == '\b' || b == 0x7f:
			send(ctx, ch, b)
		case b < 32:
			// other control bytes: drop
		case b > 126:
			// non-ASCII: drop (the UART targets here are 7-bit)
		default:
			send(ctx, ch, b)
		}
	}
}

func send(ctx context.Context, ch chan<- byte, b byte) {
	select {
	case ch <- b:
	case <-ctx.Done():
	default:
		// channel full: drop oldest-style by dropping the new byte.
	}
}

// swallowEscape consumes the rest of an ANSI escape sequence from stdin
// so nothing after the ESC byte (the CSI header, parameters, and final
// letter) leaks into the key stream.
func swallowEscape(stdin *os.File) {
	// Read at most 16 bytes or until a final byte arrives.
	buf := make([]byte, 1)
	for i := 0; i < 16; i++ {
		n, err := stdin.Read(buf)
		if err != nil || n == 0 {
			return
		}
		c := buf[0]
		// Final byte of a CSI is @..~; for single-char ESC sequences we
		// stop on any non-digit-or-separator.
		if c >= '@' && c <= '~' {
			return
		}
	}
}
