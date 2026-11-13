const { app, BrowserWindow, Tray, Menu, ipcMain, Notification, nativeImage, screen } = require('electron');
const fs = require('fs');
const path = require('path');

const DATA_FILE = process.env.DESK_TODO_DATA || path.join(__dirname, 'data.json');
const CHIME = path.join(__dirname, 'assets', 'chime.wav');
const ICON = path.join(__dirname, 'assets', 'icon.png');

app.setPath('userData', path.join(__dirname, '.cache'));
if (process.platform === 'win32') app.setAppUserModelId('com.dsh.desktopwidget');

let win = null;
let quitting = false;
let tray = null;
let data = null;
const fired = new Map(); // key -> timestamp

function readData() {
  try { return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { return { events: [], longterm: [], settings: {} }; }
}
function writeData(d) {
  try { fs.writeFileSync(DATA_FILE, JSON.stringify(d, null, 2)); data = d; } catch (e) { console.error(e); }
}

function clampSize(s) {
  const w = Math.max(300, Math.min(960, Math.round(Number(s && s.w) || 420)));
  const h = Math.max(140, Math.min(680, Math.round(Number(s && s.h) || 260)));
  return { w, h };
}

function applyBounds(s) {
  if (!win) return;
  const { w, h } = clampSize(s);
  const area = screen.getPrimaryDisplay().workArea;
  let x = Number.isFinite(s && s.x) ? Math.round(s.x) : area.x + area.width - w - 16;
  let y = Number.isFinite(s && s.y) ? Math.round(s.y) : area.y + 16;
  x = Math.max(area.x, Math.min(area.x + area.width - w, x));
  y = Math.max(area.y, Math.min(area.y + area.height - h, y));
  const b = win.getBounds();
  if (b.width !== w || b.height !== h || b.x !== x || b.y !== y) win.setBounds({ x, y, width: w, height: h });
}

function saveGeometry() {
  if (!win || !data) return;
  const b = win.getBounds();
  data.settings = Object.assign({}, data.settings, { w: b.width, h: b.height, x: b.x, y: b.y });
  writeData(data);
}

function createWindow() {
  const s = (data && data.settings) || {};
  const { w, h } = clampSize(s);
  const area = screen.getPrimaryDisplay().workArea;
  const x = Number.isFinite(s.x) ? Math.round(s.x) : area.x + area.width - w - 16;
  const y = Number.isFinite(s.y) ? Math.round(s.y) : area.y + 16;

  win = new BrowserWindow({
    width: w, height: h, x, y,
    frame: false, transparent: true, resizable: true, movable: true,
    alwaysOnTop: false, skipTaskbar: true, hasShadow: false,
    minimizable: false, maximizable: false, fullscreenable: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false }
  });
  win.setVisibleOnAllWorkspaces(true);
  win.showInactive();
  // 沉到最底层：不抢焦点、不遮挡其它窗口
  win.on('blur', () => { try { win.setAlwaysOnTop(false); } catch (e) {} });
  // Win+D / 显示桌面 会最小化所有窗口；立刻恢复，让挂件重新贴回桌面
  win.on('minimize', (e) => { try { e.preventDefault(); win.restore(); win.showInactive(); } catch (err) {} });
  win.loadFile(path.join(__dirname, 'ui', 'index.html'));
  win.on('moved', () => { clearTimeout(win._t); win._t = setTimeout(saveGeometry, 400); });
  win.on('resized', () => { clearTimeout(win._t); win._t = setTimeout(saveGeometry, 400); });
  win.on('closed', () => { win = null; if (!quitting) recreateSoon(800); });
}

function toggleShow() {
  if (!win) return createWindow();
  if (win.isVisible()) win.hide(); else win.show();
}

function buildTray() {
  const img = nativeImage.createFromPath(ICON);
  tray = new Tray(img.isEmpty() ? nativeImage.createEmpty() : img);
  tray.setToolTip('桌面挂件');
  const menu = Menu.buildFromTemplate([
    { label: '显示 / 隐藏', click: toggleShow },
    { label: '回到右上角', click: () => { if (!win) return; data.settings.x = null; data.settings.y = 16; writeData(data); applyBounds(data.settings); } },
    { type: 'separator' },
    { label: '测试提醒', click: () => { popupToast('数值分析', '15 分钟后开始 · 阶教楼W3阶', false); if (win && !win.isDestroyed()) win.webContents.send('flash', { key: '__test__', urgent: false }); } },
    { label: '打开数据文件', click: () => { require('electron').shell.openPath(DATA_FILE); } },
    { label: '重新载入数据', click: () => { data = readData(); sendState(); } },
    { type: 'separator' },
    { label: '退出', click: () => app.quit() }
  ]);
  tray.setContextMenu(menu);
  tray.on('click', toggleShow);
}

function sendState() {
  if (win && !win.isDestroyed()) win.webContents.send('state', data);
}

/* ───────── 自定义弹窗提醒（不依赖系统通知权限） ───────── */
let toastWin = null;
function popupToast(title, body, urgent) {
  try {
    if (toastWin && !toastWin.isDestroyed()) toastWin.close();
    const area = screen.getPrimaryDisplay().workArea;
    const w = 380, h = 96;
    toastWin = new BrowserWindow({
      width: w, height: h,
      x: area.x + area.width - w - 16,
      y: area.y + area.height - h - 72,
      frame: false, transparent: true, resizable: false, movable: false,
      alwaysOnTop: false, skipTaskbar: true, hasShadow: false, focusable: false,
      webPreferences: { contextIsolation: true, nodeIntegration: false }
    });
    toastWin.setAlwaysOnTop(true, 'screen-saver');
    const qs = '?t=' + encodeURIComponent(title) + '&b=' + encodeURIComponent(body) + '&u=' + (urgent ? 1 : 0) + '&ms=' + (urgent ? 12000 : 8000);
    toastWin.loadURL('file://' + path.join(__dirname, 'ui', 'toast.html') + qs);
    toastWin.on('closed', () => { toastWin = null; });
  } catch (e) { console.error('popup fail', e); }
}

/* ───────── 提醒调度 ───────── */
function pad(n) { return String(n).padStart(2, '0'); }
function todayKey(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
function minutesOf(hhmm) { const [h, m] = String(hhmm || '00:00').split(':').map(Number); return (h || 0) * 60 + (m || 0); }

function eventOccursOn(ev, date) {
  const t = todayKey(date);
  if (ev.day === t) return true;
  if (ev.repeat === 'weekly') {
    const base = new Date(ev.day + 'T00:00:00');
    return base.getDay() === date.getDay() && date >= new Date(ev.day + 'T00:00:00');
  }
  return false;
}

function fire(title, body, key, urgent) {
  if (fired.has(key)) return;
  fired.set(key, Date.now());
  console.log('[notify]', title, '|', body);
  try {
    const n = new Notification({ title, body, icon: ICON, silent: !!(data && data.settings && data.settings.silent) });
    n.on('click', () => { if (win) { win.show(); win.focus(); } });
    n.show();
  } catch (e) { console.error('notify fail', e); }
  popupToast(title, body, urgent);
  if (win && !win.isDestroyed()) {
    win.webContents.send('flash', { key, urgent: !!urgent });
    if (!(data && data.settings && data.settings.silent)) win.flashFrame(true);
  }
}

function tick() {
  if (!data) return;
  const now = new Date();
  const nowMin = now.getHours() * 60 + now.getMinutes();
  const t = todayKey(now);

  for (const ev of data.events || []) {
    if (!eventOccursOn(ev, now)) continue;
    if (ev.doneOn === t) continue;
    const startMin = minutesOf(ev.start);
    const remind = Number.isFinite(Number(ev.remindMin)) ? Number(ev.remindMin) : 15;
    const diff = startMin - nowMin;
    if (remind > 0 && diff <= remind && diff > remind - 2) {
      fire('马上要上课 · ' + ev.title, (remind + ' 分钟后开始') + (ev.place ? ' · ' + ev.place : ''), ev.id + '|' + t + '|pre');
    }
    if (diff <= 0 && diff > -2) {
      fire('开始了 · ' + ev.title, (ev.place || '') + (ev.who ? ' · ' + ev.who : ''), ev.id + '|' + t + '|now', true);
    }
    if (diff < -2 && diff > -90) {
      const stage = Math.floor((-diff) / 10);
      if (stage >= 1 && stage <= 3) {
        fire('还没完成 · ' + ev.title, '已经过去 ' + (-diff) + ' 分钟', ev.id + '|' + t + '|late' + stage, true);
      }
    }
  }

  for (const it of data.longterm || []) {
    if (it.done || !it.due) continue;
    const due = new Date(it.due + 'T23:59:00');
    const days = Math.ceil((due - now) / 86400000);
    if (days === 3 || days === 1 || days === 0) {
      fire('长期任务临期 · ' + it.title, days === 0 ? '今天到期' : days + ' 天后到期（' + it.due + '）', it.id + '|ddl|' + days);
    }
  }
}

/* ───────── IPC ───────── */
ipcMain.handle('get-state', () => data);
ipcMain.handle('save-data', (_e, next) => { writeData(next); sendState(); return true; });
ipcMain.on('set-ignore', (_e, ignore) => {
  if (win && !win.isDestroyed()) win.setIgnoreMouseEvents(!!ignore, { forward: true });
});
ipcMain.on('set-bounds', (_e, s) => { data.settings = Object.assign({}, data.settings, s); writeData(data); applyBounds(data.settings); });
ipcMain.on('set-opacity', (_e, v) => { data.settings.opacity = Math.max(0.25, Math.min(0.95, Number(v) || 0.75)); writeData(data); sendState(); });
ipcMain.on('hide-widget', () => { if (win) win.hide(); });
ipcMain.on('open-data', () => { require('electron').shell.openPath(DATA_FILE); });
ipcMain.on('reload', () => { data = readData(); sendState(); });

// 单实例：避免多开导致"旧窗口还挡着鼠标"的幽灵问题
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    try { if (win) { win.showInactive(); } } catch (e) {}
  });
}

app.whenReady().then(() => {
  if (!fs.existsSync(DATA_FILE)) writeData({ events: [], longterm: [], settings: {} });
  data = readData();
  createWindow();
  buildTray();
  // Win+D / 显示桌面 会把窗口最小化；轮询拉回来，保持"桌面贴纸"的效果
  setInterval(() => {
    try { if (win && !win.isDestroyed() && win.isMinimized()) { win.restore(); win.showInactive(); } } catch (e) {}
  }, 1200);
  setInterval(tick, 20000);
  tick();
  fs.watchFile(DATA_FILE, { interval: 1500 }, () => { data = readData(); sendState(); });
});

app.on('before-quit', () => { quitting = true; });
app.on('window-all-closed', () => { if (quitting) app.quit(); });

// 桌面右键刷新 / 资源管理器重启会把窗口顶掉：自动重建，保持长期显示
let recreateTimer = null;
function recreateSoon(ms) {
  if (quitting) return;
  clearTimeout(recreateTimer);
  recreateTimer = setTimeout(() => {
    if (quitting) return;
    if (!win || win.isDestroyed()) { try { createWindow(); } catch (e) { } }
  }, ms || 800);
}
app.on('browser-window-created', (_e, w) => {
  w.webContents.on('render-process-gone', () => recreateSoon(500));
});
