package cmd

import (
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/AinsAlmeyn/raijin-cli/internal/report"
	"github.com/AinsAlmeyn/raijin-cli/internal/sim"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var (
	benchMaxCycles uint64
	benchRuns      int
)

var benchCmd = &cobra.Command{
	Use:   "bench <hex|name>",
	Short: "Benchmark a program (silent, prints timing + perf mix).",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		r := Resolve(args[0])
		if r.HexPath == "" {
			RenderNotFound(args[0], r.Suggest)
			os.Exit(2)
		}

		w := termCols()

		// ── Header ──────────────────────────────────────────
		fmt.Println()
		title := "  " + theme.Accent.Render("⚡ BENCHMARK") + "   " +
			theme.Heading.Render(r.Display)
		meta := theme.Mute.Render("· single run")
		if benchRuns > 1 {
			meta = theme.Mute.Render(fmt.Sprintf("· %d runs", benchRuns))
		}
		fmt.Println(title + "   " + meta)
		fmt.Println()
		fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))
		fmt.Println()

		// ── Single run path: just render the usual summary ──
		if benchRuns <= 1 {
			snap, ok := runWithSpinner(r.HexPath, benchMaxCycles, 1, 1)
			if !ok {
				os.Exit(2)
			}
			fmt.Println()
			fmt.Println(report.Final(snap, r.Display))
			if snap.Halted && snap.Tohost == 1 {
				return nil
			}
			os.Exit(1)
		}

		// ── Multi-run: live spinner per run, then comparison cards ──
		var snaps []sim.Snapshot
		for i := 0; i < benchRuns; i++ {
			snap, ok := runWithSpinner(r.HexPath, benchMaxCycles, i+1, benchRuns)
			if !ok {
				fmt.Println()
				os.Exit(2)
			}
			snaps = append(snaps, snap)
			fmt.Println(finalRunLine(snap, i+1, benchRuns))
		}

		fmt.Println()
		fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))
		renderThroughput(snaps, w)
		renderDistribution(snaps, w)
		fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))
		fmt.Println()

		if allPass(snaps) {
			return nil
		}
		os.Exit(1)
		return nil
	},
}

// ── Spinner animation during a single run ─────────────────────────────

// Braille dot spinner. Classic and renders well at mono-space widths.
var spinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// runWithSpinner ticks an animated "running… elapsed X.Xs" line on the
// same row while benchOnce crunches in the background. When benchOnce
// returns we stop the ticker and leave the cursor at the start of that
// line so the caller can overwrite it with the final "done" line.
func runWithSpinner(hexPath string, maxCycles uint64, idx, total int) (sim.Snapshot, bool) {
	done := make(chan struct{})
	var wg sync.WaitGroup
	start := time.Now()

	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(80 * time.Millisecond)
		defer t.Stop()
		frame := 0
		for {
			select {
			case <-done:
				return
			case <-t.C:
				elapsed := time.Since(start)
				spinner := theme.Accent.Render(spinnerFrames[frame%len(spinnerFrames)])
				label := theme.Label.Render(fmt.Sprintf("run %d/%d", idx, total))
				status := theme.Mute.Render(fmt.Sprintf("running   %s elapsed",
					theme.FormatRuntime(elapsed)))
				// \r returns to column 1 without newline; \x1b[2K clears the
				// whole line so we don't leave trailing chars from a longer
				// previous frame.
				fmt.Printf("\r\x1b[2K    %s  %s  %s",
					spinner, lipgloss.NewStyle().Width(10).Render(label), status)
				frame++
			}
		}
	}()

	snap, ok := benchOnce(hexPath, maxCycles)
	close(done)
	wg.Wait()

	// Clear the spinner line so the caller's "final line" starts fresh.
	fmt.Print("\r\x1b[2K")
	return snap, ok
}

// finalRunLine is what replaces the spinner after a run completes. It's
// the most information-dense line in the bench output, so the hierarchy
// matters: marker ●, run label (dim), MIPS (bold accent = the hero), then
// wall time and cycle count in supporting greys.
func finalRunLine(snap sim.Snapshot, idx, total int) string {
	marker := theme.Accent.Render("●")
	if !snap.Halted || snap.Tohost != 1 {
		marker = theme.Mute.Render("●")
	}
	label := theme.Label.Render(fmt.Sprintf("run %d/%d", idx, total))
	mips  := theme.Accent.Render(fmt.Sprintf("%5.2f MIPS", mipsOf(snap)))
	sep   := theme.Faint.Render("·")
	time  := theme.Value.Render(theme.FormatRuntime(snap.RunTime))
	cyc   := theme.Mute.Render(theme.FormatCount(snap.CycleCount) + " cycles")

	return fmt.Sprintf("    %s  %s  %s   %s   %s   %s   %s",
		marker,
		lipgloss.NewStyle().Width(10).Render(label),
		mips,
		sep, time,
		sep, cyc,
	)
}

// ── benchOnce (unchanged) ─────────────────────────────────────────────

func benchOnce(hexPath string, maxCycles uint64) (sim.Snapshot, bool) {
	se, err := sim.OpenSession()
	if err != nil {
		fmt.Fprintln(os.Stderr, theme.Err.Render("error")+"  "+err.Error())
		return sim.Snapshot{}, false
	}
	defer se.Close()
	if err := se.LoadHex(hexPath); err != nil {
		fmt.Fprintln(os.Stderr, theme.Err.Render("error")+"  "+err.Error())
		return sim.Snapshot{}, false
	}
	const chunk = 100_000
	var total uint64
	for total < maxCycles && !se.S.Halted() {
		total += se.Step(chunk)
		_ = se.S.ReadUart() // drain quietly
	}
	return se.Snapshot(), true
}

// ── HERO / THROUGHPUT ─────────────────────────────────────────────────

func renderThroughput(runs []sim.Snapshot, w int) {
	mipsList := mipsOfAll(runs)
	sorted := append([]float64(nil), mipsList...)
	sort.Float64s(sorted)
	minV, maxV := sorted[0], sorted[len(sorted)-1]
	mean := avg(mipsList)
	stdev := stdev(mipsList, mean)
	cv := 0.0
	if mean > 0 {
		cv = 100 * stdev / mean
	}
	rangeV := maxV - minV

	section("throughput", w)

	// Hero block: huge mean MIPS on its own line, caption right-below.
	hero := lipgloss.NewStyle().Foreground(theme.ColAccent).Bold(true).
		Render(fmt.Sprintf("%.2f", mean))
	fmt.Println()
	fmt.Printf("      %s %s\n", hero, theme.Label.Render("MIPS"))
	fmt.Printf("      %s\n", theme.Mute.Render(fmt.Sprintf("mean across %d runs", len(runs))))
	fmt.Println()

	// Stats row: evenly spaced label/value pairs on a single line.
	stat := func(label, value string) string {
		return theme.Label.Render(label) + "  " + theme.Value.Render(value)
	}
	fmt.Printf("      %s    %s    %s    %s    %s\n",
		stat("min",   fmt.Sprintf("%.2f", minV)),
		stat("max",   fmt.Sprintf("%.2f", maxV)),
		stat("range", fmt.Sprintf("%.2f", rangeV)),
		stat("σ",     fmt.Sprintf("%.2f", stdev)),
		stat("CV",    fmt.Sprintf("%.1f%%", cv)))
}

// ── DISTRIBUTION ──────────────────────────────────────────────────────

func renderDistribution(runs []sim.Snapshot, w int) {
	section("distribution", w)

	mipsList := mipsOfAll(runs)
	sorted := append([]float64(nil), mipsList...)
	sort.Float64s(sorted)
	minV, maxV := sorted[0], sorted[len(sorted)-1]
	bestIdx, worstIdx := argmax(mipsList), argmin(mipsList)

	const scaleW = 36
	rangeV := maxV - minV

	fmt.Println()
	for i, m := range mipsList {
		pos := 0
		if rangeV > 0 {
			pos = int(((m - minV) / rangeV) * float64(scaleW-1))
		} else {
			pos = scaleW / 2
		}
		if pos < 0 {
			pos = 0
		}
		if pos >= scaleW {
			pos = scaleW - 1
		}

		// Mute dots for the axis, bright coloured dot at the value.
		left := theme.Mute.Render(strings.Repeat("·", pos))
		var dot string
		switch i {
		case bestIdx:
			dot = theme.Accent.Render("●")
		case worstIdx:
			dot = theme.Warn.Render("●")
		default:
			dot = theme.Value.Render("●")
		}
		right := theme.Mute.Render(strings.Repeat("·", scaleW-1-pos))

		tag := ""
		switch i {
		case bestIdx:
			tag = theme.Accent.Render("★ fastest")
		case worstIdx:
			tag = theme.Warn.Render("✕ slowest")
		}

		fmt.Printf("      %s  %s  %s  %s\n",
			lipgloss.NewStyle().Width(3).Render(theme.Label.Render(fmt.Sprintf("#%d", i+1))),
			lipgloss.NewStyle().Width(6).Render(theme.Value.Render(fmt.Sprintf("%5.2f", m))),
			left+dot+right,
			tag)
	}
}

// ── Stats helpers ─────────────────────────────────────────────────────

func mipsOf(s sim.Snapshot) float64 {
	if s.RunTime.Seconds() < 0.01 {
		return 0
	}
	return float64(s.Instret) / s.RunTime.Seconds() / 1_000_000
}

func mipsOfAll(runs []sim.Snapshot) []float64 {
	out := make([]float64, len(runs))
	for i, r := range runs {
		out[i] = mipsOf(r)
	}
	return out
}

func avg(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	var s float64
	for _, x := range xs {
		s += x
	}
	return s / float64(len(xs))
}

func stdev(xs []float64, mean float64) float64 {
	if len(xs) <= 1 {
		return 0
	}
	var s float64
	for _, x := range xs {
		s += (x - mean) * (x - mean)
	}
	return math.Sqrt(s / float64(len(xs)))
}

func argmax(xs []float64) int {
	idx := 0
	for i, x := range xs {
		if x > xs[idx] {
			idx = i
		}
	}
	return idx
}
func argmin(xs []float64) int {
	idx := 0
	for i, x := range xs {
		if x < xs[idx] {
			idx = i
		}
	}
	return idx
}

func allPass(runs []sim.Snapshot) bool {
	for _, r := range runs {
		if !(r.Halted && r.Tohost == 1) {
			return false
		}
	}
	return true
}

func termCols() int {
	w, _, err := term.GetSize(0)
	if err != nil || w < 64 {
		return 84
	}
	if w > 110 {
		return 110
	}
	return w
}

func init() {
	benchCmd.Flags().Uint64VarP(&benchMaxCycles, "max-cycles", "c", 50_000_000,
		"cycle cap per run (default: 50,000,000 ≈ 6 s at 8 MIPS)")
	benchCmd.Flags().IntVarP(&benchRuns, "runs", "n", 1,
		"repeat the benchmark N times; prints comparison if N > 1")
	root.AddCommand(benchCmd)
}
