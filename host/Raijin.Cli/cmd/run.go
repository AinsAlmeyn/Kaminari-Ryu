package cmd

import (
	"fmt"
	"os"

	"github.com/AinsAlmeyn/raijin-cli/internal/runner"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/spf13/cobra"
)

var (
	runMaxCycles uint64
	runQuiet     bool
	runNoStatus  bool
)

var runCmd = &cobra.Command{
	Use:   "run <hex|name>",
	Short: "Run a program — accepts a built-in name, imported name, or a .hex file path.",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		r := Resolve(args[0])
		if r.HexPath == "" {
			RenderNotFound(args[0], r.Suggest)
			os.Exit(2)
		}

		// Brief intro banner.
		fmt.Println()
		fmt.Printf("  %s  %s\n",
			theme.Label.Render("running"),
			theme.Heading.Render(r.Display))
		fmt.Printf("  %s\n",
			theme.Mute.Render("Ctrl+C to stop · type to send UART input"))
		fmt.Println()

		rc := runner.Run(runner.Options{
			HexPath:   r.HexPath,
			Display:   r.Display,
			MaxCycles: runMaxCycles,
			Quiet:     runQuiet,
			NoStatus:  runNoStatus,
		})
		os.Exit(rc)
		return nil
	},
}

func init() {
	runCmd.Flags().Uint64VarP(&runMaxCycles, "max-cycles", "c", 0,
		"stop after at most N cycles (default: until halt or Ctrl+C)")
	runCmd.Flags().BoolVarP(&runQuiet, "quiet", "q", false,
		"suppress UART passthrough; print only the final report")
	runCmd.Flags().BoolVar(&runNoStatus, "no-status-bar", false,
		"don't paint the bottom status line (plain passthrough only)")
	root.AddCommand(runCmd)
}
