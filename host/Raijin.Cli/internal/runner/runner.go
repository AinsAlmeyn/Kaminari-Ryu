// Package runner is the interactive-program runtime: alternate-screen
// driver, UART passthrough, bottom status bar, keyboard forwarder.
package runner

import (
	"context"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/AinsAlmeyn/raijin-cli/internal/report"
	"github.com/AinsAlmeyn/raijin-cli/internal/sim"
	"github.com/AinsAlmeyn/raijin-cli/internal/theme"

	"golang.org/x/term"
)

type Options struct {
	HexPath     string
	Display     string
	MaxCycles   uint64
	Quiet       bool
	NoStatus    bool
	ChunkCycles uint64
	// InMenu must be true when Run is called from the interactive menu.
	// It changes the pause-screen key mapping: Enter returns to the menu
	// and R resumes. When InMenu is false (direct CLI invocation, e.g.
	// "raijin run donut"), Enter resumes the program and Esc/Q quits.
	InMenu bool
}

// exitChoice distinguishes the three ways a run ends.
type exitChoice int

const (
	choiceNatural exitChoice = iota // halt / max-cycles / non-interactive
	choiceMenu                       // user chose "back to menu" in pause screen
	choiceQuit                       // user chose "quit raijin" in pause screen
)

// ctrlAction is what drainAndRoute tells the main loop to do.
type ctrlAction int

const (
	actContinue ctrlAction = iota
	actExitMenu
	actExitQuit
)

// Run drives a single program from LoadHex through summary.
func Run(opts Options) int {
	if opts.ChunkCycles == 0 {
		opts.ChunkCycles = 50_000
	}

	se, err := sim.OpenSession()
	if err != nil {
		fmt.Fprintln(os.Stderr, theme.Err.Render("error")+"  "+err.Error())
		return 2
	}
	defer se.Close()
	if err := se.LoadHex(opts.HexPath); err != nil {
		fmt.Fprintln(os.Stderr, theme.Err.Render("error")+"  "+err.Error())
		return 2
	}

	stdoutIsTerm := term.IsTerminal(int(os.Stdout.Fd()))
	stdinIsTerm  := term.IsTerminal(int(os.Stdin.Fd()))
	interactive  := !opts.Quiet && stdoutIsTerm && stdinIsTerm

	var tty *terminal
	var restoreStdin func() error
	if interactive {
		tty = newTerminal(os.Stdout)
		tty.enter()
		defer tty.leave()

		restore, err := enterRawMode(int(os.Stdin.Fd()))
		if err == nil {
			restoreStdin = restore
			defer restoreStdin()
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	keyCh := make(chan byte, 64)
	var wg sync.WaitGroup
	if interactive {
		wg.Add(1)
		go func() {
			defer wg.Done()
			readKeys(ctx, keyCh)
		}()
	}
	if interactive {
		drain(keyCh, 30*time.Millisecond)
	}

	var (
		totalRun uint64
		lastStat = time.Now()
		out      io.Writer = os.Stdout
	)
	mu := &sync.Mutex{}
	choice := choiceNatural

loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		default:
		}

		if interactive {
			switch drainAndRoute(keyCh, se, mu, tty, opts.InMenu) {
			case actExitMenu:
				choice = choiceMenu
				break loop
			case actExitQuit:
				choice = choiceQuit
				break loop
			}
		}

		if opts.MaxCycles > 0 && totalRun >= opts.MaxCycles {
			break
		}
		if se.S.Halted() {
			break
		}
		totalRun += se.Step(opts.ChunkCycles)

		if bytes := se.S.ReadUart(); len(bytes) > 0 && !opts.Quiet {
			mu.Lock()
			_, _ = out.Write(bytes)
			mu.Unlock()
		}

		if interactive && !opts.NoStatus && time.Since(lastStat) >= 200*time.Millisecond {
			snap := se.Snapshot()
			mu.Lock()
			tty.drawStatus(snap, "[Ctrl+C] pause")
			mu.Unlock()
			lastStat = time.Now()
		}
	}

	cancel()
	if interactive && restoreStdin != nil {
		_ = restoreStdin()
	}
	if interactive {
		done := make(chan struct{})
		go func() {
			defer close(done)
			wg.Wait()
		}()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			// Windows terminal input cancellation can occasionally stall.
			// Do not force the user to press another key just to get back
			// to the menu or summary screen.
		}
	}

	// Belt-and-braces cleanup of pending input. Windows raw-mode Enter
	// arrives as \r\n; we consume the \r but the \n usually sits in the
	// OS console input buffer, and would otherwise poison the next
	// interactive screen (bubbletea reads it as a stray Enter press).
	if interactive {
		for {
			select {
			case <-keyCh:
			default:
				goto drained
			}
		}
	drained:
		flushStdinWindows()
	}

	final := se.Snapshot()

	if tty != nil {
		tty.leave()
	}

	switch choice {
	case choiceQuit:
		// User chose to exit the app from the paused screen.
		os.Exit(0)
	case choiceMenu:
		// User saw the paused summary and picked "menu" — no further
		// screen, caller loops back to its menu.
	default:
		// Natural end (halt / cap). Show the bubbletea summary screen
		// for interactive sessions, plain text for piped.
		if interactive && !opts.Quiet {
			report.ShowSummary(final, opts.Display)
		} else if !interactive {
			fmt.Println()
			fmt.Println(report.Final(final, opts.Display))
		}
	}

	if final.Halted && final.Tohost == 1 {
		return 0
	}
	return 1
}

// drainAndRoute pulls buffered key bytes. Normal bytes go to UART RX.
// Ctrl+C freezes the sim and enters the in-place pause screen.
func drainAndRoute(keyCh chan byte, se *sim.Session, mu *sync.Mutex, tty *terminal, inMenu bool) ctrlAction {
	for {
		select {
		case b := <-keyCh:
			if b == 0x03 {
				return showPauseScreen(keyCh, se, mu, tty, inMenu)
			}
			se.S.WriteUart(b)
		default:
			return actContinue
		}
	}
}

// showPauseScreen paints the full "paused" view inside the alt screen —
// a header pill, hero MIPS, supporting stats, instruction-mix bars, and
// an action bar at the bottom. The sim is frozen while this renders;
// the user picks one of three paths:
//
// Menu mode (InMenu == true):
//
//	enter / m      → exit to menu
//	r              → resume the program
//	esc / q / ctrl+c → quit the whole app
//
// Direct mode (InMenu == false, e.g. "raijin run donut"):
//
//	enter / r      → resume the program
//	esc / q / ctrl+c → quit the whole app
//
// Any render stays in the alt screen so there's no extra page-transition
// on the way out.
func showPauseScreen(keyCh chan byte, se *sim.Session, mu *sync.Mutex, tty *terminal, inMenu bool) ctrlAction {
	for {
		snap := se.Snapshot()
		mu.Lock()
		tty.drawPausePage(snap, inMenu)
		mu.Unlock()

		// Blocking wait for a key.
		b, ok := <-keyCh
		if !ok {
			return actExitMenu
		}
		switch b {
		case '\r', '\n':
			if inMenu {
				return actExitMenu
			}
			// Direct mode: Enter resumes the program.
			mu.Lock()
			tty.clearContent()
			mu.Unlock()
			return actContinue
		case 'm', 'M':
			if inMenu {
				return actExitMenu
			}
			// In direct mode 'm' has no menu to go back to; resume instead.
			mu.Lock()
			tty.clearContent()
			mu.Unlock()
			return actContinue
		case 'r', 'R':
			// Resume in both modes.
			mu.Lock()
			tty.clearContent()
			mu.Unlock()
			return actContinue
		case 'q', 'Q', 0x03, 0x1b:
			return actExitQuit
		}
		// Anything else: redraw (handles terminal resizes).
	}
}

func drain(ch chan byte, d time.Duration) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		select {
		case <-ch:
		default:
			time.Sleep(2 * time.Millisecond)
		}
	}
}
