package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/pathing"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/spf13/cobra"
)

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
		targetExe := filepath.Join(binDir, "raijin.exe")
		targetDLL := filepath.Join(binDir, "raijin.dll")
		selfRun := isCurrentExecutable(targetExe)

		var removed []string
		var scheduled []string
		var missing []string

		for _, path := range []string{targetExe, targetDLL} {
			if selfRun {
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

		if !selfRun {
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

		if selfRun {
			cleanupDirs := []string{binDir, rootDir}
			if err := scheduleWindowsCleanup(scheduled, cleanupDirs); err != nil {
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
		if selfRun {
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

func scheduleWindowsCleanup(files, dirs []string) error {
	if len(files) == 0 {
		return nil
	}
	if runtime.GOOS != "windows" {
		return fmt.Errorf("self-uninstall cleanup scheduling is only implemented on Windows")
	}
	command := buildCleanupPowerShell(files, dirs)
	cmd := exec.Command("powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", command)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start cleanup helper: %w", err)
	}
	return nil
}

func buildCleanupPowerShell(files, dirs []string) string {
	var builder strings.Builder
	builder.WriteString("$files=@(")
	for i, path := range files {
		if i > 0 {
			builder.WriteString(",")
		}
		builder.WriteString(pathing.PsSingleQuoted(path))
	}
	builder.WriteString("); ")
	builder.WriteString("$dirs=@(")
	for i, path := range dirs {
		if i > 0 {
			builder.WriteString(",")
		}
		builder.WriteString(pathing.PsSingleQuoted(path))
	}
	builder.WriteString("); ")
	builder.WriteString("for($i=0; $i -lt 100; $i++){ $pending=$false; foreach($f in $files){ if(Test-Path -LiteralPath $f){ try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { $pending=$true } } }; if(-not $pending){ break }; Start-Sleep -Milliseconds 200 }; ")
	builder.WriteString("foreach($d in $dirs){ if(Test-Path -LiteralPath $d){ $items = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue); if($items.Count -eq 0){ Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue } } }")
	return builder.String()
}

func init() {
	uninstallCmd.Flags().BoolVar(&uninstallKeepPath, "keep-path", false,
		"leave the user's PATH unchanged instead of removing %USERPROFILE%\\.raijin\\bin")
	uninstallCmd.Flags().BoolVar(&uninstallPurgeFiles, "purge-programs", false,
		"also remove %USERPROFILE%\\.raijin\\programs and any bundled demo hex files")
	root.AddCommand(uninstallCmd)
}