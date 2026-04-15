package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/catalog"
	"github.com/AinsAlmeyn/raijin-cli/internal/pathing"
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
		_, binDir, progDir, err := pathing.UserInstallDirs()
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

		// 1. Copy the binary + library into the bin directory. Filenames are
		//    platform-specific (raijin.exe + raijin.dll on Windows,
		//    raijin + libraijin.so on Linux, raijin + libraijin.dylib on macOS),
		//    sourced from the same helper uninstall uses.
		exeName, libName := installedBinaryNames()
		files := []string{exeName, libName}
		var copied []string
		var skipped []string
		for _, f := range files {
			src := filepath.Join(srcDir, f)
			dst := filepath.Join(binDir, f)
			if pathing.AbsSameFile(src, dst) {
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
				if pathing.AbsSameFile(src, dst) {
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

		userPathHasDir, pathErr := pathing.UserPathContainsDir(destDir)
		pathChanged := false
		if installAddToPath {
			pathChanged, err = pathing.UpdateUserPathDir(destDir, pathing.ModeAdd)
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
		label, command := pathing.AppendInstructions(destDir)
		fmt.Println("  " + theme.Label.Render(label))
		fmt.Println()
		fmt.Println("    " + theme.Heading.Render(command))
		fmt.Println()
		fmt.Println("  " + theme.Mute.Render("open a fresh terminal afterwards, then:"))
		fmt.Println("    " + theme.Heading.Render("raijin"))
		fmt.Println()
		return nil
	},
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
