using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace TapSnap.Windows;

internal sealed class PriorityHotkeys : IDisposable
{
    private static readonly uint[] ModifierKeys = [0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0x5b, 0x5c];
    private readonly Dictionary<int, (Hotkey Key, Action Invoke)> bindings = new();
    private readonly HashSet<uint> consuming = new();
    private readonly KeyboardProc callback;
    private readonly Dispatcher dispatcher;
    private readonly Thread thread;
    private byte held;
    private IntPtr hook;

    public PriorityHotkeys()
    {
        callback = HandleKey;
        var ready = new TaskCompletionSource<Dispatcher>(TaskCreationOptions.RunContinuationsAsynchronously);
        thread = new Thread(() =>
        {
            ready.SetResult(Dispatcher.CurrentDispatcher);
            Dispatcher.Run();
        }) { IsBackground = true, Name = "TapSnap.Shortcuts" };
        thread.Start();
        dispatcher = ready.Task.GetAwaiter().GetResult();
    }

    public bool Bind(int id, Hotkey key, Action dispatch)
    {
        // The function keys used by the debugger and the Windows logo shortcuts stay with the OS.
        if ((key.Modifiers & 8) != 0 || key.KeyCode == 0x7b ||
            key is { Modifiers: 1, KeyCode: 0x09 or 0x1b or 0x73 } ||
            key is { Modifiers: 3, KeyCode: 0x2e }) return false;
        return dispatcher.Invoke(() =>
        {
            if (hook == IntPtr.Zero)
            {
                held = 0;
                for (int i = 0; i < ModifierKeys.Length; i++)
                    if ((GetAsyncKeyState((int)ModifierKeys[i]) & 0x8000) != 0) held |= (byte)(1 << i);
                hook = SetWindowsHookExW(13, callback, GetModuleHandleW(null), 0);
                if (hook == IntPtr.Zero) return false;
            }
            bindings[id] = (key, dispatch);
            return true;
        });
    }

    public void Remove(int id) => dispatcher.Invoke(() =>
    {
        if (!bindings.Remove(id) || bindings.Count != 0) return;
        StopHook();
    });

    private IntPtr HandleKey(int code, IntPtr message, IntPtr data)
    {
        if (code == 0)
        {
            int flags = Marshal.ReadInt32(data, 8);
            if ((flags & 0x10) == 0) // Pass through synthetic input.
            {
                uint key = (uint)Marshal.ReadInt32(data);
                bool released = (flags & 0x80) != 0;
                int index = Array.IndexOf(ModifierKeys, key);
                if (index >= 0)
                {
                    if (released) held &= (byte)~(1 << index);
                    else held |= (byte)(1 << index);
                }
                else if (released)
                {
                    if (consuming.Remove(key)) return new IntPtr(1);
                }
                else
                {
                    if (consuming.Contains(key)) return new IntPtr(1);
                    uint mods = (uint)(((held & 0x30) != 0 ? 1 : 0) | ((held & 0x0c) != 0 ? 2 : 0) |
                        ((held & 0x03) != 0 ? 4 : 0) | ((held & 0xc0) != 0 ? 8 : 0));
                    foreach (var binding in bindings.Values)
                    {
                        if (binding.Key.KeyCode != key || binding.Key.Modifiers != mods) continue;
                        consuming.Add(key);
                        binding.Invoke();
                        return new IntPtr(1);
                    }
                }
            }
        }
        return CallNextHookEx(hook, code, message, data);
    }

    private void StopHook()
    {
        if (hook == IntPtr.Zero) return;
        UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
        consuming.Clear();
    }

    public void Dispose()
    {
        dispatcher.Invoke(StopHook);
        dispatcher.BeginInvokeShutdown(DispatcherPriority.Normal);
        thread.Join();
    }

    private delegate IntPtr KeyboardProc(int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] private static extern IntPtr SetWindowsHookExW(int type, KeyboardProc callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr GetModuleHandleW(string? name);
}
