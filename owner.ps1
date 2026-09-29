# owner.ps1 - dock the overlay to ZCode's main window (daemon)
# Strategy (no GWL_HWNDPARENT - it fails silently when ZCode recreates windows):
#   * WinEvent hooks: EVENT_OBJECT_LOCATIONCHANGE on the ZCode window (move/resize
#     follow) and on the overlay (user drag updates the relative offset);
#     EVENT_SYSTEM_FOREGROUND re-inserts the overlay right above ZCode whenever
#     ZCode gets activated (plain activation would otherwise cover the overlay).
#   * Positioning uses SetWindowPos with hWndInsertAfter = ZCode's window, so the
#     overlay always sits directly above it: covered together, restored together.
#   * The 2s loop re-finds both windows (handles change when ZCode recreates its
#     window), re-arms hooks, hides the overlay while ZCode is minimized.
# Exits when the overlay process is gone. ASCII-only file (PS 5.1 / BOM reason).
param([string]$OverlayDir = "D:\workspace\zcode-token-meter")
if (-not (Test-Path $OverlayDir)) { exit 1 }
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Diagnostics;
public class Docking {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint id, uint flags);
  [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
  public delegate void WinEventProc(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
  public struct R { public int L, T, Rt, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public R rcMonitor; public R rcWork; public int dwFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptx, pty; }
  [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG m, IntPtr h, uint mn, uint mx, uint remove);

  static IntPtr zc = IntPtr.Zero, ov = IntPtr.Zero;
  static IntPtr hLoc = IntPtr.Zero, hFg = IntPtr.Zero;
  static WinEventProc procLoc, procFg; // rooted delegates
  static EnumProc _findCb; // rooted: local-only delegates get GC'd mid-EnumWindows
  public static int dx = 0, dy = 0;
  static bool offsetReady = false;
  static int lastSelfMoveTick = 0;

  static R Rect(IntPtr h) { var r = new R(); GetWindowRect(h, out r); return r; }
  static bool NotCloaked(IntPtr h) { int c; try { DwmGetWindowAttribute(h, 14 /*DWMWA_CLOAKED*/, out c, 4); return c == 0; } catch { return true; } }


  static System.Collections.Generic.HashSet<uint> _pids;
  static int _wantW, _wantH; static long _matchVis, _matchAny, _fallback;
  // The overlay card is the window whose size matches the config (w x h, +/-40%).
  // Do NOT require visibility - after we hide it, a visibility-filtered search
  // finds nothing and the daemon deadlocks with the window stuck hidden.
  // The size match also rejects Electron's hidden helper windows (e.g. 1440x753).
  public static long FindOverlayWindow(uint[] pids, int wantW, int wantH) {
    _pids = new System.Collections.Generic.HashSet<uint>(pids);
    _wantW = wantW; _wantH = wantH; _matchVis = 0; _matchAny = 0; _fallback = 0;
    _findCb = (h, l) => {
      uint w; GetWindowThreadProcessId(h, out w);
      if (_pids.Contains(w) && NotCloaked(h)) {
        var r = new R(); GetWindowRect(h, out r);
        int ww = r.Rt - r.L, hh = r.B - r.T;
        if (ww < 80 || ww > 500 || hh < 30 || hh > 600) return true; // card/capsule range only
        bool sizeOk = Math.Abs(ww - _wantW) <= _wantW * 0.4 && Math.Abs(hh - _wantH) <= _wantH * 0.4;
        if (sizeOk) {
          if (IsWindowVisible(h)) { if (_matchVis == 0) _matchVis = h.ToInt64(); }
          else if (_matchAny == 0) _matchAny = h.ToInt64();
        }
        if (IsWindowVisible(h) && ww >= 150) { var a = ww * hh; /* fallback: first visible decent window */ if (_fallback == 0) _fallback = h.ToInt64(); }
      }
      return true;
    };
    EnumWindows(_findCb, IntPtr.Zero);
    if (_matchVis != 0) return _matchVis;
    if (_matchAny != 0) return _matchAny;
    return _fallback;
  }

  // .NET MainWindowHandle goes stale after ZCode recreates its window; find the
  // main window ourselves. IMPORTANT: never call GetWindowText inside the enum
  // callback - it hangs on dying windows and aborts the whole enumeration (this
  // caused a day of flaky lookups). Collect candidates first, then read titles
  // via SendMessageTimeout(WM_GETTEXT) with a short timeout.
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wp, System.Text.StringBuilder lp, uint flags, uint timeout, out IntPtr result);
  static System.Collections.Generic.List<long> _cand;
  static string TitleOf(IntPtr h) {
    var sb = new System.Text.StringBuilder(64);
    IntPtr res;
    IntPtr r = SendMessageTimeout(h, 0x000D /*WM_GETTEXT*/, (IntPtr)64, sb, 2 /*SMTO_ABORTIFHUNG*/, 120, out res);
    return r != IntPtr.Zero ? sb.ToString() : "";
  }
  public static long FindZcodeMain() {
    var pids = new System.Collections.Generic.HashSet<uint>();
    foreach (var p in Process.GetProcessesByName("ZCode")) pids.Add((uint)p.Id);
    IntPtr fg = GetForegroundWindow();
    _cand = new System.Collections.Generic.List<long>();
    _findCb = (h, l) => {
      uint w; GetWindowThreadProcessId(h, out w);
      if (pids.Contains(w) && IsWindowVisible(h) && NotCloaked(h)) _cand.Add(h.ToInt64());
      return true;
    };
    EnumWindows(_findCb, IntPtr.Zero);
    long best = 0; int ba = 0;
    foreach (var hv in _cand) {
      var h = (IntPtr)hv;
      if (TitleOf(h) != "ZCode") continue;
      // reject the force-update prompt: it is a small MODAL child (has an owner)
      // of the main window - docking to it hides the overlay or covers its buttons
      if (GetWindowLongPtr(h, -8) != IntPtr.Zero) continue;
      var r = new R(); GetWindowRect(h, out r);
      if ((r.Rt - r.L) < 500 || (r.B - r.T) < 400) continue;
      if (h == fg) return hv; // prefer the foreground one
      int a = (r.Rt - r.L) * (r.B - r.T);
      if (a > ba) { ba = a; best = hv; }
    }
    return best;
  }

  static void OnLoc(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
    if (idObject != 0) return;
    if (hwnd == zc) {
      if (offsetReady) ApplyOffset();
    } else if (hwnd == ov) {
      if (Environment.TickCount - lastSelfMoveTick < 250) return; // self move
      var z = Rect(zc);
      if (z.Rt > z.L) { var o = Rect(ov); dx = o.L - z.L; dy = o.T - z.T; offsetReady = true; }
    }
  }

  static void OnFg(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
    if (hwnd == zc && offsetReady) ApplyOffset(); // ZCode activated: re-insert above it
  }

  // position the overlay at (zc + offset), clamped INSIDE the ZCode window rect
  // (6px margin) so it behaves like a panel of the app; fall back to the monitor
  // work area when the window is smaller than the overlay. z-order untouched -
  // the window is topmost and visibility is governed by ShouldShow().
  public static void ApplyOffset() {
    var z = Rect(zc);
    if (z.Rt <= z.L || z.L < -10000) return; // minimized windows sit at -32000: keep last good position
    var o = Rect(ov);
    int ow = o.Rt - o.L, oh = o.B - o.T;
    int tx = z.L + dx, ty = z.T + dy;
    if (z.Rt - z.L > ow + 12 && z.B - z.T > oh + 12) {
      if (tx < z.L + 6) tx = z.L + 6;
      if (ty < z.T + 6) ty = z.T + 6;
      if (tx + ow > z.Rt - 6) tx = z.Rt - 6 - ow;
      if (ty + oh > z.B - 6) ty = z.B - 6 - oh;
    } else {
      IntPtr mon = MonitorFromWindow(zc, 2);
      var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
      if (GetMonitorInfo(mon, ref mi)) {
        if (tx < mi.rcWork.L) tx = mi.rcWork.L;
        if (ty < mi.rcWork.T) ty = mi.rcWork.T;
        if (tx + ow > mi.rcWork.Rt) tx = mi.rcWork.Rt - ow;
        if (ty + oh > mi.rcWork.B) ty = mi.rcWork.B - oh;
      }
    }
    var cur = Rect(ov);
    if (Math.Abs(cur.L - tx) >= 1 || Math.Abs(cur.T - ty) >= 1) {
      lastSelfMoveTick = Environment.TickCount;
      SetWindowPos(ov, IntPtr.Zero, tx, ty, 0, 0, 0x0001 /*SWP_NOSIZE*/ | 0x0010 /*SWP_NOACTIVATE*/ | 0x0004 /*SWP_NOZORDER*/);
    }
  }

  public static void Ensure(IntPtr zcH, IntPtr ovH) {
    if (zcH == zc && ovH == ov && hLoc != IntPtr.Zero) return;
    if (hLoc != IntPtr.Zero) { UnhookWinEvent(hLoc); hLoc = IntPtr.Zero; }
    if (hFg != IntPtr.Zero) { UnhookWinEvent(hFg); hFg = IntPtr.Zero; }
    zc = zcH; ov = ovH;
    if (zc == IntPtr.Zero || ov == IntPtr.Zero) return;
    if (!offsetReady) {
      var z = Rect(zc); var o = Rect(ov);
      if (z.Rt > z.L && o.Rt > o.L) { dx = o.L - z.L; dy = o.T - z.T; offsetReady = true; ApplyOffset(); }
    }
    procLoc = OnLoc; procFg = OnFg;
    uint zcPid = 0; GetWindowThreadProcessId(zc, out zcPid);
    uint ovPid = 0; GetWindowThreadProcessId(ov, out ovPid);
    // one hook per pid covers both windows' LOCATIONCHANGE
    hLoc = SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, procLoc, 0, 0, 0);
    hFg = SetWinEventHook(0x0003 /*EVENT_SYSTEM_FOREGROUND*/, 0x0003, IntPtr.Zero, procFg, 0, 0, 0);
    ApplyOffset();
  }

  // visibility: hide while ZCode is minimized or occluded by the foreground
  // window on the same screen (foreground on another screen = no occlusion)
  public static bool ShouldShow() {
    if (IsIconic(zc)) return false;
    IntPtr fg = GetForegroundWindow();
    if (fg == zc || fg == ov || fg == IntPtr.Zero) return true;
    uint fgPid = 0; GetWindowThreadProcessId(fg, out fgPid);
    // ignore foreground windows belonging to our own overlay process
    uint ovPid = 0; GetWindowThreadProcessId(ov, out ovPid);
    if (fgPid == ovPid) return true;
    if (MonitorFromWindow(fg, 2) != MonitorFromWindow(zc, 2)) return true; // other screen
    var f = Rect(fg); var z = Rect(zc);
    bool intersect = (f.L < z.Rt) && (z.L < f.Rt) && (f.T < z.B) && (z.T < f.B);
    return !intersect;
  }
  public static void HideWhenNoMain(IntPtr ovH) {
    if (ovH != IntPtr.Zero && IsWindowVisible(ovH)) ShowWindow(ovH, 0);
  }
  public static void SyncVisibility() {
    if (zc == IntPtr.Zero || ov == IntPtr.Zero) return;
    bool want = ShouldShow();
    bool vis = IsWindowVisible(ov);
    if (!want && vis) { ShowWindow(ov, 0 /*SW_HIDE*/); }
    else if (want && !vis) { ShowWindow(ov, 4 /*SW_SHOWNOACTIVATE*/); ApplyOffset(); }
  }

  public static void Pump(int ms) {
    var sw = Stopwatch.StartNew();
    MSG m;
    while (sw.ElapsedMilliseconds < ms) {
      while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1 /*PM_REMOVE*/)) { }
      Thread.Sleep(15);
    }
  }
}
"@
while ($true) {
  # Match ALL electron processes whose exe lives under the overlay dir (main +
  # children); a single pid is unreliable - child processes stay alive with no
  # windows and leave the daemon idling on the wrong pid.
  $ovPids = @(Get-CimInstance Win32_Process -Filter "Name='electron.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -like "$OverlayDir*" } | Select-Object -ExpandProperty ProcessId)
  if ($ovPids.Count -eq 0) { break }  # overlay app fully closed, daemon exits
  $cfgW = 260; $cfgH = 194
  try { $c = Get-Content "$env:USERPROFILE\.zcode\zcode-token-meter.json" -Raw | ConvertFrom-Json; if ($c.w) { $cfgW = [int]$c.w }; if ($c.h) { $cfgH = [int]$c.h } } catch {}
  $ovH = [Docking]::FindOverlayWindow([uint32[]]$ovPids, $cfgW, $cfgH)
  if ($ovH -eq 0) {
    Start-Sleep -Milliseconds 400
    continue
  }
  $zcH = [Docking]::FindZcodeMain()
  if ($zcH -ne 0) {
    $script:noMain = 0
    [Docking]::Ensure([IntPtr]$zcH, [IntPtr]$ovH)
    [Docking]::SyncVisibility()
  } else {
    # main window gone (update handoff / tray / close): hide after ~1.2s
    $script:noMain = 1 + $(if ($script:noMain) { $script:noMain } else { 0 })
    if ($script:noMain -ge 3) { [Docking]::HideWhenNoMain([IntPtr]$ovH) }
  }
  [Docking]::Pump(400)
}
