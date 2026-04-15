package cmd

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/catalog"
	"github.com/AinsAlmeyn/raijin-cli/internal/runner"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"golang.org/x/term"
)

// runMenu drives the top-level interactive loop. Each iteration shows the
// selection screen; whatever the user picks drops us into that action,
// runs to completion, then loops back to the menu (unless they quit).
func runMenu() int {
	for {
		pick, err := showMenu()
		if err != nil || pick == nil || pick.kind == "quit" {
			return 0
		}
		switch pick.kind {
		case "import":
			menuImportProgram()
		case "compile":
			menuCompileProgram()
		case "remove":
			menuDeleteProgram()
		case "demos":
			clearScreen()
			PrintCatalog()
			waitEnter()
		case "info":
			clearScreen()
			printInfo()
			waitEnter()
		case "demo":
			hex := catalog.ResolveHex(pick.demo)
			if hex == "" {
				clearScreen()
				notBuiltScreen(pick.demo)
				waitEnter()
				continue
			}
			// runner owns the terminal for the whole run AND shows the
			// results screen in bubbletea; we come back here with the
			// main screen restored and the user already acknowledged
			// the summary. No extra prompt needed.
			runner.Run(runner.Options{
				HexPath: hex,
				Display: pick.demo.Name,
				InMenu:  true,
			})
		}
	}
}

func clearScreen() { fmt.Print("\x1b[2J\x1b[H") }

func notBuiltScreen(d *catalog.Entry) {
	fmt.Println()
	fmt.Println(theme.Card.Render(
		theme.Err.Render("  hex not built  ") + "\n\n" +
			"  " + theme.Label.Render("demo:      ") + theme.Heading.Render(d.Name) + "\n" +
			"  " + theme.Label.Render("expected:  ") + theme.Faint.Render(d.HexPath) + "\n" +
			"  " + theme.Label.Render("hint:      ") + theme.Mute.Render("use `raijin add file.hex` or reinstall the built-in payload") + "\n",
	))
	fmt.Println()
}

// ─────────────────────────────────────────────────────────────────────
// bubbletea model
// ─────────────────────────────────────────────────────────────────────

type menuPick struct {
	kind string
	demo *catalog.Entry
}

type menuItem struct {
	kind  string
	name  string
	tag   string // short tag shown next to name
	hint  string // long description for the preview pane
	ctrls string
	demo  *catalog.Entry
	ready bool
}

type menuModel struct {
	items  []menuItem
	cursor int
	choice *menuPick
	width  int
	height int
}

func initialMenu() menuModel {
	entries := catalog.All()
	builtins, customs := splitProgramEntries(entries)
	var items []menuItem
	appendEntry := func(d *catalog.Entry) {
		items = append(items, menuItem{
			kind:  "demo",
			name:  d.Name,
			tag:   d.Tag,
			hint:  d.Hint,
			ctrls: d.Controls,
			demo:  d,
			ready: catalog.IsBuilt(d),
		})
	}
	for i := range builtins {
		d := builtins[i]
		appendEntry(&d)
	}
	if len(customs) > 0 {
		items = append(items, menuItem{kind: "sep"})
		for i := range customs {
			d := customs[i]
			appendEntry(&d)
		}
	}
	// Separator is a "fake" item we skip over when navigating.
	items = append(items,
		menuItem{kind: "sep"},
		menuItem{kind: "import", name: "Import .hex / .elf", tag: "action",
			hint: "Copy a ready .hex into your personal library or convert an .elf into a runnable Raijin hex."},
		menuItem{kind: "compile", name: "Compile C / asm", tag: "action",
			hint: "Build a .c, .s, or .S file with the packaged Raijin runtime, then add it to your personal library."},
		menuItem{kind: "remove", name: "Delete personal program", tag: "action",
			hint: "Remove one of your custom programs and its metadata sidecar from the library."},
		menuItem{kind: "demos", name: "Browse catalog", tag: "action",
			hint: "Full table with build status for every demo. Good for checking what's compiled."},
		menuItem{kind: "info", name: "CPU info", tag: "action",
			hint: "Architecture card: ISA, memory map, MMIO, reset semantics, quick-start commands."},
		menuItem{kind: "quit", name: "Quit raijin", tag: "action",
			hint: "Leave the CLI. Same as pressing Esc or Ctrl+C on this screen."},
	)
	return menuModel{items: items, cursor: 0}
}

func (m menuModel) Init() tea.Cmd { return nil }

func (m menuModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "esc", "q":
			m.choice = &menuPick{kind: "quit"}
			return m, tea.Quit
		case "up", "k":
			m.cursor = m.prev()
		case "down", "j":
			m.cursor = m.next()
		case "home", "g":
			m.cursor = 0
		case "end", "G":
			m.cursor = len(m.items) - 1
			if m.items[m.cursor].kind == "sep" {
				m.cursor = m.prev()
			}
		case "enter":
			it := m.items[m.cursor]
			if it.kind == "sep" {
				break
			}
			m.choice = &menuPick{kind: it.kind, demo: it.demo}
			return m, tea.Quit
		}
	}
	return m, nil
}

func (m menuModel) prev() int {
	c := m.cursor
	for {
		c--
		if c < 0 {
			c = len(m.items) - 1
		}
		if m.items[c].kind != "sep" {
			return c
		}
	}
}
func (m menuModel) next() int {
	c := m.cursor
	for {
		c++
		if c >= len(m.items) {
			c = 0
		}
		if m.items[c].kind != "sep" {
			return c
		}
	}
}

// ─────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────

func (m menuModel) View() string {
	if m.choice != nil {
		return ""
	}
	w := m.width
	if w <= 0 {
		w = 84
	}
	contentW := maxInt(40, w-4)
	stacked := contentW < 92
	listW := contentW
	prevW := contentW
	if !stacked {
		listW = clampInt(contentW*2/5, 28, 38)
		prevW = maxInt(30, contentW-listW-2)
	}

	body := m.list(listW)
	if stacked {
		body = lipgloss.JoinVertical(lipgloss.Left,
			body,
			"",
			theme.Section("details", contentW),
			"",
			m.preview(prevW),
		)
	} else {
		body = lipgloss.JoinHorizontal(lipgloss.Top,
			body,
			"  ",
			m.preview(prevW),
		)
	}

	// The preview pane is the single source of truth for "what does this
	// item do?" — we intentionally do NOT repeat its text above the list.
	return lipgloss.JoinVertical(lipgloss.Left,
		"",
		header(w),
		"",
		theme.Section("programs", contentW),
		"",
		body,
		"",
		m.footer(contentW),
		"",
	)
}

func header(w int) string {
	left := theme.Accent.Render("  ⚡ RAIJIN") + "   " +
		theme.Faint.Render(InformationalVersion())
	right := theme.Mute.Render("RV32IM · single-cycle · 32 MB")
	pad := w - lipglossWidth(left) - lipglossWidth(right) - 4
	if pad < 4 {
		return left + "\n  " + right
	}
	return left + strings.Repeat(" ", pad) + right + "  "
}

func (m menuModel) list(w int) string {
	var b strings.Builder
	for i, it := range m.items {
		if it.kind == "sep" {
			rail := maxInt(8, w-8)
			b.WriteString("    " + theme.Faint.Render(strings.Repeat("·", rail)) + "\n")
			continue
		}
		sel := i == m.cursor
		var nameStyle lipgloss.Style
		var prefix    string
		if sel {
			nameStyle = theme.Heading
			prefix    = "  " + theme.Accent.Render("▸ ")
		} else {
			nameStyle = theme.Value
			prefix    = "    "
		}

		var status string
		switch {
		case it.kind != "demo":
			status = theme.Faint.Render("→")
		case it.ready:
			status = theme.Ok.Render("●")
		default:
			status = theme.Err.Render("○")
		}

		contentW := maxInt(12, w-6)
		line := prefix
		if it.kind == "demo" {
			tagCol := clampInt(contentW/3, 7, 10)
			nameCol := maxInt(8, contentW-tagCol-3)
			nameCell := lipgloss.NewStyle().Width(nameCol).Render(nameStyle.Render(truncatePlain(it.name, nameCol)))
			tagCell := lipgloss.NewStyle().Width(tagCol).Render(theme.Mute.Render(truncatePlain(it.tag, tagCol)))
			line += nameCell + tagCell + "  " + status
		} else {
			nameCol := maxInt(8, contentW-3)
			nameCell := lipgloss.NewStyle().Width(nameCol).Render(nameStyle.Render(truncatePlain(it.name, nameCol)))
			line += nameCell + "  " + status
		}
		b.WriteString(line + "\n")
	}
	return b.String()
}

func (m menuModel) preview(w int) string {
	it := m.items[m.cursor]
	var rows []string

	// Top line: name + status pill.
	var status string
	switch {
	case it.kind != "demo":
		status = theme.PillMute(" action ")
	case it.ready:
		status = theme.PillOk(" ready ")
	default:
		status = theme.PillErr(" not built ")
	}
	titleW := maxInt(12, w-lipglossWidth(status)-3)
	rows = append(rows, theme.Heading.Render(truncatePlain(titleCase(it.name), titleW))+"   "+status)
	rows = append(rows, theme.Faint.Render(strings.Repeat("─", maxInt(8, w-2))))
	rows = append(rows, "")

	// Description.
	if it.hint != "" {
		rows = append(rows, wrap(theme.Value.Render(it.hint), w-2))
		rows = append(rows, "")
	}

	// Controls.
	if it.kind == "demo" && it.ctrls != "" {
		rows = append(rows, theme.Label.Render("controls"))
		rows = append(rows, "  "+theme.Value.Render(it.ctrls))
		rows = append(rows, "")
	}

	// Stats for demos.
	if it.kind == "demo" && it.demo != nil {
		rows = append(rows, theme.Label.Render("built at"))
		built := catalog.ResolveHex(it.demo)
		if built == "" {
			rows = append(rows, "  "+theme.Err.Render(it.demo.HexPath+"  (missing)"))
		} else {
			rows = append(rows, "  "+theme.Faint.Render(shortPath(built, maxInt(10, w-4))))
		}
	}
	return theme.Thin.Render(strings.Join(rows, "\n"))
}

func (m menuModel) footer(w int) string {
	keys := []struct{ k, v string }{
		{"↑↓", "navigate"},
		{"enter", "launch"},
		{"esc", "quit"},
	}
	var parts []string
	for _, kv := range keys {
		parts = append(parts, theme.Kbd.Render(kv.k)+" "+theme.Mute.Render(kv.v))
	}
	return "  " + joinStyledParts(parts, maxInt(20, w-2))
}

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

func showMenu() (*menuPick, error) {
	p := tea.NewProgram(initialMenu(),
		tea.WithAltScreen(),
		tea.WithMouseCellMotion())
	m, err := p.Run()
	if err != nil {
		return nil, err
	}
	mm := m.(menuModel)
	if mm.choice == nil {
		return &menuPick{kind: "quit"}, nil
	}
	return mm.choice, nil
}

func waitEnter() {
	fmt.Println()
	fmt.Printf("  %s %s    %s %s\n",
		theme.Kbd.Render("enter"), theme.Mute.Render("return to menu"),
		theme.Kbd.Render("Ctrl+C"), theme.Mute.Render("quit raijin"))

	// Raw mode so Enter arrives as a single \r byte (no orphan \n left
	// over to poison the next bubbletea screen). Everything other than
	// Enter and Ctrl+C is swallowed — arrow keys and other escape
	// sequences must be ignored, since they start with 0x1b just like a
	// lone Esc and we can't cheaply distinguish the two in raw mode.
	fd := int(os.Stdin.Fd())
	oldState, err := term.MakeRaw(fd)
	if err != nil {
		// Non-TTY fallback: drain one line and return.
		var buf [1]byte
		for {
			n, _ := os.Stdin.Read(buf[:])
			if n == 0 || buf[0] == '\n' || buf[0] == '\r' {
				return
			}
		}
	}
	defer term.Restore(fd, oldState)

	buf := make([]byte, 16)
	for {
		n, err := os.Stdin.Read(buf)
		if err != nil || n == 0 {
			return
		}
		for i := 0; i < n; i++ {
			switch buf[i] {
			case 0x03: // Ctrl+C → quit the app cleanly
				term.Restore(fd, oldState)
				os.Exit(0)
			case '\r', '\n':
				return
			}
			// Any other byte (arrow keys' \x1b[A, function keys, printable
			// chars, etc.) is intentionally ignored. The user hasn't yet
			// chosen one of the two meaningful actions.
		}
	}
}

func lipglossWidth(s string) int {
	return lipgloss.Width(s)
}

func titleCase(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func shortPath(p string, max int) string {
	if len(p) <= max {
		return p
	}
	return "…" + p[len(p)-max+1:]
}

func truncatePlain(s string, max int) string {
	if max <= 1 {
		return "…"
	}
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return string(runes[:max-1]) + "…"
}

func joinStyledParts(parts []string, maxWidth int) string {
	if len(parts) == 0 {
		return ""
	}
	var lines []string
	cur := parts[0]
	for _, part := range parts[1:] {
		candidate := cur + "   " + part
		if len(stripAnsi(candidate)) > maxWidth {
			lines = append(lines, cur)
			cur = part
			continue
		}
		cur = candidate
	}
	lines = append(lines, cur)
	return strings.Join(lines, "\n  ")
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// wrap soft-wraps text at word boundaries to width w.
func wrap(s string, w int) string {
	if w <= 0 {
		return s
	}
	words := strings.Fields(s)
	var lines []string
	var cur string
	for _, word := range words {
		if cur == "" {
			cur = word
			continue
		}
		if len(stripAnsi(cur))+1+len(stripAnsi(word)) > w {
			lines = append(lines, cur)
			cur = word
		} else {
			cur += " " + word
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	return strings.Join(lines, "\n")
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

func menuImportProgram() {
	clearScreen()
	printMenuActionHeader("import program", "Add a ready .hex or .elf into your personal library.")
	input, ok := promptMenuLine("file path", "blank cancels")
	if !ok {
		return
	}
	input = filepath.Clean(input)
	if !isImportableBinary(input) {
		showMenuError("import expects a .hex or .elf file; use \"Compile C / asm\" for source files.")
		return
	}
	name, _ := promptMenuLine("program name", "blank = derive from file name")
	result, err := addProgramFromInput(input, addProgramOptions{
		Name:  name,
		Tag:   catalog.KindCustom,
		Depth: 8192,
	})
	if err != nil {
		showMenuError(err.Error())
		return
	}

	clearScreen()
	printMenuActionHeader("program imported", "Your custom entry is now part of the menu and demos catalog.")
	printMenuBullet("name", result.Name)
	printMenuBullet("hex", result.HexPath)
	printMenuBullet("run", "raijin run "+result.Name)
	waitEnter()
}

func menuCompileProgram() {
	clearScreen()
	printMenuActionHeader("compile source", "Build a .c, .s, or .S file and register it as a personal program.")
	input, ok := promptMenuLine("source path", "blank cancels")
	if !ok {
		return
	}
	input = filepath.Clean(input)
	if !isCompilableSource(input) {
		showMenuError("compile expects a .c, .s, or .S file.")
		return
	}
	name, _ := promptMenuLine("program name", "blank = derive from file name")
	march, _ := promptMenuLine("march", "blank = rv32i_zicsr")
	result, err := addProgramFromInput(input, addProgramOptions{
		Name:  name,
		Tag:   catalog.KindCustom,
		March: firstNonEmpty(strings.TrimSpace(march), "rv32i_zicsr"),
		Depth: 8192,
	})
	if err != nil {
		showMenuError(err.Error())
		return
	}

	clearScreen()
	printMenuActionHeader("program compiled", "The source was compiled into hex and added to your personal library.")
	printMenuBullet("name", result.Name)
	printMenuBullet("hex", result.HexPath)
	printMenuBullet("run", "raijin run "+result.Name)
	waitEnter()
}

func menuDeleteProgram() {
	clearScreen()
	customs := customEntries()
	if len(customs) == 0 {
		printMenuActionHeader("delete personal program", "There are no custom programs to remove yet.")
		waitEnter()
		return
	}

	printMenuActionHeader("delete personal program", "Choose one of your custom entries by number or by name.")
	for i, entry := range customs {
		hexPath := entry.HexPath
		if resolved := catalog.ResolveHex(&entry); resolved != "" {
			hexPath = resolved
		}
		fmt.Printf("  %s  %s  %s\n",
			theme.Label.Render(fmt.Sprintf("%2d.", i+1)),
			theme.Heading.Render(entry.Name),
			theme.Mute.Render(shortPath(hexPath, 56)))
	}
	fmt.Println()
	selection, ok := promptMenuLine("program", "number or name; blank cancels")
	if !ok {
		return
	}
	target, err := resolveCustomSelection(selection, customs)
	if err != nil {
		showMenuError(err.Error())
		return
	}
	confirm, _ := promptMenuLine("confirm", "type y to delete")
	if !strings.EqualFold(strings.TrimSpace(confirm), "y") {
		clearScreen()
		printMenuActionHeader("delete cancelled", "No files were removed.")
		waitEnter()
		return
	}
	removedPath, err := removeProgramByName(target.Name)
	if err != nil {
		showMenuError(err.Error())
		return
	}

	clearScreen()
	printMenuActionHeader("program deleted", "The custom entry and its metadata sidecar were removed.")
	printMenuBullet("name", target.Name)
	printMenuBullet("hex", removedPath)
	waitEnter()
}

func printMenuActionHeader(title, subtitle string) {
	fmt.Println()
	fmt.Println("  " + theme.Accent.Render("⚡") + "  " + theme.Heading.Render(strings.ToUpper(title)))
	if strings.TrimSpace(subtitle) != "" {
		fmt.Println("  " + theme.Mute.Render(subtitle))
	}
	fmt.Println()
}

func printMenuBullet(label, value string) {
	fmt.Println("  " + theme.Faint.Render("→ ") + theme.Label.Render(label+":") + " " + theme.Value.Render(value))
}

func promptMenuLine(label, hint string) (string, bool) {
	if strings.TrimSpace(hint) != "" {
		fmt.Println("  " + theme.Label.Render(label) + "  " + theme.Mute.Render("("+hint+")"))
	} else {
		fmt.Println("  " + theme.Label.Render(label))
	}
	reader := bufio.NewReader(os.Stdin)
	fmt.Print("    > ")
	line, err := reader.ReadString('\n')
	if err != nil && len(line) == 0 {
		return "", false
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return "", false
	}
	return line, true
}

func showMenuError(message string) {
	clearScreen()
	printMenuActionHeader("program management error", "The requested action could not be completed.")
	fmt.Println("  " + theme.Err.Render(message))
	fmt.Println()
	waitEnter()
}

func customEntries() []catalog.Entry {
	_, customs := splitProgramEntries(catalog.All())
	return customs
}

func resolveCustomSelection(selection string, customs []catalog.Entry) (*catalog.Entry, error) {
	selection = strings.TrimSpace(selection)
	if index, err := strconv.Atoi(selection); err == nil {
		if index < 1 || index > len(customs) {
			return nil, fmt.Errorf("selection %d is out of range", index)
		}
		entry := customs[index-1]
		return &entry, nil
	}
	for i := range customs {
		if strings.EqualFold(customs[i].Name, selection) {
			entry := customs[i]
			return &entry, nil
		}
	}
	return nil, fmt.Errorf("no custom program matched %q", selection)
}
