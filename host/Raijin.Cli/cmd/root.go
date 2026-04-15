// Package cmd wires the Cobra command tree. The default command, when
// `raijin` is invoked with no args, launches the interactive menu.
package cmd

import (
	"fmt"
	"os"

	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/spf13/cobra"
)

var root = &cobra.Command{
	Use:          "raijin",
	Short:        "Raijin — virtual RISC-V machine",
	Long:         "Raijin is a Verilator-backed RV32IM+Zicsr simulator. This CLI drives it: interactive menu, demo runner, benchmarks.",
	SilenceUsage: true,
	// If no subcommand was given, launch the interactive menu.
	RunE: func(cmd *cobra.Command, args []string) error {
		os.Exit(runMenu())
		return nil
	},
}

// Execute is the single entry point from main.go.
func Execute() {
	root.SetErrPrefix(theme.Err.Render("error") + " ")
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "  "+theme.Err.Render("error")+"  "+err.Error())
		os.Exit(1)
	}
}

var showVersionFlag bool

func init() {
	// Own --version / -v ourselves (instead of cobra's template pipeline)
	// so the flag renders the same rich card as `raijin version`.
	root.PersistentFlags().BoolVarP(&showVersionFlag, "version", "v", false,
		"print the version card and exit")
	root.PersistentPreRunE = func(cmd *cobra.Command, args []string) error {
		if showVersionFlag {
			printVersion()
			os.Exit(0)
		}
		return nil
	}

	registerHelp()
}
