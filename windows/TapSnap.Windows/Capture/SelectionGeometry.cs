using System;
using System.Drawing;

namespace TapSnap.Windows;

internal static class SelectionGeometry
{
    public static Rectangle? Create(Point anchor, Point cursor, Rectangle display)
    {
        var bounds = Rectangle.Intersect(display, Rectangle.FromLTRB(Math.Min(anchor.X, cursor.X), Math.Min(anchor.Y, cursor.Y),
            Math.Max(anchor.X, cursor.X), Math.Max(anchor.Y, cursor.Y)));
        return bounds.Width >= 2 && bounds.Height >= 2 ? bounds : null;
    }

    public static Rectangle Move(Rectangle selection, Rectangle display, int dx, int dy) => new(
        Math.Clamp(selection.Left + dx, display.Left, display.Right - selection.Width),
        Math.Clamp(selection.Top + dy, display.Top, display.Bottom - selection.Height), selection.Width, selection.Height);

    public static Rectangle Resize(Rectangle selection, Rectangle display, int handle, int dx, int dy)
    {
        int left = selection.Left, right = selection.Right, top = selection.Top, bottom = selection.Bottom;
        if (handle is 0 or 6 or 7) left = Math.Clamp(left + dx, display.Left, right - 2);
        if (handle is 2 or 3 or 4) right = Math.Clamp(right + dx, left + 2, display.Right);
        if (handle is 0 or 1 or 2) top = Math.Clamp(top + dy, display.Top, bottom - 2);
        if (handle is 4 or 5 or 6) bottom = Math.Clamp(bottom + dy, top + 2, display.Bottom);
        return Rectangle.FromLTRB(left, top, right, bottom);
    }

    public static Rectangle OffsetToImage(Rectangle selection, Rectangle display)
    {
        selection.Offset(-display.X, -display.Y);
        return selection;
    }

    public static Rectangle PlaceRecordingControls(Rectangle workArea, Rectangle selection, Size size, int inset)
    {
        int lastLeft = Math.Max(workArea.Left, workArea.Right - size.Width);
        int lastTop = Math.Max(workArea.Top, workArea.Bottom - size.Height);
        var bounds = new Rectangle(workArea.Left + (lastLeft - workArea.Left) / 2,
            Math.Min(workArea.Top + inset, lastTop), size.Width, size.Height);
        if (!bounds.IntersectsWith(selection)) return bounds;

        if (selection.Right + inset <= lastLeft)
            bounds.X = selection.Right + inset;
        else if (selection.Left - inset - size.Width >= workArea.Left)
            bounds.X = selection.Left - inset - size.Width;
        else if (selection.Bottom + inset <= lastTop)
            bounds.Y = selection.Bottom + inset;
        return bounds;
    }
}
