//go:build windows

package pathing

import (
	"os"
	"os/exec"
	"strings"
)

// UpdateUserPathDir adds or removes dir from the user PATH and reports
// whether the value actually changed. Idempotent: adding an already-present
// dir or removing an absent one is a no-op and returns (false, nil).
//
// On Windows the user PATH lives in HKCU\Environment\Path, so this
// performs a read-modify-write cycle through PowerShell.
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

// ReadUserPath returns the current value of the user-scoped Path env var
// from HKCU\Environment via PowerShell.
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

// AppendInstructions returns a short human label and the actual command
// the user can paste into their shell to add dir to PATH. Used by the
// install handler to teach the user how to make `raijin` available.
func AppendInstructions(dir string) (label, command string) {
	return "one-time setup  (PowerShell, user PATH):", AppendOneLiner(dir)
}
