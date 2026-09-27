using System.Text.Json;
using Microsoft.Win32;

namespace MagniGlass;

internal sealed class Settings
{
    public const double MinZoom = 1.0, MaxZoom = 10.0;
    public const int MinPixels = 80, MaxPixels = 1600;
    public const int MinPercent = 5, MaxPercent = 90;

    /// <summary>Shortcut that shows / hides the glass (RegisterHotKey modifiers + virtual key).</summary>
    public uint HotkeyModifiers { get; set; } = NativeMethods.MOD_CONTROL | NativeMethods.MOD_ALT;
    public int HotkeyKey { get; set; } = (int)Keys.M;

    /// <summary>"px": <see cref="SizePixels"/> (at 100 % display scaling); "percent": of the screen's shorter side.</summary>
    public string SizeUnit { get; set; } = "px";
    public int SizePixels { get; set; } = 320;
    public int SizePercent { get; set; } = 30;

    public double Zoom { get; set; } = 2.5;
    public bool WheelZoom { get; set; } = true;
    /// <summary>Key to hold for the wheel to zoom: "none", "ctrl", "shift" or "alt".</summary>
    public string WheelModifier { get; set; } = "none";
    /// <summary>Zoom change per wheel notch, in percent.</summary>
    public int WheelStep { get; set; } = 15;

    public bool HandleLeft { get; set; }
    public bool Shadow { get; set; } = true;
    public bool StartWithWindows { get; set; } = true;
    /// <summary>Install new releases automatically (checked at most every 12 hours).</summary>
    public bool AutoUpdate { get; set; } = true;
    public bool FirstRun { get; set; } = true;

    public Settings Clone() => (Settings)MemberwiseClone();

    public void Normalize()
    {
        Zoom = Math.Clamp(Zoom, MinZoom, MaxZoom);
        SizePixels = Math.Clamp(SizePixels, MinPixels, MaxPixels);
        SizePercent = Math.Clamp(SizePercent, MinPercent, MaxPercent);
        WheelStep = Math.Clamp(WheelStep, 5, 50);
        if (SizeUnit != "percent") SizeUnit = "px";
        if (WheelModifier is not ("none" or "ctrl" or "shift" or "alt")) WheelModifier = "none";
        if (HotkeyKey <= 0) HotkeyKey = (int)Keys.M;
    }

    /// <summary>Glass diameter in physical pixels on a monitor.</summary>
    public int DiameterFor(int monitorWidth, int monitorHeight, uint dpi)
    {
        int d = SizeUnit == "percent"
            ? (int)Math.Round(Math.Min(monitorWidth, monitorHeight) * SizePercent / 100.0)
            : (int)Math.Round(SizePixels * dpi / 96.0);
        return Math.Clamp(d, 32, 4096);
    }

    public int LensFlags => (HandleLeft ? LensCore.HandleLeft : 0) | (Shadow ? 0 : LensCore.NoShadow);

    public string HotkeyText => HotkeyFormat.Describe(HotkeyModifiers, (Keys)HotkeyKey);

    // ---- storage ----

    public static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MagniGlass");
    private static string FilePath => Path.Combine(Folder, "settings.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath) && JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) is { } s)
            {
                s.Normalize();
                return s;
            }
        }
        catch (Exception ex) { Log.Error("Reading settings", ex); }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            string tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, Json));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception ex) { Log.Error("Saving settings", ex); }
        ApplyStartup();
    }

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public void ApplyStartup()
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (StartWithWindows) key.SetValue("MagniGlass", $"\"{Environment.ProcessPath}\" --background");
            else key.DeleteValue("MagniGlass", throwOnMissingValue: false);
        }
        catch (Exception ex) { Log.Error("Start with Windows", ex); }
    }
}

internal static class HotkeyFormat
{
    public static string Describe(uint mods, Keys key)
    {
        var parts = new List<string>();
        if ((mods & NativeMethods.MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((mods & NativeMethods.MOD_ALT) != 0) parts.Add("Alt");
        if ((mods & NativeMethods.MOD_SHIFT) != 0) parts.Add("Shift");
        if ((mods & NativeMethods.MOD_WIN) != 0) parts.Add("Win");
        parts.Add(KeyName(key));
        return string.Join(" + ", parts);
    }

    public static string KeyName(Keys key) => key switch
    {
        >= Keys.D0 and <= Keys.D9 => ((char)('0' + (key - Keys.D0))).ToString(),
        >= Keys.NumPad0 and <= Keys.NumPad9 => "Num " + (key - Keys.NumPad0),
        Keys.Oemplus => "=",
        Keys.OemMinus => "-",
        Keys.Oemcomma => ",",
        Keys.OemPeriod => ".",
        Keys.OemQuestion => "/",
        Keys.OemSemicolon => ";",
        Keys.OemQuotes => "'",
        Keys.OemOpenBrackets => "[",
        Keys.OemCloseBrackets => "]",
        Keys.OemPipe => "\\",
        Keys.Oemtilde => "`",
        Keys.Add => "Num +",
        Keys.Subtract => "Num -",
        Keys.Multiply => "Num *",
        Keys.Divide => "Num /",
        Keys.Next => "Page Down",
        Keys.Prior => "Page Up",
        Keys.Return => "Enter",
        Keys.Back => "Backspace",
        Keys.Capital => "Caps Lock",
        Keys.Scroll => "Scroll Lock",
        Keys.Snapshot => "Print Screen",
        _ => key.ToString(),
    };
}

internal static class Log
{
    private static readonly object Gate = new();

    public static void Info(string message) => Write("INFO", message);
    public static void Error(string what, Exception? ex) => Write("ERROR", $"{what}: {ex}");

    private static void Write(string level, string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Settings.Folder);
                string path = Path.Combine(Settings.Folder, "magniglass.log");
                if (File.Exists(path) && new FileInfo(path).Length > 512 * 1024) File.Delete(path);
                File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {level} {message}{Environment.NewLine}");
            }
        }
        catch { /* logging must never break the app */ }
    }
}
