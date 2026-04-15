//go:build !windows

package cmd

// selfUninstallNeedsScheduling is false on Unix because the kernel keeps
// a deleted-but-still-open file's inode alive until every fd to it is
// closed. The running raijin binary can be `os.Remove`d inline without
// any post-exit choreography.
const selfUninstallNeedsScheduling = false

// scheduleSelfCleanup is a no-op on Unix; the inline Remove path in the
// uninstall handler already deleted everything. Kept as a function so
// the cross-platform RunE doesn't need a build tag.
func scheduleSelfCleanup(files, dirs []string) error {
	return nil
}
