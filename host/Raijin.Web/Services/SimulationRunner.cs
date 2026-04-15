using Raijin.Core;
using Raijin.Core.Models;

namespace Raijin.Web.Services;

/// <summary>
/// Background driver around <see cref="SimulationService"/>.
/// One simulator instance owned for the lifetime of the process (MVP single-user).
/// </summary>
public sealed class SimulationRunner : IAsyncDisposable
{
    private readonly SimulationService _sim = new();
    private readonly object _stateLock = new();

    private CancellationTokenSource? _cts;
    private Task? _worker;
    private SimulationState _liveState = SimulationState.Idle;

    public bool   IsRunning         => _liveState == SimulationState.Running;
    public bool   ProgramLoaded     => _sim.ProgramLoaded;
    public string? LoadedProgramName { get; private set; }
    public CpuSnapshot? Latest      { get; private set; }

    /// <summary>Fired ~10 Hz while running, plus once after each lifecycle event.</summary>
    public event Action<CpuSnapshot>? SnapshotPublished;

    /// <summary>Fired when UART TX bytes are drained from the CPU.</summary>
    public event Action<string>? UartReceived;

    /// <summary>Fired when a new program is loaded (so the terminal can clear).</summary>
    public event Action? ProgramLoadedChanged;

    /// <summary>Fired when the user resets, so the terminal can wipe.</summary>
    public event Action? ResetRequested;

    public bool LoadProgram(string filePath, string? displayName = null)
    {
        StopWorker();
        var ok = _sim.LoadHex(filePath);
        LoadedProgramName = ok ? (displayName ?? Path.GetFileName(filePath)) : null;
        _liveState        = ok ? SimulationState.Ready : SimulationState.Idle;
        ProgramLoadedChanged?.Invoke();
        Publish();
        return ok;
    }

    public void Start()
    {
        lock (_stateLock)
        {
            if (IsRunning || !ProgramLoaded || _sim.IsHalted) return;
            _cts = new CancellationTokenSource();
            var token = _cts.Token;
            _liveState = SimulationState.Running;
            _worker = Task.Run(() => RunLoop(token));
        }
        Publish();
    }

    public void Pause()
    {
        StopWorker();
        if (!_sim.IsHalted) _liveState = SimulationState.Ready;
        Publish();
    }

    public void Reset()
    {
        StopWorker();
        _sim.Reset();
        if (ProgramLoaded) _liveState = SimulationState.Ready;
        ResetRequested?.Invoke();
        Publish();
    }

    public void StepOnce(ulong cycles = 1)
    {
        if (IsRunning) return;
        _sim.Step(cycles);
        DrainUart();
        if (_sim.IsHalted) _liveState = SimulationState.Halted;
        Publish();
    }

    private async Task RunLoop(CancellationToken token)
    {
        const ulong ChunkCycles = 50_000;
        var snapshotInterval = TimeSpan.FromMilliseconds(100);
        var nextSnapshot = DateTime.UtcNow + snapshotInterval;

        try
        {
            while (!token.IsCancellationRequested)
            {
                _sim.Step(ChunkCycles);
                DrainUart();

                if (_sim.IsHalted)
                {
                    _liveState = SimulationState.Halted;
                    Publish();
                    break;
                }

                if (DateTime.UtcNow >= nextSnapshot)
                {
                    Publish();
                    nextSnapshot = DateTime.UtcNow + snapshotInterval;
                }
            }
        }
        finally
        {
            lock (_stateLock)
            {
                if (_liveState == SimulationState.Running)
                    _liveState = SimulationState.Ready;
            }
            await Task.CompletedTask;
        }
    }

    private void StopWorker()
    {
        CancellationTokenSource? cts;
        Task? worker;
        lock (_stateLock)
        {
            cts = _cts; _cts = null;
            worker = _worker; _worker = null;
        }
        if (cts is null) return;
        cts.Cancel();
        try { worker?.Wait(TimeSpan.FromSeconds(2)); } catch { /* swallow */ }
        cts.Dispose();
    }

    private void DrainUart()
    {
        var s = _sim.ReadUart();
        if (s.Length > 0) UartReceived?.Invoke(s);
    }

    private void Publish()
    {
        var snap = _sim.Snapshot(_liveState);
        Latest = snap;
        SnapshotPublished?.Invoke(snap);
    }

    public byte[] ReadDmem(uint addr, uint length) => _sim.ReadDmem(addr, length);

    public void SendUart(string s) => _sim.WriteUart(s);
    public void SendUart(byte b)   => _sim.WriteUart(b);

    public async ValueTask DisposeAsync()
    {
        StopWorker();
        _sim.Dispose();
        await Task.CompletedTask;
    }
}
