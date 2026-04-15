namespace Raijin.Core.Models;

/// <summary>
/// One snapshot of CPU state plus user-friendly system metrics and the
/// hardware perf-counter breakdown.
/// </summary>
public sealed record CpuSnapshot(
    // ---- raw CPU state ----
    uint   Pc,
    uint[] Regs,
    ulong  CycleCount,
    ulong  Instret,
    bool   Halted,
    uint   Tohost,

    // ---- user-friendly metrics ----
    SimulationState State,
    double SimulatedMips,
    uint   ProgramBytes,
    uint   StackBytesUsed,
    uint   MemoryCapacityBytes,
    TimeSpan RunTime,

    // ---- hardware perf counters (instruction-class breakdown) ----
    InstructionMix Mix,

    DateTime SampledAt
)
{
    public uint MemoryUsedBytes => ProgramBytes + StackBytesUsed;

    public double MemoryFraction =>
        MemoryCapacityBytes == 0 ? 0 : Math.Min(1.0, MemoryUsedBytes / (double)MemoryCapacityBytes);
}

public sealed record InstructionMix(
    ulong Multiplications,
    ulong BranchesTotal,
    ulong BranchesTaken,
    ulong Jumps,
    ulong Loads,
    ulong Stores,
    ulong Traps
)
{
    /// <summary>
    /// Sum of all classified-by-perfcounter instructions. Note this is
    /// LESS than instret because plain ALU ops (addi, xor, etc.) and
    /// CSR ops aren't classified here. Useful for percentage math.
    /// </summary>
    public ulong ClassifiedTotal =>
        Multiplications + BranchesTotal + Jumps + Loads + Stores + Traps;

    public double TakenRate =>
        BranchesTotal == 0 ? 0 : BranchesTaken / (double)BranchesTotal;

    public double Percent(ulong count, ulong instret) =>
        instret == 0 ? 0 : (count * 100.0) / instret;
}

public enum SimulationState
{
    Idle,
    Ready,
    Running,
    Halted,
}
