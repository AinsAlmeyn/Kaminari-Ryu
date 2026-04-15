//go:build !windows

package pathing

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// raijinMarker tags the lines we add to the user's shell rc so we can
// find and remove them later. Keeping a unique marker matters because
// users edit these files by hand.
const raijinMarker = "# raijin-cli (do not edit this line)"

// ReadUserPath returns the current $PATH. On Unix the canonical "user
// PATH" lives in shell rc files, but those only take effect for new
// shells; the running process's environment is what's actually in use,
// so that's what we return for membership checks.
func ReadUserPath() (string, error) {
	return os.Getenv("PATH"), nil
}

// WriteUserPath is the symmetric write half of ReadUserPath. On Windows
// it edits the registry, but on Unix the closest equivalent is appending
// (or removing) a line in the user's shell rc. UpdateUserPathDir below
// handles the Add/Remove flow directly so it can be idempotent at the
// line level; this function exists only to satisfy the cross-platform
// signature and is a no-op for the Add path.
func WriteUserPath(pathValue string) error {
	// Intentionally a no-op. The Linux path through UpdateUserPathDir
	// edits the rc file directly via writeRcAddDir / writeRcRemoveDir
	// below, since "rewrite the whole PATH" doesn't map cleanly to a
	// rc file the user owns and edits by hand.
	return nil
}

// UpdateUserPathDir on Unix takes a different shape than on Windows:
// instead of computing a new full PATH string and writing it, we manage
// a single line in the user's shell rc file. The line carries our marker
// comment so we can find and remove it cleanly. Returns whether the rc
// file actually changed.
func UpdateUserPathDir(dir string, mode Mode) (bool, error) {
	rc, err := userShellRC()
	if err != nil {
		return false, fmt.Errorf("locate shell rc: %w", err)
	}

	switch mode {
	case ModeAdd:
		return writeRcAddDir(rc, dir)
	case ModeRemove:
		return writeRcRemoveDir(rc, dir)
	}
	return false, nil
}

// userShellRC returns the rc file we should edit, picked from $SHELL.
// Defaults to ~/.bashrc when $SHELL is unset or unrecognized; that's
// what every distro ships interactive shells with.
func userShellRC() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	shell := os.Getenv("SHELL")
	switch {
	case strings.Contains(shell, "zsh"):
		return filepath.Join(home, ".zshrc"), nil
	case strings.Contains(shell, "fish"):
		return filepath.Join(home, ".config", "fish", "config.fish"), nil
	default:
		return filepath.Join(home, ".bashrc"), nil
	}
}

// writeRcAddDir appends an idempotent PATH-prepend line to the shell rc
// if it isn't already present. Reports whether the file changed.
func writeRcAddDir(rcFile, dir string) (bool, error) {
	if hasRaijinLine(rcFile, dir) {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(rcFile), 0o755); err != nil {
		return false, fmt.Errorf("ensure rc dir: %w", err)
	}
	f, err := os.OpenFile(rcFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return false, fmt.Errorf("open %s: %w", rcFile, err)
	}
	defer f.Close()
	line := buildRcLine(rcFile, dir)
	if _, err := fmt.Fprintf(f, "\n%s\n%s\n", raijinMarker, line); err != nil {
		return false, fmt.Errorf("append to %s: %w", rcFile, err)
	}
	return true, nil
}

// writeRcRemoveDir strips any raijin-tagged lines that reference dir.
// Other content in the rc file is preserved verbatim. Reports whether
// the file changed.
func writeRcRemoveDir(rcFile, dir string) (bool, error) {
	in, err := os.Open(rcFile)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("open %s: %w", rcFile, err)
	}
	defer in.Close()

	var kept []string
	skipNext := false
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	changed := false
	for scanner.Scan() {
		line := scanner.Text()
		if skipNext {
			skipNext = false
			changed = true
			continue
		}
		if strings.TrimSpace(line) == raijinMarker {
			// Drop this marker AND the next line if it's our PATH line.
			skipNext = true
			changed = true
			continue
		}
		kept = append(kept, line)
	}
	if err := scanner.Err(); err != nil {
		return false, fmt.Errorf("read %s: %w", rcFile, err)
	}
	if !changed {
		return false, nil
	}
	// Trim a trailing run of empty lines we may have created so the file
	// doesn't grow whitespace each install/uninstall cycle.
	for len(kept) > 0 && strings.TrimSpace(kept[len(kept)-1]) == "" {
		kept = kept[:len(kept)-1]
	}
	out := strings.Join(kept, "\n")
	if len(kept) > 0 {
		out += "\n"
	}
	if err := os.WriteFile(rcFile, []byte(out), 0o644); err != nil {
		return false, fmt.Errorf("rewrite %s: %w", rcFile, err)
	}
	return true, nil
}

// hasRaijinLine reports whether rcFile already contains a PATH-prepend
// line for dir tagged with our marker. Used for idempotency on add.
func hasRaijinLine(rcFile, dir string) bool {
	data, err := os.ReadFile(rcFile)
	if err != nil {
		return false
	}
	want := buildRcLine(rcFile, dir)
	return strings.Contains(string(data), want)
}

// buildRcLine returns the exact PATH-prepend line to write. fish uses a
// different syntax (set -gx) than POSIX-compatible shells (export PATH).
func buildRcLine(rcFile, dir string) string {
	if strings.Contains(rcFile, "fish") {
		return fmt.Sprintf(`set -gx PATH "%s" $PATH`, dir)
	}
	return fmt.Sprintf(`export PATH="%s:$PATH"`, dir)
}

// AppendOneLiner returns the same line writeRcAddDir would write, suitable
// for printing as a copy-pasteable instruction.
func AppendOneLiner(dir string) string {
	rc, _ := userShellRC()
	return fmt.Sprintf(`echo '%s' >> %s`, buildRcLine(rc, dir), shortHome(rc))
}

// RemoveOneLiner is the symmetric removal one-liner. Mostly informational;
// the actual remove path goes through writeRcRemoveDir which handles the
// marker comments cleanly.
func RemoveOneLiner(dir string) string {
	rc, _ := userShellRC()
	return fmt.Sprintf(`# manually remove the raijin block from %s`, shortHome(rc))
}

// PsSingleQuoted is unused on Unix but kept so cross-platform callers
// (the uninstall cleanup helper) compile cleanly.
func PsSingleQuoted(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// AppendInstructions returns the human-friendly label + command pair.
// Same shape as the Windows version so install.go can stay generic.
func AppendInstructions(dir string) (label, command string) {
	rc, _ := userShellRC()
	return fmt.Sprintf("one-time setup  (append to %s):", shortHome(rc)), AppendOneLiner(dir)
}

// shortHome turns /home/user/.bashrc into ~/.bashrc for friendlier
// display. Falls back to the raw path if HOME isn't available.
func shortHome(p string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return p
	}
	rel, err := filepath.Rel(home, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		return p
	}
	return "~/" + filepath.ToSlash(rel)
}
