#!/usr/bin/env node
// token-meter 悬浮窗拉起 Hook —— 挂在 SessionStart / UserPromptSubmit 上:
// 悬浮窗没在跑就 detached 拉起一次,在跑则跳过(靠 ~/.zcode/zcode-token-meter.json 里的 pid 判断)。
// 悬浮窗自己每 3s 探测 ZCode.exe,ZCode 退出后它跟着退出,由此实现"跟随 ZCode 启停"。
// 关闭方式:环境变量 ZCODE_TOKEN_METER_OVERLAY=0,或删除 hooks.json 里的对应注册。

import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.env.ZCODE_TOKEN_METER_OVERLAY === '0') process.exit(0);

// 仓库内可移植默认:本文件位于 <repo>/plugin/,悬浮窗项目根即上一级目录;
// 也可用 ZCODE_TOKEN_METER_OVERLAY_DIR 指到任意安装位置
const OVERLAY_DIR = process.env.ZCODE_TOKEN_METER_OVERLAY_DIR || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CFG = path.join(homedir(), '.zcode', 'zcode-token-meter.json');

function overlayAlive() {
  try {
    const cfg = JSON.parse(readFileSync(CFG, 'utf8'));
    if (!Number.isInteger(cfg.pid) || cfg.pid <= 0) return false;
    process.kill(cfg.pid, 0); // 不在跑会抛 ESRCH;EPERM 表示活着但无权限
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

if (overlayAlive()) process.exit(0);

const electronExe = path.join(OVERLAY_DIR, 'node_modules', 'electron', 'dist', 'electron.exe');
if (!existsSync(electronExe)) process.exit(0); // 悬浮窗项目不在本机,静默跳过

try {
  const child = spawn(electronExe, ['.'], {
    cwd: OVERLAY_DIR,
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
  });
  child.unref();
} catch { /* 拉起失败不影响会话 */ }
process.exit(0);
