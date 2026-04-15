package cmd

import (
	"fmt"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var infoCmd = &cobra.Command{
	Use:   "info",
	Short: "Show CPU specs + quick-start hints.",
	RunE: func(cmd *cobra.Command, args []string) error {
		printInfo()
		return nil
	},
}

func printInfo() {
	w, _, err := term.GetSize(0)
	if err != nil || w < 64 {
		w = 84
	}
	if w > 110 {
		w = 110
	}
	innerW := w - 4

	// Header
	fmt.Println()
	fmt.Println("  " + theme.Accent.Render("⚡ RAIJIN") + "   " +
		theme.Faint.Render(InformationalVersion()) + "   " +
		theme.Faint.Render("·") + "   " +
		theme.Mute.Render("virtual RV32IM RISC-V machine"))
	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", innerW)))

	// ARCHITECTURE section
	section("architecture", innerW)
	kvRow("ISA",        "RV32IM + Zicsr",    "hardware multiplier/divider")
	kvRow("pipeline",   "single-cycle",      "one instruction per clock")
	kvRow("CSR set",    "M-mode subset",     "+ mcycle/minstret free-running counters")
	kvRow("trap model", "synchronous only",  "ECALL · EBREAK · illegal · misalign")

	// MEMORY section
	section("memory map", innerW)
	memRow("instruction mem", "16 MB", "fetched by PC",          theme.ColAccent)
	memRow("data memory",     "16 MB", "load/store + heap/stack", lipgloss.Color("108"))
	memRow("UART TX",         "mmio",  "0x10000000",              lipgloss.Color("173"))
	memRow("UART RX",         "mmio",  "0x10000008 · status 0x1000000C", lipgloss.Color("173"))

	// PERF COUNTERS section
	section("performance counters", innerW)
	kvRow("mcycle / minstret", "64-bit", "free-running, increments every retired insn")
	kvRow("class counters",    "6 kinds", "mul · branch+taken · jump · load · store · trap")

	// RESET section
	section("reset semantics", innerW)
	kvRow("program counter", "0x00000000", "fetch resumes at the reset vector")
	kvRow("registers",       "x1..x31",    "zeroed in one clock via synchronous reset")
	kvRow("CSRs",            "all",        "mstatus, mepc, mtvec, mcause, mtval, mscratch → 0")
	kvRow("memory",          "reloaded",   "fresh image flashed on every Reset action")

	// QUICK START
	section("quick start", innerW)
	startRow("raijin",                   "interactive menu (pick a demo)")
	startRow("raijin run snake",         "run a demo by name")
	startRow("raijin run path/to.hex",   "run any $readmemh hex file")
	startRow("raijin demos",             "full catalog with controls")
	startRow("raijin bench donut -n 5",  "repeat and compare runs")
	startRow("raijin --help",            "full command reference")

	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", innerW)))
	fmt.Println()
}

// section prints "⚡ TITLE ─────…────" as a row header.
func section(title string, w int) {
	fmt.Println()
	label := "  " + theme.Accent.Render("⚡") + "  " + theme.Heading.Render(strings.ToUpper(title))
	tail  := w - lipgloss.Width(label) - 2
	if tail < 2 {
		tail = 2
	}
	fmt.Println(label + "   " + theme.Faint.Render(strings.Repeat("─", tail-1)))
}

// kvRow prints a three-column row: label | value | caption.
// Caption is Mute, not Faint — user needs to read it.
func kvRow(label, value, caption string) {
	fmt.Printf("    %s  %s  %s\n",
		lipgloss.NewStyle().Width(20).Render(theme.Label.Render(label)),
		lipgloss.NewStyle().Width(20).Render(theme.Value.Render(value)),
		theme.Mute.Render(caption))
}

// memRow renders a memory-map entry with a coloured tag chip.
func memRow(label, tag, detail string, chip lipgloss.Color) {
	tagBox := lipgloss.NewStyle().
		Foreground(theme.ColBg).
		Background(chip).
		Bold(true).
		Padding(0, 1).
		Render(tag)
	fmt.Printf("    %s  %s  %s\n",
		lipgloss.NewStyle().Width(20).Render(theme.Label.Render(label)),
		lipgloss.NewStyle().Width(12).Render(tagBox),
		theme.Value.Render(detail))
}

// startRow is "command   → caption".
func startRow(cmd, caption string) {
	fmt.Printf("    %s  %s  %s\n",
		lipgloss.NewStyle().Width(28).Render(theme.Heading.Render(cmd)),
		theme.Faint.Render("→"),
		theme.Mute.Render(caption))
}

func init() {
	root.AddCommand(infoCmd)
}
