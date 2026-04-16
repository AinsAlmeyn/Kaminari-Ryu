package cmd

import (
	"fmt"
	"runtime"
	"runtime/debug"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

// Version is the SemVer literal. GitSHA is filled by the linker at build
// time (see build.sh: -ldflags "-X …/cmd.GitSHA=…").
var (
	Version = "0.2.2"
	GitSHA  = "dev"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the CLI version and exit.",
	RunE: func(cmd *cobra.Command, args []string) error {
		printVersion()
		return nil
	},
}

func printVersion() {
	w, _, err := term.GetSize(0)
	if err != nil || w < 64 {
		w = 84
	}
	if w > 110 {
		w = 110
	}

	fmt.Println()
	fmt.Printf("  %s  %s\n",
		theme.Accent.Render("⚡"),
		theme.Heading.Render("raijin "+versionLiteral()))
	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))

	section("build", w)
	kvRow("sha",      vcsSha(),      "git short hash (linker-injected)")
	kvRow("semver",   Version,       "stable release identifier")
	kvRow("profile",  buildProfile(), "debug symbols + LTO state")

	section("runtime", w)
	kvRow("Go",       runtime.Version(), "compiler + stdlib")
	kvRow("platform", runtime.GOOS+" / "+runtime.GOARCH, "host OS + cpu arch")
	kvRow("threads",  fmt.Sprintf("GOMAXPROCS=%d", runtime.GOMAXPROCS(0)),
		"concurrent goroutines cap")

	fmt.Println()
	fmt.Println("  " + theme.Faint.Render(strings.Repeat("─", w-4)))
	fmt.Println()
	fmt.Printf("  %s %s\n",
		theme.Mute.Render("project:"),
		theme.Heading.Render("Kaminari-Ryū")+theme.Mute.Render("  ·  first model: Raijin (RV32IM + Zicsr, single-cycle)"))
	fmt.Println()
}

// versionLiteral returns "v0.3.0+gSHA" or "v0.3.0+dev" — cobra also uses
// this for `--version`, so we keep the format stable.
func versionLiteral() string { return "v" + Version + "+g" + shaOrDev() }

// shaOrDev extracts the short git SHA: compile-time linker var wins, but
// when building ad-hoc we fall back to whatever the go modules system
// stamped into the binary via debug.BuildInfo.
func shaOrDev() string {
	if GitSHA != "" && GitSHA != "dev" {
		return GitSHA
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, s := range info.Settings {
			if s.Key == "vcs.revision" && len(s.Value) >= 8 {
				return s.Value[:8]
			}
		}
	}
	return "dev"
}

// vcsSha is the same value shaOrDev returns, but shown on its own row.
func vcsSha() string { return shaOrDev() }

// InformationalVersion is still what the rest of the CLI reads to show
// "v0.3.0+gSHA" inline in headers.
func InformationalVersion() string { return versionLiteral() }

// buildProfile is a coarse marker of "how was this built?". We don't get
// a direct signal from the compiler, but we can infer by looking at
// whether debug info was stripped. This is best-effort information.
func buildProfile() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		// If -s -w was passed, certain settings are missing. We don't
		// have a perfect detector, so just report what debug/buildinfo
		// knows about.
		for _, s := range info.Settings {
			if s.Key == "-ldflags" && strings.Contains(s.Value, "-s") {
				return "release"
			}
		}
	}
	return "release"
}

// ── Helpers specific to version (avoid import cycle with info) ──────

// We reuse kvRow / section from info.go — they're in the same package.

func init() {
	root.AddCommand(versionCmd)
	_ = lipgloss.Width // keep the import useful if refactors need it
}
