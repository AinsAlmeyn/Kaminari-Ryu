using System.Runtime.InteropServices;

namespace Raijin.Core.Native;

/// <summary>
/// P/Invoke surface for raijin.dll (Windows) / libraijin.so (Linux).
/// Names map 1:1 to the extern "C" entry points in sim/raijin_api.h.
/// LibraryImport (source-generated) is preferred over DllImport.
/// </summary>
internal static partial class RaijinNative
{
    private const string LibName = "raijin";

    [LibraryImport(LibName, EntryPoint = "raijin_create")]
    public static partial IntPtr Create();

    [LibraryImport(LibName, EntryPoint = "raijin_destroy")]
    public static partial void Destroy(IntPtr sim);

    [LibraryImport(LibName, EntryPoint = "raijin_reset")]
    public static partial void Reset(IntPtr sim);

    [LibraryImport(LibName, EntryPoint = "raijin_load_hex",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial int LoadHex(IntPtr sim, string path);

    [LibraryImport(LibName, EntryPoint = "raijin_step")]
    public static partial ulong Step(IntPtr sim, ulong maxCycles);

    [LibraryImport(LibName, EntryPoint = "raijin_halted")]
    public static partial int Halted(IntPtr sim);

    [LibraryImport(LibName, EntryPoint = "raijin_tohost")]
    public static partial uint Tohost(IntPtr sim);

    [LibraryImport(LibName, EntryPoint = "raijin_get_pc")]
    public static partial uint GetPc(IntPtr sim);

    [LibraryImport(LibName, EntryPoint = "raijin_get_regs")]
    public static partial void GetRegs(IntPtr sim,
        [Out] uint[] outRegs);

    [LibraryImport(LibName, EntryPoint = "raijin_get_csrs")]
    public static partial void GetCsrs(IntPtr sim,
        [Out] uint[] outCsrs);

    [LibraryImport(LibName, EntryPoint = "raijin_read_dmem")]
    public static partial void ReadDmem(IntPtr sim, uint byteAddr,
        [Out] byte[] buf, uint len);

    [LibraryImport(LibName, EntryPoint = "raijin_cycle_count")]
    public static partial ulong CycleCount(IntPtr sim);

    [LibraryImport(LibName, EntryPoint = "raijin_instret")]
    public static partial ulong Instret(IntPtr sim);

    [LibraryImport(LibName, EntryPoint = "raijin_get_class_counters")]
    public static partial void GetClassCounters(IntPtr sim,
        [Out] ulong[] outCounters);

    [LibraryImport(LibName, EntryPoint = "raijin_uart_read")]
    public static partial int UartRead(IntPtr sim,
        [Out] byte[] buf, int max);

    [LibraryImport(LibName, EntryPoint = "raijin_uart_write")]
    public static partial void UartWrite(IntPtr sim, byte c);
}
