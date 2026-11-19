using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace TapSnap.Windows;

internal sealed record CapturePreset(string Name, int X, int Y, int Width, int Height,
    string? SaveFormat = null, bool? AutoSave = null, bool FixedRegion = true, string? MonitorName = null)
{
    public System.Drawing.Rectangle ScreenRegion => new(X, Y, Width, Height);
}

internal sealed class Settings
{
    public static string DirectoryPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TapSnap");
    public static string SettingsPath => Path.Combine(DirectoryPath, "settings.json");
    public static string[] SaveFormats { get; } = ["png", "jpg", "webp", "avif", "heic", "tiff", "bmp", "gif"];

    public Dictionary<string, Hotkey> Hotkeys { get; set; } = Defaults();
    public Dictionary<string, Hotkey>? OperationHotkeys { get; set; }
    public List<CapturePreset> Presets { get; set; } = [];
    public string OutputFolder { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "TapSnap");
    public bool CopyAfterConfirm { get; set; } = true;
    public bool SaveAfterConfirm { get; set; }
    public bool ShutterSound { get; set; } = true;
    public bool DarkTheme { get; set; } = true;
    public bool PreferPriorityHotkeys { get; set; }
    public double DefaultLineWidth { get; set; } = 3;
    public double DefaultFontSize { get; set; } = 14;
    public int DefaultMosaicBlockSize { get; set; } = 12;
    public bool AutoMosaicFaces { get; set; }
    public string PrivacyMaskStyle { get; set; } = "Frosted";
    public int PrivacyMaskPatternSize { get; set; } = 8;
    public int PrivacyMaskRgb { get; set; } = 0x46566c;
    public bool HideDesktopIcons { get; set; }
    public bool ShowMagnifier { get; set; } = true;
    public bool ShowSelectionSize { get; set; } = true;
    public string SelectionBorder { get; set; } = "极光";
    public string SaveFormat { get; set; } = "png";
    public bool LongShotAutoScroll { get; set; } = true;
    public int LongShotStepPixels { get; set; } = 200;
    public int LongShotIntervalMilliseconds { get; set; } = 500;
    public double LongShotOverlap { get; set; } = 0.4;
    public bool ShowDesktopToolbar { get; set; }
    public bool ShowToolBall { get; set; }
    public bool StartAtLogin { get; set; }
    public int RecordFrameRate { get; set; } = 30;
    public bool RecordCursor { get; set; } = true;
    public bool RecordMicrophone { get; set; }
    public bool RecordSystemAudio { get; set; }
    public bool RecordCamera { get; set; }
    public bool RecordShowKeys { get; set; }
    public bool RecordShowClicks { get; set; }
    public int DesktopToolbarX { get; set; } = int.MinValue;
    public int DesktopToolbarY { get; set; } = int.MinValue;
    public int ToolBallX { get; set; } = int.MinValue;
    public int ToolBallY { get; set; } = int.MinValue;

    public static Dictionary<string, Hotkey> Defaults() => new()
    {
        ["capture"] = new(2, 0x31),
        ["capturePin"] = new(6, 0x32),
        ["clipboardPin"] = new(6, 0x56),
        ["longShot"] = new(6, 0x4C),
        ["record"] = new(6, 0x52),
        ["ocr"] = new(6, 0x4F),
        ["history"] = new(6, 0x48)
    };

    public static Settings Load()
    {
        try
        {
            if (File.Exists(SettingsPath)) return JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath)) ?? new Settings();
        }
        catch (IOException) { }
        catch (JsonException) { }
        return new Settings();
    }

    public void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        string tmp = SettingsPath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, SettingsPath, true);
    }
}
