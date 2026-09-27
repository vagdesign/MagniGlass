using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DirectComposition;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace MagniGlass;

/// <summary>
/// Shows premultiplied BGRA frames in a window through DirectComposition (a composition
/// swap chain as the window's visual). Unlike a window updated with UpdateLayeredWindow,
/// such a window can be excluded from screen capture (WDA_EXCLUDEFROMCAPTURE).
/// Present(1) also paces the lens to the display refresh.
/// </summary>
internal sealed class CompositionOutput : IDisposable
{
    private readonly ID3D11Device _device;
    private readonly ID3D11DeviceContext _context;
    private readonly IDXGIFactory2 _factory;
    private readonly IDCompositionDevice _dcomp;
    private readonly IDCompositionTarget _target;
    private readonly IDCompositionVisual _visual;
    private IDXGISwapChain1 _swapChain;

    public int Width { get; private set; }
    public int Height { get; private set; }

    public CompositionOutput(IntPtr hwnd, int width, int height)
    {
        FeatureLevel[] levels = { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0, FeatureLevel.Level_10_1, FeatureLevel.Level_10_0 };
        var flags = DeviceCreationFlags.BgraSupport;
        if (D3D11.D3D11CreateDevice(null, DriverType.Hardware, flags, levels, out _device!, out _context!).Failure)
            D3D11.D3D11CreateDevice(null, DriverType.Warp, flags, levels, out _device!, out _context!).CheckError();

        using var dxgiDevice = _device.QueryInterface<IDXGIDevice>();
        _factory = DXGI.CreateDXGIFactory2<IDXGIFactory2>(false);
        Width = Math.Max(1, width);
        Height = Math.Max(1, height);
        _swapChain = _factory.CreateSwapChainForComposition(_device, Description(Width, Height));

        _dcomp = DComp.DCompositionCreateDevice<IDCompositionDevice>(dxgiDevice);
        _dcomp.CreateTargetForHwnd(hwnd, true, out _target!).CheckError();
        _visual = _dcomp.CreateVisual();
        _visual.SetContent(_swapChain);
        _target.SetRoot(_visual);
        _dcomp.Commit();
    }

    private static SwapChainDescription1 Description(int w, int h) => new()
    {
        Width = (uint)w,
        Height = (uint)h,
        Format = Format.B8G8R8A8_UNorm,
        BufferCount = 2,
        BufferUsage = Usage.RenderTargetOutput,
        SampleDescription = new SampleDescription(1, 0),
        Scaling = Scaling.Stretch,
        SwapEffect = SwapEffect.FlipSequential,
        AlphaMode = AlphaMode.Premultiplied,
    };

    public void Resize(int width, int height)
    {
        width = Math.Max(1, width);
        height = Math.Max(1, height);
        if (width == Width && height == Height) return;
        _context.ClearState();
        _context.Flush();
        _swapChain.ResizeBuffers(2, (uint)width, (uint)height, Format.B8G8R8A8_UNorm, SwapChainFlags.None).CheckError();
        Width = width;
        Height = height;
    }

    /// <summary>Copies a premultiplied BGRA image of the current size and shows it at the next refresh.</summary>
    public void Present(IntPtr pixels, int stride)
    {
        using (var buffer = _swapChain.GetBuffer<ID3D11Texture2D>(0))
            _context.UpdateSubresource(buffer, 0, null, pixels, (uint)stride, 0);
        _swapChain.Present(1, PresentFlags.None);
    }

    /// <summary>A fully transparent frame (the glass "hidden" while the window stays shown).</summary>
    public void PresentClear()
    {
        using (var buffer = _swapChain.GetBuffer<ID3D11Texture2D>(0))
        using (var rtv = _device.CreateRenderTargetView(buffer))
            _context.ClearRenderTargetView(rtv, new Color4(0, 0, 0, 0));
        _swapChain.Present(1, PresentFlags.None);
    }

    public void Dispose()
    {
        _visual.Dispose();
        _target.Dispose();
        _dcomp.Dispose();
        _swapChain.Dispose();
        _factory.Dispose();
        _context.Dispose();
        _device.Dispose();
    }
}
