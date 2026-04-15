package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/catalog"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/spf13/cobra"
)

var (
	installAddToPath bool
	installNoPrograms bool
)

var installCmd = &cobra.Command{
	Use:   "install",
	Short: "Copy raijin into %USERPROFILE%\\.raijin\\bin so you can run it from anywhere.",
	Long: `Install raijin.exe + raijin.dll into a stable location under your
home directory, and (if needed) tell you how to add that location to
your PATH. After that, `+"`raijin`"+` works from any shell without
	the `+"`.\\`"+` prefix.

By default this installs the CLI runtime plus any built-in program hex files
found in the packaged payload or repo checkout. Pass `+"`--no-programs`"+` for a smaller
tool-only install, or `+"`--add-to-path`"+` to update the user's PATH
immediately.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		_, binDir, progDir, err := userInstallDirs()
		if err != nil {
			return fmt.Errorf("cannot locate home dir: %w", err)
		}
		sdkDir, err := installedSDKDir()
		if err != nil {
			return fmt.Errorf("cannot locate sdk dir: %w", err)
		}
		for _, d := range []string{binDir, progDir, sdkDir} {
			if err := os.MkdirAll(d, 0o755); err != nil {
				return fmt.Errorf("mkdir %s: %w", d, err)
			}
		}

		srcExe, _ := os.Executable()
		srcDir   := filepath.Dir(srcExe)

		// 1. Copy the binary + DLL into the bin directory.
		files := []string{"raijin.exe", "raijin.dll"}
		var copied []string
		var skipped []string
		for _, f := range files {
			src := filepath.Join(srcDir, f)
			dst := filepath.Join(binDir, f)
			if absSameFile(src, dst) {
				skipped = append(skipped, dst)
				continue
			}
			if err := copyFile(src, dst); err != nil {
				return fmt.Errorf("copy %s: %w", f, err)
			}
			copied = append(copied, dst)
		}

		// 2. Copy each built-in program into programs/. We deliberately skip
		//    catalog.ResolveHex here — that search includes ~/.raijin/programs/
		//    itself, which would make install try to copy a file onto itself.
		var hexCopied, hexMissed []string
		if !installNoPrograms {
			for _, d := range catalog.Builtins() {
				src := findBuiltinHex(&d)
				dst := filepath.Join(progDir, filepath.Base(d.HexPath))
				if src == "" {
					if fileExists(dst) {
						hexCopied = append(hexCopied, d.Name)
						continue
					}
					hexMissed = append(hexMissed, d.Name)
					continue
				}
				if absSameFile(src, dst) {
					// Already in place — nothing to copy.
					hexCopied = append(hexCopied, d.Name)
					continue
				}
				if err := copyFile(src, dst); err != nil {
					return fmt.Errorf("copy %s: %w", d.Name, err)
				}
				hexCopied = append(hexCopied, d.Name)
			}
		}

		// 3. Copy the tiny SDK payload used by `raijin add` when compiling
		//    user-provided C / asm / ELF inputs into .hex files.
		sdkSource := locateInstallableSDKSource()
		sdkCopied := false
		if sdkSource != "" {
			if err := copyTree(filepath.Join(sdkSource, "c-runtime"), filepath.Join(sdkDir, "c-runtime")); err != nil {
				return fmt.Errorf("copy sdk c-runtime: %w", err)
			}
			if err := copyTree(filepath.Join(sdkSource, "runners"), filepath.Join(sdkDir, "runners")); err != nil {
				return fmt.Errorf("copy sdk runners: %w", err)
			}
			sdkCopied = true
		}
		_ = hexCopied
		// Expose the missing list to the output below.
		cmd.SetContext(cmd.Context())
		// (stored on a package-level var for the epilogue)
		lastMissed = hexMissed
		destDir := binDir

		userPathHasDir, pathErr := userPathContainsDir(destDir)
		pathChanged := false
		if installAddToPath {
			pathChanged, err = updateUserPathDir(destDir, pathModeAdd)
			if err != nil {
				return fmt.Errorf("update user PATH: %w", err)
			}
			userPathHasDir = true
			pathErr = nil
		}

		fmt.Println()
		fmt.Println("  " + theme.Accent.Render("✓") + "  " +
			theme.Heading.Render("installed"))
		fmt.Println()
		for _, c := range copied {
			fmt.Println("    " + theme.Faint.Render("→ ") + theme.Value.Render(c))
		}
		for _, c := range skipped {
			fmt.Println("    " + theme.Faint.Render("→ ") + theme.Mute.Render(c+"  (already the running install copy)"))
		}
		if installNoPrograms {
			fmt.Println("    " + theme.Faint.Render("→ ") +
				theme.Mute.Render("program copy skipped  ") + theme.Value.Render("(--no-programs)"))
		} else {
			fmt.Println("    " + theme.Faint.Render("→ ") +
				theme.Value.Render(progDir) +
				"  " + theme.Mute.Render(fmt.Sprintf("(%d built-ins)", len(catalog.Builtins())-len(lastMissed))))
			if len(lastMissed) > 0 {
				fmt.Println("    " + theme.Warn.Render("!  ") +
					theme.Mute.Render("hex missing for: ") +
					theme.Value.Render(strings.Join(lastMissed, ", ")))
				fmt.Println("    " + theme.Mute.Render("   package the built-in payloads next to the CLI or regenerate the repo assets, then re-run install"))
			}
		}
		if sdkCopied {
			fmt.Println("    " + theme.Faint.Render("→ ") +
				theme.Value.Render(sdkDir) + "  " + theme.Mute.Render("(compiler support for `raijin add` )"))
		}
		fmt.Println()

		switch {
		case pathErr != nil:
			fmt.Println("  " + theme.Warn.Render("!") + "  " +
				theme.Mute.Render("could not inspect the user PATH; current shell PATH may still work"))
			fmt.Println()
		case userPathHasDir:
			fmt.Println("  " + theme.Ok.Render("✓") + "  " +
				theme.Value.Render(destDir) + "  " +
				theme.Mute.Render("is on your user PATH"))
			if pathChanged {
				fmt.Println("  " + theme.Mute.Render("open a fresh terminal to pick up the updated PATH"))
			} else if len(skipped) > 0 && len(copied) == 0 {
				fmt.Println("  " + theme.Mute.Render("you ran the already-installed copy; to update from a newer build, run that build's .\\raijin.exe directly"))
			}
			fmt.Println()
			fmt.Println("  try it:")
			fmt.Println("    " + theme.Heading.Render("raijin"))
			fmt.Println()
			return nil
		case installAddToPath:
			fmt.Println("  " + theme.Warn.Render("!") + "  " +
				theme.Mute.Render("PATH update was requested but the directory is still not visible in the user PATH"))
			fmt.Println()
		}

		fmt.Println("  " + theme.Warn.Render("!") + "  " +
			theme.Value.Render(destDir) + "  " +
			theme.Mute.Render("is not on your user PATH yet"))
		fmt.Println()
		fmt.Println("  " + theme.Label.Render("one-time setup  (PowerShell, user PATH):"))
		fmt.Println()
		fmt.Println("    " + theme.Heading.Render(pathAppendPs(destDir)))
		fmt.Println()
		fmt.Println("  " + theme.Mute.Render("open a fresh terminal afterwards, then:"))
		fmt.Println("    " + theme.Heading.Render("raijin"))
		fmt.Println()
		return nil
	},
}

func userInstallDirs() (root, binDir, progDir string, err error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", "", err
	}
	root = filepath.Join(home, ".raijin")
	binDir = filepath.Join(root, "bin")
	progDir = filepath.Join(root, "programs")
	return root, binDir, progDir, nil
}

// pathAppendPs returns the one-liner that appends dir to the user's
// persistent PATH. Idempotent: re-running won't duplicate the entry.
func pathAppendPs(dir string) string {
	quoted := psSingleQuoted(dir)
	return `$p=[Environment]::GetEnvironmentVariable('Path','User'); ` +
		`$d=` + quoted + `; ` +
		`$items=@(); if ($p) { $items += ($p -split ';' | Where-Object { $_ }); } ` +
		`if ($items -notcontains $d) { $items += $d; [Environment]::SetEnvironmentVariable('Path', ($items -join ';'), 'User') }`
}

func pathRemovePs(dir string) string {
	quoted := psSingleQuoted(dir)
	return `$p=[Environment]::GetEnvironmentVariable('Path','User'); ` +
		`$d=` + quoted + `; ` +
		`$items=@(); if ($p) { $items += ($p -split ';' | Where-Object { $_ -and $_ -ne $d }); } ` +
		`[Environment]::SetEnvironmentVariable('Path', ($items -join ';'), 'User')`
}

// absSameFile reports whether two paths resolve to the same on-disk file.
// Used by install to skip a pointless self-copy that would otherwise
// truncate the destination.
func absSameFile(a, b string) bool {
	aa, err1 := filepath.Abs(a)
	bb, err2 := filepath.Abs(b)
	if err1 != nil || err2 != nil {
		return false
	}
	return strings.EqualFold(filepath.Clean(aa), filepath.Clean(bb))
}

type pathMode int

const (
	pathModeAdd pathMode = iota
	pathModeRemove
)

func userPathContainsDir(dir string) (bool, error) {
	pathValue, err := readUserPath()
	if err != nil {
		return false, err
	}
	return pathListContainsDir(pathValue, dir), nil
}

func updateUserPathDir(dir string, mode pathMode) (bool, error) {
	pathValue, err := readUserPath()
	if err != nil {
		return false, err
	}

	var next string
	switch mode {
	case pathModeAdd:
		next = pathListAppendDir(pathValue, dir)
	case pathModeRemove:
		next = pathListRemoveDir(pathValue, dir)
	default:
		next = pathValue
	}

	if next == pathValue {
		return false, nil
	}
	if err := writeUserPath(next); err != nil {
		return false, err
	}
	return true, nil
}

func readUserPath() (string, error) {
	cmd := exec.Command("powershell", "-NoProfile", "-Command",
		"[Environment]::GetEnvironmentVariable('Path','User')")
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func writeUserPath(pathValue string) error {
	command := "[Environment]::SetEnvironmentVariable('Path', " + psSingleQuoted(pathValue) + ", 'User')"
	cmd := exec.Command("powershell", "-NoProfile", "-Command", command)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func psSingleQuoted(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func pathListContainsDir(pathValue, dir string) bool {
	normalizedDir := normalizeDir(dir)
	for _, item := range pathListItems(pathValue) {
		if normalizeDir(item) == normalizedDir {
			return true
		}
	}
	return false
}

func pathListAppendDir(pathValue, dir string) string {
	items := pathListItems(pathValue)
	if pathListContainsDir(pathValue, dir) {
		return strings.Join(items, string(os.PathListSeparator))
	}
	items = append(items, dir)
	return strings.Join(items, string(os.PathListSeparator))
}

func pathListRemoveDir(pathValue, dir string) string {
	normalizedDir := normalizeDir(dir)
	items := pathListItems(pathValue)
	filtered := make([]string, 0, len(items))
	for _, item := range items {
		if normalizeDir(item) == normalizedDir {
			continue
		}
		filtered = append(filtered, item)
	}
	return strings.Join(filtered, string(os.PathListSeparator))
}

func pathListItems(pathValue string) []string {
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

// lastMissed carries the list of demos whose hex couldn't be found
// between the main handler and the epilogue printing. Simple package-
// scope state because this command runs exactly once per invocation.
var lastMissed []string

func init() {
	installCmd.Flags().BoolVar(&installAddToPath, "add-to-path", false,
		"update the user's PATH immediately instead of only printing the PowerShell command")
	installCmd.Flags().BoolVar(&installNoPrograms, "no-programs", false,
		"install only raijin.exe + raijin.dll; skip copying bundled demo hex files")
	root.AddCommand(installCmd)
}
