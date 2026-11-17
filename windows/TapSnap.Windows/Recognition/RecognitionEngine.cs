using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Tesseract;
using ZXing;
using global::Windows.Globalization;
using global::Windows.Graphics.Imaging;
using global::Windows.Media.FaceAnalysis;
using global::Windows.Media.Ocr;
using global::Windows.Security.Cryptography;
using BitmapFrame = System.Windows.Media.Imaging.BitmapFrame;
using Rect = System.Windows.Rect;
using PixelFormats = System.Windows.Media.PixelFormats;

namespace TapSnap.Windows;

internal static class RecognitionEngine
{
    private const int TileSize = 1700;
    private const int TileOverlap = 88;
    private const int OverlapHalf = TileOverlap / 2;
    private static readonly object TessLock = new();
    private static string DataPath => Path.Combine(RecognitionService.SettingsDirectory, "tessdata");

    public static async Task<IReadOnlyList<RecognizedLine>> ReadAsync(BitmapSource source, string language,
        System.Threading.CancellationToken cancellationToken = default)
    {
        source = Freeze(source);
        OcrEngine? engine = null;
        if (language.Length == 0 || language.Contains('-'))
        {
            try
            {
                engine = language.Length == 0
                    ? OcrEngine.TryCreateFromUserProfileLanguages()
                    : OcrEngine.TryCreateFromLanguage(new Language(language));
            }
            catch (Exception error) when (error is COMException or TypeLoadException or ArgumentException)
            {
                // The native OCR API requires package identity on Windows.
            }
        }

        if (engine is not null)
        {
            try
            {
                var windows = new List<RecognizedLine>();
                int size = (int)Math.Min(TileSize, OcrEngine.MaxImageDimension);
                foreach (var tile in Tiles(source, size))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var pixels = Pixels(tile.Image, PixelFormats.Bgra32, 4);
                    using var software = SoftwareBitmap.CreateCopyFromBuffer(CryptographicBuffer.CreateFromByteArray(pixels),
                        BitmapPixelFormat.Bgra8, tile.Image.PixelWidth, tile.Image.PixelHeight, BitmapAlphaMode.Ignore);
                    var ocr = await engine.RecognizeAsync(software).AsTask(cancellationToken);
                    foreach (var line in ocr.Lines)
                        AddLine(windows, tile, line.Words.Select(word =>
                        {
                            var box = word.BoundingRect;
                            return new RecognizedWord(word.Text, new RectangleF((float)(box.X + tile.X), (float)(box.Y + tile.Y), (float)box.Width, (float)box.Height));
                        }));
                }
                return OrderLines(windows);
            }
            catch (Exception error) when (error is COMException or InvalidOperationException)
            {
                // Try the locally installed Tesseract data if Windows OCR rejects the session.
            }
        }

        return await Task.Run(() => ReadTesseract(source, language, cancellationToken), cancellationToken)
            .WaitAsync(cancellationToken);
    }

    private static IReadOnlyList<RecognizedLine> ReadTesseract(BitmapSource source, string language,
        System.Threading.CancellationToken cancellationToken)
    {
        var paths = new[] { DataPath, Path.Combine(AppContext.BaseDirectory, "tessdata") };
        string selected = language switch
        {
            "zh-CN" or "zh-Hans" => "chi_sim+eng",
            "zh-TW" or "zh-Hant" => "chi_tra+eng",
            "en-US" or "en-GB" => "eng",
            "" => paths.Any(path => File.Exists(Path.Combine(path, "chi_sim.traineddata")) &&
                File.Exists(Path.Combine(path, "eng.traineddata"))) ? "chi_sim+eng" : "eng",
            _ => language
        };
        var languages = selected.Split('+');
        if (languages.Any(code => code.Length is < 2 or > 20 ||
            code.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '_')))
            throw new InvalidOperationException("OCR 语言设置无效。");
        string? data = paths.FirstOrDefault(path => languages.All(code => File.Exists(Path.Combine(path, code + ".traineddata"))));
        if (data is null && !paths.Any(path => File.Exists(Path.Combine(path, "eng.traineddata"))))
            throw new InvalidOperationException("本机 OCR 语言包未安装。请先运行 Windows 工程的 Install-OcrLanguages.ps1。");
        if (data is null)
            throw new InvalidOperationException("选中的 OCR 语言数据尚未安装，请在识别设置中调整语言。");

        var results = new List<RecognizedLine>();
        if (RuntimeInformation.ProcessArchitecture is not (Architecture.X64 or Architecture.X86) ||
            !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("TAPSNAP_TESSERACT")))
        {
            string executable = TesseractCli.FindExecutable();
            foreach (var tile in Tiles(source, TileSize))
            {
                cancellationToken.ThrowIfCancellationRequested();
                foreach (var words in TesseractCli.ReadAsync(executable, data, selected, Png(tile.Image),
                    tile.X, tile.Y, cancellationToken).GetAwaiter().GetResult())
                    AddLine(results, tile, words);
            }
            return OrderLines(results);
        }
        lock (TessLock)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var engine = new TesseractEngine(data, selected, EngineMode.LstmOnly);
                foreach (var tile in Tiles(source, TileSize))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    using var pix = Pix.LoadFromMemory(Png(tile.Image));
                    using var page = engine.Process(pix, PageSegMode.SparseText);
                    using var iterator = page.GetIterator();
                    var words = new List<RecognizedWord>();
                    iterator.Begin();
                    do
                    {
                        if (iterator.IsAtBeginningOf(PageIteratorLevel.TextLine) && words.Count > 0)
                        {
                            AddLine(results, tile, words);
                            words.Clear();
                        }
                        if (!iterator.TryGetBoundingBox(PageIteratorLevel.Word, out var box))
                            continue;
                        var text = iterator.GetText(PageIteratorLevel.Word);
                        if (!string.IsNullOrWhiteSpace(text))
                            words.Add(new RecognizedWord(text.Trim(),
                                new RectangleF(tile.X + box.X1, tile.Y + box.Y1, box.Width, box.Height)));
                    } while (iterator.Next(PageIteratorLevel.Word));
                    AddLine(results, tile, words);
                }
            }
            catch (Exception error) when (error is TesseractException or DllNotFoundException or TypeInitializationException)
            {
                throw new InvalidOperationException("本机 OCR 引擎无法启动。请检查 OCR 语言包及 Microsoft Visual C++ Runtime。", error);
            }
        }

        return OrderLines(results);
    }

    public static async Task<IReadOnlyList<PrivacyCandidate>> FacesAsync(BitmapSource source, PrivacyRuleMode mode)
    {
        if (!FaceDetector.IsSupported || !FaceDetector.IsBitmapPixelFormatSupported(BitmapPixelFormat.Gray8))
            throw new InvalidOperationException("当前 Windows 设备不支持本机人脸识别。");
        var detector = await FaceDetector.CreateAsync();
        var candidates = new List<PrivacyCandidate>();
        foreach (var tile in Tiles(source, TileSize))
        {
            var pixels = Pixels(tile.Image, PixelFormats.Gray8, 1);
            using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(CryptographicBuffer.CreateFromByteArray(pixels),
                BitmapPixelFormat.Gray8, tile.Image.PixelWidth, tile.Image.PixelHeight);
            var faces = await detector.DetectFacesAsync(bitmap);
            foreach (var face in faces)
            {
                var box = face.FaceBox;
                var rect = new Rect(tile.X + box.X, tile.Y + box.Y, box.Width, box.Height);
                if (tile.Accept(rect))
                    candidates.Add(new PrivacyCandidate("人脸", rect, mode == PrivacyRuleMode.Automatic));
            }
        }
        return candidates;
    }

    public static Task<IReadOnlyList<(string Text, Rect Bounds)>> BarcodesAsync(BitmapSource source)
    {
        source = Freeze(source);
        return Task.Run<IReadOnlyList<(string, Rect)>>(() =>
        {
            var detected = new List<(string, Rect)>();
            foreach (var tile in Tiles(source, TileSize))
            {
                var reader = new BarcodeReaderGeneric { AutoRotate = false };
                reader.Options.TryHarder = true;
                var pixels = Pixels(tile.Image, PixelFormats.Bgra32, 4);
                var barcodes = reader.DecodeMultiple(pixels, tile.Image.PixelWidth, tile.Image.PixelHeight,
                    RGBLuminanceSource.BitmapFormat.BGRA32) ?? [];
                foreach (var barcode in barcodes)
                {
                    var points = barcode.ResultPoints?.Where(point => point is not null).ToArray() ?? [];
                    if (points.Length == 0)
                    {
                        detected.Add((barcode.Text, Rect.Empty));
                        continue;
                    }
                    double left = points.Min(point => point.X) + tile.X, right = points.Max(point => point.X) + tile.X;
                    double top = points.Min(point => point.Y) + tile.Y, bottom = points.Max(point => point.Y) + tile.Y;
                    Rect bounds;
                    if (barcode.BarcodeFormat == BarcodeFormat.QR_CODE && points.Length >= 3)
                    {
                        double horizontal = Math.Max(8, (right - left) * .35);
                        double vertical = Math.Max(8, (bottom - top) * .35);
                        bounds = new Rect(left - horizontal, top - vertical, right - left + horizontal * 2, bottom - top + vertical * 2);
                    }
                    else
                    {
                        double extension = Math.Max(10, (right - left) * .08);
                        double side = Math.Max(20, Math.Max(right - left, bottom - top) * .35);
                        bounds = new Rect(left - extension, top - side, right - left + extension * 2, bottom - top + side * 2);
                    }
                    bounds.Intersect(new Rect(0, 0, source.PixelWidth, source.PixelHeight));
                    if (!bounds.IsEmpty && tile.Accept(bounds))
                        detected.Add((barcode.Text, bounds));
                }
            }
            return detected.Distinct().ToArray();
        });
    }

    public static string Text(IReadOnlyList<RecognizedLine> lines) => string.Join(Environment.NewLine, lines.Select(line => line.Text));

    public static async Task<string> CsvAsync(BitmapSource source, string language,
        System.Threading.CancellationToken cancellationToken = default)
    {
        var frozen = Freeze(source);
        var grid = await Task.Run(() => TableGrid.Detect(Pixels(frozen, PixelFormats.Gray8, 1),
            frozen.PixelWidth, frozen.PixelHeight), cancellationToken);
        if (grid is null)
            throw new InvalidOperationException("没有检测到表格线，试试框选得更紧一些。");
        var lines = await ReadAsync(frozen, language, cancellationToken);
        if (lines.Count == 0) return "";
        var cells = new string?[grid.RowCount, grid.ColumnCount];
        foreach (var line in lines)
            foreach (var word in line.Words)
            {
                int row = grid.Row(word.Bounds.Y + word.Bounds.Height / 2);
                int column = grid.Column(word.Bounds.X + word.Bounds.Width / 2);
                if (row < 0 || column < 0) continue;
                cells[row, column] = cells[row, column] is { } previous ? previous + " " + word.Text : word.Text;
            }
        return string.Join(Environment.NewLine, Enumerable.Range(0, grid.RowCount).Select(row =>
            string.Join(',', Enumerable.Range(0, grid.ColumnCount).Select(column => CsvField(cells[row, column])))));
    }

    private static string CsvField(string? value)
    {
        if (value is null) return "";
        // Spreadsheet programs otherwise interpret screenshot text that starts with a formula marker.
        if (value.Length > 0 && value[0] is '=' or '+' or '-' or '@' or '\t' or '\r')
            value = "'" + value;
        if (value.IndexOfAny([',', '"', '\r', '\n']) < 0) return value;
        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }

    public static BitmapSource Freeze(BitmapSource source)
    {
        if (source.IsFrozen) return source;
        var clone = source.CloneCurrentValue();
        clone.Freeze();
        return clone;
    }

    public static byte[] Png(BitmapSource source)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var output = new MemoryStream();
        encoder.Save(output);
        return output.ToArray();
    }

    private static byte[] Pixels(BitmapSource source, PixelFormat target, int bytesPerPixel)
    {
        var converted = source.Format == target ? source : new FormatConvertedBitmap(source, target, null, 0);
        int stride = checked(converted.PixelWidth * bytesPerPixel);
        var pixels = new byte[checked(stride * converted.PixelHeight)];
        converted.CopyPixels(pixels, stride, 0);
        return pixels;
    }

    private static IReadOnlyList<RecognizedLine> OrderLines(IEnumerable<RecognizedLine> lines) =>
        lines.OrderBy(line => line.Bounds.Top).ThenBy(line => line.Bounds.Left).ToArray();

    private static void AddLine(List<RecognizedLine> output, Tile tile, IEnumerable<RecognizedWord> words)
    {
        if (RecognizedLine.From(words) is { } line && tile.Accept(RecognitionService.ToRect(line.Bounds)))
            output.Add(line);
    }

    private sealed record Tile(BitmapSource Image, int X, int Y, Rect Inner)
    {
        public bool Accept(Rect box) => Inner.Contains(box.X + box.Width / 2, box.Y + box.Height / 2);
    }

    private static IEnumerable<Tile> Tiles(BitmapSource image, int size)
    {
        int step = Math.Max(1, size - TileOverlap);
        for (int y = 0; y < image.PixelHeight; y += step)
        {
            for (int x = 0; x < image.PixelWidth; x += step)
            {
                int width = Math.Min(size, image.PixelWidth - x), height = Math.Min(size, image.PixelHeight - y);
                if (x != 0 && width <= OverlapHalf || y != 0 && height <= OverlapHalf) continue;
                double left = x == 0 ? x : x + OverlapHalf, top = y == 0 ? y : y + OverlapHalf;
                double right = x + width < image.PixelWidth ? x + width - OverlapHalf : x + width;
                double bottom = y + height < image.PixelHeight ? y + height - OverlapHalf : y + height;
                yield return new Tile(new CroppedBitmap(image, new Int32Rect(x, y, width, height)), x, y,
                    new Rect(left, top, right - left, bottom - top));
                if (x + width >= image.PixelWidth) break;
            }
            if (y + size >= image.PixelHeight) break;
        }
    }
}
