// Package catalog holds Raijin's built-in program catalog plus the user's
// personal program library. Built-ins are versioned in the repo and can
// also be bundled next to the CLI binary for portable installs.
package catalog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

const (
	KindBuiltIn = "builtin"
	KindCustom  = "custom"
)

type Entry struct {
	Name        string // short identifier used on the command line
	Description string // one-liner for the menu and `demos`
	HexPath     string // relative to the repo root
	Tag         string // visual/game/legendary (used for the catalog table)
	Controls    string // human-readable control scheme
	Hint        string // longer description shown at menu hover / run intro
	Kind        string // builtin/custom
}

type UserMetadata struct {
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
	Controls    string `json:"controls,omitempty"`
	Hint        string `json:"hint,omitempty"`
	Tag         string `json:"tag,omitempty"`
	SourcePath  string `json:"sourcePath,omitempty"`
	SourceKind  string `json:"sourceKind,omitempty"`
	ImportedAt  string `json:"importedAt,omitempty"`
}

// builtins is the canonical built-in catalog. Order matters — this is what
// the menu and the `demos` table render top-to-bottom.
var builtins = []Entry{
	{"snake", "Snake game", "raijin/programs/snake.hex", "game",
		"WASD to steer, R to restart",
		"Classic snake on an 80×40 grid. Leans on branches and loads.", KindBuiltIn},
	{"matrix", "Matrix rain effect", "raijin/programs/matrix.hex", "visual",
		"no input — just watch",
		"Falling glyphs with ANSI dim trail. Sustained UART throughput.", KindBuiltIn},
	{"donut", "Spinning ASCII donut", "raijin/programs/donut.hex", "visual",
		"no input — just watch",
		"Andy Sloane's integer donut. Q12 fixed-point sin/cos with 3D projection.", KindBuiltIn},
	{"doom", "DOOM (id Software, 1993)", "raijin/programs/doom/doom.hex", "legendary",
		"WASD to move, Q to fire, SPACE to use, ENTER for menu",
		"Actual DOOM shareware running on Raijin. 160×100 halfblock render.", KindBuiltIn},
}

// Builtins returns the canonical built-in catalog.
func Builtins() []Entry {
	out := make([]Entry, len(builtins))
	copy(out, builtins)
	return out
}

// All returns built-ins plus any user programs discovered from the personal
// library directories.
func All() []Entry {
	out := Builtins()
	out = append(out, discoverUserPrograms()...)
	return out
}

// Find returns the catalog entry for a short name (case-insensitive) or
// nil if no match.
func Find(name string) *Entry {
	all := All()
	for i := range all {
		if equalFold(all[i].Name, name) {
			e := all[i]
			return &e
		}
	}
	return nil
}

// ResolveHex locates the entry's hex file, searching (in order):
//   1. direct/absolute entry path
//   2. packaged programs next to the CLI binary
//   3. RAIJIN_HOME override, if set
//   4. the per-user install under %USERPROFILE%\.raijin\programs\
//   5. repo layout walked up from the exe / CWD
// Returns "" if none hit.
func ResolveHex(e *Entry) string {
	if e == nil {
		return ""
	}
	if filepath.IsAbs(e.HexPath) {
		if p := firstExists(e.HexPath); p != "" {
			return p
		}
	}

	base := filepath.Base(e.HexPath)
	if exe, err := os.Executable(); err == nil {
		if p := firstExists(filepath.Join(filepath.Dir(exe), "programs", base)); p != "" {
			return p
		}
	}

	if root := os.Getenv("RAIJIN_HOME"); root != "" {
		if p := firstExists(
			filepath.Join(root, "programs", base),
			filepath.Join(root, e.HexPath),
		); p != "" {
			return p
		}
	}

	if home, err := os.UserHomeDir(); err == nil {
		if p := firstExists(filepath.Join(home, ".raijin", "programs", base)); p != "" {
			return p
		}
	}

	// Repo-relative: walk up from exe.
	exe, _ := os.Executable()
	here := filepath.Dir(exe)
	for i := 0; i < 8 && here != ""; i++ {
		if p := firstExists(filepath.Join(here, e.HexPath)); p != "" {
			return p
		}
		parent := filepath.Dir(here)
		if parent == here {
			break
		}
		here = parent
	}

	// Repo-relative: from CWD.
	if wd, err := os.Getwd(); err == nil {
		if p := firstExists(filepath.Join(wd, e.HexPath)); p != "" {
			return p
		}
	}
	return ""
}

// UserProgramDirs returns the directories from which custom programs are
// discovered. First entry wins when duplicate names exist.
func UserProgramDirs() []string {
	seen := map[string]struct{}{}
	var dirs []string
	add := func(path string) {
		if path == "" {
			return
		}
		clean := filepath.Clean(path)
		if _, ok := seen[clean]; ok {
			return
		}
		seen[clean] = struct{}{}
		dirs = append(dirs, clean)
	}

	if exe, err := os.Executable(); err == nil {
		add(filepath.Join(filepath.Dir(exe), "programs"))
	}
	if root := os.Getenv("RAIJIN_HOME"); root != "" {
		add(filepath.Join(root, "programs"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		add(filepath.Join(home, ".raijin", "programs"))
	}
	return dirs
}

func discoverUserPrograms() []Entry {
	reserved := map[string]struct{}{}
	for _, entry := range builtins {
		reserved[lower(entry.Name)] = struct{}{}
	}

	seen := map[string]struct{}{}
	var out []Entry
	for _, dir := range UserProgramDirs() {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, item := range entries {
			if item.IsDir() || filepath.Ext(item.Name()) != ".hex" {
				continue
		}
			hexPath := filepath.Join(dir, item.Name())
			base := item.Name()[:len(item.Name())-len(filepath.Ext(item.Name()))]
			key := lower(base)
			if _, ok := reserved[key]; ok {
				continue
			}

			entry := Entry{
				Name:        base,
				Description: "User program",
				HexPath:     hexPath,
				Tag:         KindCustom,
				Controls:    "depends on the imported program",
				Hint:        "Imported into your personal Raijin program library.",
				Kind:        KindCustom,
			}
			applyMetadata(&entry, readMetadata(hexPath))
			key = lower(entry.Name)
			if _, ok := reserved[key]; ok {
				continue
			}
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			out = append(out, entry)
		}
	}

	sort.Slice(out, func(i, j int) bool {
		return lower(out[i].Name) < lower(out[j].Name)
	})
	return out
}

func readMetadata(hexPath string) *UserMetadata {
	metaPath := hexPath[:len(hexPath)-len(filepath.Ext(hexPath))] + ".json"
	data, err := os.ReadFile(metaPath)
	if err != nil {
		return nil
	}
	var meta UserMetadata
	if err := json.Unmarshal(data, &meta); err != nil {
		return nil
	}
	return &meta
}

func applyMetadata(entry *Entry, meta *UserMetadata) {
	if entry == nil || meta == nil {
		return
	}
	if meta.Name != "" {
		entry.Name = meta.Name
	}
	if meta.Description != "" {
		entry.Description = meta.Description
	}
	if meta.Controls != "" {
		entry.Controls = meta.Controls
	}
	if meta.Hint != "" {
		entry.Hint = meta.Hint
	}
	if meta.Tag != "" {
		entry.Tag = meta.Tag
	}
}

func firstExists(paths ...string) string {
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// IsBuilt reports whether the hex file for this entry exists right now.
func IsBuilt(e *Entry) bool { return ResolveHex(e) != "" }

func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// equalFold = case-insensitive compare without pulling in strings.EqualFold.
func equalFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 32
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 32
		}
		if ca != cb {
			return false
		}
	}
	return true
}
