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
param([int]$OverlayPid = 0)
if ($OverlayPid -le 0) { exit 1 }
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
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint id, uint flags);
  [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
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
  static bool hiddenByUs = false;

  static R Rect(IntPtr h) { var r = new R(); GetWindowRect(h, out r); return r; }

  public static long FindBiggestVisible(uint pid) {
    long best = 0; int ba = 0;
    _findCb = (h, l) => {
      uint w; GetWindowThreadProcessId(h, out w);
      if (w == pid && IsWindowVisible(h)) {
        var r = new R(); GetWindowRect(h, out r);
        int a = (r.Rt - r.L) * (r.B - r.T);
        if (a > ba) { ba = a; best = h.ToInt64(); }
      }
      return true;
    };
    EnumWindows(_findCb, IntPtr.Zero);
    return best;
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
      if (pids.Contains(w) && IsWindowVisible(h)) _cand.Add(h.ToInt64());
      return true;
    };
    EnumWindows(_findCb, IntPtr.Zero);
    long best = 0; int ba = 0;
    foreach (var hv in _cand) {
      var h = (IntPtr)hv;
      if (TitleOf(h) != "ZCode") continue;
      if (h == fg) return hv; // prefer the foreground one
      var r = new R(); GetWindowRect(h, out r);
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

  // position the overlay at (zc + offset) and directly above zc in z-order
  public static void ApplyOffset() {
    var z = Rect(zc);
    if (z.Rt <= z.L) return;
    int tx = z.L + dx, ty = z.T + dy;
    IntPtr mon = MonitorFromWindow(zc, 2);
    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
    if (GetMonitorInfo(mon, ref mi)) {
      var o = Rect(ov); int ow = o.Rt - o.L, oh = o.B - o.T;
      if (tx < mi.rcWork.L) tx = mi.rcWork.L;
      if (ty < mi.rcWork.T) ty = mi.rcWork.T;
      if (tx + ow > mi.rcWork.Rt) tx = mi.rcWork.Rt - ow;
      if (ty + oh > mi.rcWork.B) ty = mi.rcWork.B - oh;
    }
    var cur = Rect(ov);
    if (Math.Abs(cur.L - tx) >= 1 || Math.Abs(cur.T - ty) >= 1) {
      lastSelfMoveTick = Environment.TickCount;
      SetWindowPos(ov, zc, tx, ty, 0, 0, 0x0001 /*SWP_NOSIZE*/ | 0x0010 /*SWP_NOACTIVATE*/);
    } else {
      // same position: still re-assert z-order above ZCode
      lastSelfMoveTick = Environment.TickCount;
      SetWindowPos(ov, zc, 0, 0, 0, 0, 0x0001 | 0x0010 | 0x0002 /*SWP_NOMOVE*/);
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

  // hide while ZCode is minimized, restore otherwise
  public static void SyncMinimize() {
    if (zc == IntPtr.Zero || ov == IntPtr.Zero) return;
    bool iconic = IsIconic(zc);
    bool ovVis = IsWindowVisible(ov);
    if (iconic && ovVis) { ShowWindow(ov, 0 /*SW_HIDE*/); hiddenByUs = true; }
    else if (!iconic && !ovVis && hiddenByUs) { ShowWindow(ov, 4 /*SW_SHOWNOACTIVATE*/); hiddenByUs = false; ApplyOffset(); }
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
  $ovH = [Docking]::FindBiggestVisible([uint32]$OverlayPid)
  if ($ovH -eq 0) {
    $ovProc = Get-Process -Id $OverlayPid -ErrorAction SilentlyContinue
    if (-not $ovProc) { break }  # overlay gone, daemon exits
    Start-Sleep -Milliseconds 400
    continue
  }
  $zcH = [Docking]::FindZcodeMain()
  if ($zcH -ne 0) { [Docking]::Ensure([IntPtr]$zcH, [IntPtr]$ovH) }
  [Docking]::SyncMinimize()
  [Docking]::Pump(2000)
}
