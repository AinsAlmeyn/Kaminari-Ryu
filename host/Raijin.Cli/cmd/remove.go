package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/catalog"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/spf13/cobra"
)

var removeCmd = &cobra.Command{
	Use:     "remove <name>",
	Aliases: []string{"delete", "rm"},
	Short:   "Delete a custom program from your personal library.",
	Long: `Remove deletes a custom program's .hex file and its sidecar .json
metadata from the personal program library.

Built-in demos cannot be removed with this command.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		removedPath, err := removeProgramByName(args[0])
		if err != nil {
			return err
		}

		fmt.Println()
		fmt.Println("  " + theme.Accent.Render("✓") + "  " + theme.Heading.Render("program removed"))
		fmt.Println()
		fmt.Println("    " + theme.Faint.Render("→ ") + theme.Value.Render(removedPath))
		fmt.Println()
		return nil
	},
}

func removeProgramByName(name string) (string, error) {
	entry := catalog.Find(name)
	if entry == nil {
		return "", fmt.Errorf("%q is not in the program catalog", name)
	}
	if entry.Kind == catalog.KindBuiltIn {
		return "", fmt.Errorf("%q is a built-in program and cannot be removed", entry.Name)
	}

	hexPath := entry.HexPath
	if !filepath.IsAbs(hexPath) {
		hexPath = catalog.ResolveHex(entry)
	}
	if strings.TrimSpace(hexPath) == "" {
		return "", fmt.Errorf("could not locate the hex file for %q", entry.Name)
	}
	if err := os.Remove(hexPath); err != nil {
		return "", fmt.Errorf("remove %s: %w", hexPath, err)
	}
	metaPath := strings.TrimSuffix(hexPath, filepath.Ext(hexPath)) + ".json"
	if err := os.Remove(metaPath); err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("remove %s: %w", metaPath, err)
	}
	return hexPath, nil
}

func init() {
	root.AddCommand(removeCmd)
}