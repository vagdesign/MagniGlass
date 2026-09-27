using System.Diagnostics;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace MagniGlass;

/// <summary>
/// Updates from GitHub Releases (as in RailSaver and 3D Earth): finds a newer
/// MagniGlass-Setup-x.y.z.exe, downloads it, verifies its size and SHA-256 and runs it
/// silently. The settings are kept and MagniGlass starts again afterwards.
/// </summary>
internal static class UpdateService
{
    public const string FeedRepo = "vagdesign/MagniGlass";
    private const string AppId = "{8C3F2A61-4D7E-4B9A-A1C5-6E2F9D0B7A34}";
    public static readonly TimeSpan Interval = TimeSpan.FromHours(12);

    public sealed record Release(Version Version, string Url, string Name, long Size, string? Sha256, string PageUrl);

    public static Version Current =>
        typeof(Program).Assembly.GetName().Version is { } v ? new Version(v.Major, v.Minor, Math.Max(0, v.Build)) : new Version(0, 0, 0);

    private static HttpClient NewClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("MagniGlass", Current.ToString(3)));
        http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return http;
    }

    /// <summary>The latest release (newer or not) and whether it is newer than this copy.</summary>
    public static async Task<(Version Latest, Release? Newer)> CheckAsync()
    {
        using var http = NewClient();
        var root = JsonNode.Parse(await http.GetStringAsync($"https://api.github.com/repos/{FeedRepo}/releases/latest"));
        string tag = root?["tag_name"]?.ToString() ?? "";
        if (!Version.TryParse(tag.TrimStart('v', 'V'), out var v)) throw new InvalidDataException($"unexpected release tag '{tag}'");
        v = new Version(v.Major, v.Minor, Math.Max(0, v.Build));
        var asset = (root?["assets"] as JsonArray)?.FirstOrDefault(a =>
        {
            string n = a?["name"]?.ToString() ?? "";
            return n.StartsWith("MagniGlass-Setup-", StringComparison.OrdinalIgnoreCase) && n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
        });
        if (v <= Current || asset == null) return (v, null);
        string? digest = asset["digest"]?.ToString();
        var release = new Release(v, asset["browser_download_url"]!.ToString(), asset["name"]!.ToString(),
            asset["size"]?.GetValue<long>() ?? 0,
            digest != null && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) ? digest[7..] : null,
            root?["html_url"]?.ToString() ?? $"https://github.com/{FeedRepo}/releases/latest");
        return (v, release);
    }

    /// <summary>True when this copy came from the installer (the portable zip does not update itself).</summary>
    public static bool IsInstalled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey($@"Software\Microsoft\Windows\CurrentVersion\Uninstall\{AppId}_is1");
                string? dir = key?.GetValue("InstallLocation") as string;
                return dir != null && AppContext.BaseDirectory.StartsWith(Path.GetFullPath(dir), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }
    }

    /// <summary>Downloads and verifies the installer; returns its path.</summary>
    public static async Task<string> DownloadAsync(Release r, IProgress<int>? progress = null)
    {
        string dir = Path.Combine(Path.GetTempPath(), "MagniGlass-Update");
        Directory.CreateDirectory(dir);
        string file = Path.Combine(dir, r.Name);
        using var http = NewClient();
        using (var resp = await http.GetAsync(r.Url, HttpCompletionOption.ResponseHeadersRead))
        {
            resp.EnsureSuccessStatusCode();
            long total = resp.Content.Headers.ContentLength ?? r.Size;
            await using var src = await resp.Content.ReadAsStreamAsync();
            await using var dst = File.Create(file);
            var buffer = new byte[81920];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buffer)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, n));
                done += n;
                if (total > 0) progress?.Report((int)(done * 100 / total));
            }
        }
        if (r.Size > 0 && new FileInfo(file).Length != r.Size) throw new InvalidDataException("the download has the wrong size");
        if (r.Sha256 != null)
        {
            await using var fs = File.OpenRead(file);
            string hash = Convert.ToHexString(await SHA256.HashDataAsync(fs));
            if (!hash.Equals(r.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("checksum mismatch");
        }
        return file;
    }

    /// <summary>
    /// Runs the installer after a short delay (so this process can exit first). It starts
    /// MagniGlass again when it is done; '!startup' leaves the start-at-sign-in choice to the app.
    /// </summary>
    public static void RunInstaller(string file, bool showProgress)
    {
        string mode = showProgress ? "/SILENT" : "/VERYSILENT";
        string args = $"/C timeout /T 2 /NOBREAK >NUL & \"{file}\" {mode} /SUPPRESSMSGBOXES /NORESTART /SP- /MERGETASKS=\"!startup,!desktopicon\"";
        Process.Start(new ProcessStartInfo("cmd.exe", args) { UseShellExecute = false, CreateNoWindow = true });
        Log.Info($"Installer started: {file}");
    }

    // ---- automatic updates ----

    private static string StampFile => Path.Combine(Settings.Folder, "last-update-check.txt");

    /// <summary>True when the last automatic check was less than 12 hours ago.</summary>
    public static bool CheckedRecently =>
        File.Exists(StampFile) && DateTime.UtcNow - File.GetLastWriteTimeUtc(StampFile) < Interval;

    public static void MarkChecked()
    {
        try
        {
            Directory.CreateDirectory(Settings.Folder);
            File.WriteAllText(StampFile, DateTime.UtcNow.ToString("o"));
        }
        catch (Exception ex) { Log.Error("Update stamp", ex); }
    }
}
