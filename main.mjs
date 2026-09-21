// main.mjs — token-meter 悬浮窗主进程
// 无边框置顶小窗,按 ZCODE_TOKEN_METER_OVERLAY_POLL_MS(默认 2s)只读轮询 db.sqlite。
// 窗口自适应:宽度=基准宽x字号缩放,高度由渲染层实测内容高度上报,主进程据此 setContentSize
// 并夹回工作区内。字号(存于 ~/.zcode/zcode-token-meter.json 的 scale)支持右键菜单与渲染层上报。
// 跟随 ZCode:pid 写入配置供插件 hook 幂等拉起;每 5s 探测 ZCode.exe,连续两次不在则退出。

import { app, BrowserWindow, screen, ipcMain, Menu } from 'electron';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { collectSnapshot, defaultDbPath, listSessions } from './meter.mjs';
import { statSync } from 'node:fs';

const execFileAsync = promisify(execFile);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.join(homedir(), '.zcode', 'zcode-token-meter.json');
const POLL_MS = Math.max(500, Number(process.env.ZCODE_TOKEN_METER_OVERLAY_POLL_MS) || 2000);
// 空闲自适应:无数据变化超过 IDLE_AFTER 后,探测间隔拉长 POLL_MS*SLOW_MULT;
// 闸门是 db.sqlite/-wal/-shm 的 mtime,不变就不开 SQLite,空闲时成本≈0
const IDLE_AFTER = Math.max(30000, Number(process.env.ZCODE_TOKEN_METER_OVERLAY_IDLE_MS) || 180000);
const SLOW_MULT = 5;
const WATCH_MS = 5000;
const WATCH_PROC = process.env.ZCODE_TOKEN_METER_OVERLAY_PROC || 'ZCode.exe';
const FOLLOW = process.env.ZCODE_TOKEN_METER_OVERLAY_FOLLOW !== '0';
// 层级绑定:把悬浮窗设为 ZCode 主窗口的 owned window(owner.ps1),最小化/遮挡跟随全部交给系统;
// ZORDER=0 时退回旧的"常置顶独立窗"行为
const ZORDER = process.env.ZCODE_TOKEN_METER_OVERLAY_ZORDER !== '0';
const BASE_W = 260;
const FALLBACK_H = 180;
const MENU_SCALES = [
  { s: 0.85, label: '小 (85%)' },
  { s: 1.0, label: '标准 (100%)' },
  { s: 1.15, label: '大 (115%)' },
  { s: 1.3, label: '特大 (130%)' },
];

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    for (const w of BrowserWindow.getAllWindows()) {
      if (!w.isDestroyed()) { w.showInactive(); } // 窗口不可聚焦,show 即可
    }
  });
  app.whenReady().then(start);
}

function loadConfig() {
  try { return JSON.parse(readFileSync(CONFIG_PATH, 'utf8')); } catch { return {}; }
}

function saveConfig(patch) {
  try {
    mkdirSync(path.dirname(CONFIG_PATH), { recursive: true });
    // 读-改-写非原子,短暂的重启过渡期可能有两进程同时写;先写临时文件再替换,减少整段丢失
    const tmp = CONFIG_PATH + '.tmp';
    writeFileSync(tmp, JSON.stringify({ ...loadConfig(), ...patch }));
    renameSync(tmp, CONFIG_PATH);
  } catch { /* 位置记忆失败不致命 */ }
}

// 分辨率自适应:以 1920x1080 为 1.0 基准按工作区比例缩放;
// 比例 <1.15 视为 1(1080p 级屏幕保持现状),上限 1.6、下限 0.75。
// 用户字号倍率在渲染层叠加于其上;拖到另一块屏时 move 处理器里重算并推送。
function autoScaleFor(rect) {
  const wa = screen.getDisplayMatching(rect).workArea;
  const r = Math.min(wa.width / 1920, wa.height / 1080);
  return r < 1.15 ? 1 : Math.min(1.6, Math.max(0.75, r));
}

// 恢复的位置必须仍落在某块屏幕的工作区内,否则回默认(主屏右上角)
function resolvePosition(cfg) {  const w = Number.isFinite(cfg.w) ? cfg.w : BASE_W * (cfg.scale || 1);
  const h = Number.isFinite(cfg.h) ? cfg.h : FALLBACK_H;
  if (Number.isFinite(cfg.x) && Number.isFinite(cfg.y)) {
    const rect = { x: cfg.x, y: cfg.y, width: w, height: h };
    const wa = screen.getDisplayMatching(rect).workArea;
    if (cfg.x >= wa.x && cfg.y >= wa.y
      && cfg.x + w <= wa.x + wa.width && cfg.y + h <= wa.y + wa.height) {
      return { x: cfg.x, y: cfg.y };
    }
  }
  const wa = screen.getPrimaryDisplay().workArea;
  return { x: wa.x + wa.width - w - 16, y: wa.y + 12 };
}

async function zcodeAlive() {
  try {
    const { stdout } = await execFileAsync('tasklist', ['/FI', `IMAGENAME eq ${WATCH_PROC}`, '/FO', 'CSV', '/NH']);
    return stdout.includes(WATCH_PROC);
  } catch { return true; } // 探测失败按活着算,避免误退
}

// db 三件套(SQLite WAL)的最新 mtime,作为"有没有新数据"的廉价闸门
function dbMtime() {
  const base = defaultDbPath();
  let m = 0;
  for (const suffix of ['', '-wal', '-shm']) {
    try { m = Math.max(m, statSync(base + suffix).mtimeMs); } catch { /* 文件不存在忽略 */ }
  }
  return m;
}

function start() {
  const cfg = loadConfig();
  const scale = Number.isFinite(cfg.scale) && cfg.scale > 0 ? cfg.scale : 1;
  const pos = resolvePosition(cfg);
  const win = new BrowserWindow({
    width: Math.round(BASE_W * scale),
    height: Math.round((Number.isFinite(cfg.h) ? cfg.h : FALLBACK_H)),
    x: pos.x,
    y: pos.y,
    frame: false,
    transparent: true,
    thickFrame: false, // Windows 透明无边框窗必须关掉,否则 DPI 缩放下内容与窗口错位/被裁
    focusable: false, // 拖动/点击永不抢占前台,避免 ZCode 失焦
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    show: false,
    useContentSize: true,
    webPreferences: {
      preload: path.join(HERE, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  // 绑定为 owned window 时不能置顶(owner 关系负责层级);仅退回独立模式时置顶
  if (!ZORDER) win.setAlwaysOnTop(true, 'screen-saver');
  win.loadFile(path.join(HERE, 'renderer.html'));

  // 先隐藏,等渲染层上报真实内容尺寸后再显示;1.5s 兜底防 IPC 失败永不显示
  const showFallback = setTimeout(() => {
    if (!win.isDestroyed() && !win.isVisible()) win.showInactive();
  }, 1500);
  win.once('ready-to-show', () => {
    saveConfig({ pid: process.pid }); // 供插件 hook 判断是否需要拉起
  });

  win.webContents.on('did-finish-load', () => {
    win.webContents.send('overlay:init', { scale, autoScale: autoScaleFor(win.getBounds()), capsule: !!cfg.capsule });
  });

  win.on('closed', () => app.quit());
  app.on('will-quit', () => saveConfig({ pid: null }));

  // 位置记忆:move 事件高频,防抖 500ms 落盘
  // 位置记忆:move 事件高频,防抖 500ms 落盘;顺带检测换了显示器→重算分辨率自适应系数
  let saveTimer = null;
  let lastWa = screen.getDisplayMatching(win.getBounds()).workArea;
  win.on('move', () => {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      if (win.isDestroyed()) return;
      const [x, y] = win.getPosition();
      saveConfig({ x, y, pid: process.pid });
      const wa = screen.getDisplayMatching(win.getBounds()).workArea;
      if (wa.x !== lastWa.x || wa.y !== lastWa.y || wa.width !== lastWa.width || wa.height !== lastWa.height) {
        lastWa = wa;
        win.webContents.send('overlay:autoscale', { autoScale: autoScaleFor(win.getBounds()) });
      }
    }, 500);
  });

  ipcMain.handle('overlay:quit', () => app.quit());

  // 渲染层实测内容尺寸 → 调整窗口并夹回工作区,同时记忆尺寸供下次启动校验
  ipcMain.on('overlay:resize', (_e, sz) => {
    if (win.isDestroyed() || !sz || !Number.isFinite(sz.w) || !Number.isFinite(sz.h)) return;
    const w = Math.max(100, Math.round(sz.w));
    const h = Math.max(24, Math.round(sz.h));
    const wa = screen.getDisplayMatching({ ...win.getBounds(), width: w, height: h }).workArea;
    let [x, y] = win.getPosition();
    if (x + w > wa.x + wa.width) x = wa.x + wa.width - w;
    if (y + h > wa.y + wa.height) y = wa.y + wa.height - h;
    if (x < wa.x) x = wa.x;
    if (y < wa.y) y = wa.y;
    win.setBounds({ x, y, width: w, height: h });
    clearTimeout(showFallback);
    if (!win.isVisible()) { win.showInactive(); pokePoll(); }
    saveConfig({ w, h });
  });

  // 字号持久化(渲染层 Aa 按钮/ctrl+滚轮触发;菜单触发时回推给渲染层应用)
  ipcMain.on('overlay:scale', (_e, s) => {
    if (win.isDestroyed() || !Number.isFinite(s) || s <= 0.5 || s >= 2.5) return;
    saveConfig({ scale: Math.round(s * 100) / 100 });
  });

  // 胶囊态持久化
  ipcMain.on('overlay:capsule', (_e, on) => {
    if (!win.isDestroyed()) saveConfig({ capsule: !!on });
  });

  // 会话切换菜单:自动(双重检测) 或 强制固定到某个最近会话
  const rel = (ms) => ms < 60000 ? '刚刚'
    : ms < 3600000 ? Math.round(ms / 60000) + ' 分钟前'
    : Math.round(ms / 3600000) + ' 小时前';
  ipcMain.on('overlay:pick', () => {
    if (win.isDestroyed()) return;
    const cfg = loadConfig();
    const items = [
      { label: '自动(双重检测)', type: 'radio', checked: !cfg.pinSid, click: () => { saveConfig({ pinSid: null }); pokePoll(true); } },
      { type: 'separator' },
    ];
    for (const s of listSessions(8)) {
      items.push({
        label: s.title.slice(0, 24) + ' · ' + rel(s.agoMs),
        type: 'radio',
        checked: cfg.pinSid === s.id,
        click: () => { saveConfig({ pinSid: s.id }); pokePoll(true); },
      });
    }
    Menu.buildFromTemplate(items).popup({ window: win });
  });

  // 右键菜单:字号预设 + 退出
  win.webContents.on('context-menu', () => {
    if (win.isDestroyed()) return;
    const cur = loadConfig().scale || 1;
    Menu.buildFromTemplate([
      ...MENU_SCALES.map(({ s, label }) => ({
        label,
        type: 'radio',
        checked: Math.abs(s - cur) < 0.01,
        click: () => win.webContents.send('overlay:scale', s),
      })),
      { type: 'separator' },
      { label: '退出', click: () => app.quit() },
    ]).popup({ window: win });
  });

  // 自适应轮询:可见时每 tick 先 stat db 文件,mtime 变了才发快照;
  // 窗口被 z 序跟随隐藏时暂停;持续无变化超过 IDLE_AFTER 降频到 POLL_MS*SLOW_MULT。
  // force=true 绕过 mtime 闸门立即重查——切换/固定会话、恢复显示时必须用:
  // 固定一个不活跃会话不会产生 db 写入,闸门不知道"想看的数据变了"。
  let pollTimer = null, lastMtime = -1, lastChangeAt = Date.now();
  function pollTick(force = false) {
    pollTimer = null;
    if (win.isDestroyed()) return;
    if (win.isVisible()) {
      const m = dbMtime();
      if (force || m !== lastMtime) {
        lastMtime = m;
        lastChangeAt = Date.now();
        try {
          const { pinSid } = loadConfig();
          win.webContents.send('snapshot', collectSnapshot(defaultDbPath(), { pinSid }));
        } catch { /* 窗口销毁竞态 */ }
      }
    }
    const delay = (Date.now() - lastChangeAt > IDLE_AFTER) ? POLL_MS * SLOW_MULT : POLL_MS;
    pollTimer = setTimeout(pollTick, delay);
  }
  // 显示/切回前台/菜单选择时立刻补一次,不等慢周期
  function pokePoll(force = false) {
    lastChangeAt = Date.now();
    if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
    if (!win.isDestroyed()) pollTick(force);
  }
  pollTick();
  win.on('closed', () => { if (pollTimer) clearTimeout(pollTimer); });

  // 跟随 ZCode 退出:连续两次探测不到 ZCode.exe 才退,抗瞬时抖动
  if (FOLLOW) {
    let misses = 0;
    const watcher = setInterval(async () => {
      if (win.isDestroyed()) { clearInterval(watcher); return; }
      if (await zcodeAlive()) misses = 0;
      else if (++misses >= 2) app.quit();
    }, WATCH_MS);
    win.on('closed', () => clearInterval(watcher));
  }

  // 绑定为 ZCode 主窗口的 owned window(GWL_HWNDPARENT):最小化/被遮挡/恢复全部由
  // 系统原生处理,替代旧的 400ms 轮询探测;owner.ps1 等悬浮窗可见后绑定一次即退出。
  // ZORDER=0 退回旧的常置顶行为。
  if (ZORDER) {
    try {
      // owner.ps1 自读配置文件里的 pid,无需传参(注意:该文件带 UTF-8 BOM,PS5.1 才能正确解析中文注释)
      const ps = spawn('powershell', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', path.join(HERE, 'owner.ps1'),
      ], { stdio: ['ignore', 'ignore', 'ignore'] });
      win.on('closed', () => ps.kill());
    } catch { /* 绑定失败保持独立置顶窗,行为退化为旧版 */ }
  }
}
