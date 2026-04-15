//go:build windows

package cmd

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/AinsAlmeyn/raijin-cli/internal/pathing"
)

// selfUninstallNeedsScheduling reports whether deleting the running
// binary requires deferred cleanup. Windows can't delete a running .exe
// (the OS keeps the file locked); we shell out to a hidden PowerShell
// helper that polls and removes the files after this process exits.
const selfUninstallNeedsScheduling = true

// scheduleSelfCleanup queues the post-exit removal of files and (when
// they end up empty) of dirs. Files is the list of binaries we couldn't
// delete inline because they were the running process. No-op when files
// is empty.
func scheduleSelfCleanup(files, dirs []string) error {
	if len(files) == 0 {
		return nil
	}
	command := buildCleanupPowerShell(files, dirs)
	cmd := exec.Command("powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", command)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start cleanup helper: %w", err)
	}
	return nil
}

func buildCleanupPowerShell(files, dirs []string) string {
	var builder strings.Builder
	builder.WriteString("$files=@(")
	for i, path := range files {
		if i > 0 {
			builder.WriteString(",")
		}
		builder.WriteString(pathing.PsSingleQuoted(path))
	}
	builder.WriteString("); ")
	builder.WriteString("$dirs=@(")
	for i, path := range dirs {
		if i > 0 {
			builder.WriteString(",")
		}
		builder.WriteString(pathing.PsSingleQuoted(path))
	}
	builder.WriteString("); ")
	builder.WriteString("for($i=0; $i -lt 100; $i++){ $pending=$false; foreach($f in $files){ if(Test-Path -LiteralPath $f){ try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { $pending=$true } } }; if(-not $pending){ break }; Start-Sleep -Milliseconds 200 }; ")
	builder.WriteString("foreach($d in $dirs){ if(Test-Path -LiteralPath $d){ $items = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue); if($items.Count -eq 0){ Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue } } }")
	return builder.String()
}
