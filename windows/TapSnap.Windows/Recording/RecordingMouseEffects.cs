using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace TapSnap.Windows;

internal static class RecordingMouseEffectCatalog
{
    public static readonly string[] ClickStyles =
    [
        "液态玻璃水波", "方框角标轻扣", "迷你鼠标亮键", "精密靶环合焦", "轨道一笔画弧",
        "极简微粒迸散", "触控玻璃压痕", "精密十字轻锁", "无框聚光微晕", "声纳极细三波",
        "双轨脉冲环", "棱镜菱形切晶", "露珠四瓣绽放", "键标微泡提示"
    ];

    public static readonly string[] ScrollStyles =
    [
        "液态滚动胶囊", "双层导向箭羽", "精密滚轮刻度", "轻盈水流尾迹", "方向弧波"
    ];

    public static readonly string[] Palettes =
    [
        "液态冰蓝", "纯净白晶", "徕卡橘红", "薄荷青翠", "香槟暖金"
    ];

    public static string ResolveClickStyle(string? raw) =>
        raw is not null && ClickStyles.Contains(raw) ? raw : ClickStyles[0];

    public static string ResolveScrollStyle(string? raw) =>
        raw is not null && ScrollStyles.Contains(raw) ? raw : ScrollStyles[0];

    public static string ResolvePalette(string? raw) =>
        raw is not null && Palettes.Contains(raw) ? raw : Palettes[0];

    public static (uint Left, uint Right) PaletteColors(string? palette) => ResolvePalette(palette) switch
    {
        "纯净白晶" => (0xffffffu, 0x93c5fdu),
        "徕卡橘红" => (0xfb7185u, 0xfbbf24u),
        "薄荷青翠" => (0x34d399u, 0x60a5fau),
        "香槟暖金" => (0xfbbf24u, 0xc084fcu),
        _ => (0x38bdf8u, 0xf472b6u)
    };
}

internal static class RecordingMouseEffectsArtwork
{
    private static double EaseOutCubic(double t) => 1 - Math.Pow(1 - Math.Clamp(t, 0, 1), 3);

    private static SolidColorBrush Brush(uint rgb, double alpha) =>
        SelectionBorder.BrushFor(rgb, Math.Clamp(alpha, 0, 1));

    private static Pen Pen(uint rgb, double width, double alpha, double[]? dashes = null)
    {
        var pen = new Pen(Brush(rgb, alpha), width)
        {
            StartLineCap = PenLineCap.Round,
            EndLineCap = PenLineCap.Round,
            LineJoin = PenLineJoin.Round
        };
        if (dashes != null) pen.DashStyle = new DashStyle(Array.ConvertAll(dashes, d => d / Math.Max(0.5, width)), 0);
        pen.Freeze();
        return pen;
    }

    public static void DrawClick(DrawingContext dc, string style, Point center, double progress,
        bool isRight, int clickCount, string palette, double scale)
    {
        double t = Math.Clamp(progress, 0, 1);
        double ease = EaseOutCubic(t);
        double fade = Math.Clamp(1 - Math.Pow(t, 1.55), 0, 1);
        if (fade <= 0.01) return;

        var (leftRgb, rightRgb) = RecordingMouseEffectCatalog.PaletteColors(palette);
        uint rgb = isRight ? rightRgb : leftRgb;
        uint altRgb = isRight ? leftRgb : rightRgb;
        double u = Math.Clamp(scale, 0.7, 1.5);
        double boost = clickCount >= 2 ? 1.18 : 1.0;

        switch (RecordingMouseEffectCatalog.ResolveClickStyle(style))
        {
            case "方框角标轻扣":
            {
                double half = (12 + 12 * ease) * u * boost;
                double arm = 7.5 * u;
                var pen = Pen(rgb, 2.2 * u, fade);
                foreach (int sx in new[] { -1, 1 })
                foreach (int sy in new[] { -1, 1 })
                {
                    var corner = new Point(center.X + sx * half, center.Y + sy * half);
                    dc.DrawLine(pen, corner, new Point(corner.X - sx * arm, corner.Y));
                    dc.DrawLine(pen, corner, new Point(corner.X, corner.Y - sy * arm));
                }
                break;
            }
            case "迷你鼠标亮键":
            {
                double w = 16 * u, h = 23 * u;
                var body = new Rect(center.X - w / 2, center.Y - h / 2, w, h);
                dc.DrawRoundedRectangle(Brush(0x0f172au, 0.72 * fade), Pen(0xffffffu, 1.4 * u, 0.85 * fade), body, w * 0.45, w * 0.45);
                var btnRect = new Rect(isRight ? center.X : body.Left + 1.5, body.Top + 1.5, w / 2 - 1.5, h * 0.44);
                dc.DrawRoundedRectangle(Brush(rgb, 0.92 * fade), null, btnRect, 3 * u, 3 * u);
                break;
            }
            case "精密靶环合焦":
            {
                double outer = (26 - 12 * ease) * u * boost;
                double inner = (7 + 6 * ease) * u;
                dc.DrawEllipse(null, Pen(rgb, 1.8 * u, fade), center, outer, outer);
                dc.DrawEllipse(null, Pen(0xffffffu, 1.2 * u, 0.85 * fade), center, inner, inner);
                dc.DrawEllipse(Brush(rgb, fade), null, center, 2.4 * u, 2.4 * u);
                break;
            }
            case "轨道一笔画弧":
            {
                double r = (10 + 16 * ease) * u * boost;
                double a0 = -Math.PI / 2 + t * Math.PI * 1.4;
                double sweep = Math.PI * (1.35 - 0.55 * t);
                DrawArc(dc, center, r, a0, a0 + sweep, Pen(rgb, 2.6 * u, fade));
                break;
            }
            case "极简微粒迸散":
            {
                int count = clickCount >= 2 ? 10 : 8;
                double dist = (7 + 20 * ease) * u;
                for (int i = 0; i < count; i++)
                {
                    double ang = i * (Math.PI * 2 / count) + (isRight ? 0.3 : 0);
                    var p = new Point(center.X + Math.Cos(ang) * dist, center.Y + Math.Sin(ang) * dist);
                    double pr = (2.6 - 1.4 * t) * u;
                    dc.DrawEllipse(Brush(i % 2 == 0 ? rgb : 0xffffffu, fade), null, p, pr, pr);
                }
                break;
            }
            case "触控玻璃压痕":
            {
                double r = (14 + 8 * ease) * u * boost;
                dc.DrawEllipse(Brush(rgb, 0.24 * fade), Pen(0xffffffu, 1.6 * u, 0.78 * fade), center, r, r);
                dc.DrawEllipse(Brush(rgb, 0.48 * fade), null, center, r * 0.45, r * 0.45);
                break;
            }
            case "精密十字轻锁":
            {
                double gap = (4 + 8 * ease) * u;
                double len = (10 + 4 * ease) * u;
                var pen = Pen(rgb, 2.0 * u, fade);
                dc.DrawLine(pen, new Point(center.X - gap - len, center.Y), new Point(center.X - gap, center.Y));
                dc.DrawLine(pen, new Point(center.X + gap, center.Y), new Point(center.X + gap + len, center.Y));
                dc.DrawLine(pen, new Point(center.X, center.Y - gap - len), new Point(center.X, center.Y - gap));
                dc.DrawLine(pen, new Point(center.X, center.Y + gap), new Point(center.X, center.Y + gap + len));
                break;
            }
            case "无框聚光微晕":
            {
                double r = (16 + 18 * ease) * u * boost;
                dc.DrawEllipse(Brush(rgb, 0.16 * fade), null, center, r, r);
                dc.DrawEllipse(Brush(rgb, 0.28 * fade), null, center, r * 0.62, r * 0.62);
                dc.DrawEllipse(Brush(0xffffffu, 0.45 * fade), null, center, r * 0.25, r * 0.25);
                break;
            }
            case "声纳极细三波":
            {
                for (int i = 0; i < 3; i++)
                {
                    double local = Math.Clamp(t * 1.35 - i * 0.18, 0, 1);
                    if (local <= 0) continue;
                    double r = (6 + 24 * EaseOutCubic(local)) * u * boost;
                    dc.DrawEllipse(null, Pen(rgb, 1.2 * u, (1 - local) * 0.9), center, r, r);
                }
                break;
            }
            case "双轨脉冲环":
            {
                double r1 = (9 + 19 * ease) * u * boost;
                double r2 = (6 + 12 * ease) * u * boost;
                dc.DrawEllipse(null, Pen(rgb, 2.4 * u, fade), center, r1, r1);
                dc.DrawEllipse(null, Pen(altRgb, 1.5 * u, fade * 0.85, [4 * u, 3 * u]), center, r2, r2);
                break;
            }
            case "棱镜菱形切晶":
            {
                double r = (10 + 16 * ease) * u * boost;
                var geo = new StreamGeometry();
                using (var ctx = geo.Open())
                {
                    ctx.BeginFigure(new Point(center.X, center.Y - r), true, true);
                    ctx.LineTo(new Point(center.X + r, center.Y), true, false);
                    ctx.LineTo(new Point(center.X, center.Y + r), true, false);
                    ctx.LineTo(new Point(center.X - r, center.Y), true, false);
                }
                geo.Freeze();
                dc.DrawGeometry(Brush(rgb, 0.18 * fade), Pen(rgb, 2.0 * u, fade), geo);
                break;
            }
            case "露珠四瓣绽放":
            {
                double dist = (6 + 13 * ease) * u * boost;
                double pr = (4.5 - 1.5 * t) * u;
                for (int i = 0; i < 4; i++)
                {
                    double ang = Math.PI / 4 + i * Math.PI / 2;
                    dc.DrawEllipse(Brush(rgb, 0.72 * fade), Pen(0xffffffu, 1.0 * u, 0.7 * fade),
                        new Point(center.X + Math.Cos(ang) * dist, center.Y + Math.Sin(ang) * dist), pr, pr);
                }
                break;
            }
            case "键标微泡提示":
            {
                string label = clickCount >= 2 ? "2×" : (isRight ? "R" : "L");
                double y = center.Y - (14 + 10 * ease) * u;
                var box = new Rect(center.X - 13 * u, y - 9 * u, 26 * u, 18 * u);
                dc.DrawRoundedRectangle(Brush(rgb, 0.90 * fade), Pen(0xffffffu, 1.2 * u, 0.85 * fade), box, 9 * u, 9 * u);
                var text = new FormattedText(label, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                    new Typeface("Segoe UI Semibold"), 10.5 * u, Brush(0x0f172au, fade), 1);
                dc.DrawText(text, new Point(center.X - text.Width / 2, y - text.Height / 2));
                break;
            }
            default: // 液态玻璃水波
            {
                double r = (8 + 22 * ease) * u * boost;
                dc.DrawEllipse(Brush(rgb, 0.14 * fade), Pen(rgb, 2.6 * u, fade), center, r, r);
                dc.DrawEllipse(null, Pen(0xffffffu, 1.2 * u, 0.85 * fade), center, r * 0.72, r * 0.72);
                if (clickCount >= 2)
                    dc.DrawEllipse(null, Pen(altRgb, 1.6 * u, fade * 0.8), center, r * 1.24, r * 1.24);
                break;
            }
        }
    }

    public static void DrawScroll(DrawingContext dc, string style, Point center, double alpha,
        double direction, double accumulated, double time, string palette, double scale)
    {
        double a = Math.Clamp(alpha, 0, 1);
        if (a <= 0.01) return;
        var (leftRgb, rightRgb) = RecordingMouseEffectCatalog.PaletteColors(palette);
        uint rgb = direction >= 0 ? leftRgb : rightRgb;
        double u = Math.Clamp(scale, 0.7, 1.5);
        double dir = direction >= 0 ? 1 : -1;

        switch (RecordingMouseEffectCatalog.ResolveScrollStyle(style))
        {
            case "双层导向箭羽":
            {
                var pen = Pen(rgb, 2.2 * u, a);
                for (int i = 0; i < 2; i++)
                {
                    double oy = dir * (-5 + i * 7 + ((time * 18) % 6));
                    var tip = new Point(center.X, center.Y + oy + dir * 4 * u);
                    dc.DrawLine(pen, new Point(center.X - 6 * u, center.Y + oy), tip);
                    dc.DrawLine(pen, new Point(center.X + 6 * u, center.Y + oy), tip);
                }
                break;
            }
            case "精密滚轮刻度":
            {
                var box = new Rect(center.X - 6 * u, center.Y - 14 * u, 12 * u, 28 * u);
                dc.DrawRoundedRectangle(Brush(0x0f172au, 0.72 * a), Pen(rgb, 1.5 * u, a), box, 6 * u, 6 * u);
                double offset = ((accumulated * 0.35) % 6 + 6) % 6;
                for (double y = box.Top + 4 + offset; y < box.Bottom - 3; y += 6)
                    dc.DrawLine(Pen(0xffffffu, 1.3 * u, 0.85 * a), new Point(box.Left + 3 * u, y), new Point(box.Right - 3 * u, y));
                break;
            }
            case "轻盈水流尾迹":
            {
                for (int i = 0; i < 4; i++)
                {
                    double frac = 1 - i * 0.22;
                    double y = center.Y - dir * i * 6.5 * u;
                    double r = (4.2 - i * 0.8) * u;
                    dc.DrawEllipse(Brush(rgb, a * frac * 0.85), null, new Point(center.X, y), r, r);
                }
                break;
            }
            case "方向弧波":
            {
                double baseAngle = dir > 0 ? Math.PI / 2 : -Math.PI / 2;
                for (int i = 0; i < 2; i++)
                {
                    double r = (10 + i * 6 + ((time * 16) % 5)) * u;
                    DrawArc(dc, center, r, baseAngle - 0.65, baseAngle + 0.65, Pen(rgb, 2.0 * u, a * (1 - i * 0.35)));
                }
                break;
            }
            default: // 液态滚动胶囊
            {
                var pill = new Rect(center.X - 9 * u, center.Y - 16 * u, 18 * u, 32 * u);
                dc.DrawRoundedRectangle(Brush(0x0f172au, 0.68 * a), Pen(rgb, 1.6 * u, a), pill, 9 * u, 9 * u);
                double dotY = center.Y + dir * (4.5 * u + Math.Sin(time * 9) * 2.5 * u);
                dc.DrawEllipse(Brush(rgb, a), null, new Point(center.X, dotY), 3.4 * u, 3.4 * u);
                break;
            }
        }
    }

    private static void DrawArc(DrawingContext dc, Point center, double radius, double startAngle, double endAngle, Pen pen)
    {
        var p0 = new Point(center.X + Math.Cos(startAngle) * radius, center.Y + Math.Sin(startAngle) * radius);
        var p1 = new Point(center.X + Math.Cos(endAngle) * radius, center.Y + Math.Sin(endAngle) * radius);
        bool largeArc = Math.Abs(endAngle - startAngle) > Math.PI;
        var geo = new StreamGeometry();
        using (var ctx = geo.Open())
        {
            ctx.BeginFigure(p0, false, false);
            ctx.ArcTo(p1, new Size(radius, radius), 0, largeArc, SweepDirection.Clockwise, true, false);
        }
        geo.Freeze();
        dc.DrawGeometry(null, pen, geo);
    }
}

internal sealed class MouseWheelHook : IDisposable
{
    private const int WhMouseLl = 14;
    private const int WmMouseWheel = 0x020A;
    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
    private readonly HookProc proc;
    private IntPtr hook;
    public event Action<int>? Scrolled;

    public MouseWheelHook()
    {
        proc = Callback;
        hook = SetWindowsHookExW(WhMouseLl, proc, IntPtr.Zero, 0);
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && wParam == (IntPtr)WmMouseWheel)
        {
            var data = Marshal.PtrToStructure<MsLlHookStruct>(lParam);
            short delta = (short)((data.MouseData >> 16) & 0xFFFF);
            if (delta != 0) Scrolled?.Invoke(delta);
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MsLlHookStruct { public int X, Y; public uint MouseData, Flags, Time; public IntPtr ExtraInfo; }
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookExW(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
}

internal sealed class RecordingMouseEffectsPreview : FrameworkElement
{
    private readonly record struct LiveClick(Point Point, double Born, bool IsRight, int ClickCount);
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly List<LiveClick> liveClicks = [];
    private (Point Point, double Direction, double Accumulated, double LastTime)? liveScroll;
    private double lastLeftClick = -10;
    private bool listening;

    public bool ShowsClicks { get; set; } = true;
    public bool ShowsScrolls { get; set; } = true;
    public string ClickStyle { get; set; } = RecordingMouseEffectCatalog.ClickStyles[0];
    public string ScrollStyle { get; set; } = RecordingMouseEffectCatalog.ScrollStyles[0];
    public string Palette { get; set; } = RecordingMouseEffectCatalog.Palettes[0];
    public double EffectScale { get; set; } = 1.0;

    public RecordingMouseEffectsPreview()
    {
        ToolTip = "可在预览区内直接左键、右键、双击或滚轮试看效果";
        IsVisibleChanged += (_, _) => UpdateListen();
        Unloaded += (_, _) => SetListen(false);
        MouseLeftButtonDown += (_, e) =>
        {
            if (!ShowsClicks) return;
            double now = clock.Elapsed.TotalSeconds;
            bool dbl = now - lastLeftClick < 0.30;
            lastLeftClick = now;
            liveClicks.Add(new(e.GetPosition(this), now, false, dbl ? 2 : 1));
            InvalidateVisual();
        };
        MouseRightButtonDown += (_, e) =>
        {
            if (!ShowsClicks) return;
            liveClicks.Add(new(e.GetPosition(this), clock.Elapsed.TotalSeconds, true, 1));
            InvalidateVisual();
        };
        MouseWheel += (_, e) =>
        {
            if (!ShowsScrolls) return;
            double dir = e.Delta < 0 ? 1 : -1;
            double prev = liveScroll?.Accumulated ?? 0;
            liveScroll = (e.GetPosition(this), dir, prev + dir * 24, clock.Elapsed.TotalSeconds);
            InvalidateVisual();
            e.Handled = true;
        };
    }

    public void Refresh()
    {
        UpdateListen();
        InvalidateVisual();
    }

    private void UpdateListen() => SetListen(IsVisible && (ShowsClicks || ShowsScrolls) && SystemParameters.ClientAreaAnimation);

    private void SetListen(bool enable)
    {
        if (listening == enable) return;
        listening = enable;
        if (enable) CompositionTarget.Rendering += OnRenderTick;
        else CompositionTarget.Rendering -= OnRenderTick;
    }

    private void OnRenderTick(object? sender, EventArgs args) => InvalidateVisual();

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w < 4 || h < 4) return;
        dc.DrawRectangle(SnapTheme.Brush(0xf5f7fau), null, new Rect(0, 0, w / 2, h));
        dc.DrawRectangle(SnapTheme.Brush(0x161c25u), null, new Rect(w / 2, 0, w - w / 2, h));

        double now = clock.Elapsed.TotalSeconds;
        liveClicks.RemoveAll(c => now - c.Born > 0.65);

        if (ShowsClicks)
        {
            if (liveClicks.Count > 0)
            {
                foreach (var item in liveClicks)
                    RecordingMouseEffectsArtwork.DrawClick(dc, ClickStyle, item.Point, (now - item.Born) / 0.62,
                        item.IsRight, item.ClickCount, Palette, EffectScale);
            }
            else
            {
                const double period = 1.45;
                double cycle = now % (period * 2);
                bool isRight = cycle >= period;
                double u = (cycle % period) / 0.68;
                if (u <= 1)
                    RecordingMouseEffectsArtwork.DrawClick(dc, ClickStyle, new Point(w * (isRight ? 0.68 : 0.28), h * 0.5),
                        u, isRight, 1, Palette, EffectScale);
            }
        }

        if (ShowsScrolls)
        {
            if (liveScroll is { } s && now - s.LastTime < 0.55)
            {
                double age = now - s.LastTime;
                double alpha = age < 0.24 ? 1.0 : Math.Max(0, 1 - (age - 0.24) / 0.30);
                RecordingMouseEffectsArtwork.DrawScroll(dc, ScrollStyle, s.Point, alpha, s.Direction, s.Accumulated, now, Palette, EffectScale);
            }
            else
            {
                double dir = (now % 3.6) < 1.8 ? 1 : -1;
                RecordingMouseEffectsArtwork.DrawScroll(dc, ScrollStyle, new Point(w * (ShowsClicks ? 0.48 : 0.50), h * 0.5),
                    0.95, dir, now * 38 * dir, now, Palette, EffectScale);
            }
        }
    }
}
