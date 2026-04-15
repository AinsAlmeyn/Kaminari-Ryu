// Package sim binds the Raijin simulator DLL via purego + Windows
// syscalls. No cgo toolchain required.
package sim

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"github.com/ebitengine/purego"
	"golang.org/x/sys/windows"
)

// Sim is an opaque handle to a Verilated Raijin instance living in the DLL.
type Sim struct {
	h uintptr
}

// Out-param note: the C API takes `T*` pointers for arrays-of-T. We
// express these as uintptr on the Go side and convert once with
// unsafe.Pointer at the call site. An earlier attempt via []byte /
// []uint64 slice types returned all zeros on Windows — purego's slice
// header handling appears to mismatch the ABI some callers expect.
// Raw uintptr is unambiguous.
var (
	raijinCreate           func() uintptr
	raijinDestroy          func(uintptr)
	raijinReset            func(uintptr)
	raijinLoadHex          func(uintptr, string) int32
	raijinStep             func(uintptr, uint64) uint64
	raijinHalted           func(uintptr) int32
	raijinTohost           func(uintptr) uint32
	raijinGetPc            func(uintptr) uint32
	raijinGetRegs          func(uintptr, uintptr)
	raijinGetCsrs          func(uintptr, uintptr)
	raijinReadDmem         func(uintptr, uint32, uintptr, uint32)
	raijinCycleCount       func(uintptr) uint64
	raijinInstret          func(uintptr) uint64
	raijinGetClassCounters func(uintptr, uintptr)
	raijinUartRead         func(uintptr, uintptr, int32) int32
	raijinUartWrite        func(uintptr, byte)

	dllLoaded bool
)

// Load opens raijin.dll. Looks next to the exe first, then anywhere the
// Windows loader would search. Safe to call repeatedly — only opens once.
func Load() error {
	if dllLoaded {
		return nil
	}
	if runtime.GOOS != "windows" {
		return fmt.Errorf("only windows supported right now (runtime=%s)", runtime.GOOS)
	}

	// Try next to the exe first; fall back to the default loader search path.
	exe, _ := exeDir()
	candidates := []string{
		filepath.Join(exe, "raijin.dll"),
		"raijin.dll",
	}

	var handle windows.Handle
	var lastErr error
	var attempts []string
	for _, c := range candidates {
		h, err := windows.LoadLibrary(c)
		if err == nil {
			handle = h
			lastErr = nil
			break
		}
		attempts = append(attempts, fmt.Sprintf("  %s -> %v", c, err))
		lastErr = err
	}
	if lastErr != nil {
		// errno 126 (ERROR_MOD_NOT_FOUND) on a path that exists means the
		// DLL itself was found but one of its dependencies was not. Tell
		// the user instead of leaving them to decode the raw Windows code.
		hint := ""
		primary := filepath.Join(exe, "raijin.dll")
		if _, statErr := os.Stat(primary); statErr == nil {
			if errno, ok := lastErr.(syscall.Errno); ok && errno == 126 {
				hint = "\n\nraijin.dll exists but a dependency failed to load.\n" +
					"Re-download the latest release zip and extract it so every\n" +
					"file lands in the same directory (some archive tools split files)."
			}
		} else {
			hint = "\n\nraijin.dll not found next to raijin.exe. Extract the\n" +
				"full release zip into a single directory before running."
		}
		return fmt.Errorf("cannot load raijin.dll (last error: %w)\nattempted:\n%s%s",
			lastErr, strings.Join(attempts, "\n"), hint)
	}

	dll := uintptr(handle)
	purego.RegisterLibFunc(&raijinCreate, dll, "raijin_create")
	purego.RegisterLibFunc(&raijinDestroy, dll, "raijin_destroy")
	purego.RegisterLibFunc(&raijinReset, dll, "raijin_reset")
	purego.RegisterLibFunc(&raijinLoadHex, dll, "raijin_load_hex")
	purego.RegisterLibFunc(&raijinStep, dll, "raijin_step")
	purego.RegisterLibFunc(&raijinHalted, dll, "raijin_halted")
	purego.RegisterLibFunc(&raijinTohost, dll, "raijin_tohost")
	purego.RegisterLibFunc(&raijinGetPc, dll, "raijin_get_pc")
	purego.RegisterLibFunc(&raijinGetRegs, dll, "raijin_get_regs")
	purego.RegisterLibFunc(&raijinGetCsrs, dll, "raijin_get_csrs")
	purego.RegisterLibFunc(&raijinReadDmem, dll, "raijin_read_dmem")
	purego.RegisterLibFunc(&raijinCycleCount, dll, "raijin_cycle_count")
	purego.RegisterLibFunc(&raijinInstret, dll, "raijin_instret")
	purego.RegisterLibFunc(&raijinGetClassCounters, dll, "raijin_get_class_counters")
	purego.RegisterLibFunc(&raijinUartRead, dll, "raijin_uart_read")
	purego.RegisterLibFunc(&raijinUartWrite, dll, "raijin_uart_write")
	dllLoaded = true
	return nil
}

func New() (*Sim, error) {
	if err := Load(); err != nil {
		return nil, err
	}
	h := raijinCreate()
	if h == 0 {
		return nil, fmt.Errorf("raijin_create returned null")
	}
	return &Sim{h: h}, nil
}

func (s *Sim) Close() {
	if s == nil || s.h == 0 {
		return
	}
	raijinDestroy(s.h)
	s.h = 0
}

func (s *Sim) Reset() { raijinReset(s.h) }
func (s *Sim) LoadHex(path string) error {
	rc := raijinLoadHex(s.h, path)
	if rc != 0 {
		return fmt.Errorf("load_hex failed (rc=%d, path=%s)", rc, path)
	}
	return nil
}
func (s *Sim) Step(maxCycles uint64) uint64 { return raijinStep(s.h, maxCycles) }
func (s *Sim) Halted() bool                 { return raijinHalted(s.h) != 0 }
func (s *Sim) Tohost() uint32               { return raijinTohost(s.h) }
func (s *Sim) PC() uint32                   { return raijinGetPc(s.h) }
func (s *Sim) CycleCount() uint64           { return raijinCycleCount(s.h) }
func (s *Sim) Instret() uint64              { return raijinInstret(s.h) }

func (s *Sim) Regs() [32]uint32 {
	var out [32]uint32
	raijinGetRegs(s.h, uintptr(unsafe.Pointer(&out[0])))
	return out
}

func (s *Sim) CSRs() [8]uint32 {
	var out [8]uint32
	raijinGetCsrs(s.h, uintptr(unsafe.Pointer(&out[0])))
	return out
}

// ClassCounters returns [mul, branches_total, branches_taken, jumps, loads,
// stores, traps]. Matches the sim's DLL ABI.
func (s *Sim) ClassCounters() [7]uint64 {
	var out [7]uint64
	raijinGetClassCounters(s.h, uintptr(unsafe.Pointer(&out[0])))
	return out
}

func (s *Sim) ReadDmem(byteAddr uint32, length uint32) []byte {
	if length == 0 {
		return nil
	}
	buf := make([]byte, length)
	raijinReadDmem(s.h, byteAddr, uintptr(unsafe.Pointer(&buf[0])), length)
	return buf
}

// ReadUart drains the UART TX ring into a byte slice. Returns nil if empty.
func (s *Sim) ReadUart() []byte {
	var buf [4096]byte
	n := raijinUartRead(s.h, uintptr(unsafe.Pointer(&buf[0])), int32(len(buf)))
	if n <= 0 {
		return nil
	}
	out := make([]byte, n)
	copy(out, buf[:n])
	return out
}

// WriteUart pushes a byte onto the simulator's UART RX queue.
func (s *Sim) WriteUart(b byte) { raijinUartWrite(s.h, b) }
