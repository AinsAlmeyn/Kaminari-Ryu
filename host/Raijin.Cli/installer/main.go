// Command raijin-setup is the single-file Windows installer for the Raijin
// CLI. It carries the entire CLI bundle (raijin.exe, raijin.dll, demo .hex
// programs, compile SDK) embedded inside itself, so a fresh user only has
// to download one .exe, double-click, and walk through the on-screen flow.
//
// The TUI matches the rest of the CLI's Bubbletea look (amber accents,
// section dividers, faint glyphs). For CI smoke tests and scripted use the
// `--silent` flag skips the menus and just performs the install.
package main

import (
	"archive/zip"
	"bytes"
	_ "embed"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/AinsAlmeyn/raijin-cli/internal/pathing"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
)

// payloadZip is the bundled raijin-cli-windows-x64.zip, baked in at build
// time. build.sh writes the freshly-produced zip into installer/payload.zip
// right before `go build ./installer` runs. A small placeholder is checked
// in so plain `go build ./...` still succeeds in fresh clones; the runtime
// validity check below catches that case with a clear error instead of a
// confusing extract failure.
//
//go:embed payload.zip
var payloadZip []byte

// Version is set at build time via -ldflags "-X main.Version=..." to match
// the CLI's own version string. Not load-bearing; just shown in the header.
var (
	Version = "dev"
	GitSHA  = "dev"
)

func main() {
	var (
		silent      bool
		noPath      bool
		showVersion bool
	)
	flag.BoolVar(&silent, "silent", false, "skip the interactive UI; install with defaults and exit")
	flag.BoolVar(&noPath, "no-path", false, "do not modify the user PATH")
	flag.BoolVar(&showVersion, "version", false, "print the installer version and exit")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(),
			"raijin-setup  installs the Raijin CLI into %%USERPROFILE%%\\.raijin\n\n"+
				"usage: raijin-setup [--silent] [--no-path] [--version]\n\n"+
				"flags:\n")
		flag.PrintDefaults()
	}
	flag.Parse()

	if showVersion {
		fmt.Printf("raijin-setup v%s+g%s\n", Version, GitSHA)
		return
	}

	if !payloadIsValid() {
		fmt.Fprintln(os.Stderr,
			"error: this installer was built without a real payload.\n"+
				"       (installer/payload.zip is the placeholder, not the real bundle.)\n"+
				"       Run host/Raijin.Cli/build.sh from the repo to produce a real installer.")
		os.Exit(2)
	}

	if silent {
		runSilent(!noPath)
		return
	}
	runInteractive(!noPath)
}

// payloadIsValid sniffs the embedded payload to make sure it's a real zip
// rather than the committed placeholder. The placeholder is a tiny text
// file, real zips start with PK\x03\x04 and are always at least a few KB.
func payloadIsValid() bool {
	if len(payloadZip) < 1024 {
		return false
	}
	return bytes.HasPrefix(payloadZip, []byte("PK\x03\x04"))
}

// ----------------------------------------------------------------------------
// Install plan: what we copy and where.
// ----------------------------------------------------------------------------

type installPlan struct {
	rootDir string
	binDir  string
	progDir string
	sdkDir  string
}

func buildPlan() (installPlan, error) {
	root, binDir, progDir, err := pathing.UserInstallDirs()
	if err != nil {
		return installPlan{}, fmt.Errorf("locate home dir: %w", err)
	}
	return installPlan{
		rootDir: root,
		binDir:  binDir,
		progDir: progDir,
		sdkDir:  filepath.Join(root, "sdk"),
	}, nil
}

// installResult captures everything the done-screen and silent-mode
// epilogue need to print. We keep it small and value-typed so it can ride
// across a tea.Msg without footguns.
type installResult struct {
	plan         installPlan
	copiedFiles  []string // entries written to bin/, programs/, sdk/
	skippedFiles []string // already-present-and-identical entries (rare; first install: zero)
	pathAdded    bool     // true when we actually wrote to user PATH this run
	pathAlready  bool     // true when binDir was already on PATH (no write needed)
	pathSkipped  bool     // true when --no-path was set
}

// performInstall does the real work: extract embedded zip into ~/.raijin,
// then optionally update the user PATH. Reused by both the silent path and
// the bubbletea command. Idempotent: running twice over an existing install
// just overwrites the same files.
func performInstall(plan installPlan, addToPath bool) (installResult, error) {
	res := installResult{plan: plan}

	for _, d := range []string{plan.rootDir, plan.binDir, plan.progDir, plan.sdkDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return res, fmt.Errorf("mkdir %s: %w", d, err)
		}
	}

	zr, err := zip.NewReader(bytes.NewReader(payloadZip), int64(len(payloadZip)))
	if err != nil {
		return res, fmt.Errorf("open embedded payload: %w", err)
	}

	for _, f := range zr.File {
		// Defense in depth against zip-slip: reject anything that escapes
		// the install root after cleaning. The bundle we ship has flat
		// paths so this is purely a safety net.
		dst := filepath.Join(plan.rootDir, filepath.FromSlash(f.Name))
		if !strings.HasPrefix(dst, filepath.Clean(plan.rootDir)+string(os.PathSeparator)) &&
			dst != filepath.Clean(plan.rootDir) {
			return res, fmt.Errorf("zip entry escapes install root: %s", f.Name)
		}

		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(dst, 0o755); err != nil {
				return res, fmt.Errorf("mkdir %s: %w", dst, err)
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return res, fmt.Errorf("mkdir parent of %s: %w", dst, err)
		}

		// We rewrite top-level raijin.exe/raijin.dll into bin/, since the
		// zip stores them at its root for the portable use case. Anything
		// already nested (programs/, sdk/) lands where it lives in the zip.
		dst = relocateForInstall(plan, f.Name)

		if err := writeZipEntry(f, dst); err != nil {
			return res, err
		}
		res.copiedFiles = append(res.copiedFiles, dst)
	}

	if !addToPath {
		res.pathSkipped = true
		return res, nil
	}

	hasIt, err := pathing.UserPathContainsDir(plan.binDir)
	if err != nil {
		// PATH inspection failed (PowerShell missing? unusual). Don't fail
		// the whole install over it; the user can paste the one-liner the
		// regular `raijin install` command prints.
		res.pathAdded = false
		return res, nil
	}
	if hasIt {
		res.pathAlready = true
		return res, nil
	}
	changed, err := pathing.UpdateUserPathDir(plan.binDir, pathing.ModeAdd)
	if err != nil {
		return res, fmt.Errorf("update user PATH: %w", err)
	}
	res.pathAdded = changed
	return res, nil
}

// relocateForInstall maps a zip entry name onto its on-disk install path.
// The zip stores raijin.exe / raijin.dll / README.txt at the top level so
// that extracting the zip alone is a working portable bundle. For the
// installed copy we want raijin.exe and raijin.dll under bin/ specifically.
func relocateForInstall(plan installPlan, zipName string) string {
	clean := filepath.FromSlash(zipName)
	switch clean {
	case "raijin.exe", "raijin.dll":
		return filepath.Join(plan.binDir, clean)
	case "README.txt":
		return filepath.Join(plan.rootDir, clean)
	}
	// programs/foo.hex, sdk/c-runtime/..., etc. land relative to root.
	return filepath.Join(plan.rootDir, clean)
}

func writeZipEntry(f *zip.File, dst string) error {
	rc, err := f.Open()
	if err != nil {
		return fmt.Errorf("open %s in zip: %w", f.Name, err)
	}
	defer rc.Close()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return fmt.Errorf("create %s: %w", dst, err)
	}
	if _, err := io.Copy(out, rc); err != nil {
		out.Close()
		return fmt.Errorf("write %s: %w", dst, err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("close %s: %w", dst, err)
	}
	return nil
}

// ----------------------------------------------------------------------------
// Silent mode: scripted install for CI smoke tests and power users.
// ----------------------------------------------------------------------------

func runSilent(addToPath bool) {
	plan, err := buildPlan()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	res, err := performInstall(plan, addToPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	fmt.Println("raijin installed:")
	fmt.Println("  bin     ", plan.binDir)
	fmt.Println("  programs", plan.progDir)
	fmt.Println("  sdk     ", plan.sdkDir)
	fmt.Printf("  files   %d entries\n", len(res.copiedFiles))
	switch {
	case res.pathSkipped:
		fmt.Println("  PATH    not modified (--no-path)")
	case res.pathAdded:
		fmt.Println("  PATH    added", plan.binDir)
	case res.pathAlready:
		fmt.Println("  PATH    already contained", plan.binDir)
	default:
		fmt.Println("  PATH    inspection failed; bin not added")
	}
}

// ----------------------------------------------------------------------------
// Interactive Bubbletea TUI.
// ----------------------------------------------------------------------------

type screen int

const (
	screenWelcome screen = iota
	screenInstalling
	screenDone
	screenError
	screenCanceled
)

type model struct {
	screen    screen
	selected  int // 0 = install, 1 = cancel
	plan      installPlan
	result    installResult
	err       error
	width     int
	addToPath bool
}

type installFinishedMsg struct {
	result installResult
	err    error
}

func (m model) Init() tea.Cmd { return nil }

func (m model) installCmd() tea.Cmd {
	plan := m.plan
	addToPath := m.addToPath
	return func() tea.Msg {
		res, err := performInstall(plan, addToPath)
		return installFinishedMsg{result: res, err: err}
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil
	case installFinishedMsg:
		if msg.err != nil {
			m.err = msg.err
			m.screen = screenError
		} else {
			m.result = msg.result
			m.screen = screenDone
		}
		return m, nil
	case tea.KeyMsg:
		switch m.screen {
		case screenWelcome:
			switch msg.String() {
			case "ctrl+c", "esc", "q":
				m.screen = screenCanceled
				return m, tea.Quit
			case "up", "k":
				if m.selected > 0 {
					m.selected--
				}
			case "down", "j":
				if m.selected < 1 {
					m.selected++
				}
			case "enter":
				if m.selected == 0 {
					m.screen = screenInstalling
					return m, m.installCmd()
				}
				m.screen = screenCanceled
				return m, tea.Quit
			}
		case screenDone, screenError, screenCanceled:
			switch msg.String() {
			case "enter", "esc", "q", "ctrl+c":
				return m, tea.Quit
			}
		case screenInstalling:
			// Install runs in a tea.Cmd goroutine. Ignore key input until done.
		}
	}
	return m, nil
}

func (m model) View() string {
	switch m.screen {
	case screenWelcome:
		return welcomeView(m)
	case screenInstalling:
		return installingView(m)
	case screenDone:
		return doneView(m)
	case screenError:
		return errorView(m)
	case screenCanceled:
		return canceledView(m)
	}
	return ""
}

// Width target for the divider rules. Stays put at 64 even on big terminals
// so the layout matches the rest of the CLI's blocks.
const ruleWidth = 64

func ruler() string {
	return theme.Faint.Render(strings.Repeat("─", ruleWidth))
}

func brandHeader() string {
	left := "  " + theme.Accent.Render("⚡") + "  " +
		theme.Heading.Render("RAIJIN INSTALLER") + "   " +
		theme.Faint.Render("v"+Version+"+g"+GitSHA)
	return left
}

func arrowRow(target string, caption string) string {
	row := "    " + theme.Faint.Render("→  ") + theme.Value.Render(target)
	if caption != "" {
		row += "   " + theme.Mute.Render(caption)
	}
	return row
}

func welcomeView(m model) string {
	tildeBin := tildeify(m.plan.binDir)
	tildeProg := tildeify(m.plan.progDir)
	tildeSdk := tildeify(m.plan.sdkDir)

	var b strings.Builder
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, brandHeader())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+ruler())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Value.Render("This will install Raijin into your home directory and"))
	fmt.Fprintln(&b, "  "+theme.Value.Render("add it to your PATH so you can run ")+
		theme.Heading.Render("raijin")+
		theme.Value.Render(" from any terminal."))
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Label.Render("install target"))
	fmt.Fprintln(&b, arrowRow(filepath.Join(tildeBin, "raijin.exe"), "the CLI"))
	fmt.Fprintln(&b, arrowRow(filepath.Join(tildeBin, "raijin.dll"), "verilated RV32IM core"))
	fmt.Fprintln(&b, arrowRow(tildeProg, "demo programs (matrix, snake, donut, doom)"))
	fmt.Fprintln(&b, arrowRow(tildeSdk, "compile-your-own toolkit (c-runtime + elf2hex)"))
	fmt.Fprintln(&b)
	pathNote := tildeBin + " will be added to your user PATH"
	if !m.addToPath {
		pathNote = "PATH will not be modified (--no-path)"
	}
	fmt.Fprintln(&b, "  "+theme.Label.Render("user PATH"))
	fmt.Fprintln(&b, "    "+theme.Faint.Render("→  ")+theme.Value.Render(pathNote))
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+ruler())
	fmt.Fprintln(&b)

	options := []string{"install", "cancel"}
	for i, opt := range options {
		if i == m.selected {
			fmt.Fprintln(&b, "  "+theme.Accent.Render("▸ ")+theme.Heading.Render(opt))
		} else {
			fmt.Fprintln(&b, "    "+theme.Value.Render(opt))
		}
	}
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+keysFooter([][2]string{
		{"↑↓", "navigate"},
		{"enter", "confirm"},
		{"esc", "quit"},
	}))
	fmt.Fprintln(&b)
	return b.String()
}

func installingView(m model) string {
	var b strings.Builder
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, brandHeader())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+ruler())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Accent.Render("⚡")+"  "+theme.Heading.Render("installing…"))
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "    "+theme.Mute.Render("extracting bundle into "+tildeify(m.plan.rootDir)))
	fmt.Fprintln(&b)
	return b.String()
}

func doneView(m model) string {
	var b strings.Builder
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, brandHeader())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+ruler())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Ok.Render("✓")+"  "+theme.Heading.Render("installed"))
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, arrowRow(filepath.Join(m.plan.binDir, "raijin.exe"), ""))
	fmt.Fprintln(&b, arrowRow(filepath.Join(m.plan.binDir, "raijin.dll"), ""))
	fmt.Fprintln(&b, arrowRow(m.plan.progDir, "demo programs"))
	fmt.Fprintln(&b, arrowRow(m.plan.sdkDir, "compile toolkit"))
	fmt.Fprintln(&b)
	switch {
	case m.result.pathSkipped:
		fmt.Fprintln(&b, "  "+theme.Mute.Render("user PATH was left unchanged (--no-path)"))
		fmt.Fprintln(&b, "  "+theme.Mute.Render("to use ")+theme.Heading.Render("raijin")+
			theme.Mute.Render(" from any terminal, add ")+
			theme.Value.Render(m.plan.binDir)+theme.Mute.Render(" to your user PATH."))
	case m.result.pathAdded:
		fmt.Fprintln(&b, "  "+theme.Ok.Render("✓")+"  "+
			theme.Value.Render(m.plan.binDir)+"  "+
			theme.Mute.Render("added to your user PATH"))
	case m.result.pathAlready:
		fmt.Fprintln(&b, "  "+theme.Ok.Render("✓")+"  "+
			theme.Value.Render(m.plan.binDir)+"  "+
			theme.Mute.Render("was already on your user PATH"))
	default:
		fmt.Fprintln(&b, "  "+theme.Warn.Render("!")+"  "+
			theme.Mute.Render("could not inspect or update the user PATH; add ")+
			theme.Value.Render(m.plan.binDir)+theme.Mute.Render(" yourself if needed"))
	}
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Mute.Render("open a fresh terminal, then type:"))
	fmt.Fprintln(&b, "    "+theme.Heading.Render("raijin"))
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Faint.Render("you can delete this installer now."))
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+keysFooter([][2]string{{"enter", "exit"}}))
	fmt.Fprintln(&b)
	return b.String()
}

func errorView(m model) string {
	var b strings.Builder
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, brandHeader())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+ruler())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Err.Render("✗")+"  "+theme.Heading.Render("install failed"))
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Mute.Render(m.err.Error()))
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+keysFooter([][2]string{{"enter", "exit"}}))
	fmt.Fprintln(&b)
	return b.String()
}

func canceledView(m model) string {
	var b strings.Builder
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, brandHeader())
	fmt.Fprintln(&b)
	fmt.Fprintln(&b, "  "+theme.Mute.Render("install canceled. nothing was changed."))
	fmt.Fprintln(&b)
	return b.String()
}

func keysFooter(pairs [][2]string) string {
	var parts []string
	for _, p := range pairs {
		parts = append(parts,
			theme.Kbd.Render(" "+p[0]+" ")+" "+theme.Mute.Render(p[1]))
	}
	return strings.Join(parts, "   ")
}

// tildeify rewrites %USERPROFILE%\X to ~\X for shorter display.
func tildeify(p string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return p
	}
	rel, err := filepath.Rel(home, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		return p
	}
	return filepath.Join("~", rel)
}

func runInteractive(addToPath bool) {
	plan, err := buildPlan()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	m := model{
		screen:    screenWelcome,
		selected:  0,
		plan:      plan,
		addToPath: addToPath,
	}
	prog := tea.NewProgram(m)
	finalModel, err := prog.Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	// On Windows, double-clicking the .exe opens a console that closes the
	// instant the process exits. Wait for an Enter key so the user actually
	// sees the result. Skip if the program canceled because Bubbletea has
	// already restored the terminal and the user clearly chose to leave.
	if fm, ok := finalModel.(model); ok && fm.screen != screenCanceled {
		fmt.Println()
		fmt.Print("  press enter to close this window… ")
		var buf [1]byte
		_, _ = os.Stdin.Read(buf[:])
	}
}
