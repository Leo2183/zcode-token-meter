# owner.ps1 - 把悬浮窗绑定为 ZCode 主窗口的 owned window(守护式)
# GWL_HWNDPARENT(-8) 设定 owner 后,Windows 原生保证:
#   owner 最小化 -> owned 隐藏; owner 被盖 -> owned 同被盖; owner 可见 -> owned 保持其上。
# ZCode 主窗口可能被重建(更新/崩溃恢复),一次性绑定会失效,故常驻:
# 每 2s 检查悬浮窗的 owner,断链则用当前 ZCode 主窗口重绑;悬浮窗进程退出后本脚本退出。
# pid 直接读配置文件;本文件含中文注释,必须保持 UTF-8 BOM(PS5.1 否则按 GBK 解析腐蚀 here-string)。
Add-Type @"
using System;using System.Runtime.InteropServices;
public class OwnerBind {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
 [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
 [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
 public struct R { public int L,T,Rt,B; }
 public static long FindBiggestVisible(uint pid) {
   long best=0; int ba=0;
   EnumWindows((h,l)=>{ uint w; GetWindowThreadProcessId(h,out w); if(w==pid && IsWindowVisible(h)) { var r=new R(); GetWindowRect(h,out r); int a=(r.Rt-r.L)*(r.B-r.T); if(a>ba){ba=a;best=h.ToInt64();} } return true; }, IntPtr.Zero);
   return best;
 }
}
"@
function Get-CfgPid {
  try { return [int]((Get-Content "$env:USERPROFILE\.zcode\zcode-token-meter.json" | ConvertFrom-Json).pid) } catch { return 0 }
}
$overlayPid = Get-CfgPid
while ($true) {
  $ovH = [long]0
  if ($overlayPid -gt 0) { $ovH = [OwnerBind]::FindBiggestVisible([uint32]$overlayPid) }
  if ($ovH -eq 0) {
    # 悬浮窗窗口暂时不可见(可能刚重启未显示或已退出):刷新 pid 后小睡重试
    $newPid = Get-CfgPid
    if ($newPid -ne $overlayPid) { $overlayPid = $newPid }
    $ovProc = Get-Process -Id $overlayPid -ErrorAction SilentlyContinue
    if (-not $ovProc) { break }  # 悬浮窗进程没了,守护结束
    Start-Sleep -Milliseconds 500
    continue
  }
  $owner = [OwnerBind]::GetWindowLongPtr([IntPtr]$ovH, -8)
  $zc = Get-Process ZCode -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($owner -eq [IntPtr]::Zero -and $zc) {
    [OwnerBind]::SetWindowLongPtr([IntPtr]$ovH, -8, $zc.MainWindowHandle) | Out-Null
  }
  Start-Sleep -Milliseconds 2000
}
