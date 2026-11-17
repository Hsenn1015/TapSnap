using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using global::Windows.Media.Core;
using global::Windows.Media.MediaProperties;
using global::Windows.Media.Transcoding;
using global::Windows.Security.Cryptography;
using global::Windows.Storage;

namespace TapSnap.Windows;

internal sealed partial class RecordingPreview
{
    private void SaveGif(string path, double from, double to, int fps, int longestEdge, CancellationToken cancellation)
    {
        string temporary = path + ".tapsnap-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var input = frames.Open())
            using (var output = File.Create(temporary))
            using (var writer = new BinaryWriter(output))
            {
                int count = (int)Math.Ceiling((to - from) * fps);
                for (int index = 0; index < count; index++)
                {
                    cancellation.ThrowIfCancellationRequested();
                    var frame = frames.Read(input, from + index / (double)fps);
                    double scale = longestEdge == 0 ? 1 : Math.Min(1, (double)longestEdge / Math.Max(frame.PixelWidth, frame.PixelHeight));
                    if (scale != 1) frame = new TransformedBitmap(frame, new ScaleTransform(scale, scale));
                    var encoder = new GifBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(frame));
                    using var encoded = new MemoryStream();
                    encoder.Save(encoded);
                    double before = index / (double)fps;
                    double after = Math.Min((index + 1) / (double)fps, to - from);
                    WriteGifFrame(writer, encoded.ToArray(), index == 0, (ushort)Math.Max(1,
                        Math.Round(after * 100) - Math.Round(before * 100)));
                }
                writer.Write((byte)0x3b);
            }
            cancellation.ThrowIfCancellationRequested();
            File.Move(temporary, path, true);
        }
        finally { File.Delete(temporary); }
    }

    private static void WriteGifFrame(BinaryWriter output, byte[] frame, bool first, ushort delay)
    {
        if (frame.Length < 14 || frame[0] != 'G') throw new InvalidDataException("无法编码 GIF 帧。");
        int globalSize = (frame[10] & 0x80) != 0 ? 3 << ((frame[10] & 7) + 1) : 0;
        if (first)
        {
            output.Write(System.Text.Encoding.ASCII.GetBytes("GIF89a"));
            output.Write(frame, 6, 7);
            output.Write(frame, 13, globalSize);
            output.Write(new byte[] { 0x21, 0xff, 0x0b, 0x4e, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2e, 0x30, 3, 1, 0, 0, 0 });
        }
        int p = 13 + globalSize;
        while (p < frame.Length && frame[p] == 0x21)
        {
            p += 2;
            while (p < frame.Length && frame[p] != 0) p += frame[p] + 1;
            p++;
        }
        if (p + 10 >= frame.Length || frame[p] != 0x2c) throw new InvalidDataException("GIF 帧缺少图像数据。");
        output.Write(new byte[] { 0x21, 0xf9, 4, 4 });
        output.Write(delay);
        output.Write((ushort)0);
        bool localTable = (frame[p + 9] & 0x80) != 0;
        output.Write(frame, p, 9);
        if (!localTable && globalSize > 0)
        {
            output.Write((byte)((frame[p + 9] & 0x78) | 0x80 | (frame[10] & 7)));
            output.Write(frame, 13, globalSize);
        }
        else output.Write(frame[p + 9]);
        output.Write(frame, p + 10, frame.Length - p - 11);
    }

    private async Task SaveMp4(string path, double from, double to, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        int fps = videoRate;
        int w = frames.Width & ~1, h = frames.Height & ~1;
        if (w == 0 || h == 0) throw new InvalidOperationException("录屏区域太小。");
        int count = (int)Math.Ceiling((to - from) * fps);
        var props = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)w, (uint)h);
        props.FrameRate.Numerator = (uint)fps;
        props.FrameRate.Denominator = 1;
        var source = new MediaStreamSource(new VideoStreamDescriptor(props))
        {
            BufferTime = TimeSpan.Zero, Duration = TimeSpan.FromSeconds(count / (double)fps)
        };
        using var videoFile = frames.Open();
        using var sound = audio == null ? null : File.OpenHandle(audio, FileMode.Open, FileAccess.Read, FileShare.Read, FileOptions.RandomAccess);
        AudioStreamDescriptor? audioStream = null;
        if (sound != null)
        {
            audioStream = new AudioStreamDescriptor(AudioEncodingProperties.CreatePcm(RecordingAudio.SampleRate, 2, 16));
            source.AddStreamDescriptor(audioStream);
        }
        source.Starting += (_, e) => e.Request.SetActualStartPosition(TimeSpan.Zero);
        int index = 0;
        long audioOffset = 0;
        const int sampleRate = RecordingAudio.SampleRate, soundFrameBytes = RecordingAudio.FrameBytes;
        Exception? playbackError = null;
        source.SampleRequested += (_, e) =>
        {
            if (cancellation.IsCancellationRequested) { e.Request.Sample = null; return; }
            try
            {
                if (e.Request.StreamDescriptor is AudioStreamDescriptor && sound != null)
                {
                    long maxFrames = (long)((to - from) * sampleRate);
                    if (audioOffset >= maxFrames) { e.Request.Sample = null; return; }
                    int length = (int)Math.Min(960L, maxFrames - audioOffset);
                    long originalOffset = checked(((long)(from * sampleRate) + audioOffset) * soundFrameBytes);
                    byte[] buffer = new byte[length * soundFrameBytes];
                    for (int offset = 0; offset < buffer.Length;)
                    {
                        int read = RandomAccess.Read(sound, buffer.AsSpan(offset), originalOffset + offset);
                        if (read == 0) break;
                        offset += read;
                    }
                    var audioSample = MediaStreamSample.CreateFromBuffer(CryptographicBuffer.CreateFromByteArray(buffer),
                        TimeSpan.FromSeconds(audioOffset / (double)sampleRate));
                    audioSample.Duration = TimeSpan.FromSeconds(length / (double)sampleRate);
                    audioOffset += length;
                    e.Request.Sample = audioSample;
                    return;
                }
                if (index >= count) { e.Request.Sample = null; return; }
                var bitmap = new FormatConvertedBitmap(frames.Read(videoFile, from + index / (double)fps), PixelFormats.Bgra32, null, 0);
                byte[] pixels = new byte[checked(w * h * 4)];
                bitmap.CopyPixels(new Int32Rect(0, 0, w, h), pixels, w * 4, 0);
                var sample = MediaStreamSample.CreateFromBuffer(CryptographicBuffer.CreateFromByteArray(pixels), TimeSpan.FromSeconds(index++ / (double)fps));
                sample.Duration = TimeSpan.FromSeconds(1d / fps);
                e.Request.Sample = sample;
            }
            catch (Exception error)
            {
                Interlocked.CompareExchange(ref playbackError, error, null);
                source.NotifyError(MediaStreamSourceErrorStatus.Other);
            }
        };
        string temporary = path + ".tapsnap-" + Guid.NewGuid().ToString("N") + ".mp4";
        try
        {
            using (File.Create(temporary)) { }
            var file = await StorageFile.GetFileFromPathAsync(temporary);
            using (var output = await file.OpenAsync(FileAccessMode.ReadWrite))
            {
                var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
                var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD720p);
                profile.Video.Width = (uint)w;
                profile.Video.Height = (uint)h;
                profile.Video.Bitrate = 8_000_000;
                profile.Video.FrameRate.Numerator = (uint)fps;
                profile.Video.FrameRate.Denominator = 1;
                if (audioStream == null) profile.Audio = null;
                else
                {
                    profile.Audio.SampleRate = sampleRate;
                    profile.Audio.ChannelCount = 2;
                    profile.Audio.Bitrate = 128_000;
                }
                var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(source, output, profile);
                if (!prepared.CanTranscode) throw new InvalidOperationException(prepared.FailureReason.ToString());
                try { await prepared.TranscodeAsync().AsTask(cancellation); }
                catch (Exception) when (playbackError != null) { throw new IOException("无法读取录制数据。", playbackError); }
            }
            cancellation.ThrowIfCancellationRequested();
            File.Move(temporary, path, true);
        }
        finally { File.Delete(temporary); }
    }
}
