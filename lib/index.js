/**
 * dsh-desk-todo — 桌面待办挂件（宿主半身）
 *
 * 用一个无边框、透明、置底的窗口把「本周待办 + 长期任务」贴在桌面上；
 * 到点用自定义弹窗 + 提示音提醒（不依赖系统通知权限）。
 *
 * 窗口用的是 DSH 自己那份 Electron，不额外要求用户安装运行时。
 * 数据存 $DSH_HOME/desk-todo/data.json，纯文本，随时能手改。
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export const name = 'dsh-desk-todo';

let electron = null;
try {
  electron = await import('electron');
} catch {
  electron = null;
}
const { app, BrowserWindow, Tray, Menu, Notification, screen, nativeImage, ipcMain, shell } = electron || {};

const DEFAULT_CONFIG = {
  width: 520,
  height: 330,
  opacity: 0.85,
  top: 16,
  right: 16,
  alwaysOnTop: false,
  startHidden: false,
  silent: false,
  autoStart: true
};

const EMPTY_DATA = {
  semester: null,
  events: [],
  longterm: [],
  settings: { w: 520, h: 330, x: null, y: 16, opacity: 0.85, silent: false }
};

function dataDir() {
  const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
  return path.join(home, 'desk-todo');
}

function dataFile() {
  return path.join(dataDir(), 'data.json');
}

function readData() {
  try {
    return JSON.parse(fs.readFileSync(dataFile(), 'utf8'));
  } catch {
    return JSON.parse(JSON.stringify(EMPTY_DATA));
  }
}

function writeData(d) {
  try {
    fs.mkdirSync(dataDir(), { recursive: true });
    fs.writeFileSync(dataFile(), JSON.stringify(d, null, 2));
  } catch (e) {
    console.error('[desk-todo] 写入数据失败', e);
  }
}

const pad = (n) => String(n).padStart(2, '0');
const dayKey = (d) => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
const mins = (t) => {
  const p = String(t || '00:00').split(':');
  return (Number(p[0]) || 0) * 60 + (Number(p[1]) || 0);
};

export function apply(ctx, config = {}) {
  if (!electron || !app) {
    ctx?.logger?.warn?.('[desk-todo] 当前宿主不是 Electron，挂件无法创建窗口；已跳过');
    return;
  }

  const cfg = { ...DEFAULT_CONFIG, ...(config || {}) };
  let win = null;
  let toastWin = null;
  let tray = null;
  let quitting = false;
  let recreateTimer = null;
  const fired = new Map();

  if (!fs.existsSync(dataFile())) writeData({ ...EMPTY_DATA, settings: { ...EMPTY_DATA.settings, opacity: cfg.opacity } });

  function winSize(s) {
    const w = Math.max(300, Math.min(960, Math.round(Number(s && s.w) || cfg.width)));
    const h = Math.max(140, Math.min(680, Math.round(Number(s && s.h) || cfg.height)));
    return { w, h };
  }

  function applyBounds(s) {
    if (!win) return;
    const { w, h } = winSize(s);
    const area = screen.getPrimaryDisplay().workArea;
    let x = Number.isFinite(s && s.x) ? Math.round(s.x) : area.x + area.width - w - cfg.right;
    let y = Number.isFinite(s && s.y) ? Math.round(s.y) : area.y + cfg.top;
    x = Math.max(area.x, Math.min(area.x + area.width - w, x));
    y = Math.max(area.y, Math.min(area.y + area.height - h, y));
    const b = win.getBounds();
    if (b.width !== w || b.height !== h || b.x !== x || b.y !== y) win.setBounds({ x, y, width: w, height: h });
  }

  function persistGeometry() {
    if (!win) return;
    const b = win.getBounds();
    const d = readData();
    d.settings = { ...(d.settings || {}), w: b.width, h: b.height, x: b.x, y: b.y };
    writeData(d);
  }

  function createWindow() {
    if (win && !win.isDestroyed()) return;
    const d = readData();
    const { w, h } = winSize(d.settings);
    const area = screen.getPrimaryDisplay().workArea;
    const x = Number.isFinite(d.settings && d.settings.x)
      ? Math.round(d.settings.x)
      : area.x + area.width - w - cfg.right;
    const y = Number.isFinite(d.settings && d.settings.y) ? Math.round(d.settings.y) : area.y + cfg.top;

    win = new BrowserWindow({
      width: w, height: h, x, y,
      frame: false, transparent: true, resizable: true, movable: true,
      alwaysOnTop: !!cfg.alwaysOnTop, skipTaskbar: true, hasShadow: false,
      minimizable: false, maximizable: false, fullscreenable: false,
      show: false,
      webPreferences: {
        preload: path.join(import.meta.dirname, 'preload.cjs'),
        contextIsolation: true,
        nodeIntegration: false
      }
    });
    win.setVisibleOnAllWorkspaces(true);
    win.loadFile(path.join(import.meta.dirname, 'ui', 'index.html'));
    win.once('ready-to-show', () => {
      if (cfg.startHidden) return;
      win.showInactive();
    });
    win.on('moved', () => { clearTimeout(win._t); win._t = setTimeout(persistGeometry, 400); });
    win.on('resized', () => { clearTimeout(win._t); win._t = setTimeout(persistGeometry, 400); });
    win.on('minimize', (e) => { try { e.preventDefault(); win.restore(); win.showInactive(); } catch {} });
    win.on('closed', () => { win = null; if (!quitting) recreateSoon(800); });
  }

  function recreateSoon(ms = 800) {
    if (quitting) return;
    clearTimeout(recreateTimer);
    recreateTimer = setTimeout(() => {
      if (quitting) return;
      if (!win || win.isDestroyed()) { try { createWindow(); } catch (e) { console.error(e); } }
    }, ms);
  }

  function send(payload) {
    if (win && !win.isDestroyed()) win.webContents.send('desk-todo:state', payload);
  }

  function popupToast(title, body, urgent) {
    try {
      if (toastWin && !toastWin.isDestroyed()) toastWin.close();
      const area = screen.getPrimaryDisplay().workArea;
      const tw = 380, th = 96;
      toastWin = new BrowserWindow({
        width: tw, height: th,
        x: area.x + area.width - tw - 16,
        y: area.y + area.height - th - 72,
        frame: false, transparent: true, resizable: false, movable: false,
        alwaysOnTop: true, skipTaskbar: true, hasShadow: false, focusable: false,
        webPreferences: { contextIsolation: true, nodeIntegration: false }
      });
      toastWin.setAlwaysOnTop(true, 'screen-saver');
      const qs = '?t=' + encodeURIComponent(title) + '&b=' + encodeURIComponent(body) +
        '&u=' + (urgent ? 1 : 0) + '&ms=' + (urgent ? 12000 : 8000);
      toastWin.loadURL('file://' + path.join(import.meta.dirname, 'ui', 'toast.html') + qs);
      toastWin.on('closed', () => { toastWin = null; });
    } catch (e) {
      console.error('[desk-todo] toast 失败', e);
    }
  }

  function fire(title, body, key, urgent) {
    if (fired.has(key)) return;
    fired.set(key, Date.now());
    try {
      const d = readData();
      if (!(d.settings && d.settings.silent) && Notification) {
        const n = new Notification({ title, body, silent: false });
        n.on('click', () => { try { win && win.showInactive(); } catch {} });
        n.show();
      }
    } catch {}
    popupToast(title, body, urgent);
    if (win && !win.isDestroyed()) win.webContents.send('desk-todo:sound', !!urgent);
    send({ type: 'refresh' });
  }

  /* ─── 定时检查 ─── */
  function tick() {
    const d = readData();
    const now = new Date();
    const nowMin = now.getHours() * 60 + now.getMinutes();
    const today = dayKey(now);

    for (const ev of d.events || []) {
      const base = new Date(ev.day + 'T00:00:00');
      const occurs = ev.day === today || (ev.repeat === 'weekly' && base.getDay() === now.getDay() && now >= base);
      if (!occurs || ev.doneOn === today) continue;
      const startMin = mins(ev.start);
      const remind = Number.isFinite(Number(ev.remindMin)) ? Number(ev.remindMin) : 15;
      const diff = startMin - nowMin;
      if (remind > 0 && diff <= remind && diff > remind - 2) {
        fire('马上要开始 · ' + ev.title, remind + ' 分钟后' + (ev.place ? ' · ' + ev.place : ''), ev.id + '|' + today + '|pre');
      }
      if (diff <= 0 && diff > -2) {
        fire('开始了 · ' + ev.title, ev.place || '', ev.id + '|' + today + '|now', true);
      }
      if (diff < -2 && diff > -90) {
        const stage = Math.floor((-diff) / 10);
        if (stage >= 1 && stage <= 3) {
          fire('还没完成 · ' + ev.title, '已经过去 ' + (-diff) + ' 分钟', ev.id + '|' + today + '|late' + stage, true);
        }
      }
    }

    for (const it of d.longterm || []) {
      if (it.done || !it.due) continue;
      const due = new Date(it.due + 'T23:59:00');
      const days = Math.ceil((due - now) / 86400000);
      if (days === 3 || days === 1 || days === 0) {
        fire('临期 · ' + it.title, days === 0 ? '今天到期' : days + ' 天后到期（' + it.due + '）', it.id + '|ddl|' + days);
      }
    }
  }

  function buildTray() {
    if (tray || !Tray) return;
    try {
      const img = nativeImage.createFromPath(path.join(import.meta.dirname, '..', 'assets', 'icon.png'));
      tray = new Tray(img.isEmpty() ? nativeImage.createEmpty() : img);
      tray.setToolTip('桌面待办');
      tray.setContextMenu(Menu.buildFromTemplate([
        { label: '显示 / 隐藏', click: () => { if (!win) return createWindow(); win.isVisible() ? win.hide() : win.showInactive(); } },
        { label: '回到右上角', click: () => { const d = readData(); d.settings.x = null; d.settings.y = cfg.top; writeData(d); applyBounds(d.settings); } },
        { type: 'separator' },
        { label: '测试提醒', click: () => popupToast('数值分析', '15 分钟后 · 阶教楼W3阶', false) },
        { label: '打开数据文件', click: () => shell.openPath(dataFile()) },
        { type: 'separator' },
        { label: '退出 DSH', click: () => { quitting = true; app.quit(); } }
      ]));
      tray.on('click', () => { if (!win) return createWindow(); win.isVisible() ? win.hide() : win.showInactive(); });
    } catch (e) {
      console.error('[desk-todo] 托盘创建失败', e);
    }
  }

  /* ─── IPC ─── */
  ipcMain.handle('desk-todo:get', () => readData());
  ipcMain.handle('desk-todo:save', (_e, next) => { writeData(next); send({ type: 'refresh' }); return true; });
  ipcMain.on('desk-todo:bounds', (_e, s) => { const d = readData(); d.settings = { ...(d.settings || {}), ...s }; writeData(d); applyBounds(d.settings); });
  ipcMain.on('desk-todo:opacity', (_e, v) => { const d = readData(); d.settings = { ...(d.settings || {}), opacity: Math.max(0.25, Math.min(0.95, Number(v) || 0.85)) }; writeData(d); send({ type: 'refresh' }); });
  ipcMain.on('desk-todo:hide', () => { if (win) win.hide(); });
  ipcMain.on('desk-todo:datafile', () => shell.openPath(dataFile()));

  const boot = () => {
    createWindow();
    buildTray();
    setInterval(tick, 20000);
    setInterval(() => {
      try { if (win && !win.isDestroyed() && win.isMinimized()) { win.restore(); win.showInactive(); } } catch {}
    }, 1200);
    tick();
    fs.watchFile(dataFile(), { interval: 1500 }, () => send({ type: 'refresh' }));
  };

  if (app.isReady()) boot();
  else app.whenReady().then(boot);

  if (ctx && typeof ctx.effect === 'function') {
    ctx.effect(() => () => {
      quitting = true;
      try { fs.unwatchFile(dataFile()); } catch {}
      try { tray && tray.destroy(); } catch {}
      try { win && !win.isDestroyed() && win.destroy(); } catch {}
      try { toastWin && !toastWin.isDestroyed() && toastWin.destroy(); } catch {}
    });
  }

  ctx?.logger?.info?.('[desk-todo] 桌面待办挂件已启动，数据：' + dataFile());
}
