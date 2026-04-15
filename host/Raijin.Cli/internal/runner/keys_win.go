//go:build windows

package runner

import (
	"context"
	"encoding/binary"
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	keyEventType     = 0x0001
	vkC              = 0x43
	leftCtrlPressed  = 0x0008
	rightCtrlPressed = 0x0004
)

// readKeys reads Windows console INPUT_RECORDs directly instead of relying on
// os.Stdin.Read. That avoids the raw-mode ReadFile hang where the goroutine
// stays blocked until the user presses a second key after leaving the pause
// screen.
func readKeys(ctx context.Context, ch chan<- byte) {
	h := windows.Handle(os.Stdin.Fd())
	var records [8]inputRecord

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if !waitForStdinInput(ctx) {
			return
		}

		read, ok := readConsoleRecords(h, records[:])
		if !ok {
			return
		}

		for i := uint32(0); i < read; i++ {
			b, repeat, ok := decodeConsoleKey(records[i])
			if !ok {
				continue
			}
			for j := uint16(0); j < repeat; j++ {
				send(ctx, ch, b)
			}
		}
	}
}

func readConsoleRecords(h windows.Handle, buf []inputRecord) (uint32, bool) {
	if len(buf) == 0 {
		return 0, true
	}
	var read uint32
	r1, _, _ := procReadConsoleInput.Call(
		uintptr(h),
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf)),
		uintptr(unsafe.Pointer(&read)),
	)
	return read, r1 != 0
}

func decodeConsoleKey(rec inputRecord) (byte, uint16, bool) {
	if rec.EventType != keyEventType {
		return 0, 0, false
	}
	if binary.LittleEndian.Uint32(rec.Event[0:4]) == 0 {
		return 0, 0, false
	}

	repeat := binary.LittleEndian.Uint16(rec.Event[4:6])
	if repeat == 0 {
		repeat = 1
	}
	vkey := binary.LittleEndian.Uint16(rec.Event[6:8])
	char := binary.LittleEndian.Uint16(rec.Event[10:12])
	ctrlState := binary.LittleEndian.Uint32(rec.Event[12:16])

	// Ctrl+C can surface either as ETX (0x03) or as keycode 'C' with ctrl held.
	if char == 0x03 || (vkey == vkC && ctrlState&(leftCtrlPressed|rightCtrlPressed) != 0) {
		return 0x03, repeat, true
	}

	if char == 0 {
		return 0, 0, false
	}

	b := byte(char)
	switch {
	case b == '\t' || b == '\r' || b == '\n' || b == '\b' || b == 0x7f || b == 0x1b:
		return b, repeat, true
	case b < 32:
		return 0, 0, false
	case b > 126:
		return 0, 0, false
	default:
		return b, repeat, true
	}
}

func send(ctx context.Context, ch chan<- byte, b byte) {
	select {
	case ch <- b:
	case <-ctx.Done():
	default:
		// channel full: drop the new byte
	}
}