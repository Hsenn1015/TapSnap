using System;
using System.Runtime.InteropServices;
using System.Windows;

namespace TapSnap.Windows;

internal sealed class ScrollInput : IDisposable
{
    private const int LowLevelMouse = 14;
    private const int MouseWheel = 0x020A;
    private readonly HookProcedure procedure;
    private IntPtr hook;

    public ScrollInput(Action<Point> onScroll, Action<Point> onClick)
    {
        procedure = (code, message, data) =>
        {
            if (code >= 0 && message == MouseWheel)
            {
                var position = Marshal.PtrToStructure<PointerData>(data);
                onScroll(new Point(position.X, position.Y));
            }
            else if (code >= 0 && (message == 0x0201 || message == 0x0204 || message == 0x0207))
            {
                var position = Marshal.PtrToStructure<PointerData>(data);
                onClick(new Point(position.X, position.Y));
            }
            return CallNextHookEx(IntPtr.Zero, code, message, data);
        };
        hook = SetWindowsHookEx(LowLevelMouse, procedure, GetModuleHandle(null), 0);
    }

    public bool IsAvailable => hook != IntPtr.Zero;

    public void Dispose()
    {
        if (hook == IntPtr.Zero)
            return;
        UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PointerData
    {
        public int X;
        public int Y;
        public int Wheel;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr HookProcedure(int code, nint message, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SetWindowsHookEx(int hookId, HookProcedure callback, IntPtr module, uint threadId);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, nint message, IntPtr data);
    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? name);
}
