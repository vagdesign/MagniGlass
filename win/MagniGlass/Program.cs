using System.Runtime.InteropServices;
using static MagniGlass.NativeMethods;

namespace MagniGlass;

/// <summary>
/// MagniGlass runs in the notification area. The shortcut (default Ctrl+Alt+M) shows or
/// hides the glass; while it is shown the mouse wheel changes the magnification.
///   MagniGlass.exe               start (or open the settings if already running)
///   MagniGlass.exe --background  start without opening anything (used at sign-in)
///   MagniGlass.exe --settings    open the settings
/// </summary>
internal static class Program
{
    private const string MutexName = "MagniGlass.SingleInstance";
    private const string ShowSettingsEvent = "MagniGlass.ShowSettings";

    [STAThread]
    private static void Main(string[] args)
    {
        bool background = args.Any(a => a.Equals("--background", StringComparison.OrdinalIgnoreCase));
        bool settings = args.Any(a => a.Equals("--settings", StringComparison.OrdinalIgnoreCase));

        using var mutex = new Mutex(true, MutexName, out bool first);
        if (!first)
        {
            // Already running: ask that copy to open its settings.
            if (!background && EventWaitHandle.TryOpenExisting(ShowSettingsEvent, out var ev)) ev.Set();
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => Log.Error("UI thread", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Error("Unhandled", e.ExceptionObject as Exception);
        Log.Info($"MagniGlass {Version} {string.Join(' ', args)}");

        using var showSettings = new EventWaitHandle(false, EventResetMode.AutoReset, ShowSettingsEvent);
        using var app = new TrayApp(showSettings, openSettings: settings);
        Application.Run(app);
    }

    public static string Version =>
        typeof(Program).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0.0.0";

    public static Icon AppIcon
    {
        get
        {
            using var s = typeof(Program).Assembly.GetManifestResourceStream("MagniGlass.ico");
            return s != null ? new Icon(s) : SystemIcons.Application;
        }
    }
}

internal sealed class TrayApp : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly ToolStripMenuItem _toggleItem;
    private readonly HotkeyWindow _hotkeys;
    private readonly Magnifier _magnifier;
    private readonly MouseHook _wheel;
    private readonly RegisteredWaitHandle _wait;
    private readonly SynchronizationContext _ui;
    private Settings _settings;
    private SettingsForm? _settingsForm;

    public TrayApp(EventWaitHandle showSettings, bool openSettings)
    {
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _settings = Settings.Load();
        _settings.ApplyStartup();
        _magnifier = new Magnifier(_settings);
        _wheel = new MouseHook(OnWheel);

        _toggleItem = new ToolStripMenuItem("Show magnifier", null, (_, _) => Toggle());
        var menu = new ContextMenuStrip();
        menu.Items.Add(_toggleItem);
        menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => ExitThread());
        _tray = new NotifyIcon
        {
            Icon = Program.AppIcon,
            Text = "MagniGlass",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) Toggle(); };
        _tray.MouseDoubleClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowSettings(); };

        _hotkeys = new HotkeyWindow(Toggle);
        RegisterHotkey(showErrors: true);

        _wait = ThreadPool.RegisterWaitForSingleObject(showSettings, (_, _) => _ui.Post(_ => ShowSettings(), null), null, -1, false);

        if (openSettings) _ui.Post(_ => ShowSettings(), null);
        else if (_settings.FirstRun)
        {
            _tray.ShowBalloonTip(6000, "MagniGlass is ready",
                $"Press {_settings.HotkeyText} to show or hide the magnifier. Scroll the mouse wheel to zoom.", ToolTipIcon.Info);
        }
        if (_settings.FirstRun)
        {
            _settings.FirstRun = false;
            _settings.Save();
        }
        UpdateMenu();
    }

    private bool RegisterHotkey(bool showErrors)
    {
        bool ok = _hotkeys.Register(_settings.HotkeyModifiers, (uint)_settings.HotkeyKey);
        if (!ok)
        {
            Log.Info($"Shortcut {_settings.HotkeyText} is taken");
            if (showErrors)
                _tray.ShowBalloonTip(8000, "MagniGlass",
                    $"The shortcut {_settings.HotkeyText} is used by another program. Pick another one in Settings.", ToolTipIcon.Warning);
        }
        return ok;
    }

    private void Toggle()
    {
        bool show = !_magnifier.Visible;
        _magnifier.Visible = show;
        if (show && _settings.WheelZoom) _wheel.Install();
        else _wheel.Uninstall();
        if (!show) SaveZoom();
        UpdateMenu();
    }

    private void UpdateMenu()
    {
        _toggleItem.Text = (_magnifier.Visible ? "Hide magnifier" : "Show magnifier") + "\t" + _settings.HotkeyText;
        _tray.Text = "MagniGlass  (" + _settings.HotkeyText + ")";
    }

    /// <summary>Low-level hook callback (UI thread): true swallows the wheel event.</summary>
    private bool OnWheel(int delta)
    {
        if (!_magnifier.Visible || !_settings.WheelZoom) return false;
        bool held = _settings.WheelModifier switch
        {
            "ctrl" => KeyDown(Keys.ControlKey),
            "shift" => KeyDown(Keys.ShiftKey),
            "alt" => KeyDown(Keys.Menu),
            _ => true,
        };
        if (!held) return false;
        double step = 1 + _settings.WheelStep / 100.0;
        _magnifier.Zoom = (float)(_magnifier.Zoom * Math.Pow(step, delta / 120.0));
        _settingsForm?.ShowZoom(_magnifier.Zoom);
        return true;
    }

    private static bool KeyDown(Keys k) => (GetAsyncKeyState((int)k) & 0x8000) != 0;

    private void SaveZoom()
    {
        double z = Math.Round(_magnifier.Zoom, 2);
        if (Math.Abs(z - _settings.Zoom) < 0.005) return;
        _settings.Zoom = z;
        _settings.Save();
    }

    private void ShowSettings()
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            return;
        }
        var s = _settings.Clone();
        s.Zoom = Math.Round(_magnifier.Zoom, 2);
        _settingsForm = new SettingsForm(s, ApplySettings, _hotkeys);
        _settingsForm.FormClosed += (_, _) => _settingsForm = null;
        _settingsForm.Show();
        _settingsForm.Activate();
    }

    /// <summary>Called by the settings window on OK / Apply. Returns false if the shortcut is taken.</summary>
    private bool ApplySettings(Settings s)
    {
        s.Normalize();
        var old = _settings;
        _settings = s;
        bool ok = true;
        if (old.HotkeyModifiers != s.HotkeyModifiers || old.HotkeyKey != s.HotkeyKey || !_hotkeys.Registered)
        {
            ok = RegisterHotkey(showErrors: false);
            if (!ok)
            {
                _settings.HotkeyModifiers = old.HotkeyModifiers;
                _settings.HotkeyKey = old.HotkeyKey;
                RegisterHotkey(showErrors: false);
            }
        }
        _settings.Save();
        _magnifier.Apply(_settings);
        if (_magnifier.Visible && _settings.WheelZoom) _wheel.Install();
        else _wheel.Uninstall();
        UpdateMenu();
        return ok;
    }

    protected override void ExitThreadCore()
    {
        SaveZoom();
        _tray.Visible = false;
        base.ExitThreadCore();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _wait.Unregister(null);
            _wheel.Dispose();
            _hotkeys.Dispose();
            _magnifier.Dispose();
            _tray.Dispose();
        }
        base.Dispose(disposing);
    }
}

/// <summary>Receives the global shortcut (RegisterHotKey).</summary>
internal sealed class HotkeyWindow : NativeWindow, IDisposable
{
    private const int Id = 1;
    private readonly Action _pressed;

    public HotkeyWindow(Action pressed)
    {
        _pressed = pressed;
        CreateHandle(new CreateParams { Caption = "MagniGlass hotkeys" });
    }

    public bool Registered { get; private set; }

    /// <summary>While the settings window records a new shortcut, the old one must not fire.</summary>
    public bool Suspended { get; set; }

    public bool Register(uint mods, uint vk)
    {
        Unregister();
        Registered = RegisterHotKey(Handle, Id, mods | MOD_NOREPEAT, vk);
        return Registered;
    }

    public void Unregister()
    {
        if (Registered) UnregisterHotKey(Handle, Id);
        Registered = false;
    }

    /// <summary>True if the combination can be registered (tries it on a spare id).</summary>
    public bool IsFree(uint mods, uint vk)
    {
        if (!RegisterHotKey(Handle, Id + 1, mods | MOD_NOREPEAT, vk)) return false;
        UnregisterHotKey(Handle, Id + 1);
        return true;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == Id && !Suspended) _pressed();
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        Unregister();
        DestroyHandle();
    }
}

/// <summary>Low-level mouse hook, installed only while the glass is shown, for wheel zoom.</summary>
internal sealed class MouseHook : IDisposable
{
    private readonly Func<int, bool> _onWheel;
    private readonly HookProc _proc;
    private IntPtr _hook;

    public MouseHook(Func<int, bool> onWheel)
    {
        _onWheel = onWheel;
        _proc = Callback;
    }

    public void Install()
    {
        if (_hook != IntPtr.Zero) return;
        _hook = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero) Log.Info("Mouse hook failed: " + Marshal.GetLastWin32Error());
    }

    public void Uninstall()
    {
        if (_hook == IntPtr.Zero) return;
        UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && wParam.ToInt32() == WM_MOUSEWHEEL)
        {
            var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            int delta = (short)(info.mouseData >> 16);
            try
            {
                if (delta != 0 && _onWheel(delta)) return new IntPtr(1);
            }
            catch (Exception ex) { Log.Error("Wheel", ex); }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    public void Dispose() => Uninstall();
}
