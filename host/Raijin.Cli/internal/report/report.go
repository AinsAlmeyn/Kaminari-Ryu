// Package report renders the post-run Summary + Instruction-mix panels.
// ShowSummary (summary.go) is the interactive bubbletea screen; Final is
// the plain-text fallback used when output is piped or --quiet is set.
package report

import (
	"fmt"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/sim"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"

	"github.com/charmbracelet/lipgloss"
)

// Final is the plain-text summary for piped / quiet contexts.
func Final(snap sim.Snapshot, program string) string {
	var b strings.Builder

	result := "STOPPED"
	if snap.Halted {
		if snap.Tohost == 1 {
			result = "PASS"
		} else {
			result = fmt.Sprintf("FAIL  subtest %d", snap.Tohost>>1)
		}
	}

	rows := [][2]string{
		{"program", program},
		{"result", result},
		{"runtime", theme.FormatRuntime(snap.RunTime)},
		{"cycles", theme.FormatCount(snap.CycleCount)},
		{"instructions", theme.FormatCount(snap.Instret)},
		{"avg speed", plainSpeed(snap)},
		{"memory used",
			fmt.Sprintf("%s / %s",
				theme.FormatBytes(snap.MemoryUsedBytes()),
				theme.FormatBytes(snap.MemoryCapacity))},
		{"  program", theme.FormatBytes(snap.ProgramBytes)},
		{"  stack peak", theme.FormatBytes(snap.StackBytesUsed)},
	}

	b.WriteString(theme.Label.Render(" Summary"))
	b.WriteString("\n")
	for _, r := range rows {
		b.WriteString(fmt.Sprintf("  %s  %s\n",
			lipgloss.NewStyle().Width(16).Render(theme.Label.Render(r[0])),
			theme.Value.Render(r[1])))
	}
	b.WriteString("\n")

	if snap.Instret > 0 {
		b.WriteString(theme.Label.Render(" Instruction mix"))
		b.WriteString("\n")
		total := snap.Instret
		items := []struct {
			label string
			count uint64
			note  string
		}{
			{"multiply/divide", snap.Mix[0], ""},
			{"branches", snap.Mix[1], plainTakenRate(snap.Mix[1], snap.Mix[2])},
			{"loads", snap.Mix[4], ""},
			{"stores", snap.Mix[5], ""},
			{"jumps", snap.Mix[3], ""},
		}
		for _, it := range items {
			pct := float64(it.count) * 100 / float64(total)
			b.WriteString(fmt.Sprintf("  %-16s %10s  %5.1f%%  %s\n",
				it.label, theme.FormatCount(it.count), pct, it.note))
		}
	}
	return b.String()
}

func plainSpeed(s sim.Snapshot) string {
	if s.RunTime.Seconds() < 0.01 {
		return "—"
	}
	m := float64(s.Instret) / s.RunTime.Seconds() / 1_000_000
	return fmt.Sprintf("%.1f MIPS", m)
}

func plainTakenRate(total, taken uint64) string {
	if total == 0 {
		return ""
	}
	return fmt.Sprintf("%.0f%% taken", float64(taken)*100/float64(total))
}
