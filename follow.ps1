# follow.ps1 — 悬浮窗 z 序跟随探测(按屏幕遮挡判定)
# 每 400ms 输出一行:1=显示,0=隐藏。
# 隐藏条件:ZCode 最小化,或前台窗口与 ZCode 同屏且矩形相交(真遮挡)。
# 前台在别的屏幕、或同屏但不与 ZCode 重叠(无遮挡)→ 保持显示。
param([int]$OverlayPid = 0)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ZOrder {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L, T, R, B; }
}
"@
function Test-Intersect($a, $b) {
  return ($a.L -lt $b.R) -and ($b.L -lt $a.R) -and ($a.T -lt $b.B) -and ($b.T -lt $a.B)
}
while ($true) {
  $show = 0
  $zc = Get-Process ZCode -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($zc) {
    $h = $zc.MainWindowHandle
    $fg = [ZOrder]::GetForegroundWindow()
    $fgPid = 0
    [ZOrder]::GetWindowThreadProcessId($fg, [ref]$fgPid) | Out-Null
    if ([ZOrder]::IsIconic($h)) {
      $show = 0
    } elseif ($fg -eq $h -or $fgPid -eq $OverlayPid) {
      $show = 1
    } else {
      # 前台是别的窗口:不同屏=无遮挡;同屏再比矩形是否相交
      $zm = [ZOrder]::MonitorFromWindow($h, 2) # MONITOR_DEFAULTTONEAREST
      $fm = [ZOrder]::MonitorFromWindow($fg, 2)
      if ($zm -ne $fm) {
        $show = 1
      } else {
        $zr = New-Object ZOrder+RECT
        $fr = New-Object ZOrder+RECT
        [ZOrder]::GetWindowRect($h, [ref]$zr) | Out-Null
        [ZOrder]::GetWindowRect($fg, [ref]$fr) | Out-Null
        $show = if (Test-Intersect $zr $fr) { 0 } else { 1 }
      }
    }
  }
  [Console]::WriteLine($show)
  [Console]::Out.Flush()
  Start-Sleep -Milliseconds 400
}
