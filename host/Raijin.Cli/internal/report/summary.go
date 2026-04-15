// summary.go renders the post-run "results card" as a bubbletea model.
//
// Design philosophy: treat the post-run screen as a *moment of celebration*.
// One big hero number (MIPS), a coloured status pill, a clean instruction
// mix broken down as filled bars, and a one-key exit back to the menu.
package report

import (
	"fmt"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/sim"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ShowSummary renders the final-results screen and blocks until the user
// hits Enter (returns to menu) or Esc (quit). Must be called AFTER the
// runner has released the terminal (restored cooked mode).
func ShowSummary(snap sim.Snapshot, program string) (quit bool) {
	m := summaryModel{snap: snap, program: program}
	p := tea.NewProgram(m, tea.WithAltScreen())
	out, _ := p.Run()
	mm := out.(summaryModel)
	return mm.quit
}

type summaryModel struct {
	snap    sim.Snapshot
	program string
	width   int
	height  int
	quit    bool
}

func (m summaryModel) Init() tea.Cmd { return nil }

func (m summaryModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "esc", "q":
			m.quit = true
			return m, tea.Quit
		case "enter", " ":
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m summaryModel) View() string {
	w := m.width
	if w < 70 {
		w = 70
	}

	return lipgloss.JoinVertical(lipgloss.Left,
		"",
		m.headerLine(w),
		"",
		m.hero(w),
		"",
		m.breakdown(w),
		"",
		m.footer(w),
		"",
	)
}

func (m summaryModel) headerLine(w int) string {
	left := "  " + theme.Accent.Render("⚡") + "  " + theme.Heading.Render(m.program)
	right := m.statusPill() + "   " + theme.Faint.Render("run complete")
	pad := w - lipgloss.Width(left) - lipgloss.Width(right) - 2
	if pad < 1 {
		pad = 1
	}
	return left + strings.Repeat(" ", pad) + right
}

func (m summaryModel) statusPill() string {
	s := m.snap
	switch {
	case !s.Halted:
		return theme.PillMute(" STOPPED ")
	case s.Tohost == 1:
		return theme.PillOk(" PASS ")
	default:
		return theme.PillErr(fmt.Sprintf(" FAIL · %d ", s.Tohost>>1))
	}
}

// ─────────────────────────────────────────────────────────────────────
// Hero block: one big MIPS number + supporting stats
// ─────────────────────────────────────────────────────────────────────

func (m summaryModel) hero(w int) string {
	mips := speed(m.snap)

	bigNum := lipgloss.NewStyle().
		Foreground(theme.ColAccent).
		Bold(true).
		Render(fmt.Sprintf("%.1f", mips))
	unit := theme.Label.Render("  MIPS")
	caption := theme.Faint.Render("  simulation throughput")

	leftBlock := lipgloss.JoinVertical(lipgloss.Left,
		lipgloss.JoinHorizontal(lipgloss.Bottom, bigNum, unit),
		caption)

	statsBlock := m.stats(w - 40)

	return "  " + lipgloss.JoinHorizontal(lipgloss.Top,
		lipgloss.NewStyle().Width(32).Render(leftBlock),
		"  ",
		statsBlock,
	)
}

func (m summaryModel) stats(w int) string {
	rows := [][2]string{
		{"runtime", theme.FormatRuntime(m.snap.RunTime)},
		{"cycles", theme.FormatCount(m.snap.CycleCount)},
		{"instructions", theme.FormatCount(m.snap.Instret)},
		{"memory",
			theme.FormatBytes(m.snap.MemoryUsedBytes()) +
				theme.Faint.Render("  / "+theme.FormatBytes(m.snap.MemoryCapacity))},
		{"stack peak", theme.FormatBytes(m.snap.StackBytesUsed)},
	}
	var b strings.Builder
	for _, r := range rows {
		b.WriteString(lipgloss.NewStyle().Width(14).Render(theme.Label.Render(r[0])))
		b.WriteString("  ")
		b.WriteString(theme.Value.Render(r[1]))
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

// ─────────────────────────────────────────────────────────────────────
// Instruction mix as horizontal colour bars
// ─────────────────────────────────────────────────────────────────────

func (m summaryModel) breakdown(w int) string {
	total := m.snap.Instret
	if total == 0 {
		return ""
	}
	bw := w - 40
	if bw < 16 {
		bw = 16
	}

	type row struct {
		label string
		cnt   uint64
		color lipgloss.Color
		note  string
	}
	mix := m.snap.Mix
	rows := []row{
		{"multiply / divide", mix[0], theme.ColAccent, ""},
		{"branches", mix[1], lipgloss.Color("110"), takenRate(mix[1], mix[2])},
		{"loads", mix[4], lipgloss.Color("108"), ""},
		{"stores", mix[5], lipgloss.Color("175"), ""},
		{"jumps", mix[3], lipgloss.Color("244"), ""},
	}
	if mix[6] > 0 {
		rows = append(rows, row{"traps", mix[6], theme.ColErr, ""})
	}

	var b strings.Builder
	b.WriteString("  " + theme.Section("instruction mix", w-4) + "\n")
	for _, r := range rows {
		pct := float64(r.cnt) / float64(total)
		bar := theme.Bar(pct, bw, r.color)
		b.WriteString(fmt.Sprintf("  %s %s  %s  %s  %s\n",
			lipgloss.NewStyle().Width(18).Render(theme.Label.Render(r.label)),
			bar,
			lipgloss.NewStyle().Width(8).Align(lipgloss.Right).Render(theme.Value.Render(theme.FormatCount(r.cnt))),
			lipgloss.NewStyle().Width(6).Align(lipgloss.Right).Render(theme.Mute.Render(fmt.Sprintf("%.1f%%", pct*100))),
			theme.Faint.Render(r.note),
		))
	}
	return b.String()
}

// ─────────────────────────────────────────────────────────────────────
// Footer
// ─────────────────────────────────────────────────────────────────────

func (m summaryModel) footer(w int) string {
	return "  " +
		theme.Kbd.Render("enter") + " " + theme.Mute.Render("back to menu") +
		"   " +
		theme.Kbd.Render("esc") + " " + theme.Mute.Render("quit raijin")
}

func speed(s sim.Snapshot) float64 {
	if s.RunTime.Seconds() < 0.01 {
		return 0
	}
	return float64(s.Instret) / s.RunTime.Seconds() / 1_000_000
}

func takenRate(total, taken uint64) string {
	if total == 0 {
		return ""
	}
	return fmt.Sprintf("%.0f%% taken", float64(taken)*100/float64(total))
}
