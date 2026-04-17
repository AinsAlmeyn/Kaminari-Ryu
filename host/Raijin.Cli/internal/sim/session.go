package sim

import (
	"fmt"
	"os"
	"time"
)

var _ = fmt.Sprintf // keep fmt imported in case of future debug use

// MemoryCapacityBytes mirrors the DLL's MEM_DEPTH_WORDS (currently 4 M words
// per side × 2 sides × 4 bytes = 32 MiB logical address space).
const MemoryCapacityBytes uint32 = 32 * 1024 * 1024

// Session wraps a Sim with bookkeeping the CLI wants: wall clock, MIPS
// rolling window, stack-peak tracking, program size computed once at load.
type Session struct {
	S             *Sim
	ProgramBytes  uint32
	startWall     time.Time
	lastInstret   uint64
	lastSampleAt  time.Time
	mipsEMA       float64
	maxSp, minSp  uint32
	lastHexPath   string
}

func OpenSession() (*Session, error) {
	s, err := New()
	if err != nil {
		return nil, err
	}
	return &Session{
		S:      s,
		minSp:  ^uint32(0),
		startWall: time.Now(),
	}, nil
}

func (se *Session) Close() {
	if se == nil {
		return
	}
	se.S.Close()
}

func (se *Session) LoadHex(path string) error {
	if err := se.S.LoadHex(path); err != nil {
		return err
	}
	se.lastHexPath = path
	se.startWall = time.Now()
	se.lastInstret = 0
	se.lastSampleAt = time.Now()
	se.mipsEMA = 0
	se.maxSp = 0
	se.minSp = ^uint32(0)
	se.ProgramBytes = se.scanProgramBytes()
	return nil
}

// Reset re-loads the hex (wipes memory + zeroes perfcounters) or just
// asserts CPU reset if no program was loaded.
func (se *Session) Reset() {
	if se.lastHexPath != "" {
		if _, err := os.Stat(se.lastHexPath); err == nil {
			_ = se.LoadHex(se.lastHexPath)
			return
		}
	}
	se.S.Reset()
	se.startWall = time.Now()
}

// Step drives the simulator and updates watermarks. Always call this from
// the same goroutine — the underlying Verilated model is not thread-safe.
func (se *Session) Step(maxCycles uint64) uint64 {
	ran := se.S.Step(maxCycles)
	sp := se.S.Regs()[2]
	if sp != 0 && sp < MemoryCapacityBytes {
		if sp > se.maxSp {
			se.maxSp = sp
		}
		if sp < se.minSp {
			se.minSp = sp
		}
	}
	return ran
}

// Snapshot captures everything the UI typically displays. Call from the
// render loop at whatever cadence makes sense (the CLI uses 5–10 Hz).
func (se *Session) Snapshot() Snapshot {
	now := time.Now()
	instret := se.S.Instret()
	cycles  := se.S.CycleCount()

	var instantMips float64
	dt := now.Sub(se.lastSampleAt).Seconds()
	if dt >= 0.05 {
		di := instret - se.lastInstret
		instantMips = float64(di) / dt / 1_000_000.0
		// Exponential moving average smooths the 5 Hz noise.
		if se.mipsEMA == 0 {
			se.mipsEMA = instantMips
		} else {
			se.mipsEMA = 0.6*se.mipsEMA + 0.4*instantMips
		}
		se.lastInstret  = instret
		se.lastSampleAt = now
	}

	stack := uint32(0)
	if se.maxSp > 0 && se.minSp != ^uint32(0) {
		stack = se.maxSp - se.minSp
	}

	return Snapshot{
		PC:              se.S.PC(),
		Regs:            se.S.Regs(),
		CycleCount:      cycles,
		Instret:         instret,
		Halted:          se.S.Halted(),
		Tohost:          se.S.Tohost(),
		MIPS:            se.mipsEMA,
		ProgramBytes:    se.ProgramBytes,
		StackBytesUsed:  stack,
		MemoryCapacity:  MemoryCapacityBytes,
		RunTime:         now.Sub(se.startWall),
		Mix:             se.S.ClassCounters(),
		MixV2:           se.S.ClassCountersV2(),
		CSRs:            se.S.CSRs(),
		SampledAt:       now,
	}
}

// Snapshot is an immutable value the render layer binds against.
type Snapshot struct {
	PC             uint32
	Regs           [32]uint32
	CycleCount     uint64
	Instret        uint64
	Halted         bool
	Tohost         uint32
	MIPS           float64
	ProgramBytes   uint32
	StackBytesUsed uint32
	MemoryCapacity uint32
	RunTime        time.Duration
	Mix            [7]uint64  // [mul, br_total, br_taken, jumps, loads, stores, traps]
	MixV2          [11]uint64 // adds [..., exceptions, interrupts, wfi, csr_access]
	CSRs           CSRSnapshot
	SampledAt      time.Time
}

// Extended-counter accessors. Indices 7..10 of MixV2 are only populated
// against a v2 DLL; older builds leave them zero.
func (s Snapshot) Exceptions() uint64 { return s.MixV2[7] }
func (s Snapshot) Interrupts() uint64 { return s.MixV2[8] }
func (s Snapshot) WfiCommits() uint64 { return s.MixV2[9] }
func (s Snapshot) CsrAccess()  uint64 { return s.MixV2[10] }

// MemoryUsedBytes sums program image + dynamic stack.
func (s Snapshot) MemoryUsedBytes() uint32 {
	return s.ProgramBytes + s.StackBytesUsed
}

// Pass / Fail / Stopped derived from Halted + Tohost.
func (s Snapshot) State() string {
	switch {
	case !s.Halted:
		return "running"
	case s.Tohost == 1:
		return "pass"
	default:
		return fmt.Sprintf("fail (subtest %d)", s.Tohost>>1)
	}
}

// scanProgramBytes mirrors the C# service: walks DMEM top-to-bottom in
// 64 KB pages, finds the highest non-zero byte, rounds up to a word.
func (se *Session) scanProgramBytes() uint32 {
	const pageBytes = 64 * 1024
	cap := MemoryCapacityBytes / 2 // image lives in the first half
	for p := int(cap/pageBytes) - 1; p >= 0; p-- {
		addr := uint32(p) * pageBytes
		page := se.S.ReadDmem(addr, pageBytes)
		for i := len(page) - 1; i >= 0; i-- {
			if page[i] != 0 {
				bytes := addr + uint32(i+1)
				return (bytes + 3) &^ 3
			}
		}
	}
	return 0
}
