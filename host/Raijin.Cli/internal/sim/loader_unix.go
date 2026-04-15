//go:build !windows

package sim

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/ebitengine/purego"
)

// libraryName is the ELF/Mach-O filename produced by sim/CMakeLists.txt
// on each Unix platform.
func libraryName() string {
	if runtime.GOOS == "darwin" {
		return "libraijin.dylib"
	}
	return "libraijin.so"
}

// Load opens libraijin.so (Linux) or libraijin.dylib (macOS) via dlopen.
// Looks next to the exe first, then falls back to the dynamic linker's
// default search (LD_LIBRARY_PATH, /etc/ld.so.cache, etc.). Safe to call
// repeatedly  only opens once.
func Load() error {
	if dllLoaded {
		return nil
	}

	libName := libraryName()
	exe, _ := exeDir()
	candidates := []string{
		filepath.Join(exe, libName),
		// Bare name lets the dynamic linker search system paths. Useful
		// when the user installed the lib via package manager or copied
		// it to /usr/local/lib.
		libName,
	}

	var handle uintptr
	var lastErr error
	var attempts []string
	for _, c := range candidates {
		h, err := purego.Dlopen(c, purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err == nil {
			handle = h
			lastErr = nil
			break
		}
		attempts = append(attempts, fmt.Sprintf("  %s -> %v", c, err))
		lastErr = err
	}
	if lastErr != nil {
		// dlopen errors are string-based on Linux ("cannot open shared
		// object file: No such file or directory"). Give the user a hint
		// based on whether the primary path actually exists.
		hint := ""
		primary := filepath.Join(exe, libName)
		if _, statErr := os.Stat(primary); statErr == nil {
			hint = "\n\n" + libName + " exists but a dependency failed to load.\n" +
				"Run `ldd " + primary + "` to see which library is missing.\n" +
				"On Linux this is usually a stale glibc/libstdc++; install a\n" +
				"recent build-essential package."
		} else {
			hint = "\n\n" + libName + " not found next to the raijin binary.\n" +
				"Extract the full release tarball into a single directory before\n" +
				"running."
		}
		return fmt.Errorf("cannot load %s (last error: %w)\nattempted:\n%s%s",
			libName, lastErr, strings.Join(attempts, "\n"), hint)
	}

	bindAll(handle)
	return nil
}
