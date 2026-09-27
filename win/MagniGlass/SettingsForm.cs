using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace MagniGlass;

internal sealed class SettingsForm : Form
{
    private readonly Settings _s;
    private readonly Func<Settings, bool> _apply;
    private readonly HotkeyWindow _hotkeys;

    private readonly HotkeyBox _hotkey = new();
    private readonly Label _hotkeyNote = new() { AutoSize = true, ForeColor = SystemColors.GrayText };
    private readonly NumericUpDown _size = new() { Width = 80 };
    private readonly ComboBox _unit = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
    private readonly TrackBar _zoom = new() { Minimum = 10, Maximum = 100, TickFrequency = 10, SmallChange = 1, LargeChange = 5, Width = 260, AutoSize = false, Height = 32 };
    private readonly Label _zoomText = new() { AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont!, FontStyle.Bold) };
    private readonly CheckBox _wheel = new() { Text = "Mouse wheel changes the magnification while the glass is shown", AutoSize = true };
    private readonly ComboBox _wheelMod = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
    private readonly NumericUpDown _wheelStep = new() { Minimum = 5, Maximum = 50, Width = 60 };
    private readonly ComboBox _handle = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 150 };
    private readonly CheckBox _shadow = new() { Text = "Drop shadow", AutoSize = true };
    private readonly CheckBox _startup = new() { Text = "Start MagniGlass when I sign in to Windows", AutoSize = true };
    private readonly PictureBox _preview = new() { BorderStyle = BorderStyle.FixedSingle, SizeMode = PictureBoxSizeMode.Normal };

    private Bitmap? _sample;
    private LensCore? _previewLens;
    private bool _loading;

    private static readonly string[] Mods = { "none", "ctrl", "shift", "alt" };

    public SettingsForm(Settings settings, Func<Settings, bool> apply, HotkeyWindow hotkeys)
    {
        _s = settings;
        _apply = apply;
        _hotkeys = hotkeys;

        Text = "MagniGlass Settings";
        Icon = Program.AppIcon;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = SystemFonts.MessageBoxFont ?? Font;
        Padding = new Padding(12);

        var grid = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, Dock = DockStyle.Fill, Padding = new Padding(0) };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        void Row(string label, Control c)
        {
            grid.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, 8, 12, 4) });
            c.Margin = new Padding(0, 4, 0, 4);
            grid.Controls.Add(c);
        }
        FlowLayoutPanel Flow(params Control[] cs)
        {
            var f = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            foreach (var c in cs)
            {
                c.Anchor = AnchorStyles.Left;
                if (c is Label) c.Margin = new Padding(4, 7, 4, 0);
                f.Controls.Add(c);
            }
            return f;
        }

        _hotkey.Width = 200;
        var resetKey = new Button { Text = "Default", AutoSize = true };
        resetKey.Click += (_, _) => SetHotkey(NativeMethods.MOD_CONTROL | NativeMethods.MOD_ALT, Keys.M);
        Row("Shortcut", Flow(_hotkey, resetKey));
        grid.Controls.Add(new Label());
        _hotkeyNote.Text = "Click the box and press the new keys (e.g. Ctrl + Alt + M).";
        grid.Controls.Add(_hotkeyNote);

        _unit.Items.AddRange(new object[] { "pixels", "% of the screen" });
        Row("Glass size", Flow(_size, _unit));

        Row("Magnification", Flow(_zoom, _zoomText));

        grid.Controls.Add(new Label());
        grid.Controls.Add(_wheel);
        _wheelMod.Items.AddRange(new object[] { "no key needed", "Ctrl", "Shift", "Alt" });
        Row("Wheel", Flow(new Label { Text = "hold", AutoSize = true }, _wheelMod, new Label { Text = "step", AutoSize = true }, _wheelStep, new Label { Text = "% per notch", AutoSize = true }));

        _handle.Items.AddRange(new object[] { "Lower right", "Lower left" });
        Row("Handle", Flow(_handle, _shadow));
        grid.Controls.Add(new Label());
        grid.Controls.Add(_startup);

        _preview.Size = LogicalToDeviceUnits(new Size(440, 260));
        _preview.Margin = new Padding(0, 10, 0, 6);
        grid.Controls.Add(_preview);
        grid.SetColumnSpan(_preview, 2);

        var ok = new Button { Text = "OK", DialogResult = DialogResult.None, AutoSize = true, MinimumSize = new Size(80, 0) };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(80, 0) };
        var applyBtn = new Button { Text = "Apply", AutoSize = true, MinimumSize = new Size(80, 0) };
        ok.Click += (_, _) => { if (Commit()) Close(); };
        applyBtn.Click += (_, _) => Commit();
        cancel.Click += (_, _) => Close();
        AcceptButton = ok;
        CancelButton = cancel;
        var about = new Label { Text = $"MagniGlass {Program.Version}", AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(0, 8, 24, 0) };
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 6, 0, 0) };
        buttons.Controls.AddRange(new Control[] { about, ok, cancel, applyBtn });
        grid.Controls.Add(buttons);
        grid.SetColumnSpan(buttons, 2);
        buttons.Anchor = AnchorStyles.Right;

        Controls.Add(grid);

        LoadValues();

        _hotkey.Changed += (m, k) => SetHotkey(m, k);
        _hotkey.Enter += (_, _) => _hotkeys.Suspended = true;
        _hotkey.Leave += (_, _) => _hotkeys.Suspended = false;
        _unit.SelectedIndexChanged += (_, _) => UnitChanged();
        _size.ValueChanged += (_, _) => { if (!_loading) { StoreSize(); } };
        _zoom.ValueChanged += (_, _) => { _s.Zoom = _zoom.Value / 10.0; _zoomText.Text = $"{_s.Zoom:0.0}×"; RenderPreview(); };
        _wheel.CheckedChanged += (_, _) => { _wheelMod.Enabled = _wheelStep.Enabled = _wheel.Checked; };
        _handle.SelectedIndexChanged += (_, _) => { _s.HandleLeft = _handle.SelectedIndex == 1; RenderPreview(); };
        _shadow.CheckedChanged += (_, _) => { _s.Shadow = _shadow.Checked; RenderPreview(); };
        FormClosed += (_, _) => { _hotkeys.Suspended = false; _previewLens?.Dispose(); _sample?.Dispose(); };
    }

    private void LoadValues()
    {
        _loading = true;
        _hotkey.Set(_s.HotkeyModifiers, (Keys)_s.HotkeyKey);
        _unit.SelectedIndex = _s.SizeUnit == "percent" ? 1 : 0;
        ConfigureSize();
        _zoom.Value = Math.Clamp((int)Math.Round(_s.Zoom * 10), _zoom.Minimum, _zoom.Maximum);
        _zoomText.Text = $"{_zoom.Value / 10.0:0.0}×";
        _wheel.Checked = _s.WheelZoom;
        _wheelMod.SelectedIndex = Math.Max(0, Array.IndexOf(Mods, _s.WheelModifier));
        _wheelStep.Value = _s.WheelStep;
        _wheelMod.Enabled = _wheelStep.Enabled = _s.WheelZoom;
        _handle.SelectedIndex = _s.HandleLeft ? 1 : 0;
        _shadow.Checked = _s.Shadow;
        _startup.Checked = _s.StartWithWindows;
        _loading = false;
        RenderPreview();
    }

    private void ConfigureSize()
    {
        bool pct = _unit.SelectedIndex == 1;
        _size.Minimum = pct ? Settings.MinPercent : Settings.MinPixels;
        _size.Maximum = pct ? Settings.MaxPercent : Settings.MaxPixels;
        _size.Increment = pct ? 1 : 10;
        _size.Value = Math.Clamp(pct ? _s.SizePercent : _s.SizePixels, (int)_size.Minimum, (int)_size.Maximum);
    }

    private void UnitChanged()
    {
        if (_loading) return;
        // Carry the current size over to the other unit (on this screen).
        var scr = Screen.FromPoint(Cursor.Position).Bounds;
        int shorter = Math.Min(scr.Width, scr.Height);
        float scale = DeviceDpi / 96f;
        if (_unit.SelectedIndex == 1)
            _s.SizePercent = Math.Clamp((int)Math.Round(_s.SizePixels * scale * 100.0 / shorter), Settings.MinPercent, Settings.MaxPercent);
        else
            _s.SizePixels = Math.Clamp((int)Math.Round(_s.SizePercent / 100.0 * shorter / scale / 10) * 10, Settings.MinPixels, Settings.MaxPixels);
        _s.SizeUnit = _unit.SelectedIndex == 1 ? "percent" : "px";
        _loading = true;
        ConfigureSize();
        _loading = false;
    }

    private void StoreSize()
    {
        if (_unit.SelectedIndex == 1) _s.SizePercent = (int)_size.Value;
        else _s.SizePixels = (int)_size.Value;
    }

    private void SetHotkey(uint mods, Keys key)
    {
        _hotkey.Set(mods, key);
        bool same = mods == _s.HotkeyModifiers && (int)key == _s.HotkeyKey;
        _s.HotkeyModifiers = mods;
        _s.HotkeyKey = (int)key;
        if (!same && !_hotkeys.IsFree(mods, (uint)key))
        {
            _hotkeyNote.Text = $"{HotkeyFormat.Describe(mods, key)} is used by another program: pick another.";
            _hotkeyNote.ForeColor = Color.Firebrick;
        }
        else
        {
            _hotkeyNote.Text = "Press it anywhere to show or hide the glass.";
            _hotkeyNote.ForeColor = SystemColors.GrayText;
        }
    }

    /// <summary>Called from the wheel hook while the settings are open.</summary>
    public void ShowZoom(float zoom)
    {
        if (IsDisposed) return;
        _zoom.Value = Math.Clamp((int)Math.Round(zoom * 10), _zoom.Minimum, _zoom.Maximum);
    }

    private bool Commit()
    {
        StoreSize();
        _s.SizeUnit = _unit.SelectedIndex == 1 ? "percent" : "px";
        _s.Zoom = _zoom.Value / 10.0;
        _s.WheelZoom = _wheel.Checked;
        _s.WheelModifier = Mods[Math.Max(0, _wheelMod.SelectedIndex)];
        _s.WheelStep = (int)_wheelStep.Value;
        _s.HandleLeft = _handle.SelectedIndex == 1;
        _s.Shadow = _shadow.Checked;
        _s.StartWithWindows = _startup.Checked;
        if (_apply(_s.Clone())) return true;
        _hotkeyNote.Text = $"{_s.HotkeyText} could not be registered (another program uses it). The old shortcut was kept.";
        _hotkeyNote.ForeColor = Color.Firebrick;
        return false;
    }

    // ---- preview: the real lens renderer over a sample page ----

    private void RenderPreview()
    {
        if (_loading || _preview.Width <= 0) return;
        try
        {
            int w = _preview.ClientSize.Width, h = _preview.ClientSize.Height;
            _sample ??= SamplePage(w, h);
            int d = (int)(h * 0.52);
            int flags = _s.LensFlags;
            if (_previewLens == null || _previewLens.Flags != flags || _previewLens.Diameter != d)
            {
                _previewLens?.Dispose();
                _previewLens = new LensCore(d, (float)_s.Zoom, flags);
            }
            var lens = _previewLens;
            lens.SetZoom((float)_s.Zoom);
            int cx = _s.HandleLeft ? (int)(w * 0.62) : (int)(w * 0.38), cy = (int)(h * 0.40);

            var frame = new Bitmap(lens.Width, lens.Height, PixelFormat.Format32bppPArgb);
            var fd = frame.LockBits(new Rectangle(0, 0, frame.Width, frame.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppPArgb);
            var sd = _sample.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                lens.DrawStatic(fd.Scan0, fd.Stride);
                lens.DrawGlass(sd.Scan0, w, h, sd.Stride, cx, cy, fd.Scan0, fd.Stride);
            }
            finally
            {
                _sample.UnlockBits(sd);
                frame.UnlockBits(fd);
            }
            var output = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(output))
            {
                g.DrawImageUnscaled(_sample, 0, 0);
                g.DrawImageUnscaled(frame, cx - lens.CenterX, cy - lens.CenterY);
            }
            frame.Dispose();
            var old = _preview.Image;
            _preview.Image = output;
            old?.Dispose();
        }
        catch (DllNotFoundException ex) { Log.Error("Preview", ex); }
    }

    private Bitmap SamplePage(int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.Clear(Color.FromArgb(250, 250, 247));
        float s = DeviceDpi / 96f;
        using var title = new Font("Segoe UI Semibold", 20 * s, GraphicsUnit.Pixel);
        using var body = new Font("Segoe UI", 12 * s, GraphicsUnit.Pixel);
        using var ink = new SolidBrush(Color.FromArgb(40, 40, 46));
        using var soft = new SolidBrush(Color.FromArgb(110, 110, 118));
        g.DrawString("The quick brown fox", title, ink, 14 * s, 10 * s);
        string text = "MagniGlass follows your pointer with a real lens: fine print, icons and pixels " +
                      "come up large and sharp, the edge of the glass bends the page like a real magnifier " +
                      "and the chrome catches the light. Scroll the mouse wheel to zoom in and out. " +
                      "0123456789 · ABCDEFGHIJKLMNOPQRSTUVWXYZ · abcdefghijklmnopqrstuvwxyz";
        g.DrawString(text, body, soft, new RectangleF(14 * s, 44 * s, w - 28 * s, h * 0.5f));
        Color[] sw = { Color.FromArgb(230, 57, 70), Color.FromArgb(244, 162, 97), Color.FromArgb(233, 196, 106), Color.FromArgb(42, 157, 143), Color.FromArgb(38, 70, 83), Color.FromArgb(69, 123, 157) };
        float bw = (w - 28 * s) / sw.Length;
        for (int i = 0; i < sw.Length; i++)
        {
            using var b = new SolidBrush(sw[i]);
            float bh = h * (0.12f + 0.05f * ((i * 7) % 5));
            g.FillRectangle(b, 14 * s + i * bw + 3 * s, h - 12 * s - bh, bw - 6 * s, bh);
        }
        return bmp;
    }
}

/// <summary>Records a key combination: click it, press the keys.</summary>
internal sealed class HotkeyBox : TextBox
{
    public event Action<uint, Keys>? Changed;

    public HotkeyBox()
    {
        ReadOnly = true;
        BackColor = SystemColors.Window;
        Cursor = Cursors.Hand;
        ShortcutsEnabled = false;
    }

    public void Set(uint mods, Keys key) => Text = HotkeyFormat.Describe(mods, key);

    protected override bool IsInputKey(Keys keyData) => true;

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        // Let Tab / Alt+F4 etc. reach us instead of the dialog.
        if (Focused && (msg.Msg == 0x100 || msg.Msg == 0x104))
        {
            OnKeyDown(new KeyEventArgs(keyData));
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        e.SuppressKeyPress = true;
        e.Handled = true;
        Keys key = e.KeyCode;
        if (key is Keys.ControlKey or Keys.ShiftKey or Keys.Menu or Keys.LWin or Keys.RWin or Keys.None) return;
        uint mods = 0;
        if (e.Control) mods |= NativeMethods.MOD_CONTROL;
        if (e.Alt) mods |= NativeMethods.MOD_ALT;
        if (e.Shift) mods |= NativeMethods.MOD_SHIFT;
        if ((NativeMethods.GetAsyncKeyState((int)Keys.LWin) & 0x8000) != 0 || (NativeMethods.GetAsyncKeyState((int)Keys.RWin) & 0x8000) != 0)
            mods |= NativeMethods.MOD_WIN;
        bool functionKey = key is >= Keys.F1 and <= Keys.F24;
        if (mods == 0 && !functionKey) return; // plain letters would stop working in every program
        Changed?.Invoke(mods, key);
    }
}
