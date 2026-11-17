using Color = System.Drawing.Color;
using Forms = System.Windows.Forms;

namespace TapSnap.Windows;

internal sealed class SnapTrayMenu : Forms.ProfessionalColorTable
{
    private SnapTrayMenu() => UseSystemColors = false;

    public static void Style(Forms.ContextMenuStrip menu)
    {
        menu.Renderer = new Forms.ToolStripProfessionalRenderer(new SnapTrayMenu());
        menu.Opening += (_, _) => menu.ForeColor = Gray(250, 10);
    }

    public override Color ToolStripDropDownBackground => Gray(23, 255);
    public override Color MenuBorder => Gray(48, 229);
    public override Color MenuItemSelected => Gray(38, 245);
    public override Color MenuItemBorder => MenuItemSelected;
    public override Color SeparatorDark => MenuBorder;
    public override Color SeparatorLight => ToolStripDropDownBackground;

    private static Color Gray(int dark, int light)
    {
        int shade = SnapTheme.IsDark ? dark : light;
        return Color.FromArgb(shade, shade, shade);
    }
}
