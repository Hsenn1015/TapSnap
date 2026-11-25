using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Media;

namespace TapSnap.Windows;

internal static class SelectionBorderCatalog
{
    public static readonly string[] Styles =
    [
        "液态玻璃", "光学取景器", "瑞士极简线", "精致像素工艺", "阳极钛金属", "匠心缝线", "双翼锁角"
    ];

    public static string ResolveStyle(string? raw) => raw switch
    {
        "液态玻璃" or "极光" or "冰蓝薄荷" or "冷白追光" => "液态玻璃",
        "光学取景器" or "四角取景" => "光学取景器",
        "瑞士极简线" or "黑白双线" => "瑞士极简线",
        "精致像素工艺" or "像素阶梯" => "精致像素工艺",
        "阳极钛金属" or "双色套印" => "阳极钛金属",
        "匠心缝线" or "布纹缝线" => "匠心缝线",
        "双翼锁角" or "琥珀虚线" => "双翼锁角",
        _ => "液态玻璃"
    };

    public static string[] MotionsFor(string style) => ResolveStyle(style) switch
    {
        "液态玻璃" => ["静谧折光", "水膜呼吸", "双液滴对滑", "四角折晶", "棱镜缓转", "水光垂拂"],
        "光学取景器" => ["对焦轻合", "测距扫描", "光圈呼吸"],
        "瑞士极简线" => ["现代丝滑虚线", "笔尖单丝滑行", "精密十字节点"],
        "精致像素工艺" => ["点阵步进", "像素角标轻跳", "像素扫屏"],
        "阳极钛金属" => ["拉丝掠光", "双面镜棱", "冷冽呼吸"],
        "匠心缝线" => ["慢针走线", "丝线光泽", "四角锁针"],
        "双翼锁角" => ["双翼锁角", "刻度波浪", "脉冲信标"],
        _ => ["静谧折光"]
    };

    public static string[] PalettesFor(string style) => ResolveStyle(style) switch
    {
        "液态玻璃" => ["冰川白晶", "海盐薄荷", "暮雾银紫", "香槟珠光", "极夜钛蓝", "珍珠母贝"],
        "光学取景器" => ["徕卡红白", "哈苏冷钛", "电影冷青", "夜视琥珀"],
        "瑞士极简线" => ["瑞士黑白", "Linear 靛蓝", "博朗国际橙", "松石翡翠"],
        "精致像素工艺" => ["霓虹紫青", "掌机翠绿", "琥珀终端", "薄荷桃子"],
        "阳极钛金属" => ["原色钛金", "沙漠金钛", "深空黑钛", "冰蓝铝钛"],
        "匠心缝线" => ["鞍革焦糖", "丹宁靛蓝", "英伦墨绿", "亚麻炭灰"],
        "双翼锁角" => ["TE 工程橘", "示波荧光绿", "航电冰蓝", "星舰琥珀"],
        _ => ["冰川白晶"]
    };

    public static string ResolveMotion(string style, string? motion)
    {
        var list = MotionsFor(style);
        return motion is not null && list.Contains(motion) ? motion : list[0];
    }

    public static string ResolvePalette(string style, string? palette)
    {
        var list = PalettesFor(style);
        return palette is not null && list.Contains(palette) ? palette : list[0];
    }

    public static (uint Primary, uint Secondary, uint Accent) ColorsFor(string palette) => palette switch
    {
        // 液态玻璃
        "冰川白晶" => (0xdbf4ffu, 0x67d8ffu, 0xffffffu),
        "海盐薄荷" => (0xa7f3d0u, 0x38bdf8u, 0xecfdf5u),
        "暮雾银紫" => (0xd8b4feu, 0x818cf8u, 0xf5f3ffu),
        "香槟珠光" => (0xfde68au, 0xfba974u, 0xfffbebu),
        "极夜钛蓝" => (0x60a5fau, 0x1e40afu, 0xdbeafeu),
        "珍珠母贝" => (0xf9a8d4u, 0x67e8f9u, 0xfefce8u),
        // 光学取景器
        "徕卡红白" => (0xf8fafcu, 0x1e293bu, 0xef4444u),
        "哈苏冷钛" => (0xcbd5e1u, 0x334155u, 0xf97316u),
        "电影冷青" => (0x67e8f9u, 0x0f172au, 0x22d3eeu),
        "夜视琥珀" => (0xfbbf24u, 0x451a03u, 0xfde047u),
        // 瑞士极简线
        "瑞士黑白" => (0xffffffu, 0x18181bu, 0xef4444u),
        "Linear 靛蓝" => (0x818cf8u, 0x1e1b4bu, 0xc7d2feu),
        "博朗国际橙" => (0xf97316u, 0x27272au, 0xfed7aau),
        "松石翡翠" => (0x10b981u, 0x064e3bu, 0xa7f3d0u),
        // 精致像素工艺
        "霓虹紫青" => (0xc084fcu, 0x22d3eeu, 0x38bdf8u),
        "掌机翠绿" => (0x84cc16u, 0x14532du, 0xd9f99du),
        "琥珀终端" => (0xf59e0bu, 0x451a03u, 0xfef08au),
        "薄荷桃子" => (0x6ee7b7u, 0xfb7185u, 0xfde68au),
        // 阳极钛金属
        "原色钛金" => (0xd6d3d1u, 0x57534eu, 0xfafaf9u),
        "沙漠金钛" => (0xe7c89au, 0x78593bu, 0xfef3c7u),
        "深空黑钛" => (0x94a3b8u, 0x1e293bu, 0xe2e8f0u),
        "冰蓝铝钛" => (0x93c5fdu, 0x1e3a8au, 0xeff6ffu),
        // 匠心缝线
        "鞍革焦糖" => (0xf3d5a5u, 0x7c3f1du, 0xf59e0bu),
        "丹宁靛蓝" => (0xbfdbfeu, 0x1e3a5fu, 0xfbbf24u),
        "英伦墨绿" => (0xd1fae5u, 0x14532du, 0xf59e0bu),
        "亚麻炭灰" => (0xe5e7ebu, 0x374151u, 0xfca5a5u),
        // 双翼锁角
        "TE 工程橘" => (0xff6b2bu, 0x27272au, 0xfef08au),
        "示波荧光绿" => (0x34d399u, 0x064e3bu, 0xa7f3d0u),
        "航电冰蓝" => (0x38bdf8u, 0x0c4a6eu, 0xe0f2feu),
        "星舰琥珀" => (0xfbbf24u, 0x451a03u, 0xfef9c3u),
        _ => (0xdbf4ffu, 0x67d8ffu, 0xffffffu)
    };
}

internal sealed class SelectionBorder : FrameworkElement
{
    private const int GradientSegments = 56;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private Rect rim = Rect.Empty;
    private string style;
    private string motion;
    private string palette;
    private bool handles;
    private bool listening;
    private Geometry[]? gradientPath;

    public SelectionBorder(string style, string? motion = null, string? palette = null)
    {
        this.style = SelectionBorderCatalog.ResolveStyle(style);
        this.motion = SelectionBorderCatalog.ResolveMotion(this.style, motion);
        this.palette = SelectionBorderCatalog.ResolvePalette(this.style, palette);
        IsHitTestVisible = false;
        Unloaded += (_, _) => Listen(false);
        IsVisibleChanged += (_, _) => Refresh();
    }

    public static Rect Outline(Rect selection, Rect bounds)
    {
        if (selection.IsEmpty || bounds.Width < 10 || bounds.Height < 10) return Rect.Empty;
        selection.Inflate(8, 8);
        bounds.Inflate(-5, -5);
        return Rect.Intersect(selection, bounds);
    }

    public static Point[] Handles(Rect r) =>
    [
        r.TopLeft, new((r.Left + r.Right) / 2, r.Top), r.TopRight,
        new(r.Right, (r.Top + r.Bottom) / 2), r.BottomRight,
        new((r.Left + r.Right) / 2, r.Bottom), r.BottomLeft, new(r.Left, (r.Top + r.Bottom) / 2)
    ];

    public void Update(Rect outline, bool showsHandles, string? nextStyle = null, string? nextMotion = null, string? nextPalette = null)
    {
        if (rim != outline) gradientPath = null;
        rim = outline;
        handles = showsHandles;
        if (nextStyle != null) style = SelectionBorderCatalog.ResolveStyle(nextStyle);
        motion = SelectionBorderCatalog.ResolveMotion(style, nextMotion ?? motion);
        palette = SelectionBorderCatalog.ResolvePalette(style, nextPalette ?? palette);
        Refresh();
    }

    private void Refresh()
    {
        Listen(!rim.IsEmpty && IsVisible && SystemParameters.ClientAreaAnimation);
        InvalidateVisual();
    }

    private void Listen(bool enable)
    {
        if (listening == enable) return;
        listening = enable;
        if (enable) CompositionTarget.Rendering += Animate;
        else CompositionTarget.Rendering -= Animate;
    }

    private void Animate(object? sender, EventArgs args) => InvalidateVisual();

    protected override void OnRender(DrawingContext context)
    {
        if (rim.IsEmpty || rim.Width < 1 || rim.Height < 1) return;
        double elapsed = listening ? clock.Elapsed.TotalSeconds : 0;
        double phase = (elapsed / 3.2) % 1.0;
        double breathe = 0.5 + 0.5 * Math.Sin(elapsed * Math.PI * 0.85);
        var (primary, secondary, accent) = SelectionBorderCatalog.ColorsFor(palette);

        var sharp = new RectangleGeometry(rim);
        var rounded = new RectangleGeometry(rim, 4, 4);
        void Stroke(Geometry g, uint color, double width, double alpha = 1, double[]? dashes = null, double dashOffset = 0) =>
            context.DrawGeometry(null, PenFor(color, width, alpha, dashes, dashOffset), g);

        switch (style)
        {
            case "液态玻璃":
            {
                double haloAlpha = motion == "水膜呼吸" ? 0.14 + 0.16 * breathe : 0.16;
                Stroke(rounded, secondary, 14, haloAlpha * 0.65);
                Stroke(rounded, 0x0f172au, 3.6, 0.30);
                DrawGradient(context, [primary, secondary, accent, primary],
                    motion == "棱镜缓转" ? phase : phase * 0.35, 2.2, haloAlpha);
                if (listening)
                {
                    bool dual = motion is "双液滴对滑" or "四角折晶";
                    DrawSweeps(context, phase, dual, primary, accent);
                }
                break;
            }
            case "光学取景器":
            {
                Stroke(sharp, secondary, 3.0, 0.55);
                Stroke(sharp, primary, 1.0, motion == "光圈呼吸" ? 0.45 + 0.4 * breathe : 0.72);
                if (listening && motion == "测距扫描")
                {
                    double scanY = rim.Top + rim.Height * ((elapsed * 0.42) % 1.0);
                    context.DrawLine(PenFor(accent, 1.2, 0.55), new Point(rim.Left + 4, scanY), new Point(rim.Right - 4, scanY));
                }
                break;
            }
            case "瑞士极简线":
            {
                Stroke(sharp, secondary, 3.2, 0.68);
                if (motion == "现代丝滑虚线")
                    Stroke(sharp, primary, 1.5, 0.95, [6, 4], -elapsed * 18);
                else
                {
                    Stroke(sharp, primary, 1.4, 0.92);
                    if (listening && motion == "笔尖单丝滑行")
                        DrawSweeps(context, phase, false, accent, primary);
                }
                break;
            }
            case "精致像素工艺":
            {
                Stroke(sharp, secondary, 3.4, 0.78);
                double stepOffset = motion == "点阵步进" ? -Math.Floor(elapsed * 8) * 3 : 0;
                Stroke(sharp, primary, 1.6, 0.95, [3, 3], stepOffset);
                if (listening && motion == "像素扫屏")
                {
                    double scanY = rim.Top + Math.Floor(((elapsed * 0.5) % 1.0) * rim.Height / 4) * 4;
                    context.DrawLine(PenFor(accent, 2, 0.45), new Point(rim.Left, scanY), new Point(rim.Right, scanY));
                }
                break;
            }
            case "阳极钛金属":
            {
                double metallicAlpha = motion == "冷冽呼吸" ? 0.68 + 0.28 * breathe : 0.90;
                Stroke(rounded, secondary, 4.2, 0.72);
                Stroke(rounded, primary, 1.9, metallicAlpha);
                var inner = rim;
                inner.Inflate(-1.1, -1.1);
                if (!inner.IsEmpty) Stroke(new RectangleGeometry(inner, 3, 3), accent, 0.9, 0.72);
                if (listening && motion is "拉丝掠光" or "双面镜棱")
                    DrawSweeps(context, phase, motion == "双面镜棱", primary, accent);
                break;
            }
            case "匠心缝线":
            {
                Stroke(sharp, secondary, 6.2, 0.86);
                double stitchOffset = motion == "慢针走线" ? -elapsed * 12 : 0;
                Stroke(sharp, primary, 1.3, 0.96, [4, 3], stitchOffset);
                if (listening && motion == "丝线光泽")
                    DrawSweeps(context, phase, false, accent, primary);
                break;
            }
            case "双翼锁角":
            {
                Stroke(sharp, secondary, 3.4, 0.65);
                Stroke(sharp, primary, 1.6, 0.88, motion == "刻度波浪" ? [8, 3] : null, -elapsed * 16);
                if (listening && motion == "脉冲信标")
                {
                    double r = 3.5 + 3.5 * breathe;
                    context.DrawEllipse(BrushFor(accent, 0.85), null, new Point(rim.Right - 10, rim.Top + 10), r * 0.5, r * 0.5);
                    context.DrawEllipse(null, PenFor(primary, 1.2, 1 - breathe * 0.7), new Point(rim.Right - 10, rim.Top + 10), r, r);
                }
                break;
            }
        }

        DrawHandles(context, primary, secondary, accent, breathe);
    }

    private void DrawGradient(DrawingContext context, uint[] colors, double phase, double width, double halo)
    {
        if (gradientPath == null)
        {
            double perimeter = 2 * (rim.Width + rim.Height);
            gradientPath = new Geometry[GradientSegments];
            for (int i = 0; i < gradientPath.Length; i++)
            {
                var segment = Segment(i * perimeter / GradientSegments, (i + 1) * perimeter / GradientSegments + .65);
                segment.Freeze();
                gradientPath[i] = segment;
            }
        }
        for (int i = 0; i < gradientPath.Length; i++)
        {
            var path = gradientPath[i];
            double progress = ((i / (double)GradientSegments + phase) % 1 + 1) % 1 * colors.Length;
            int left = (int)progress % colors.Length;
            uint color = Blend(colors[left], colors[(left + 1) % colors.Length], progress - Math.Floor(progress));
            if (halo > 0) context.DrawGeometry(null, PenFor(color, 10, halo), path);
            context.DrawGeometry(null, PenFor(color, width), path);
        }
    }

    private void DrawSweeps(DrawingContext context, double phase, bool two, uint glowColor, uint headColor)
    {
        double perimeter = 2 * (rim.Width + rim.Height);
        double spacing = two ? perimeter / 2 : perimeter;
        double length = Math.Min(two ? 78 : 74, spacing * (two ? 0.22 : 0.18));
        for (int i = 0; i < (two ? 2 : 1); i++)
        {
            double end = (phase % 1 + i) * spacing;
            var glow = Segment(end - length, end);
            var trail = Segment(end - length * .55, end);
            var head = Segment(end - length * .20, end);
            context.DrawGeometry(null, PenFor(glowColor, two ? 12 : 8, .22), glow);
            context.DrawGeometry(null, PenFor(glowColor, two ? 4 : 2.6, .62), trail);
            context.DrawGeometry(null, PenFor(headColor, two ? 2 : 1.5), head);
        }
    }

    private Geometry Segment(double start, double end)
    {
        double perimeter = 2 * (rim.Width + rim.Height);
        double Distance(double length) => ((length % perimeter) + perimeter) % perimeter;
        Point At(double length)
        {
            double value = Distance(length);
            if (value <= rim.Width) return new(rim.Left + value, rim.Top);
            value -= rim.Width;
            if (value <= rim.Height) return new(rim.Right, rim.Top + value);
            value -= rim.Height;
            if (value <= rim.Width) return new(rim.Right - value, rim.Bottom);
            return new(rim.Left, rim.Bottom - (value - rim.Width));
        }
        var geometry = new StreamGeometry();
        using (var path = geometry.Open())
        {
            path.BeginFigure(At(start), false, false);
            double cycle = Math.Floor(start / perimeter) * perimeter;
            double[] corners = [rim.Width, rim.Width + rim.Height, 2 * rim.Width + rim.Height, perimeter];
            for (var offset = cycle; offset < end; offset += perimeter)
                foreach (double corner in corners)
                    if (offset + corner > start && offset + corner < end) path.LineTo(At(offset + corner), true, false);
            path.LineTo(At(end), true, false);
        }
        return geometry;
    }

    private void DrawHandles(DrawingContext context, uint primary, uint secondary, uint accent, double breathe)
    {
        var points = Handles(rim);
        double extent = Math.Min(rim.Width, rim.Height) * .36;
        for (int i = 0; i < points.Length; i++)
        {
            var point = points[i];
            if (i % 2 != 0 && !handles) continue;
            if (i % 2 == 0)
            {
                double xAxis = i is 0 or 6 ? 1 : -1, yAxis = i is 0 or 2 ? 1 : -1;
                Point Rel(double x, double y) => new(point.X + x * xAxis, point.Y + y * yAxis);
                if (style is "光学取景器" or "双翼锁角")
                {
                    double inset = (style == "光学取景器" && motion == "对焦轻合") || (style == "双翼锁角" && motion == "双翼锁角")
                        ? 2.2 * (1 - breathe) : 0;
                    var corner = Rel(-inset, -inset);
                    double len = Math.Min(style == "双翼锁角" ? 20 : 16, extent);
                    var path = Poly([new Point(corner.X, corner.Y + len * yAxis), corner, new Point(corner.X + len * xAxis, corner.Y)], false);
                    context.DrawGeometry(null, PenFor(secondary, 4.6), path);
                    context.DrawGeometry(null, PenFor(i == 4 ? accent : primary, 2.8), path);
                    continue;
                }
                if (style == "精致像素工艺")
                {
                    double s = Math.Min(1, extent / 16);
                    var path = Poly([Rel(-2*s,-2*s), Rel(16*s,-2*s), Rel(16*s,2*s),
                        Rel(9*s,2*s), Rel(9*s,5*s), Rel(5*s,5*s), Rel(5*s,9*s),
                        Rel(2*s,9*s), Rel(2*s,16*s), Rel(-2*s,16*s)], true);
                    context.DrawGeometry(BrushFor(i == 4 ? accent : primary), PenFor(secondary, 1.2), path);
                    continue;
                }
                if (style == "匠心缝线")
                {
                    context.DrawRectangle(BrushFor(secondary), null, new Rect(point.X - 3.5, point.Y - 3.5, 7, 7));
                    var stitch = PenFor(i == 4 ? accent : primary, 1.2);
                    context.DrawLine(stitch, Rel(-2.7, -2.7), Rel(2.7, 2.7));
                    context.DrawLine(stitch, Rel(-2.7, 2.7), Rel(2.7, -2.7));
                    continue;
                }
                if (!handles) continue;
            }
            double size = style == "液态玻璃" || i % 2 == 0 ? 7 : 6;
            var bounds = new Rect(point.X - size / 2, point.Y - size / 2, size, size);
            context.DrawRoundedRectangle(BrushFor(i == 4 ? accent : primary),
                PenFor(secondary, style == "液态玻璃" ? 1.4 : 1.1), bounds, 1.8, 1.8);
        }
    }

    private static Geometry Poly(Point[] points, bool closed)
    {
        var path = new StreamGeometry();
        using (var output = path.Open())
        {
            output.BeginFigure(points[0], closed, closed);
            for (int i = 1; i < points.Length; i++) output.LineTo(points[i], true, false);
        }
        return path;
    }

    internal static SolidColorBrush BrushFor(uint rgb, double opacity = 1)
    {
        var brush = new SolidColorBrush(Color.FromArgb((byte)(Math.Clamp(opacity, 0, 1) * 255), (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        brush.Freeze();
        return brush;
    }

    private static Pen PenFor(uint rgb, double width, double opacity = 1, double[]? dashes = null, double dashOffset = 0)
    {
        var pen = new Pen(BrushFor(rgb, opacity), width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        if (dashes != null) pen.DashStyle = new DashStyle(Array.ConvertAll(dashes, length => length / width), dashOffset / width);
        pen.Freeze();
        return pen;
    }

    private static uint Blend(uint a, uint b, double t)
    {
        uint Channel(int shift) => (uint)Math.Round(((a >> shift) & 255) * (1 - t) + ((b >> shift) & 255) * t);
        return Channel(16) << 16 | Channel(8) << 8 | Channel(0);
    }
}
