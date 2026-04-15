//go:build windows

package runner

import (
	"context"
	"os"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// waitForStdinInput blocks until stdin has at least one byte available or ctx
// is cancelled. Returns true when input is ready, false when cancelled.
// Using WaitForSingleObject with a short timeout lets the goroutine check
// ctx.Done() periodically without spinning and without blocking forever on
// a raw-mode ReadFile that only unblocks when the user presses a key.
func waitForStdinInput(ctx context.Context) bool {
	h := windows.Handle(os.Stdin.Fd())
	for {
		const timeoutMs = 10
		r, _, _ := procWaitForSingleObject.Call(uintptr(h), timeoutMs)
		if r == 0 { // WAIT_OBJECT_0 — stdin handle is signalled (data available)
			return true
		}
		select {
		case <-ctx.Done():
			return false
		default:
		}
	}
}

// flushStdinWindows drains every pending byte AND every pending console
// input record, then waits long enough for the OS "key-up" event to
// settle, so the next raw-mode consumer (e.g. bubbletea) starts with a
// clean queue.
//
// Why all this ceremony:
//   - golang.org/x/term uses ReadFile for stdin, which only surfaces
//     key-down byte translations. But the underlying Windows console
//     input queue tracks BOTH key-down and key-up INPUT_RECORDs. A
//     stale key-up can arrive at the next reader AFTER we think we've
//     flushed, because the console input thread delivers it
//     asynchronously.
//   - FlushConsoleInputBuffer drops queued records, but not the in-
//     flight one that's already on its way. Sleeping ~20 ms covers
//     that gap (widely documented in bubbletea / crossterm hand-off
//     code; bubbletea issues #108 / #392).
func flushStdinWindows() {
	h := windows.Handle(os.Stdin.Fd())

	// Drain records, flush bytes, sleep for key-up, drain again.
	drainRecords(h)
	_ = windows.FlushConsoleInputBuffer(h)

	time.Sleep(20 * time.Millisecond)

	drainRecords(h)
	_ = windows.FlushConsoleInputBuffer(h)
}

// ── direct syscall wrappers (windows.PeekConsoleInput / ReadConsoleInput
// are not exposed by golang.org/x/sys/windows in stable form) ──────────

var (
	kernel32               = syscall.NewLazyDLL("kernel32.dll")
	procPeekConsoleInput   = kernel32.NewProc("PeekConsoleInputW")
	procReadConsoleInput   = kernel32.NewProc("ReadConsoleInputW")
	procWaitForSingleObject = kernel32.NewProc("WaitForSingleObject")
)

// inputRecord is a 20-byte prefix of the Windows INPUT_RECORD struct.
// We only care about draining the queue, never interpreting contents,
// so we allocate a buffer of the right size and discard it.
type inputRecord struct {
	EventType uint16
	_pad      uint16
	Event     [16]byte
}

func drainRecords(h windows.Handle) {
	var buf [32]inputRecord
	var read uint32

	for {
		// Peek to see if anything's there.
		r1, _, _ := procPeekConsoleInput.Call(
			uintptr(h),
			uintptr(unsafe.Pointer(&buf[0])),
			uintptr(len(buf)),
			uintptr(unsafe.Pointer(&read)),
		)
		if r1 == 0 || read == 0 {
			return
		}
		// Consume it.
		r1, _, _ = procReadConsoleInput.Call(
			uintptr(h),
			uintptr(unsafe.Pointer(&buf[0])),
			uintptr(read),
			uintptr(unsafe.Pointer(&read)),
		)
		if r1 == 0 || read == 0 {
			return
		}
	}
}
