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
                RecordingGifWriter? animation = null;
                byte[]? pixels = null;
                int previousIndex = -1;
                for (int index = 0; index < count; index++)
                {
                    cancellation.ThrowIfCancellationRequested();
                    int frameIndex = frames.IndexAt(from + index / (double)fps);
                    if (frameIndex != previousIndex)
                    {
                        var frame = frames.ReadFrame(input, frameIndex, longestEdge);
                        var bitmap = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
                        int stride = checked(bitmap.PixelWidth * 4);
                        pixels ??= new byte[checked(stride * bitmap.PixelHeight)];
                        animation ??= new RecordingGifWriter(writer, bitmap.PixelWidth, bitmap.PixelHeight);
                        bitmap.CopyPixels(pixels, stride, 0);
                        previousIndex = frameIndex;
                    }
                    double before = index / (double)fps;
                    double after = Math.Min((index + 1) / (double)fps, to - from);
                    animation!.Append(pixels!, (ushort)Math.Max(1, Math.Round(after * 100) - Math.Round(before * 100)));
                }
                if (animation == null) throw new InvalidDataException("没有可导出的 GIF 帧。");
                animation.Finish();
            }
            cancellation.ThrowIfCancellationRequested();
            File.Move(temporary, path, true);
        }
        finally { File.Delete(temporary); }
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
