using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using global::Windows.Graphics.Capture;
using global::Windows.Graphics.DirectX;
using global::Windows.Graphics.DirectX.Direct3D11;
using global::Windows.Graphics.Imaging;
using global::Windows.Security.Cryptography;
using WinRT;
using DrawingPoint = System.Drawing.Point;
using DrawingRect = System.Drawing.Rectangle;
using CaptureBuffer = global::Windows.Storage.Streams.Buffer;

namespace TapSnap.Windows;

internal sealed class GraphicsCapture : IDisposable
{
    private readonly IDirect3DDevice device;
    private readonly Direct3D11CaptureFramePool pool;
    private readonly GraphicsCaptureSession session;
    private BitmapSource? latestFrame;
    private int frameInProgress;
    private int disposed;
    private readonly TaskCompletionSource<BitmapSource> first = new(TaskCreationOptions.RunContinuationsAsynchronously);

    private GraphicsCapture(GraphicsCaptureItem item, bool cursor)
    {
        device = CreateDevice();
        try
        {
            pool = Direct3D11CaptureFramePool.CreateFreeThreaded(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
            session = pool.CreateCaptureSession(item);
            session.IsCursorCaptureEnabled = cursor;
            pool.FrameArrived += OnFrame;
            session.StartCapture();
        }
        catch
        {
            session?.Dispose();
            pool?.Dispose();
            device.Dispose();
            throw;
        }
    }

    public BitmapSource? LatestFrame => Volatile.Read(ref latestFrame);

    public static GraphicsCapture? StartMonitor(DrawingRect monitorBounds, bool cursor = false)
    {
        if (!GraphicsCaptureSession.IsSupported()) return null;
        var monitor = MonitorFromPoint(new DrawingPoint(monitorBounds.X + 1, monitorBounds.Y + 1), 2);
        return Start(monitor, false, cursor);
    }

    public static async Task<BitmapSource?> WindowAsync(IntPtr hwnd)
    {
        if (!GraphicsCaptureSession.IsSupported()) return null;
        try
        {
            using var capture = Start(hwnd, true, false);
            return capture is null ? null : await capture.first.Task.WaitAsync(TimeSpan.FromMilliseconds(850)).ConfigureAwait(false);
        }
        catch (TimeoutException) { return null; }
        catch (COMException) { return null; }
    }

    private static GraphicsCapture? Start(IntPtr handle, bool window, bool cursor)
    {
        if (handle == IntPtr.Zero) return null;
        try
        {
            var factory = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
            var iid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
            int hr = window ? factory.CreateForWindow(handle, in iid, out var nativeItem) :
                factory.CreateForMonitor(handle, in iid, out nativeItem);
            Marshal.ThrowExceptionForHR(hr);
            if (nativeItem == IntPtr.Zero) return null;
            try
            {
                var item = MarshalInterface<GraphicsCaptureItem>.FromAbi(nativeItem);
                return item is null ? null : new GraphicsCapture(item, cursor);
            }
            finally { Marshal.Release(nativeItem); }
        }
        catch (Exception error) when (ExpectedCaptureFailure(error)) { return null; }
    }

    private async void OnFrame(Direct3D11CaptureFramePool sender, object args)
    {
        if (Volatile.Read(ref disposed) != 0 || Interlocked.Exchange(ref frameInProgress, 1) != 0) return;
        try
        {
            using var frame = sender.TryGetNextFrame();
            if (frame is null) return;
            using var image = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Ignore);
            int width = Math.Min(image.PixelWidth, frame.ContentSize.Width);
            int height = Math.Min(image.PixelHeight, frame.ContentSize.Height);
            if (width <= 0 || height <= 0) return;
            using var maybeBgra = image.BitmapPixelFormat == BitmapPixelFormat.Bgra8
                ? null : SoftwareBitmap.Convert(image, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
            var converted = maybeBgra ?? image;
            int stride = checked(image.PixelWidth * 4);
            var buffer = new CaptureBuffer(checked((uint)(stride * image.PixelHeight))) { Length = checked((uint)(stride * image.PixelHeight)) };
            converted.CopyToBuffer(buffer);
            CryptographicBuffer.CopyToByteArray(buffer, out var pixels);
            var result = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr32, null, pixels, stride);
            result.Freeze();
            Volatile.Write(ref latestFrame, result);
            first.TrySetResult(result);
        }
        catch (Exception error) when (ExpectedCaptureFailure(error) || Volatile.Read(ref disposed) != 0)
        {
            System.Diagnostics.Debug.WriteLine(error);
        }
        finally { Volatile.Write(ref frameInProgress, 0); }
    }

    private static bool ExpectedCaptureFailure(Exception error) =>
        error is ExternalException or InvalidCastException or InvalidOperationException or ArgumentException
            or UnauthorizedAccessException or NotSupportedException;

    private static IDirect3DDevice CreateDevice()
    {
        IntPtr dxgi = IntPtr.Zero, wrapped = IntPtr.Zero;
        int hr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out var d3d, IntPtr.Zero, IntPtr.Zero);
        Marshal.ThrowExceptionForHR(hr);
        try
        {
            var iid = new Guid("54EC77FA-1377-44E6-8C32-88FD5F44C84C");
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(d3d, in iid, out dxgi));
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out wrapped));
            return MarshalInterface<IDirect3DDevice>.FromAbi(wrapped);
        }
        finally
        {
            if (wrapped != IntPtr.Zero) Marshal.Release(wrapped);
            if (dxgi != IntPtr.Zero) Marshal.Release(dxgi);
            Marshal.Release(d3d);
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        pool.FrameArrived -= OnFrame;
        session.Dispose();
        pool.Dispose();
        device.Dispose();
    }

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        [PreserveSig] int CreateForWindow(IntPtr window, in Guid iid, out IntPtr result);
        [PreserveSig] int CreateForMonitor(IntPtr monitor, in Guid iid, out IntPtr result);
    }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(DrawingPoint point, uint flags);

    [DllImport("d3d11.dll")]
    private static extern int D3D11CreateDevice(IntPtr adapter, uint driverType, IntPtr software, uint flags,
        IntPtr featureLevels, uint levelCount, uint sdkVersion, out IntPtr device, IntPtr selectedLevel, IntPtr context);

    [DllImport("d3d11.dll")]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr device, out IntPtr interopDevice);
}
