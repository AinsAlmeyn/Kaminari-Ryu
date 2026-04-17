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
			{"CSR reads/writes", snap.CsrAccess(), ""},
			{"WFI commits", snap.WfiCommits(), ""},
		}
		for _, it := range items {
			pct := float64(it.count) * 100 / float64(total)
			b.WriteString(fmt.Sprintf("  %-16s %10s  %5.1f%%  %s\n",
				it.label, theme.FormatCount(it.count), pct, it.note))
		}

		if snap.Mix[6] > 0 {
			b.WriteString("\n")
			b.WriteString(theme.Label.Render(" Trap breakdown"))
			b.WriteString("\n")
			exc := snap.Exceptions()
			intr := snap.Interrupts()
			b.WriteString(fmt.Sprintf("  %-16s %10s\n", "exceptions (sync)", theme.FormatCount(exc)))
			b.WriteString(fmt.Sprintf("  %-16s %10s\n", "interrupts (async)", theme.FormatCount(intr)))
			b.WriteString(fmt.Sprintf("  %-16s %10s  %s\n",
				"final mcause", fmt.Sprintf("0x%08x", snap.CSRs.Mcause), mcauseName(snap.CSRs.Mcause)))
		}
	}
	return b.String()
}

// mcauseName returns a short human label for an mcause value so the
// trap breakdown panel is readable without the spec open.
func mcauseName(mcause uint32) string {
	if mcause&0x8000_0000 != 0 {
		switch mcause & 0x7FFF_FFFF {
		case 3:
			return "machine software interrupt"
		case 7:
			return "machine timer interrupt"
		}
		return "interrupt"
	}
	switch mcause {
	case 0:
		return ""
	case 2:
		return "illegal instruction"
	case 3:
		return "breakpoint"
	case 4:
		return "load misaligned"
	case 6:
		return "store misaligned"
	case 11:
		return "environment call (M)"
	}
	return "exception"
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
