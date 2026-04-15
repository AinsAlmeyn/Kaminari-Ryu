using System.Runtime.InteropServices;
using Raijin.Core.Native;

namespace Raijin.Core;

/// <summary>
/// SafeHandle for the opaque RaijinSim* returned by raijin_create.
/// Guarantees raijin_destroy is called even if the owning object is leaked
/// (the finalizer queue handles it). Avoids the IntPtr leak hazard.
/// </summary>
public sealed class RaijinHandle : SafeHandle
{
    public RaijinHandle() : base(IntPtr.Zero, ownsHandle: true) { }

    public override bool IsInvalid => handle == IntPtr.Zero;

    protected override bool ReleaseHandle()
    {
        RaijinNative.Destroy(handle);
        return true;
    }

    /// <summary>Allocate a new simulator instance.</summary>
    public static RaijinHandle Create()
    {
        var ptr = RaijinNative.Create();
        if (ptr == IntPtr.Zero)
            throw new InvalidOperationException("raijin_create returned null");
        var h = new RaijinHandle();
        h.SetHandle(ptr);
        return h;
    }

    internal IntPtr Raw => handle;
}
