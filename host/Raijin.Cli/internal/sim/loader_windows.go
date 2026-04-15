//go:build windows

package sim

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

// Load opens raijin.dll. Looks next to the exe first, then falls back to
// whatever the Windows loader would search by default. Safe to call
// repeatedly  only opens once.
func Load() error {
	if dllLoaded {
		return nil
	}

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

	bindAll(uintptr(handle))
	return nil
}
