using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;

namespace TapSnap.Windows;

internal sealed class Shortcuts : IDisposable
{
    private readonly HwndSource source = new(new HwndSourceParameters("TapSnapHotkeys")
    {
        ParentWindow = new IntPtr(-3),
        WindowStyle = 0
    });
    private readonly Dictionary<int, Action> handlers = new();

    private PriorityHotkeys? priority;
    public Shortcuts() => source.AddHook(Dispatch);

    public bool Bind(int id, Hotkey key, Action run, bool tryPriority, out bool usesPriority)
    {
        Unbind(id);
        usesPriority = false;
        if (RegisterHotKey(source.Handle, id, key.Modifiers | 0x4000, key.KeyCode))
        {
            handlers[id] = run;
            return true;
        }
        const int hotkeyAlreadyRegistered = 1409;
        if (!tryPriority || Marshal.GetLastWin32Error() != hotkeyAlreadyRegistered) return false;
        priority ??= new PriorityHotkeys();
        usesPriority = priority.Bind(id, key, () => source.Dispatcher.BeginInvoke(run));
        return usesPriority;
    }

    public void Unbind(int id)
    {
        if (handlers.Remove(id)) UnregisterHotKey(source.Handle, id);
        priority?.Remove(id);
    }

    private IntPtr Dispatch(IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled)
    {
        if (message == 0x0312 && handlers.TryGetValue(w.ToInt32(), out var run))
        {
            handled = true;
            _ = source.Dispatcher.BeginInvoke(run);
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        foreach (int id in handlers.Keys.ToArray()) Unbind(id);
        priority?.Dispose();
        source.Dispose();
    }

    internal static Hotkey FromEvent(KeyEventArgs args) =>
        new((uint)Keyboard.Modifiers, (uint)KeyInterop.VirtualKeyFromKey(EventKey(args)));

    private static Key EventKey(KeyEventArgs args) => args.Key == Key.System ? args.SystemKey : args.Key;

    internal static string Display(Hotkey hotkey)
    {
        Key key = KeyInterop.KeyFromVirtualKey((int)hotkey.KeyCode);
        string text = key switch
        {
            >= Key.D0 and <= Key.D9 => ((int)(key - Key.D0)).ToString(),
            Key.OemPlus => "=",
            Key.OemMinus => "−",
            Key.Add => "小键盘+",
            Key.Subtract => "小键盘−",
            _ => key.ToString()
        };
        uint modifiers = hotkey.Modifiers;
        return ((modifiers & 2) != 0 ? "Ctrl+" : "") + ((modifiers & 1) != 0 ? "Alt+" : "") +
               ((modifiers & 4) != 0 ? "Shift+" : "") + ((modifiers & 8) != 0 ? "Win+" : "") + text;
    }

    internal static string WithHint(string title, string? shortcut) => shortcut is null ? title : $"{title} {shortcut}";

    public static Hotkey? Record(Window owner, bool allowsSingleKeys = false)
    {
        var instructions = new TextBlock
        {
            Text = allowsSingleKeys ? "按下单键或组合键。Esc 取消，Delete 或退格键清除。"
                                   : "按下新的组合键。Esc 取消，退格键清除。",
            Margin = new Thickness(20), TextWrapping = TextWrapping.Wrap
        };
        var prompt = new Window
        {
            Title = "录制快捷键", Width = 330, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            Owner = owner, WindowStartupLocation = WindowStartupLocation.CenterOwner, Content = instructions
        };
        SnapTheme.StyleWindow(prompt);
        Hotkey? result = null;
        prompt.PreviewKeyDown += (_, e) =>
        {
            var key = EventKey(e);
            var modifiers = Keyboard.Modifiers;
            e.Handled = true;
            if (e.IsRepeat) return;
            if (key == Key.Escape) { prompt.Close(); return; }
            if ((key == Key.Back || (allowsSingleKeys && key == Key.Delete)) && modifiers == ModifierKeys.None)
            {
                result = new Hotkey(0, 0);
                prompt.DialogResult = true;
                return;
            }
            if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
                return;
            if (allowsSingleKeys && modifiers == ModifierKeys.None && key is Key.Enter or Key.Tab)
            {
                instructions.Text = "回车和 Tab 用于确认与切换焦点，请换一个键位。";
                return;
            }
            if (!allowsSingleKeys && (modifiers & (ModifierKeys.Alt | ModifierKeys.Control | ModifierKeys.Windows)) == 0 &&
                key is not (>= Key.F1 and <= Key.F24))
            {
                instructions.Text = "请使用 Ctrl、Alt 或 Win 组合键，也可以单独按 F1–F24。";
                return;
            }
            Hotkey binding = FromEvent(e);
            if (binding.KeyCode == 0) return;
            result = binding;
            prompt.DialogResult = true;
        };
        return prompt.ShowDialog() == true ? result : null;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hwnd, int id);
}
