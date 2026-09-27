using System.Diagnostics;
using System.Runtime.InteropServices;
using static MagniGlass.NativeMethods;

namespace MagniGlass;

/// <summary>
/// The glass: a click-through, per-pixel-alpha layered window that follows the pointer.
/// It lives on its own thread, paced by the compositor (DwmFlush): each frame copies the
/// screen around the pointer, runs it through the lens and puts the window on the pointer.
/// The window is excluded from screen capture, so it never magnifies itself. Windows refuses
/// that for windows drawn with UpdateLayeredWindow, so the glass is drawn through
/// DirectComposition (<see cref="CompositionOutput"/>); UpdateLayeredWindow is only the
/// fallback when DirectComposition cannot start. Windows only
/// honours that for a window that is already shown, and a hide/show cycle can drop it, so
/// the window is shown once and then kept on screen (fully transparent while "hidden").
/// Each frame also checks that the capture does not contain our own previous frame; if it
/// does, it falls back to a plain BitBlt, which leaves layered windows (ours) out.
/// </summary>
internal sealed class Magnifier : IDisposable
{
    private readonly Thread _thread;
    private readonly AutoResetEvent _wake = new(false);
    private volatile bool _visible, _quit;
    private volatile float _zoom;
    private volatile Settings _settings;
    private volatile bool _settingsChanged = true;

    // Render-thread state
    private IntPtr _hwnd;
    private WndProc? _wndProc;
    private CompositionOutput? _comp;
    private int _winX = int.MinValue, _winY, _winW, _winH;
    private bool _shown, _blank, _affinitySet, _useCaptureBlt;
    private int _feedbackFrames;
    private bool _warned;
    private POINT _lastPt;
    private bool _lastValid;

    /// <summary>Raised (on the lens thread) if the glass keeps seeing itself in the capture.</summary>
    public event Action? CaptureProblem;
    private LensCore? _lens;
    private Dib? _frame, _source;
    private int _sourceSize;
    private long _lastTopmost;

    public Magnifier(Settings settings)
    {
        _settings = settings;
        _zoom = (float)settings.Zoom;
        _thread = new Thread(Run) { IsBackground = true, Name = "MagniGlass lens", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    public bool Visible
    {
        get => _visible;
        set
        {
            _visible = value;
            _wake.Set();
        }
    }

    public float Zoom
    {
        get => _zoom;
        set => _zoom = Math.Clamp(value, (float)Settings.MinZoom, (float)Settings.MaxZoom);
    }

    public void Apply(Settings settings)
    {
        _settings = settings;
        _zoom = (float)settings.Zoom;
        _settingsChanged = true;
        _wake.Set();
    }

    private void Run()
    {
        try
        {
            CreateWindow();
            var handles = new[] { _wake.SafeWaitHandle.DangerousGetHandle() };
            while (!_quit)
            {
                while (PeekMessage(out MSG msg, IntPtr.Zero, 0, 0, PM_REMOVE))
                {
                    if (msg.message == WM_QUIT) return;
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
                if (!_visible)
                {
                    if (_shown && !_blank)
                    {
                        Blank();
                        FreeBuffers();
                    }
                    MsgWaitForMultipleObjects(1, handles, false, 500, QS_ALLINPUT);
                    continue;
                }
                long t0 = Stopwatch.GetTimestamp();
                try { RenderFrame(); }
                catch (Exception ex)
                {
                    Log.Error("Render", ex);
                    _visible = false;
                }
                // Wait for the next composition (vsync); Present(1) already did with DirectComposition.
                // If that returns at once (it can, e.g. while the display sleeps), fall back to ~120 fps.
                if (_comp == null) DwmFlush();
                if (Stopwatch.GetElapsedTime(t0).TotalMilliseconds < 4) Thread.Sleep(4);
            }
        }
        catch (Exception ex) { Log.Error("Lens thread", ex); }
        finally
        {
            FreeBuffers();
            _comp?.Dispose();
            if (_hwnd != IntPtr.Zero) DestroyWindow(_hwnd);
        }
    }

    private void CreateWindow()
    {
        _wndProc = (h, m, w, l) => m == WM_NCHITTEST ? new IntPtr(HTTRANSPARENT) : DefWindowProc(h, m, w, l);
        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
            hInstance = GetModuleHandle(null),
            lpszClassName = "MagniGlassLens",
        };
        RegisterClassEx(ref wc);
        const int baseStyle = WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE;

        // Preferred: DirectComposition content in a click-through window. The window is layered
        // only for click-through (constant alpha 255 via SetLayeredWindowAttributes, which does
        // allow capture exclusion); the pixels come from the composition swap chain.
        _hwnd = CreateWindowEx(baseStyle | WS_EX_NOREDIRECTIONBITMAP, "MagniGlassLens", "MagniGlass", WS_POPUP,
            0, 0, 8, 8, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        if (_hwnd == IntPtr.Zero) throw new InvalidOperationException("CreateWindowEx failed: " + Marshal.GetLastWin32Error());
        try
        {
            SetLayeredWindowAttributes(_hwnd, 0, 255, LWA_ALPHA);
            _comp = new CompositionOutput(_hwnd, 8, 8);
            Log.Info($"Lens window created with DirectComposition ({Environment.OSVersion.VersionString})");
            return;
        }
        catch (Exception ex)
        {
            Log.Error("DirectComposition unavailable, using UpdateLayeredWindow", ex);
            _comp?.Dispose();
            _comp = null;
            DestroyWindow(_hwnd);
        }

        _hwnd = CreateWindowEx(baseStyle, "MagniGlassLens", "MagniGlass", WS_POPUP,
            0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        if (_hwnd == IntPtr.Zero) throw new InvalidOperationException("CreateWindowEx failed: " + Marshal.GetLastWin32Error());
        Log.Info($"Lens window created with UpdateLayeredWindow ({Environment.OSVersion.VersionString})");
    }

    /// <summary>Moves / sizes the DirectComposition window (only when something changed).</summary>
    private void PlaceWindow(int x, int y, int w, int h)
    {
        if (x == _winX && y == _winY && w == _winW && h == _winH) return;
        SetWindowPos(_hwnd, IntPtr.Zero, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
        _winX = x; _winY = y; _winW = w; _winH = h;
    }

    /// <summary>
    /// Windows 10 2004+: keep the glass out of every screen capture, ours included. Then we can
    /// capture with CAPTUREBLT, which also sees other layered windows (menus, tooltips). Must be
    /// called while the window is shown.
    /// </summary>
    private void ApplyAffinity()
    {
        bool ok = SetWindowDisplayAffinity(_hwnd, WDA_EXCLUDEFROMCAPTURE);
        int err = Marshal.GetLastWin32Error();
        uint now = 0;
        bool read = GetWindowDisplayAffinity(_hwnd, out now);
        _affinitySet = ok && read && now == WDA_EXCLUDEFROMCAPTURE;
        _useCaptureBlt = _affinitySet;
        Log.Info($"Exclude from capture ({(_comp != null ? "DirectComposition" : "UpdateLayeredWindow")}): set={ok} (error {err}), reads back 0x{now:X} -> {(_affinitySet ? "on" : "off, plain BitBlt")}");
    }

    /// <summary>"Hidden": a fully transparent 1x1 frame. The window stays shown so its capture exclusion holds.</summary>
    private void Blank()
    {
        if (_comp != null)
        {
            _comp.PresentClear();
            _blank = true;
            _lastValid = false;
            return;
        }
        using var dib = new Dib(1, 1); // zeroed: transparent
        IntPtr screen = GetDC(IntPtr.Zero);
        try
        {
            GetCursorPos(out POINT pt);
            var sz = new SIZE(1, 1);
            var src = new POINT(0, 0);
            var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = 255, AlphaFormat = AC_SRC_ALPHA };
            UpdateLayeredWindow(_hwnd, screen, ref pt, ref sz, dib.Dc, ref src, 0, ref blend, ULW_ALPHA);
        }
        finally { ReleaseDC(IntPtr.Zero, screen); }
        _blank = true;
        _lastValid = false;
    }

    /// <summary>
    /// True if the pixels just captured under the pointer are exactly the glass we drew there last
    /// frame, i.e. the capture sees our own window.
    /// </summary>
    private unsafe bool SeesItself(POINT pt, int radius, LensCore lens, Dib frame)
    {
        if (!_lastValid || pt.X != _lastPt.X || pt.Y != _lastPt.Y) return false;
        uint* src = (uint*)_source!.Bits;
        uint* dst = (uint*)frame.Bits;
        for (int dy = -3; dy <= 3; dy++)
            for (int dx = -3; dx <= 3; dx++)
            {
                uint a = src[(radius + dy) * _sourceSize + radius + dx] & 0xFFFFFF;
                uint b = dst[(lens.CenterY + dy) * frame.Width + lens.CenterX + dx] & 0xFFFFFF;
                if (a != b) return false;
            }
        return true;
    }

    private void RenderFrame()
    {
        GetCursorPos(out POINT pt);
        Settings s = _settings;

        IntPtr monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(monitor, ref mi);
        if (GetDpiForMonitor(monitor, 0, out uint dpi, out _) != 0) dpi = 96;
        int diameter = s.DiameterFor(mi.rcMonitor.Right - mi.rcMonitor.Left, mi.rcMonitor.Bottom - mi.rcMonitor.Top, dpi);

        bool rebuilt = false;
        if (_lens == null || _settingsChanged || _lens.Diameter != diameter || _lens.Flags != s.LensFlags)
        {
            _settingsChanged = false;
            FreeBuffers();
            _lens = new LensCore(diameter, _zoom, s.LensFlags);
            _frame = new Dib(_lens.Width, _lens.Height);
            _lens.DrawStatic(_frame.Bits, _frame.Width * 4);
            rebuilt = true;
        }
        LensCore lens = _lens;
        Dib frame = _frame!;
        lens.SetZoom(_zoom);

        int radius = lens.SourceRadius;
        int size = 2 * radius + 1;
        if (_source == null || size > _sourceSize)
        {
            _source?.Dispose();
            _sourceSize = size + 16;
            _source = new Dib(_sourceSize, _sourceSize);
        }

        IntPtr screen = GetDC(IntPtr.Zero);
        try
        {
            BitBlt(_source.Dc, 0, 0, size, size, screen, pt.X - radius, pt.Y - radius, SRCCOPY | (_useCaptureBlt ? CAPTUREBLT : 0));
            GdiFlush();
            if (!rebuilt && SeesItself(pt, radius, lens, frame))
            {
                if (++_feedbackFrames >= 3)
                {
                    _feedbackFrames = 0;
                    if (_useCaptureBlt)
                    {
                        Log.Info("The capture contains the glass itself: switching to plain BitBlt");
                        _useCaptureBlt = false;
                    }
                    else if (!_warned)
                    {
                        _warned = true;
                        Log.Info("The capture still contains the glass itself");
                        CaptureProblem?.Invoke();
                    }
                }
            }
            else _feedbackFrames = 0;
            lens.DrawGlass(_source.Bits, size, size, _sourceSize * 4, radius, radius, frame.Bits, frame.Width * 4);

            var dst = new POINT(pt.X - lens.CenterX, pt.Y - lens.CenterY);
            if (_comp != null)
            {
                _comp.Resize(frame.Width, frame.Height);
                PlaceWindow(dst.X, dst.Y, frame.Width, frame.Height);
                _comp.Present(frame.Bits, frame.Width * 4);
            }
            else
            {
                var sz = new SIZE(frame.Width, frame.Height);
                var src = new POINT(0, 0);
                var blend = new BLENDFUNCTION { BlendOp = AC_SRC_OVER, SourceConstantAlpha = 255, AlphaFormat = AC_SRC_ALPHA };
                UpdateLayeredWindow(_hwnd, screen, ref dst, ref sz, frame.Dc, ref src, 0, ref blend, ULW_ALPHA);
            }
            _blank = false;
            _lastPt = pt;
            _lastValid = true;
        }
        finally { ReleaseDC(IntPtr.Zero, screen); }

        long now = Environment.TickCount64;
        if (!_shown || rebuilt || now - _lastTopmost > 500)
        {
            // Stay above other topmost windows (the taskbar, Start, other tools).
            SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            _lastTopmost = now;
        }
        if (!_shown)
        {
            ShowWindow(_hwnd, SW_SHOWNOACTIVATE);
            _shown = true;
            ApplyAffinity();
        }
    }

    private void FreeBuffers()
    {
        _lens?.Dispose();
        _lens = null;
        _frame?.Dispose();
        _frame = null;
        _source?.Dispose();
        _source = null;
        _sourceSize = 0;
    }

    public void Dispose()
    {
        _quit = true;
        _wake.Set();
        _thread.Join(1000);
    }
}
