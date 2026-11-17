using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TapSnap.Windows;

internal static class TesseractCli
{
    internal static string FindExecutable()
    {
        if (Environment.GetEnvironmentVariable("TAPSNAP_TESSERACT") is { Length: > 0 } configured)
        {
            string path = configured.Trim().Trim('"');
            if (Path.IsPathFullyQualified(path) && Path.GetFileName(path).EndsWith(".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(path))
                return path;
            throw new InvalidOperationException("TAPSNAP_TESSERACT 必须指向本机 Tesseract 可执行文件的完整路径。");
        }

        string? executable = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(directory => directory.Trim().Trim('"'))
            .Where(Path.IsPathFullyQualified)
            .Select(directory => Path.Combine(directory, "tesseract.exe"))
            .FirstOrDefault(File.Exists);
        return executable ?? throw new InvalidOperationException(
            "请安装本机 Tesseract，将 tesseract.exe 添加到 PATH，或将完整路径设置为 TAPSNAP_TESSERACT。Windows 11 ARM64 也可使用 TapSnap x64 版。");
    }

    internal static async Task<IReadOnlyList<RecognizedWord>[]> ReadAsync(string executable, string data, string language,
        byte[] png, int offsetX, int offsetY, CancellationToken cancellationToken = default)
    {
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8
        };
        foreach (string argument in new[] { "stdin", "stdout", "--tessdata-dir", data, "-l", language, "--oem", "1", "--psm", "11", "-c", "tessedit_create_tsv=1" })
            start.ArgumentList.Add(argument);

        using var process = Process.Start(start) ?? throw new InvalidOperationException("无法启动本机 Tesseract。");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
        var diagnostic = process.StandardError.ReadToEndAsync(timeout.Token);
        try
        {
            await process.StandardInput.BaseStream.WriteAsync(png, timeout.Token).ConfigureAwait(false);
            process.StandardInput.Close();
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            await diagnostic.ConfigureAwait(false);
            string tsv = await output.ConfigureAwait(false);
            if (process.ExitCode != 0 || !tsv.StartsWith("level\tpage_num\t", StringComparison.Ordinal))
                throw new InvalidOperationException("本机 Tesseract 未返回识别结果。请检查可执行文件和 OCR 语言包。");
            return Parse(tsv, offsetX, offsetY);
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            throw new InvalidOperationException("本机 Tesseract 识别超时。");
        }
        finally
        {
            if (!process.HasExited) process.Kill(true);
        }
    }

    internal static IReadOnlyList<RecognizedWord>[] Parse(string tsv, int offsetX, int offsetY)
    {
        var lines = new Dictionary<(string Page, string Block, string Paragraph, string Line), List<RecognizedWord>>();
        using var rows = new StringReader(tsv);
        while (rows.ReadLine() is { } row)
        {
            string[] cell = row.Split('\t', 12);
            if (cell.Length != 12 || cell[0] != "5" || string.IsNullOrWhiteSpace(cell[11]) ||
                !int.TryParse(cell[6], out int left) || !int.TryParse(cell[7], out int top) ||
                !int.TryParse(cell[8], out int width) || !int.TryParse(cell[9], out int height) ||
                left < 0 || top < 0 || width <= 0 || height <= 0)
                continue;
            var key = (cell[1], cell[2], cell[3], cell[4]);
            if (!lines.TryGetValue(key, out var words))
                lines.Add(key, words = new List<RecognizedWord>());
            words.Add(new RecognizedWord(cell[11].Trim(), new RectangleF(offsetX + left, offsetY + top, width, height)));
        }
        return lines.Values.ToArray();
    }
}
