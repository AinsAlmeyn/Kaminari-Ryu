package cmd

import (
	"fmt"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/catalog"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var demosCmd = &cobra.Command{
	Use:     "demos",
	Aliases: []string{"programs"},
	Short:   "List built-in and user programs.",
	RunE: func(cmd *cobra.Command, args []string) error {
		PrintCatalog()
		return nil
	},
}

// PrintCatalog renders every demo as a "section card": each one gets its
// own ⚡-prefixed header + rule + body, matching the visual language of
// info / bench / help. Category chip is colour-coded, status pill
// right-aligned, and each card ends with an actionable launch line.
func PrintCatalog() {
	w, _, err := term.GetSize(0)
	if err != nil || w < 64 {
		w = 84
	}
	if w > 110 {
		w = 110
	}
	innerW := w - 4

	entries := catalog.All()
	builtins, customs := splitProgramEntries(entries)

	// ── Page header ────────────────────────────────────────────────────
	fmt.Println()
	fmt.Println("  " + theme.Accent.Render("⚡ PROGRAMS") + "   " +
		theme.Mute.Render(fmt.Sprintf("%d built-in · %d personal · pick any with  ", len(builtins), len(customs))) +
		theme.Heading.Render("raijin run <name>"))
	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", innerW)))

	for _, d := range builtins {
		fmt.Println()
		fmt.Println(renderCard(d, innerW))
	}
	for _, d := range customs {
		fmt.Println()
		fmt.Println(renderCard(d, innerW))
	}

	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", innerW)))
	fmt.Println()
	fmt.Printf("  %s  %s    %s  %s\n",
		theme.Mute.Render("launch by name:"),
		theme.Heading.Render("raijin run <name>"),
		theme.Mute.Render("· or pick from the menu:"),
		theme.Heading.Render("raijin"))
	fmt.Println()
}

// categoryGlyph + colour: keep these tight and deliberate. The glyph is
// the shape the eye locks onto; the colour is the cognitive bucket.
func categoryChrome(tag string) (string, lipgloss.Color) {
	switch tag {
	case "game":
		return "▶", lipgloss.Color("110") // cool blue
	case "visual":
		return "◈", lipgloss.Color("108") // soft green/teal
	case "legendary":
		return "⚡", theme.ColAccent        // amber / the hero chip
	case catalog.KindCustom:
		return "◆", lipgloss.Color("181")
	default:
		return "•", theme.ColFg2
	}
}

func renderCard(d catalog.Entry, innerW int) string {
	glyph, cat := categoryChrome(d.Tag)
	glyphStyled := lipgloss.NewStyle().Foreground(cat).Bold(true).Render(glyph)
	tagChip := lipgloss.NewStyle().
		Foreground(cat).
		Bold(true).
		Render(strings.ToUpper(d.Tag))

	// Status pill.
	var status string
	if catalog.IsBuilt(&d) {
		status = theme.PillOk(" ready ")
	} else {
		status = theme.PillErr(" not built ")
	}

	// ── Top row ────────────────────────────────────────────────────────
	// glyph · name · tag chip     [right-aligned]     status pill
	topLeft := fmt.Sprintf("  %s  %s   %s   %s",
		glyphStyled,
		theme.Heading.Render(d.Name),
		theme.Faint.Render("·"),
		tagChip)
	pad := innerW - lipgloss.Width(topLeft) - lipgloss.Width(status) - 2
	if pad < 1 {
		pad = 1
	}
	header := topLeft + strings.Repeat(" ", pad) + status

	// Thin rule indented under the header.
	rule := "     " + lipgloss.NewStyle().Foreground(cat).Render(strings.Repeat("─", innerW-6))

	// ── Body ───────────────────────────────────────────────────────────
	var body []string
	body = append(body, "")
	body = append(body, "     "+theme.Value.Render(d.Hint))
	body = append(body, "")

	body = append(body, propRow("controls", d.Controls))
	body = append(body, propRow("launch",   "raijin run "+d.Name))

	hex := catalog.ResolveHex(&d)
	if hex != "" {
		body = append(body, propRow("hex file", shortPath(hex, innerW-24)))
	} else {
		body = append(body, propRow("hex file",
			theme.Warn.Render("missing  ")+theme.Mute.Render("→ add or install the program payload first")))
	}

	return header + "\n" + rule + "\n" + strings.Join(body, "\n")
}

func splitProgramEntries(entries []catalog.Entry) ([]catalog.Entry, []catalog.Entry) {
	builtins := make([]catalog.Entry, 0, len(entries))
	customs := make([]catalog.Entry, 0, len(entries))
	for _, entry := range entries {
		if entry.Kind == catalog.KindCustom {
			customs = append(customs, entry)
			continue
		}
		builtins = append(builtins, entry)
	}
	return builtins, customs
}

func propRow(label, value string) string {
	return fmt.Sprintf("     %s  %s  %s",
		theme.Faint.Render("→"),
		lipgloss.NewStyle().Width(10).Render(theme.Label.Render(label)),
		theme.Value.Render(value))
}

func init() {
	root.AddCommand(demosCmd)
}
