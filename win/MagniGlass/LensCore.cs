using System.Runtime.InteropServices;

namespace MagniGlass;

/// <summary>The shared C lens renderer (core/lenscore.c, built as lenscore.dll).</summary>
internal sealed class LensCore : IDisposable
{
    public const int HandleLeft = 1, NoShadow = 2;
    private const string Dll = "lenscore.dll";

    [DllImport(Dll)] private static extern IntPtr lens_create(int diameter, float zoom, int flags);
    [DllImport(Dll)] private static extern void lens_destroy(IntPtr ctx);
    [DllImport(Dll)] private static extern void lens_set_zoom(IntPtr ctx, float zoom);
    [DllImport(Dll)] private static extern int lens_width(IntPtr ctx);
    [DllImport(Dll)] private static extern int lens_height(IntPtr ctx);
    [DllImport(Dll)] private static extern int lens_center_x(IntPtr ctx);
    [DllImport(Dll)] private static extern int lens_center_y(IntPtr ctx);
    [DllImport(Dll)] private static extern int lens_source_radius(IntPtr ctx);
    [DllImport(Dll)] private static extern int lens_glass_top(IntPtr ctx);
    [DllImport(Dll)] private static extern int lens_glass_bottom(IntPtr ctx);
    [DllImport(Dll)] private static extern void lens_draw_static(IntPtr ctx, IntPtr dst, int dstStride);
    [DllImport(Dll)] private static extern void lens_draw_glass(IntPtr ctx, IntPtr src, int srcW, int srcH, int srcStride,
        int srcCx, int srcCy, IntPtr dst, int dstStride, int y0, int y1);

    private IntPtr _ctx;

    public LensCore(int diameter, float zoom, int flags)
    {
        Diameter = diameter;
        Flags = flags;
        Zoom = zoom;
        _ctx = lens_create(diameter, zoom, flags);
        if (_ctx == IntPtr.Zero) throw new OutOfMemoryException("lens_create");
        Width = lens_width(_ctx);
        Height = lens_height(_ctx);
        CenterX = lens_center_x(_ctx);
        CenterY = lens_center_y(_ctx);
        GlassTop = lens_glass_top(_ctx);
        GlassBottom = lens_glass_bottom(_ctx);
    }

    public int Diameter { get; }
    public int Flags { get; }
    public float Zoom { get; private set; }
    public int Width { get; }
    public int Height { get; }
    public int CenterX { get; }
    public int CenterY { get; }
    public int GlassTop { get; }
    public int GlassBottom { get; }
    public int SourceRadius => lens_source_radius(_ctx);

    public void SetZoom(float zoom)
    {
        if (zoom == Zoom) return;
        Zoom = zoom;
        lens_set_zoom(_ctx, zoom);
    }

    public void DrawStatic(IntPtr dst, int stride) => lens_draw_static(_ctx, dst, stride);

    /// <summary>Glass rows split over a few threads when the lens is large.</summary>
    public void DrawGlass(IntPtr src, int srcW, int srcH, int srcStride, int srcCx, int srcCy, IntPtr dst, int dstStride)
    {
        int top = GlassTop, rows = GlassBottom - GlassTop;
        int parts = Diameter >= 360 ? Math.Min(Environment.ProcessorCount, 4) : 1;
        if (parts <= 1)
        {
            lens_draw_glass(_ctx, src, srcW, srcH, srcStride, srcCx, srcCy, dst, dstStride, top, top + rows);
            return;
        }
        Parallel.For(0, parts, i =>
        {
            int y0 = top + rows * i / parts, y1 = top + rows * (i + 1) / parts;
            lens_draw_glass(_ctx, src, srcW, srcH, srcStride, srcCx, srcCy, dst, dstStride, y0, y1);
        });
    }

    public void Dispose()
    {
        if (_ctx != IntPtr.Zero) lens_destroy(_ctx);
        _ctx = IntPtr.Zero;
    }
}
