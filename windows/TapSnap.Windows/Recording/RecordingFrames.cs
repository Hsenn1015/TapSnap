using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Channels;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Microsoft.Win32.SafeHandles;

namespace TapSnap.Windows;

internal sealed class RecordingFrames
{
    private readonly record struct Frame(TimeSpan Time, long Offset, int Length);
    private readonly string path;
    private readonly List<Frame> index = [];
    private readonly Channel<(TimeSpan Time, BitmapSource Image)> pending = Channel.CreateBounded<(TimeSpan, BitmapSource)>(
        new BoundedChannelOptions(3) { SingleReader = true, SingleWriter = true });

    public string Folder { get; }
    public Task Completion { get; }
    public int Width { get; }
    public int Height { get; }
    public int Count => index.Count;

    public RecordingFrames(int width, int height)
    {
        Width = width;
        Height = height;
        Folder = Path.Combine(Path.GetTempPath(), "TapSnap", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Folder);
        path = Path.Combine(Folder, "frames.bin");
        Completion = Task.Run(WriteAsync);
    }

    public void Add(TimeSpan time, BitmapSource image)
    {
        if (Completion.IsFaulted) Completion.GetAwaiter().GetResult();
        if (!image.IsFrozen) image.Freeze();
        pending.Writer.TryWrite((time, image));
    }

    public void Stop() => pending.Writer.TryComplete();

    public SafeFileHandle Open() => File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.Read, FileOptions.RandomAccess);

    public BitmapSource Read(SafeFileHandle file, double seconds)
    {
        int first = 0, last = index.Count - 1;
        while (first < last)
        {
            int mid = (first + last + 1) / 2;
            if (index[mid].Time.TotalSeconds <= seconds) first = mid;
            else last = mid - 1;
        }
        var frame = index[first];
        var bytes = new byte[frame.Length];
        int read = 0;
        while (read < frame.Length)
        {
            int size = RandomAccess.Read(file, bytes.AsSpan(read), frame.Offset + read);
            if (size == 0) throw new EndOfStreamException();
            read += size;
        }
        using var stream = new MemoryStream(bytes, false);
        return Images.Decode(stream);
    }

    public void Clean()
    {
        try { Directory.Delete(Folder, true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private async Task WriteAsync()
    {
        using var file = File.Create(path);
        using var encoded = new MemoryStream();
        await foreach (var (time, image) in pending.Reader.ReadAllAsync())
        {
            encoded.SetLength(0);
            Images.Encode(image, encoded, ".jpg");
            int length = checked((int)encoded.Length);
            index.Add(new Frame(time, file.Position, length));
            file.Write(encoded.GetBuffer(), 0, length);
        }
    }
}
