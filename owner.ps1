# owner.ps1 - 把悬浮窗绑定为 ZCode 主窗口的 owned window(一次性)
# GWL_HWNDPARENT(-8) 设定 owner 后,Windows 原生保证:
#   owner 最小化 -> owned 隐藏; owner 被盖 -> owned 同被盖; owner 可见 -> owned 保持其上。
# 等悬浮窗可见窗口出现(最多 8s)后绑定一次即退出;悬浮窗每次重启由 main.mjs 重新拉起本脚本。
# pid 直接读配置文件,避免参数传递问题。
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
$cfg = Get-Content "$env:USERPROFILE\.zcode\zcode-token-meter.json" | ConvertFrom-Json
$overlayPid = [int]$cfg.pid
$deadline = (Get-Date).AddSeconds(8)
$ovH = [long]0
while ((Get-Date) -lt $deadline -and $ovH -eq 0) {
  $ovH = [OwnerBind]::FindBiggestVisible([uint32]$overlayPid)
  if ($ovH -eq 0) { Start-Sleep -Milliseconds 200 }
}
$zc = Get-Process ZCode -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($ovH -ne 0 -and $zc) {
  [OwnerBind]::SetWindowLongPtr([IntPtr]$ovH, -8, $zc.MainWindowHandle) | Out-Null
  $owner = [OwnerBind]::GetWindowLongPtr([IntPtr]$ovH, -8)
  Write-Output ("bound: overlay=0x" + $ovH.ToString("X") + " owner=0x" + $owner.ToString("X") + " expect=0x" + $zc.MainWindowHandle.ToInt64().ToString("X"))
} else {
  Write-Output ("bind failed: overlay=0x" + $ovH.ToString("X") + " zcode=" + ($null -ne $zc))
}
