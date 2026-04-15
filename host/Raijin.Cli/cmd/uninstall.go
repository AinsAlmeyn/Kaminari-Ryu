package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"

	"github.com/AinsAlmeyn/raijin-cli/internal/pathing"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/spf13/cobra"
)

// installedBinaryNames returns the platform-specific filenames that the
// installer drops into ~/.raijin/bin: raijin.exe + raijin.dll on Windows,
// raijin + libraijin.so on Linux, raijin + libraijin.dylib on macOS.
func installedBinaryNames() (exeName, libName string) {
	switch runtime.GOOS {
	case "windows":
		return "raijin.exe", "raijin.dll"
	case "darwin":
		return "raijin", "libraijin.dylib"
	default:
		return "raijin", "libraijin.so"
	}
}

var (
	uninstallKeepPath   bool
	uninstallPurgeFiles bool
)

var uninstallCmd = &cobra.Command{
	Use:   "uninstall",
	Short: "Remove raijin from %USERPROFILE%\\.raijin and optionally clean its demo files.",
	Long: `Uninstall removes the user-scoped raijin installation created by
` + "`raijin install`" + `.

By default it removes the CLI binaries and also removes %USERPROFILE%\\.raijin\\bin
from the user's PATH. Bundled demo hex files are kept unless ` + "`--purge-programs`" + `
is passed.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		rootDir, binDir, progDir, err := pathing.UserInstallDirs()
		if err != nil {
			return fmt.Errorf("cannot locate home dir: %w", err)
		}
		exeName, libName := installedBinaryNames()
		targetExe := filepath.Join(binDir, exeName)
		targetDLL := filepath.Join(binDir, libName)
		selfRun := isCurrentExecutable(targetExe)
		// On Windows, deleting a running .exe fails (the OS keeps the file
		// locked), so we queue the cleanup for after-exit. On Unix, deleting
		// the running binary works fine because the kernel keeps the inode
		// alive until the process closes; we just delete inline.
		needsScheduledCleanup := selfRun && selfUninstallNeedsScheduling

		var removed []string
		var scheduled []string
		var missing []string

		for _, path := range []string{targetExe, targetDLL} {
			if needsScheduledCleanup {
				if fileExists(path) {
					scheduled = append(scheduled, path)
				} else {
					missing = append(missing, path)
				}
				continue
			}
			ok, err := removeFileIfExists(path)
			if err != nil {
				return err
			}
			if ok {
				removed = append(removed, path)
			} else {
				missing = append(missing, path)
			}
		}

		if uninstallPurgeFiles {
			if ok, err := removeDirIfExists(progDir); err != nil {
				return err
			} else if ok {
				removed = append(removed, progDir)
			} else {
				missing = append(missing, progDir)
			}
		}

		if !needsScheduledCleanup {
			_ = removeDirIfEmpty(binDir)
			_ = removeDirIfEmpty(rootDir)
		}

		pathChanged := false
		if !uninstallKeepPath {
			pathChanged, err = pathing.UpdateUserPathDir(binDir, pathing.ModeRemove)
			if err != nil {
				return fmt.Errorf("update user PATH: %w", err)
			}
		}

		if needsScheduledCleanup {
			cleanupDirs := []string{binDir, rootDir}
			if err := scheduleSelfCleanup(scheduled, cleanupDirs); err != nil {
				return err
			}
		}

		fmt.Println()
		fmt.Println("  " + theme.Accent.Render("✓") + "  " + theme.Heading.Render("uninstalled"))
		fmt.Println()
		for _, path := range removed {
			fmt.Println("    " + theme.Faint.Render("→ ") + theme.Value.Render(path))
		}
		for _, path := range scheduled {
			fmt.Println("    " + theme.Faint.Render("→ ") + theme.Mute.Render(path+"  (scheduled for deletion after this process exits)"))
		}
		if len(removed) == 0 {
			if len(scheduled) == 0 {
				fmt.Println("    " + theme.Mute.Render("nothing was removed; the user install was already absent"))
			}
		}
		if len(missing) > 0 {
			fmt.Println()
			fmt.Println("  " + theme.Mute.Render("already absent:"))
			for _, path := range missing {
				fmt.Println("    " + theme.Faint.Render("· ") + theme.Mute.Render(path))
			}
		}
		fmt.Println()

		switch {
		case uninstallKeepPath:
			fmt.Println("  " + theme.Mute.Render("user PATH was left unchanged  (--keep-path)"))
		case pathChanged:
			fmt.Println("  " + theme.Ok.Render("✓") + "  " + theme.Mute.Render("removed the user PATH entry; open a fresh terminal to pick up the change"))
		default:
			fmt.Println("  " + theme.Mute.Render("user PATH did not contain the install directory"))
		}

		if !uninstallPurgeFiles {
			fmt.Println()
			fmt.Println("  " + theme.Mute.Render("bundled demo hex files were kept; pass --purge-programs to remove them too"))
		}
		if needsScheduledCleanup {
			fmt.Println()
			fmt.Println("  " + theme.Mute.Render("the running installed copy cannot be deleted mid-process on Windows, so cleanup was queued for immediately after exit"))
		}
		fmt.Println()
		return nil
	},
}

func isCurrentExecutable(path string) bool {
	exe, err := os.Executable()
	if err != nil {
		return false
	}
	return pathing.AbsSameFile(exe, path)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func removeFileIfExists(path string) (bool, error) {
	err := os.Remove(path)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, fmt.Errorf("remove %s: %w", path, err)
}

func removeDirIfExists(path string) (bool, error) {
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("stat %s: %w", path, err)
	}
	if err := os.RemoveAll(path); err != nil {
		return false, fmt.Errorf("remove %s: %w", path, err)
	}
	return true, nil
}

func removeDirIfEmpty(path string) error {
	entries, err := os.ReadDir(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if len(entries) != 0 {
		return nil
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func init() {
	uninstallCmd.Flags().BoolVar(&uninstallKeepPath, "keep-path", false,
		"leave the user's PATH unchanged instead of removing %USERPROFILE%\\.raijin\\bin")
	uninstallCmd.Flags().BoolVar(&uninstallPurgeFiles, "purge-programs", false,
		"also remove %USERPROFILE%\\.raijin\\programs and any bundled demo hex files")
	root.AddCommand(uninstallCmd)
}