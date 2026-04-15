using System.Diagnostics;
using System.Text;
using Raijin.Core.Models;
using Raijin.Core.Native;

namespace Raijin.Core;

/// <summary>
/// High-level facade over a single Raijin simulator instance.
///
/// Threading model: this class is NOT thread-safe by design. The intended
/// pattern is one background task driving Step + sampling, with snapshots
/// and UART output published via thread-safe channels.
/// </summary>
public sealed class SimulationService : IDisposable
{
    // Logical memory capacity reported to users. The CPU now has 16 MB IMEM
    // + 16 MB DMEM = 32 MB. Sized so Doom's Z_Init (~5 MB) plus the 4 MB WAD
    // blob plus code, bss, stack all fit.
    private const uint MemoryCapacityBytes = 32 * 1024 * 1024;

    // Stack watermark: programs set sp differently (demos use 0x8000, Doom
    // uses 0x1000000, test-benches elsewhere). Instead of hard-coding one
    // top, we remember the highest sp we've ever observed during a run and
    // measure depth as (max_sp_seen - min_sp_seen). That works for every
    // link.ld the toolchain ships.

    private readonly RaijinHandle _h = RaijinHandle.Create();
    private readonly byte[] _uartBuf = new byte[4096];
    private readonly Stopwatch _wall = new();

    private ulong _lastSampledInstret;
    private long  _lastSampledTicks;

    private uint    _programBytes;     // computed once at load time
    private uint    _maxSpSeen;        // highest sp observed this run
    private uint    _minSpSeen;        // lowest sp observed this run
    private string? _lastHexPath;      // remembered so Reset can fully reload

    public bool ProgramLoaded { get; private set; }

    public bool LoadHex(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException(path);
        var rc = RaijinNative.LoadHex(_h.Raw, path);
        ProgramLoaded = rc == 0;
        if (ProgramLoaded)
        {
            _wall.Restart();
            _lastSampledInstret = 0;
            _lastSampledTicks   = 0;
            _programBytes       = ScanProgramBytes();
            _maxSpSeen          = 0;
            _minSpSeen          = uint.MaxValue;
            _lastHexPath        = path;
        }
        else
        {
            _programBytes = 0;
            _maxSpSeen    = 0;
            _minSpSeen    = uint.MaxValue;
            _lastHexPath  = null;
        }
        return ProgramLoaded;
    }

    /// <summary>
    /// "Reset" semantics for the user: rewind the program to its just-loaded
    /// state. We re-read the hex file (so memory, including the tohost byte
    /// the program may have written, gets a fresh image) and then assert the
    /// CPU's hardware reset. If no program is loaded, this falls back to a
    /// pure CPU reset.
    /// </summary>
    public void Reset()
    {
        if (_lastHexPath != null && File.Exists(_lastHexPath))
        {
            // LoadHex already wipes IMEM+DMEM, re-loads, hard-resets the CPU,
            // and resets all our bookkeeping.
            LoadHex(_lastHexPath);
        }
        else
        {
            RaijinNative.Reset(_h.Raw);
            _wall.Restart();
            _lastSampledInstret = 0;
            _lastSampledTicks   = 0;
            _maxSpSeen          = 0;
            _minSpSeen          = uint.MaxValue;
        }
    }

    public ulong Step(ulong maxCycles)
    {
        var ran = RaijinNative.Step(_h.Raw, maxCycles);
        SampleStackWatermark();   // catch in-flight sp values between snapshots
        return ran;
    }

    private readonly uint[] _spProbeRegs = new uint[32];

    /// <summary>Read sp (x2) and fold it into the stack high/low watermarks.</summary>
    private void SampleStackWatermark()
    {
        RaijinNative.GetRegs(_h.Raw, _spProbeRegs);
        var sp = _spProbeRegs[2];
        if (sp == 0 || sp >= MemoryCapacityBytes) return;
        if (sp > _maxSpSeen) _maxSpSeen = sp;
        if (sp < _minSpSeen) _minSpSeen = sp;
    }

    public bool IsHalted => RaijinNative.Halted(_h.Raw) != 0;
    public uint Tohost   => RaijinNative.Tohost(_h.Raw);

    public string ReadUart()
    {
        var n = RaijinNative.UartRead(_h.Raw, _uartBuf, _uartBuf.Length);
        return n <= 0 ? string.Empty : Encoding.UTF8.GetString(_uartBuf, 0, n);
    }

    public void WriteUart(byte b) => RaijinNative.UartWrite(_h.Raw, b);
    public void WriteUart(string s)
    {
        foreach (var b in Encoding.UTF8.GetBytes(s)) WriteUart(b);
    }

    /// <summary>Sample full CPU state plus user-facing system metrics.</summary>
    public CpuSnapshot Snapshot(SimulationState liveState)
    {
        var regs = new uint[32];
        RaijinNative.GetRegs(_h.Raw, regs);

        var ctrs = new ulong[7];
        RaijinNative.GetClassCounters(_h.Raw, ctrs);
        var mix = new InstructionMix(
            Multiplications: ctrs[0],
            BranchesTotal:   ctrs[1],
            BranchesTaken:   ctrs[2],
            Jumps:           ctrs[3],
            Loads:           ctrs[4],
            Stores:          ctrs[5],
            Traps:           ctrs[6]
        );

        var pc      = RaijinNative.GetPc(_h.Raw);
        var cycles  = RaijinNative.CycleCount(_h.Raw);
        var instret = RaijinNative.Instret(_h.Raw);
        var halted  = RaijinNative.Halted(_h.Raw) != 0;
        var tohost  = RaijinNative.Tohost(_h.Raw);

        // MIPS: rolling derivative over wall-clock since last snapshot.
        var nowTicks  = _wall.ElapsedTicks;
        var deltaInst = instret - _lastSampledInstret;
        var deltaTick = nowTicks - _lastSampledTicks;
        var mips = 0.0;
        if (deltaTick > 0)
        {
            var seconds = deltaTick / (double)Stopwatch.Frequency;
            mips = (deltaInst / seconds) / 1_000_000.0;
        }
        _lastSampledInstret = instret;
        _lastSampledTicks   = nowTicks;

        // Stack usage: track both the highest and lowest sp we've observed.
        // The depth is (high - low). We accept any sp value below our memory
        // capacity; crt.S sets sp to _stack_top very early, so the first
        // sample already captures the true top. Until then sp may be 0,
        // which we ignore.
        var sp = regs[2];
        if (sp != 0 && sp < MemoryCapacityBytes)
        {
            if (sp > _maxSpSeen) _maxSpSeen = sp;
            if (sp < _minSpSeen) _minSpSeen = sp;
        }
        uint stackUsed = (_maxSpSeen > 0 && _minSpSeen != uint.MaxValue)
            ? _maxSpSeen - _minSpSeen
            : 0u;

        // If user reported "Halted" but we observe halt, prefer halt for clarity.
        var state = halted ? SimulationState.Halted : liveState;

        return new CpuSnapshot(
            Pc:                  pc,
            Regs:                regs,
            CycleCount:          cycles,
            Instret:             instret,
            Halted:              halted,
            Tohost:              tohost,
            State:               state,
            SimulatedMips:       mips,
            ProgramBytes:        _programBytes,
            StackBytesUsed:      stackUsed,
            MemoryCapacityBytes: MemoryCapacityBytes,
            RunTime:             _wall.Elapsed,
            Mix:                 mix,
            SampledAt:           DateTime.UtcNow
        );
    }

    public byte[] ReadDmem(uint byteAddr, uint length)
    {
        var buf = new byte[length];
        RaijinNative.ReadDmem(_h.Raw, byteAddr, buf, length);
        return buf;
    }

    public void Dispose() => _h.Dispose();

    // ---- helpers ----

    /// <summary>
    /// Find the highest non-zero byte in DMEM and round up to a word — this
    /// is a good enough proxy for "how much of the image the linker laid out".
    /// Walks the capacity from the top in 64 KB pages so Doom (4+ MB image)
    /// still finishes quickly: the scan stops at the first non-empty page
    /// and then refines within it.
    /// </summary>
    private uint ScanProgramBytes()
    {
        const int  PageBytes = 64 * 1024;
        var  page = new byte[PageBytes];
        uint cap  = MemoryCapacityBytes / 2;   // image lives in the first half (text+rodata)

        for (int p = (int)(cap / PageBytes) - 1; p >= 0; p--)
        {
            uint addr = (uint)p * PageBytes;
            RaijinNative.ReadDmem(_h.Raw, addr, page, PageBytes);
            for (int i = PageBytes - 1; i >= 0; i--)
            {
                if (page[i] != 0)
                {
                    var bytes = addr + (uint)(i + 1);
                    return (bytes + 3u) & ~3u;
                }
            }
        }
        return 0;
    }
}
