package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/catalog"
	"github.com/AinsAlmeyn/raijin-cli/internal/suggest"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/charmbracelet/lipgloss"
	"golang.org/x/term"
)

// ResolveTarget turns a user-typed string (file path or demo short name)
// into an absolute hex path + display name. On failure it carries a list
// of close matches from the catalog for the caller to render.
type ResolveResult struct {
	HexPath string
	Display string
	Suggest []string
}

func Resolve(typed string) ResolveResult {
	if typed == "" {
		return ResolveResult{Suggest: catalogNames()}
	}
	if _, err := os.Stat(typed); err == nil {
		return ResolveResult{HexPath: typed, Display: filepath.Base(typed)}
	}
	if e := catalog.Find(typed); e != nil {
		if hex := catalog.ResolveHex(e); hex != "" {
			return ResolveResult{HexPath: hex, Display: e.Name + ".hex"}
		}
		return ResolveResult{Display: e.Name}
	}
	return ResolveResult{Suggest: suggest.Closest(typed, catalogNames(), 3, 4)}
}

func catalogNames() []string {
	entries := catalog.All()
	out := make([]string, len(entries))
	for i, e := range entries {
		out[i] = e.Name
	}
	return out
}

// RenderNotFound writes a styled "not found" panel to stderr. First match
// is highlighted with a ▸ and pre-filled into the "try this" line; the
// rest are shown as secondary options with their catalog descriptions so
// the user can pick the one they actually meant.
func RenderNotFound(typed string, suggestions []string) {
	w := helpWidthFallback()
	innerW := w - 4

	fmt.Fprintln(os.Stderr)
	// ── Section header ──────────────────────────────────────────────
	header := "  " + theme.Err.Render("⚡ NOT FOUND") + "   " +
		theme.Mute.Render(fmt.Sprintf("\"%s\" didn't match any file path or demo name",
			truncate(typed, 48)))
	fmt.Fprintln(os.Stderr, header)
	fmt.Fprintln(os.Stderr, "  "+theme.Faint.Render(strings.Repeat("─", innerW)))

	if len(suggestions) == 0 {
		fmt.Fprintln(os.Stderr)
		fmt.Fprintf(os.Stderr, "    %s\n", theme.Mute.Render("no close matches found"))
		fmt.Fprintln(os.Stderr)
		fmt.Fprintf(os.Stderr, "    %s  %s\n",
			theme.Mute.Render("browse everything:"),
			theme.Heading.Render("raijin demos"))
		fmt.Fprintln(os.Stderr)
		fmt.Fprintln(os.Stderr, "  "+theme.Faint.Render(strings.Repeat("─", innerW)))
		fmt.Fprintln(os.Stderr)
		return
	}

	fmt.Fprintln(os.Stderr)
	fmt.Fprintf(os.Stderr, "    %s\n", theme.Label.Render("did you mean"))
	fmt.Fprintln(os.Stderr)

	for i, s := range suggestions {
		var marker, nameStyle string
		if i == 0 {
			marker = theme.Accent.Render("▸")
			nameStyle = theme.Heading.Render(s)
		} else {
			marker = theme.Faint.Render("·")
			nameStyle = theme.Value.Render(s)
		}

		var desc, tagChip string
		if e := catalog.Find(s); e != nil {
			desc = theme.Mute.Render(e.Description)
			_, col := categoryChrome(e.Tag)
			tagChip = lipgloss.NewStyle().
				Foreground(col).
				Bold(true).
				Render(strings.ToUpper(e.Tag))
		}

		fmt.Fprintf(os.Stderr, "      %s  %s  %s  %s\n",
			marker,
			lipgloss.NewStyle().Width(10).Render(nameStyle),
			lipgloss.NewStyle().Width(12).Render(tagChip),
			desc)
	}

	fmt.Fprintln(os.Stderr)
	fmt.Fprintf(os.Stderr, "    %s  %s\n",
		theme.Mute.Render("try:"),
		theme.Heading.Render("raijin run "+suggestions[0]))
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "  "+theme.Faint.Render(strings.Repeat("─", innerW)))
	fmt.Fprintln(os.Stderr)
}

func helpWidthFallback() int {
	w, _, err := term.GetSize(0)
	if err != nil || w < 64 {
		return 84
	}
	if w > 110 {
		return 110
	}
	return w
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}
