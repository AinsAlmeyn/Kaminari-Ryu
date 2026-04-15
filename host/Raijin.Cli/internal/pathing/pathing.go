// Package pathing centralizes the user-PATH and install-directory helpers
// shared by the `raijin` CLI (install / uninstall subcommands) and the
// raijin-setup installer binary.
//
// Everything here is Windows-flavored: the PATH read/write goes through
// PowerShell because the User scope of the registry is what survives a
// reboot, and HKCU\Environment is what File Explorer's "Edit environment
// variables" UI actually edits. Calling this on Linux/macOS is undefined.
package pathing

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Mode picks between PATH list operations.
type Mode int

const (
	ModeAdd Mode = iota
	ModeRemove
)

// UserInstallDirs returns the canonical install root and its bin/programs
// children under the user's home directory. The directories are NOT created;
// the caller does that with the right scope.
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
// PATH (HKCU\Environment\Path).
func UserPathContainsDir(dir string) (bool, error) {
	pathValue, err := ReadUserPath()
	if err != nil {
		return false, err
	}
	return ListContainsDir(pathValue, dir), nil
}

// UpdateUserPathDir adds or removes dir from the user PATH and reports
// whether the value actually changed. Idempotent: adding an already-present
// dir or removing an absent one is a no-op and returns (false, nil).
func UpdateUserPathDir(dir string, mode Mode) (bool, error) {
	pathValue, err := ReadUserPath()
	if err != nil {
		return false, err
	}

	var next string
	switch mode {
	case ModeAdd:
		next = ListAppendDir(pathValue, dir)
	case ModeRemove:
		next = ListRemoveDir(pathValue, dir)
	default:
		next = pathValue
	}

	if next == pathValue {
		return false, nil
	}
	if err := WriteUserPath(next); err != nil {
		return false, err
	}
	return true, nil
}

// ReadUserPath returns the current value of the user-scoped Path env var.
func ReadUserPath() (string, error) {
	cmd := exec.Command("powershell", "-NoProfile", "-Command",
		"[Environment]::GetEnvironmentVariable('Path','User')")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// WriteUserPath persists pathValue as the user Path env var. New shells
// pick it up; the running process does not see the change.
func WriteUserPath(pathValue string) error {
	command := "[Environment]::SetEnvironmentVariable('Path', " + PsSingleQuoted(pathValue) + ", 'User')"
	cmd := exec.Command("powershell", "-NoProfile", "-Command", command)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// AppendOneLiner returns an idempotent PowerShell one-liner that appends
// dir to the user PATH. Useful when we want to print copy-pasteable
// instructions instead of touching the registry ourselves.
func AppendOneLiner(dir string) string {
	quoted := PsSingleQuoted(dir)
	return `$p=[Environment]::GetEnvironmentVariable('Path','User'); ` +
		`$d=` + quoted + `; ` +
		`$items=@(); if ($p) { $items += ($p -split ';' | Where-Object { $_ }); } ` +
		`if ($items -notcontains $d) { $items += $d; [Environment]::SetEnvironmentVariable('Path', ($items -join ';'), 'User') }`
}

// RemoveOneLiner is the symmetric removal one-liner.
func RemoveOneLiner(dir string) string {
	quoted := PsSingleQuoted(dir)
	return `$p=[Environment]::GetEnvironmentVariable('Path','User'); ` +
		`$d=` + quoted + `; ` +
		`$items=@(); if ($p) { $items += ($p -split ';' | Where-Object { $_ -and $_ -ne $d }); } ` +
		`[Environment]::SetEnvironmentVariable('Path', ($items -join ';'), 'User')`
}

// PsSingleQuoted wraps s in single quotes for PowerShell, escaping any
// embedded single quote by doubling it.
func PsSingleQuoted(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// ListContainsDir reports whether pathValue (a `;`-separated PATH string)
// contains dir, using case-insensitive directory-aware comparison.
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
// dedupes case-insensitively.
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

func normalizeDir(path string) string {
	return strings.ToLower(filepath.Clean(path))
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
	return strings.EqualFold(filepath.Clean(aa), filepath.Clean(bb))
}

// Sentinel for callers that want a clear error type when PowerShell
// inspection fails. Currently unused but reserved.
var ErrPowerShell = fmt.Errorf("powershell call failed")
