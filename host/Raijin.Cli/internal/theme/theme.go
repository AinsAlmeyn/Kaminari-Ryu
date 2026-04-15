// Package theme centralises the Raijin CLI's visual language.
//
// We pick a warm, high-contrast palette: bright amber as the single accent
// colour (the "raijin spark" — matches the thunder kanji 雷 motif), a cool
// near-black background, and four grey levels for hierarchy. Every panel,
// prompt, and chart in the app pulls from this palette so the look stays
// coherent from menu to summary to run-time overlay.
package theme

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// Colour tokens. The greyscale ladder is tuned for dark terminals: even
// the dimmest _text_ colour (Mute) stays crisply readable. Only the two
// "decoration" greys (Faint, Border) are allowed to approach the
// background, and those are reserved for dividers and dot-rails, never
// for user-facing text.
var (
	ColAccent  = lipgloss.Color("214")  // amber / raijin spark
	ColAccent2 = lipgloss.Color("172")  // deeper amber
	ColOk      = lipgloss.Color("114")  // soft green
	ColWarn    = lipgloss.Color("173")  // muted orange
	ColErr     = lipgloss.Color("204")  // soft red

	// Text ladder — use these for anything the user is expected to read.
	ColFg0     = lipgloss.Color("255")  // heading / hero
	ColFg1     = lipgloss.Color("252")  // primary body
	ColFg2     = lipgloss.Color("248")  // caption / labels
	ColFg3     = lipgloss.Color("246")  // tertiary body (still readable!)

	// Decoration — NOT for text content. Dividers, dot-rails, subtle
	// separators. These go darker than the text ladder on purpose.
	ColDivider = lipgloss.Color("240")  // horizontal rules
	ColBorder  = lipgloss.Color("238")  // box borders

	// Legacy alias for places that grabbed ColFg4 before the split.
	ColFg4 = ColBorder

	ColBg = lipgloss.Color("232")
)

// Text styles. Names describe _intent_, not colour. Every style in this
// group is bright enough to read at a glance — Mute is the floor.
var (
	Accent    = lipgloss.NewStyle().Foreground(ColAccent).Bold(true)
	AccentDim = lipgloss.NewStyle().Foreground(ColAccent2)
	Heading   = lipgloss.NewStyle().Foreground(ColFg0).Bold(true)
	Value     = lipgloss.NewStyle().Foreground(ColFg1)
	Label     = lipgloss.NewStyle().Foreground(ColFg2)
	Mute      = lipgloss.NewStyle().Foreground(ColFg3)

	// Faint is decoration-only: dividers, dot-rails, arrow glyphs next
	// to readable text. NEVER use it for the text itself.
	Faint = lipgloss.NewStyle().Foreground(ColDivider)

	Ok    = lipgloss.NewStyle().Foreground(ColOk).Bold(true)
	Warn  = lipgloss.NewStyle().Foreground(ColWarn).Bold(true)
	Err   = lipgloss.NewStyle().Foreground(ColErr).Bold(true)

	// Kbd renders like a keyboard cap: bright key over dim background.
	Kbd = lipgloss.NewStyle().
		Foreground(ColFg0).
		Background(ColFg4).
		Padding(0, 1).
		Bold(true)

	// Pill renders short status tags ("ready", "not built", "pass").
	Pill = lipgloss.NewStyle().Padding(0, 1)

	// Card is the frame used for hero panels.
	Card = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ColFg4).
		Padding(1, 2)

	// Thin border for the menu's preview pane.
	Thin = lipgloss.NewStyle().
		Border(lipgloss.NormalBorder(), false, false, false, true).
		BorderForeground(ColFg4).
		PaddingLeft(2)

	HeroNumber = lipgloss.NewStyle().
		Foreground(ColAccent).
		Bold(true)
)

// ─────────────────────────────────────────────────────────────
// Decorative primitives
// ─────────────────────────────────────────────────────────────

// Rule draws a single-character divider line. Width defaults to 60 if w<=0.
func Rule(w int) string {
	if w <= 0 {
		w = 60
	}
	return lipgloss.NewStyle().
		Foreground(ColFg4).
		Render(strings.Repeat("─", w))
}

// Section renders "── LABEL ─── … ─" with the label in label colour.
func Section(label string, w int) string {
	if w <= 0 {
		w = 60
	}
	tag := " " + Label.Render(strings.ToUpper(label)) + " "
	pre := "── "
	tail := strings.Repeat("─", max(0, w-len(stripAnsi(pre))-len(stripAnsi(tag))))
	return lipgloss.NewStyle().Foreground(ColFg4).Render(pre) + tag +
		lipgloss.NewStyle().Foreground(ColFg4).Render(tail)
}

// Bar renders a coloured fill bar over w cells, pct in [0,1].
func Bar(pct float64, w int, on lipgloss.Color) string {
	if pct < 0 {
		pct = 0
	} else if pct > 1 {
		pct = 1
	}
	fill := int(pct*float64(w) + 0.5)
	if fill > w {
		fill = w
	}
	head := lipgloss.NewStyle().Foreground(on).Render(strings.Repeat("█", fill))
	tail := lipgloss.NewStyle().Foreground(ColFg4).Render(strings.Repeat("░", w-fill))
	return head + tail
}

// Spark renders values as a one-row sparkline of block glyphs.
func Spark(values []float64) string {
	if len(values) == 0 {
		return ""
	}
	glyphs := []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}
	maxV := values[0]
	for _, v := range values {
		if v > maxV {
			maxV = v
		}
	}
	if maxV <= 0 {
		maxV = 1
	}
	var b strings.Builder
	for _, v := range values {
		i := int((v / maxV) * float64(len(glyphs)-1))
		if i < 0 {
			i = 0
		}
		if i >= len(glyphs) {
			i = len(glyphs) - 1
		}
		b.WriteRune(glyphs[i])
	}
	return lipgloss.NewStyle().Foreground(ColAccent).Render(b.String())
}

// Status pills
func PillOk(s string)   string { return Pill.Copy().Background(ColOk).Foreground(ColBg).Render(s) }
func PillWarn(s string) string { return Pill.Copy().Background(ColWarn).Foreground(ColBg).Render(s) }
func PillErr(s string)  string { return Pill.Copy().Background(ColErr).Foreground(ColBg).Render(s) }
func PillMute(s string) string { return Pill.Copy().Background(ColFg4).Foreground(ColFg1).Render(s) }

// ─────────────────────────────────────────────────────────────
// Formatters
// ─────────────────────────────────────────────────────────────

func FormatBytes(b uint32) string {
	switch {
	case b < 1024:
		return fmt.Sprintf("%d B", b)
	case b < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(b)/1024)
	default:
		return fmt.Sprintf("%.2f MB", float64(b)/(1024*1024))
	}
}

func FormatCount(n uint64) string {
	switch {
	case n < 1_000:
		return fmt.Sprintf("%d", n)
	case n < 1_000_000:
		return fmt.Sprintf("%.1fK", float64(n)/1_000)
	case n < 1_000_000_000:
		return fmt.Sprintf("%.2fM", float64(n)/1_000_000)
	default:
		return fmt.Sprintf("%.2fB", float64(n)/1_000_000_000)
	}
}

func FormatRuntime(d time.Duration) string {
	switch {
	case d == 0:
		return "—"
	case d < time.Second:
		return fmt.Sprintf("%d ms", d.Milliseconds())
	case d < time.Minute:
		return fmt.Sprintf("%.1f s", d.Seconds())
	case d < time.Hour:
		return fmt.Sprintf("%dm %02ds", int(d.Minutes()), int(d.Seconds())%60)
	default:
		return fmt.Sprintf("%dh %02dm", int(d.Hours()), int(d.Minutes())%60)
	}
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

func stripAnsi(s string) string {
	var b strings.Builder
	inEsc := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == 0x1b {
			inEsc = true
			continue
		}
		if inEsc {
			if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
				inEsc = false
			}
			continue
		}
		b.WriteByte(c)
	}
	return b.String()
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
