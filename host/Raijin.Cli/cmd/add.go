package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/AinsAlmeyn/raijin-cli/internal/catalog"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"
	"github.com/spf13/cobra"
)

var (
	addName        string
	addDescription string
	addControls    string
	addHint        string
	addTag         string
	addMarch       string
	addDepth       int
	addIncludes    []string
	addForce       bool
)

type addProgramOptions struct {
	Name        string
	Description string
	Controls    string
	Hint        string
	Tag         string
	March       string
	Depth       int
	Includes    []string
	Force       bool
}

type addProgramResult struct {
	Name    string
	HexPath string
}

var addCmd = &cobra.Command{
	Use:   "add <file>",
	Short: "Import a .hex or compile a source file into your personal program library.",
	Long: `Add copies a program into your personal Raijin library so it appears in
the menu and in ` + "`raijin demos`" + `.

Accepted inputs:
  - .hex  : copied as-is
  - .elf  : converted to .hex
  - .c/.s/.S : compiled against the packaged Raijin runtime, then converted

Imported programs are stored under %USERPROFILE%\.raijin\programs\ with a
sidecar .json metadata file for display name, hint, and controls.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		result, err := addProgramFromInput(args[0], addProgramOptions{
			Name:        addName,
			Description: addDescription,
			Controls:    addControls,
			Hint:        addHint,
			Tag:         addTag,
			March:       addMarch,
			Depth:       addDepth,
			Includes:    addIncludes,
			Force:       addForce,
		})
		if err != nil {
			return err
		}

		fmt.Println()
		fmt.Println("  " + theme.Accent.Render("✓") + "  " + theme.Heading.Render("program added"))
		fmt.Println()
		fmt.Println("    " + theme.Faint.Render("→ ") + theme.Value.Render(result.HexPath))
		fmt.Println("    " + theme.Faint.Render("→ ") + theme.Mute.Render("run it with  ") + theme.Heading.Render("raijin run "+result.Name))
		fmt.Println()
		return nil
	},
}

func addProgramFromInput(inputPath string, opts addProgramOptions) (addProgramResult, error) {
	input, err := filepath.Abs(inputPath)
	if err != nil {
		return addProgramResult{}, err
	}
	if _, err := os.Stat(input); err != nil {
		return addProgramResult{}, err
	}

	name := sanitizedProgramName(opts.Name)
	if name == "" {
		name = sanitizedProgramName(strings.TrimSuffix(filepath.Base(input), filepath.Ext(input)))
	}
	if name == "" {
		return addProgramResult{}, fmt.Errorf("could not derive a valid program name from %s", input)
	}

	if existing := catalog.Find(name); existing != nil {
		if existing.Kind == catalog.KindBuiltIn {
			return addProgramResult{}, fmt.Errorf("%q is reserved by a built-in program; choose --name", name)
		}
		if !opts.Force {
			return addProgramResult{}, fmt.Errorf("%q already exists in your program library; re-run with --force to replace it", name)
		}
	}

	progDir, err := activeProgramDir()
	if err != nil {
		return addProgramResult{}, err
	}
	if err := os.MkdirAll(progDir, 0o755); err != nil {
		return addProgramResult{}, err
	}

	dstHex := filepath.Join(progDir, name+".hex")
	switch strings.ToLower(filepath.Ext(input)) {
	case ".hex":
		if !absSameFile(input, dstHex) {
			if err := copyFile(input, dstHex); err != nil {
				return addProgramResult{}, err
			}
		}
	case ".elf":
		if err := convertElfToHex(input, dstHex, opts.Depth); err != nil {
			return addProgramResult{}, err
		}
	case ".c", ".s", ".S":
		march := firstNonEmpty(strings.TrimSpace(opts.March), "rv32i_zicsr")
		if err := compileSourceToHex(input, dstHex, march, opts.Depth, opts.Includes); err != nil {
			return addProgramResult{}, err
		}
	default:
		return addProgramResult{}, fmt.Errorf("unsupported input type %q; expected .hex, .elf, .c, .s, or .S", filepath.Ext(input))
	}

	meta := catalog.UserMetadata{
		Name:        name,
		Description: firstNonEmpty(opts.Description, defaultDescriptionFor(input)),
		Controls:    firstNonEmpty(opts.Controls, "depends on the imported program"),
		Hint:        firstNonEmpty(opts.Hint, defaultHintFor(input)),
		Tag:         firstNonEmpty(opts.Tag, catalog.KindCustom),
		SourcePath:  input,
		SourceKind:  strings.TrimPrefix(strings.ToLower(filepath.Ext(input)), "."),
		ImportedAt:  time.Now().UTC().Format(time.RFC3339),
	}
	if err := writeProgramMetadata(dstHex, meta); err != nil {
		return addProgramResult{}, err
	}

	return addProgramResult{Name: name, HexPath: dstHex}, nil
}

func isImportableBinary(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".hex", ".elf":
		return true
	default:
		return false
	}
}

func isCompilableSource(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".c", ".s", ".S":
		return true
	default:
		return false
	}
}

func compileSourceToHex(sourcePath, dstHex, march string, depth int, includeDirs []string) error {
	sdk, err := locateCompileSDK()
	if err != nil {
		return err
	}
	gcc, err := exec.LookPath("riscv-none-elf-gcc")
	if err != nil {
		return fmt.Errorf("riscv-none-elf-gcc not on PATH; import a .hex directly or install the toolchain")
	}
	tmpDir, err := os.MkdirTemp("", "raijin-add-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	elfPath := filepath.Join(tmpDir, strings.TrimSuffix(filepath.Base(dstHex), filepath.Ext(dstHex))+".elf")
	args := []string{
		fmt.Sprintf("-march=%s", march), "-mabi=ilp32", "-mcmodel=medany",
		"-nostdlib", "-nostartfiles", "-static", "-ffreestanding", "-O2", "-Wall",
		"-T", sdk.LinkLD,
		"-I", sdk.ShimsDir,
	}
	for _, dir := range includeDirs {
		args = append(args, "-I", dir)
	}
	args = append(args, sdk.CRTS, sourcePath, "-o", elfPath, "-lgcc")

	proc := exec.Command(gcc, args...)
	out, err := proc.CombinedOutput()
	if err != nil {
		return fmt.Errorf("gcc failed: %s", strings.TrimSpace(string(out)))
	}
	return runElf2Hex(sdk.Elf2Hex, elfPath, dstHex, depth)
}

func convertElfToHex(elfPath, dstHex string, depth int) error {
	sdk, err := locateCompileSDK()
	if err != nil {
		return err
	}
	return runElf2Hex(sdk.Elf2Hex, elfPath, dstHex, depth)
}

func runElf2Hex(scriptPath, elfPath, dstHex string, depth int) error {
	python, err := findPython()
	if err != nil {
		return err
	}
	args := []string{scriptPath, elfPath, dstHex, "--depth", fmt.Sprintf("%d", depth)}
	proc := exec.Command(python, args...)
	out, err := proc.CombinedOutput()
	if err != nil {
		return fmt.Errorf("elf2hex failed: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

func findPython() (string, error) {
	for _, name := range []string{"python", "python3", "py"} {
		if path, err := exec.LookPath(name); err == nil {
			return path, nil
		}
	}
	return "", fmt.Errorf("python not found on PATH; needed for ELF → HEX conversion")
}

func writeProgramMetadata(hexPath string, meta catalog.UserMetadata) error {
	metaPath := strings.TrimSuffix(hexPath, filepath.Ext(hexPath)) + ".json"
	data, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(metaPath, data, 0o644)
}

func defaultDescriptionFor(input string) string {
	base := filepath.Base(input)
	switch strings.ToLower(filepath.Ext(input)) {
	case ".hex":
		return "Imported hex program from " + base
	case ".elf":
		return "Converted ELF program from " + base
	default:
		return "Compiled from " + base
	}
}

func defaultHintFor(input string) string {
	switch strings.ToLower(filepath.Ext(input)) {
	case ".hex":
		return "Imported into your personal Raijin library as a ready-to-run hex image."
	case ".elf":
		return "Converted from ELF into a Raijin-ready hex image and added to your library."
	default:
		return "Compiled with the packaged Raijin runtime and added to your personal library."
	}
}

func activeProgramDir() (string, error) {
	if root := os.Getenv("RAIJIN_HOME"); strings.TrimSpace(root) != "" {
		return filepath.Join(root, "programs"), nil
	}
	_, _, progDir, err := userInstallDirs()
	if err != nil {
		return "", err
	}
	return progDir, nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func sanitizedProgramName(value string) string {
	value = strings.TrimSpace(strings.ToLower(value))
	if value == "" {
		return ""
	}
	var out []rune
	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z':
			out = append(out, r)
		case r >= '0' && r <= '9':
			out = append(out, r)
		case r == '-' || r == '_':
			out = append(out, r)
		case r == ' ' || r == '.':
			out = append(out, '-')
		}
	}
	return strings.Trim(string(out), "-_")
}

func init() {
	addCmd.Flags().StringVarP(&addName, "name", "n", "", "display/program name to register")
	addCmd.Flags().StringVar(&addDescription, "description", "", "one-line description shown in the menu")
	addCmd.Flags().StringVar(&addControls, "controls", "", "human-readable controls text for the menu")
	addCmd.Flags().StringVar(&addHint, "hint", "", "longer hint shown in the menu and catalog")
	addCmd.Flags().StringVar(&addTag, "tag", catalog.KindCustom, "visual tag chip (for example custom, game, visual)")
	addCmd.Flags().StringVar(&addMarch, "march", "rv32i_zicsr", "gcc -march flag used when compiling source inputs")
	addCmd.Flags().IntVar(&addDepth, "depth", 8192, "hex memory depth in 32-bit words")
	addCmd.Flags().StringArrayVarP(&addIncludes, "include", "I", nil, "additional include directory for source compilation")
	addCmd.Flags().BoolVar(&addForce, "force", false, "replace an existing custom program with the same name")
	root.AddCommand(addCmd)
}