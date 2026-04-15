package cmd

import (
	"fmt"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"golang.org/x/term"
)

// Custom help rendering that matches the rest of the CLI's visual
// language. Cobra's default template is replaced per-command here.
//
// Root help groups commands into semantic sections (programs / system)
// instead of dumping one alphabetical list. Per-command help keeps
// cobra's default flag-table structure but wraps it in our theme.

func registerHelp() {
	root.SetHelpFunc(func(c *cobra.Command, _ []string) {
		if c == root || c.Name() == "help" {
			printRootHelp()
			return
		}
		printCommandHelp(c)
	})
}

// ─── root help ────────────────────────────────────────────────────────

func printRootHelp() {
	w := helpWidth()

	fmt.Println()
	fmt.Println("  " + theme.Accent.Render("⚡ RAIJIN") + "   " +
		theme.Faint.Render(InformationalVersion()) + "   " +
		theme.Faint.Render("·") + "   " +
		theme.Mute.Render("virtual RV32IM RISC-V machine"))
	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))

	section("synopsis", w)
	synopsisRow("raijin",                    "open the interactive menu")
	synopsisRow("raijin <command> [flags]",  "anything listed below")

	// Group the cobra commands semantically. Cobra's ordering by name is
	// fine for discovery but the user cares more about "what category
	// does this belong to" — programs vs. system utilities.
	progCmds := []string{"run", "demos", "add", "remove", "bench"}
	sysCmds  := []string{"info", "version", "install", "uninstall", "completion"}

	section("programs", w)
	for _, name := range progCmds {
		if c, ok := findChild(name); ok {
			helpRow(c)
		}
	}

	section("system", w)
	for _, name := range sysCmds {
		if c, ok := findChild(name); ok {
			helpRow(c)
		}
	}

	section("global flags", w)
	synopsisRow("-h, --help",     "show help for any command")
	synopsisRow("-v, --version",  "print version and exit")

	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))
	fmt.Println()
	fmt.Printf("  %s  %s%s%s\n",
		theme.Accent.Render("tip"),
		theme.Mute.Render("use "),
		theme.Heading.Render("raijin <command> --help"),
		theme.Mute.Render(" for command-specific flags."))
	fmt.Println()
}

func helpRow(c *cobra.Command) {
	// Command name in bold, arrow as decoration (darker), description in
	// Value (bright enough to read).
	fmt.Printf("      %s  %s %s\n",
		lipgloss.NewStyle().Width(14).Render(theme.Heading.Render(c.Name())),
		theme.Faint.Render("→"),
		theme.Value.Render(shortDesc(c)))
}

// synopsisRow renders "  <lhs> → <desc>" with bright lhs + readable desc.
func synopsisRow(lhs, desc string) {
	fmt.Printf("      %s  %s %s\n",
		lipgloss.NewStyle().Width(28).Render(theme.Heading.Render(lhs)),
		theme.Faint.Render("→"),
		theme.Value.Render(desc))
}

func shortDesc(c *cobra.Command) string {
	d := c.Short
	if d == "" {
		return c.Use
	}
	// Trim trailing period for a cleaner row.
	return strings.TrimRight(d, ".")
}

// ─── per-command help ────────────────────────────────────────────────

func printCommandHelp(c *cobra.Command) {
	w := helpWidth()

	fmt.Println()
	fmt.Println("  " + theme.Accent.Render("⚡") + "  " +
		theme.Heading.Render("raijin "+c.Name()) + "   " +
		theme.Mute.Render("· "+shortDesc(c)))
	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))

	if c.Long != "" {
		fmt.Println()
		for _, line := range strings.Split(c.Long, "\n") {
			fmt.Println("  " + theme.Mute.Render(line))
		}
	}

	// Usage line.
	section("usage", w)
	fmt.Printf("      %s\n", theme.Heading.Render(c.UseLine()))

	// Flags. Cobra exposes local + inherited; show local only to keep
	// the panel tight.
	if flags := c.Flags(); flags.HasFlags() {
		section("flags", w)
		flags.VisitAll(printFlagRow)
	}

	// Subcommand list (only for verbs with children, e.g. "raijin config").
	if c.HasAvailableSubCommands() {
		section("subcommands", w)
		for _, sub := range c.Commands() {
			if sub.IsAvailableCommand() {
				helpRow(sub)
			}
		}
	}

	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))
	fmt.Println()
}

// helpWidth matches the width used by other screens (demos, info, bench).
func helpWidth() int {
	w, _, err := term.GetSize(0)
	if err != nil || w < 64 {
		return 84
	}
	if w > 110 {
		return 110
	}
	return w
}

func printFlagRow(f *pflag.Flag) {
	if f.Hidden {
		return
	}
	var spec string
	if f.Shorthand != "" && f.ShorthandDeprecated == "" {
		spec = fmt.Sprintf("-%s, --%s", f.Shorthand, f.Name)
	} else {
		spec = fmt.Sprintf("    --%s", f.Name)
	}
	if f.Value.Type() != "bool" {
		spec += " <" + f.Value.Type() + ">"
	}
	def := ""
	if f.DefValue != "" && f.DefValue != "false" && f.DefValue != "0" {
		def = theme.Mute.Render("  (default " + f.DefValue + ")")
	}
	fmt.Printf("      %s  %s%s\n",
		lipgloss.NewStyle().Width(26).Render(theme.Heading.Render(spec)),
		theme.Mute.Render(f.Usage),
		def)
}

func findChild(name string) (*cobra.Command, bool) {
	for _, c := range root.Commands() {
		if c.Name() == name {
			return c, true
		}
	}
	return nil, false
}
