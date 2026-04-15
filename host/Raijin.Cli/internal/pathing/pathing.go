// Package pathing centralizes the user-PATH and install-directory helpers
// shared by the `raijin` CLI (install / uninstall subcommands) and the
// raijin-setup installer binary.
//
// Cross-platform pieces (UserInstallDirs, AbsSameFile, the path-list
// manipulation helpers) live here. Platform-specific behavior lives in
// pathing_windows.go (PowerShell + HKCU\Environment registry) and
// pathing_unix.go (shell rc-file append).
package pathing

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// Mode picks between PATH list operations.
type Mode int

const (
	ModeAdd Mode = iota
	ModeRemove
)

// UserInstallDirs returns the canonical install root and its bin/programs
// children under the user's home directory. The directories are NOT
// created; the caller does that with the right scope. Layout is identical
// across Windows and Unix to keep documentation simple.
func UserInstallDirs() (root, binDir, progDir string, err error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", "", err
	}
	root = filepath.Join(home, ".raijin")
	binDir = filepath.Join(root, "bin")
	progDir = filepath.Join(root, "programs")
	return root, binDir, progDir, nil
}

// UserPathContainsDir reports whether dir is currently part of the user
// PATH. The notion of "user PATH" is platform-specific (registry on
// Windows, shell rc on Unix); both are routed through ReadUserPath.
func UserPathContainsDir(dir string) (bool, error) {
	pathValue, err := ReadUserPath()
	if err != nil {
		return false, err
	}
	return ListContainsDir(pathValue, dir), nil
}

// ListContainsDir reports whether pathValue (a separator-joined PATH
// string) contains dir. Comparison is case-insensitive on Windows,
// case-sensitive on Unix  matching how the OS itself resolves PATH.
func ListContainsDir(pathValue, dir string) bool {
	normalizedDir := normalizeDir(dir)
	for _, item := range listItems(pathValue) {
		if normalizeDir(item) == normalizedDir {
			return true
		}
	}
	return false
}

// ListAppendDir returns pathValue with dir appended if not already present.
// Duplicates are squashed and empty entries dropped.
func ListAppendDir(pathValue, dir string) string {
	items := listItems(pathValue)
	if ListContainsDir(pathValue, dir) {
		return strings.Join(items, string(os.PathListSeparator))
	}
	items = append(items, dir)
	return strings.Join(items, string(os.PathListSeparator))
}

// ListRemoveDir returns pathValue with every entry that resolves to dir
// removed. Other entries keep their original casing/spelling.
func ListRemoveDir(pathValue, dir string) string {
	normalizedDir := normalizeDir(dir)
	items := listItems(pathValue)
	filtered := make([]string, 0, len(items))
	for _, item := range items {
		if normalizeDir(item) == normalizedDir {
			continue
		}
		filtered = append(filtered, item)
	}
	return strings.Join(filtered, string(os.PathListSeparator))
}

// listItems splits a PATH string, trims each entry, drops empties, and
// dedupes (case-insensitively on Windows, exact-match on Unix).
func listItems(pathValue string) []string {
	raw := filepath.SplitList(pathValue)
	items := make([]string, 0, len(raw))
	seen := make(map[string]struct{}, len(raw))
	for _, item := range raw {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		normalized := normalizeDir(item)
		if _, ok := seen[normalized]; ok {
			continue
		}
		seen[normalized] = struct{}{}
		items = append(items, item)
	}
	return items
}

// normalizeDir folds the directory string to a comparison-friendly form.
// Windows file system is case-insensitive so we lowercase; Unix is
// case-sensitive so we only clean.
func normalizeDir(path string) string {
	if runtime.GOOS == "windows" {
		return strings.ToLower(filepath.Clean(path))
	}
	return filepath.Clean(path)
}

// AbsSameFile reports whether two paths resolve to the same on-disk file.
// Used by install to skip a pointless self-copy that would otherwise
// truncate the destination, and by uninstall to detect a self-uninstall.
func AbsSameFile(a, b string) bool {
	aa, err1 := filepath.Abs(a)
	bb, err2 := filepath.Abs(b)
	if err1 != nil || err2 != nil {
		return false
	}
	ca, cb := filepath.Clean(aa), filepath.Clean(bb)
	if runtime.GOOS == "windows" {
		return strings.EqualFold(ca, cb)
	}
	return ca == cb
}
