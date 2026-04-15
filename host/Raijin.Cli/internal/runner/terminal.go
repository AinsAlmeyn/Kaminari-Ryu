package runner

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/sim"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"

	"golang.org/x/term"
)

// terminal is a narrow wrapper that emits the exact VT sequences a
// polished TUI needs — alt screen, scroll region, status-line overlay —
// without going through any framework that might probe the terminal.
type terminal struct {
	w       io.Writer
	entered bool
	height  int
	width   int
}

func newTerminal(w io.Writer) *terminal {
	t := &terminal{w: w}
	t.refreshSize()
	return t
}

func (t *terminal) refreshSize() {
	w, h, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil || h < 5 {
		t.width, t.height = 80, 30
		return
	}
	t.width, t.height = w, h
}

// enter switches to alt screen, reserves the last row as status, hides
// cursor. Idempotent.
func (t *terminal) enter() {
	if t.entered {
		return
	}
	t.refreshSize()
	// \x1b[?1049h   alt screen
	// \x1b[?25l     hide cursor
	// \x1b[2J       clear
	// \x1b[1;{h-1}r scroll region rows 1..h-1 so newlines never touch row h
	// \x1b[H        home
	fmt.Fprintf(t.w, "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[1;%dr\x1b[H", t.height-1)
	t.entered = true
}

// leave clears the reserved margins and returns control to the user's
// original screen. Safe to call multiple times.
func (t *terminal) leave() {
	if !t.entered {
		return
	}
	// \x1b[r         reset scroll region
	// \x1b[?25h      show cursor
	// \x1b[?1049l    return to main screen (preserves caller's scrollback)
	fmt.Fprint(t.w, "\x1b[r\x1b[?25h\x1b[?1049l")
	t.entered = false
}

// drawStatus paints the bottom row atomically. DEC mode 2026 wraps the
// whole sequence so capable terminals buffer + flush as one frame — no
// flicker. Unsupported terminals silently ignore the markers.
func (t *terminal) drawStatus(snap sim.Snapshot, hints string) {
	if !t.entered {
		return
	}
	t.refreshSize()
	line := t.formatStatus(snap, hints)
	// ?2026h   begin synchronized update
	// ESC 7    DECSC — save cursor + attrs
	// [{h};1H  absolute move to status row
	// [2K      erase line
	// <line>
	// ESC 8    DECRC — restore cursor
	// ?2026l   end synchronized update
	fmt.Fprintf(t.w, "\x1b[?2026h\x1b7\x1b[%d;1H\x1b[2K%s\x1b8\x1b[?2026l",
		t.height, line)
}

func (t *terminal) formatStatus(s sim.Snapshot, hints string) string {
	// Plain-text body, then wrap once in a dim SGR so width calculations
	// stay predictable and nothing Spectre-style is in the pipeline.
	body := fmt.Sprintf("  PC 0x%08X   %4.1f MIPS   cyc %s   mem %s   %s",
		s.PC, s.MIPS,
		theme.FormatCount(s.CycleCount),
		theme.FormatBytes(s.MemoryUsedBytes()),
		hints,
	)
	return "\x1b[2;37m" + body + "\x1b[0m"
}

// clearContent wipes the scrollable region (rows 1..h-1) and parks the
// cursor at the top. Used when resuming from a pause so the program's
// next frame doesn't paint on top of our summary text.
func (t *terminal) clearContent() {
	if !t.entered {
		return
	}
	t.refreshSize()
	fmt.Fprintf(t.w, "\x1b[?2026h\x1b[1;1H\x1b[0J\x1b[?2026l")
}

// drawPausePage renders the "paused" view in the alt screen. Uses a
// two-column dashboard layout so the eye gets a compact, balanced
// snapshot instead of lots of vertical whitespace:
//
//	● PAUSED                                 simulation frozen
//	═════════════════════════════════════════════════════════════
//
//	  8.30  MIPS                 instruction mix
//	  simulation throughput      ─────────────────────────────
//	                              multiply/div  ░░░░░░   628  0%
//	  runtime       9.4 s         branches      ██████ 25.6M 33%
//	  cycles        76.95M        loads         ░░░░░░  1.6K  0%
//	  instructions  76.95M        stores        ░░░░░░  6.8K  0%
//	  memory        16 KB / 32 MB jumps         ░░░░░░  1.6K  0%
//
//	═════════════════════════════════════════════════════════════
//	 [Enter] back to menu    [R] resume    [Esc] quit raijin  ← menu mode
//	 [Enter] resume          [Esc] quit raijin                ← direct mode
func (t *terminal) drawPausePage(s sim.Snapshot, inMenu bool) {
	if !t.entered {
		return
	}
	t.refreshSize()

	// Column widths. Keep the left column deterministic; the right
	// expands as long as the terminal has width to spare.
	const leftW = 38
	rightW := t.width - leftW - 6
	if rightW < 32 {
		rightW = 32
	}

	var b strings.Builder
	b.WriteString("\x1b[?2026h\x1b[1;1H\x1b[2J")

	// ── Header ────────────────────────────────────────────────────
	headerL := "  " + amberBg(" ● PAUSED ") + "   " +
		dim("simulation frozen")
	headerR := dim("pick what happens next")
	pad := t.width - visibleLen(headerL) - visibleLen(headerR) - 4
	if pad < 2 {
		pad = 2
	}
	b.WriteString("\n")
	b.WriteString(headerL + strings.Repeat(" ", pad) + headerR + "\n")
	b.WriteString("  " + faint(strings.Repeat("═", t.width-4)) + "\n")
	b.WriteString("\n")

	// ── Left column: hero MIPS + stats ────────────────────────────
	leftRows := make([]string, 0, 8)
	hero := fmt.Sprintf("    %s %s",
		amberBold(fmt.Sprintf("%6.2f", s.MIPS)),
		label("MIPS"))
	leftRows = append(leftRows, hero)
	leftRows = append(leftRows, "    "+dim("simulation throughput"))
	leftRows = append(leftRows, "")
	leftRows = append(leftRows, fmt.Sprintf("    %s  %s",
		padRightV(label("runtime"), 13), value(theme.FormatRuntime(s.RunTime))))
	leftRows = append(leftRows, fmt.Sprintf("    %s  %s",
		padRightV(label("cycles"), 13), value(theme.FormatCount(s.CycleCount))))
	leftRows = append(leftRows, fmt.Sprintf("    %s  %s",
		padRightV(label("instructions"), 13), value(theme.FormatCount(s.Instret))))
	leftRows = append(leftRows, fmt.Sprintf("    %s  %s %s %s",
		padRightV(label("memory"), 13),
		value(theme.FormatBytes(s.MemoryUsedBytes())),
		faint("/"),
		dim(theme.FormatBytes(s.MemoryCapacity))))

	// ── Right column: instruction mix ─────────────────────────────
	rightRows := make([]string, 0, 8)
	rightRows = append(rightRows, "  "+label("instruction mix"))
	rightRows = append(rightRows, "  "+faint(strings.Repeat("─", rightW-2)))
	rightRows = append(rightRows, "")

	if s.Instret > 0 {
		total := s.Instret
		bw := rightW - 28
		if bw < 12 {
			bw = 12
		}
		if bw > 28 {
			bw = 28
		}

		type row struct {
			label string
			count uint64
			col   string
		}
		mix := s.Mix
		mixRows := []row{
			{"multiply/div", mix[0], "214"},
			{"branches",     mix[1], "110"},
			{"loads",        mix[4], "108"},
			{"stores",       mix[5], "175"},
			{"jumps",        mix[3], "244"},
		}
		if mix[6] > 0 {
			mixRows = append(mixRows, row{"traps", mix[6], "204"})
		}
		for _, r := range mixRows {
			pct := float64(r.count) / float64(total)
			bar := bar256(pct, bw, r.col)
			rightRows = append(rightRows, fmt.Sprintf("  %s %s %s %s",
				padRightV(label(r.label), 13),
				bar,
				padLeftV(value(theme.FormatCount(r.count)), 7),
				padLeftV(dim(fmt.Sprintf("%.0f%%", pct*100)), 4)))
		}
	} else {
		rightRows = append(rightRows, "  "+dim("no instructions retired yet"))
	}

	// Zip the two columns row-by-row.
	maxRows := len(leftRows)
	if len(rightRows) > maxRows {
		maxRows = len(rightRows)
	}
	for i := 0; i < maxRows; i++ {
		left := ""
		if i < len(leftRows) {
			left = leftRows[i]
		}
		right := ""
		if i < len(rightRows) {
			right = rightRows[i]
		}
		b.WriteString(padRightV(left, leftW) + "  " + right + "\n")
	}

	// ── Footer ────────────────────────────────────────────────────
	b.WriteString("\n")
	b.WriteString("  " + faint(strings.Repeat("═", t.width-4)) + "\n")

	var actions string
	if inMenu {
		actions = "   " + kbdCap("Enter") + " " + value("back to menu") +
			"     " + kbdCap("R") + " " + value("resume") +
			"     " + kbdCap("Esc") + " " + value("quit raijin")
	} else {
		actions = "   " + kbdCap("Enter") + " " + value("resume") +
			"     " + kbdCap("Esc") + " " + value("quit raijin")
	}
	b.WriteString(fmt.Sprintf("\x1b[%d;1H\x1b[2K%s", t.height, actions))

	b.WriteString("\x1b[?2026l")
	fmt.Fprint(t.w, b.String())
}

// visibleLen counts visible cells, ignoring ANSI escape sequences.
func visibleLen(s string) int { return len(stripAnsi(s)) }

// padRightV / padLeftV are visible-length aware (strip ANSI for width).
func padRightV(s string, w int) string {
	n := visibleLen(s)
	if n >= w {
		return s
	}
	return s + strings.Repeat(" ", w-n)
}
func padLeftV(s string, w int) string {
	n := visibleLen(s)
	if n >= w {
		return s
	}
	return strings.Repeat(" ", w-n) + s
}

// ── small ANSI helpers (independent of lipgloss so we can write raw) ──

func amber(s string)      string { return "\x1b[38;5;214;1m" + s + "\x1b[0m" }
func amberBold(s string)  string { return "\x1b[38;5;214;1m" + s + "\x1b[0m" }
func amberBg(s string)    string { return "\x1b[48;5;214;38;5;232;1m" + s + "\x1b[0m" }
func label(s string)      string { return "\x1b[38;5;248m" + s + "\x1b[0m" }
func value(s string)      string { return "\x1b[38;5;252m" + s + "\x1b[0m" }
func dim(s string)        string { return "\x1b[38;5;246m" + s + "\x1b[0m" }
func faint(s string)      string { return "\x1b[38;5;240m" + s + "\x1b[0m" }
func kbdCap(k string)     string { return "\x1b[48;5;238;38;5;255;1m " + k + " \x1b[0m" }

func section(title string, width int) string {
	tag := " " + label(strings.ToUpper(title)) + " "
	pre := faint("── ")
	tailW := width - 6 - len(title) - 2
	if tailW < 2 {
		tailW = 2
	}
	return pre + tag + faint(strings.Repeat("─", tailW))
}

func padLeft(s string, w int) string {
	visible := stripAnsi(s)
	if len(visible) >= w {
		return s
	}
	return s + strings.Repeat(" ", w-len(visible))
}
func padRight(s string, w int) string {
	visible := stripAnsi(s)
	if len(visible) >= w {
		return s
	}
	return strings.Repeat(" ", w-len(visible)) + s
}

func bar256(pct float64, w int, col string) string {
	if pct < 0 {
		pct = 0
	} else if pct > 1 {
		pct = 1
	}
	fill := int(pct*float64(w) + 0.5)
	if fill > w {
		fill = w
	}
	head := "\x1b[38;5;" + col + "m" + strings.Repeat("█", fill) + "\x1b[0m"
	tail := faint(strings.Repeat("░", w-fill))
	return head + tail
}

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
