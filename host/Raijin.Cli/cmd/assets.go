package cmd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/AinsAlmeyn/raijin-cli/internal/catalog"
	"github.com/AinsAlmeyn/raijin-cli/internal/pathing"
)

type compileSDK struct {
	Root     string
	CRTS     string
	LinkLD   string
	ShimsDir string
	Elf2Hex  string
}

func executableDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Dir(exe)
}

func packagedProgramsDir() string {
	if dir := executableDir(); dir != "" {
		return filepath.Join(dir, "programs")
	}
	return ""
}

func packagedSDKDir() string {
	if dir := executableDir(); dir != "" {
		return filepath.Join(dir, "sdk")
	}
	return ""
}

func installedSDKDir() (string, error) {
	root, _, _, err := pathing.UserInstallDirs()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "sdk"), nil
}

func findRepoRoot() string {
	var bases []string
	if dir := executableDir(); dir != "" {
		bases = append(bases, dir)
	}
	if wd, err := os.Getwd(); err == nil {
		bases = append(bases, wd)
	}

	for _, base := range bases {
		here := filepath.Clean(base)
		for i := 0; i < 10 && here != ""; i++ {
			if sdkLooksValid(filepath.Join(here, "tools"), false) {
				return here
			}
			parent := filepath.Dir(here)
			if parent == here {
				break
			}
			here = parent
		}
	}
	return ""
}

func findBuiltinHex(e *catalog.Entry) string {
	if e == nil {
		return ""
	}
	base := filepath.Base(e.HexPath)
	if dir := packagedProgramsDir(); dir != "" {
		if path := firstExistingPath(filepath.Join(dir, base)); path != "" {
			return path
		}
	}
	if root := findRepoRoot(); root != "" {
		if path := firstExistingPath(filepath.Join(root, e.HexPath)); path != "" {
			return path
		}
	}
	if wd, err := os.Getwd(); err == nil {
		if path := firstExistingPath(filepath.Join(wd, e.HexPath)); path != "" {
			return path
		}
	}
	return ""
}

func locateCompileSDK() (compileSDK, error) {
	candidates := []string{}
	if dir := packagedSDKDir(); dir != "" {
		candidates = append(candidates, dir)
	}
	if dir, err := installedSDKDir(); err == nil {
		candidates = append(candidates, dir)
	}
	if root := findRepoRoot(); root != "" {
		candidates = append(candidates, filepath.Join(root, "tools"))
	}

	for _, root := range candidates {
		if sdkLooksValid(root, true) {
			return compileSDK{
				Root:     root,
				CRTS:     filepath.Join(root, "c-runtime", "crt.S"),
				LinkLD:   filepath.Join(root, "c-runtime", "link.ld"),
				ShimsDir: filepath.Join(root, "c-runtime", "shims"),
				Elf2Hex:  filepath.Join(root, "runners", "elf2hex.py"),
			}, nil
		}
	}
	return compileSDK{}, fmt.Errorf("could not locate the Raijin SDK payload (expected sdk/ next to raijin.exe or tools/ in the repo)")
}

func locateInstallableSDKSource() string {
	if dir := packagedSDKDir(); dir != "" && sdkLooksValid(dir, true) {
		return dir
	}
	if root := findRepoRoot(); root != "" {
		tools := filepath.Join(root, "tools")
		if sdkLooksValid(tools, false) {
			return tools
		}
	}
	return ""
}

func sdkLooksValid(root string, packaged bool) bool {
	if packaged {
		return fileExists(filepath.Join(root, "c-runtime", "crt.S")) &&
			fileExists(filepath.Join(root, "c-runtime", "link.ld")) &&
			fileExists(filepath.Join(root, "runners", "elf2hex.py"))
	}
	return fileExists(filepath.Join(root, "c-runtime", "crt.S")) &&
		fileExists(filepath.Join(root, "c-runtime", "link.ld")) &&
		fileExists(filepath.Join(root, "runners", "elf2hex.py"))
}

func firstExistingPath(paths ...string) string {
	for _, path := range paths {
		if fileExists(path) {
			return path
		}
	}
	return ""
}

func copyTree(srcDir, dstDir string) error {
	return filepath.Walk(srcDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(srcDir, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dstDir, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return copyFile(path, target)
	})
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}