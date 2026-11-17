using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using NAudio.Wave;
using NAudio.CoreAudioApi;
using NAudio.Wave.SampleProviders;

namespace TapSnap.Windows;

internal sealed class RecordingAudio : IDisposable
{
    private readonly List<AudioSource> sources = [];
    private bool disposed;
    public const int SampleRate = 48000;
    public const int FrameBytes = 4;

    public RecordingAudio(bool microphone, bool system, string folder)
    {
        try
        {
            if (microphone) sources.Add(new AudioSource(new WasapiCapture(), Path.Combine(folder, "microphone.pcm")));
            if (system) sources.Add(new AudioSource(new WasapiLoopbackCapture(), Path.Combine(folder, "system.pcm")));
            foreach (var source in sources) source.Start();
        }
        catch { Dispose(); throw; }
    }

    public void SetPaused(bool value)
    {
        foreach (var source in sources) source.SetPaused(value);
    }

    public string? Mix(string outputPath, CancellationToken cancellation)
    {
        var streams = new List<RawSourceWaveStream>();
        try
        {
            var mixer = new MixingSampleProvider(WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, 2));
            foreach (var source in sources)
            {
                var stream = source.Open();
                streams.Add(stream);
                if (stream.Length == 0) continue;
                ISampleProvider samples = stream.ToSampleProvider();
                if (samples.WaveFormat.Channels == 1) samples = new MonoToStereoSampleProvider(samples);
                else if (samples.WaveFormat.Channels > 2) samples = new MultiplexingSampleProvider([samples], 2);
                if (samples.WaveFormat.SampleRate != SampleRate)
                    samples = new WdlResamplingSampleProvider(samples, SampleRate);
                mixer.AddMixerInput(samples);
            }
            if (!mixer.MixerInputs.Any()) return null;
            var pcm = new SampleToWaveProvider16(mixer);
            using var output = File.Create(outputPath);
            var buffer = new byte[64 * 1024];
            for (int read; (read = pcm.Read(buffer, 0, buffer.Length)) > 0;)
            {
                cancellation.ThrowIfCancellationRequested();
                output.Write(buffer, 0, read);
            }
            return outputPath;
        }
        finally { foreach (var stream in streams) stream.Dispose(); }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var source in sources) source.Dispose();
    }

    private sealed class AudioSource : IDisposable
    {
        private readonly IWaveIn input;
        private readonly string path;
        private readonly FileStream stream;
        private readonly Stopwatch timeline = new();
        private readonly object gate = new();
        private Exception? writeError;
        private bool paused = true;
        private bool started;

        public AudioSource(IWaveIn input, string path)
        {
            this.input = input;
            this.path = path;
            try { stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read); }
            catch { input.Dispose(); throw; }
            input.DataAvailable += Append;
        }

        public void Start()
        {
            input.StartRecording();
            started = true;
        }

        public void SetPaused(bool value)
        {
            lock (gate)
            {
                if (paused == value) return;
                paused = value;
                if (value) timeline.Stop(); else timeline.Start();
            }
        }

        private void Append(object? sender, WaveInEventArgs args)
        {
            lock (gate)
            {
                if (paused || writeError != null) return;
                try
                {
                    int align = input.WaveFormat.BlockAlign;
                    int length = args.BytesRecorded / align * align;
                    long expected = (long)(timeline.Elapsed.TotalSeconds * input.WaveFormat.SampleRate) * align - length;
                    // Loopback can stop delivering packets during complete silence.
                    if (expected > stream.Position + 2L * length) stream.Position = expected;
                    stream.Write(args.Buffer, 0, length);
                }
                catch (IOException error) { writeError = error; }
            }
        }

        public RawSourceWaveStream Open()
        {
            lock (gate)
            {
                if (writeError != null) throw new IOException("无法保存录制声音。", writeError);
                stream.Flush();
                var format = input.WaveFormat is WaveFormatExtensible extensible
                    ? extensible.ToStandardWaveFormat() : input.WaveFormat;
                return new RawSourceWaveStream(
                    new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite), format);
            }
        }

        public void Dispose()
        {
            SetPaused(true);
            input.DataAvailable -= Append;
            try { if (started) input.StopRecording(); }
            finally { input.Dispose(); stream.Dispose(); }
        }
    }
}
