/**
 * dsh-desk-todo — 宿主半身
 *
 * 界面有两种：
 *   1. 首选：app/ 里的 Electron 挂件（无边框透明窗口、原版 CSS 界面）
 *   2. 退路：win/desk-todo.ps1 的 WPF 版本（找不到 Electron 时）
 *
 * DSH 插件宿主是 ELECTRON_RUN_AS_NODE 进程，不能自己开窗口，所以插件只负责
 * 「找一份 Electron 二进制 → 拉起来 → 崩了重启」，界面完全在被拉起的进程里跑。
 *
 * Electron 搜索顺序：
 *   config.electronPath → 环境变量 DSH_DESK_TODO_ELECTRON →
 *   $DSH_HOME/data/surfcore/pet/runtime/electron-<ver>/electron.exe →
 *   %LOCALAPPDATA%\Programs\electron\electron.exe
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { parseQuick } from './parse.js';

export const name = 'dsh-desk-todo';

const DEFAULT_CONFIG = {
  electronPath: '',
  width: 520,
  height: 330,
  opacity: 0.85,
  top: 16,
  right: 16,
  alwaysOnTop: false,
  silent: false,
  autoStart: true
};

const EMPTY_DATA = {
  semester: null,
  events: [],
  longterm: [],
  settings: { w: 520, h: 330, x: null, y: 16, opacity: 0.85 }
};

const dshHome = () => process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const dataDir = () => path.join(dshHome(), 'desk-todo');
const dataFile = () => path.join(dataDir(), 'data.json');

function ensureData() {
  if (fs.existsSync(dataFile())) return;
  try {
    fs.mkdirSync(dataDir(), { recursive: true });
    fs.writeFileSync(dataFile(), JSON.stringify(EMPTY_DATA, null, 2));
  } catch (e) {
    console.error('[desk-todo] 初始化数据失败', e);
  }
}

function diag(msg) {
  try {
    fs.appendFileSync(path.join(os.tmpdir(), 'desk-todo-load.txt'), String.fromCharCode(10) + new Date().toISOString() + ' ' + msg);
  } catch {}
}

function newestDir(parent, prefix) {
  try {
    const dirs = fs.readdirSync(parent).filter((n) => n.startsWith(prefix));
    if (!dirs.length) return null;
    dirs.sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
    return path.join(parent, dirs[0]);
  } catch {
    return null;
  }
}

function findElectron(cfg) {
  const candidates = [];
  if (cfg.electronPath) candidates.push(cfg.electronPath);
  if (process.env.DSH_DESK_TODO_ELECTRON) candidates.push(process.env.DSH_DESK_TODO_ELECTRON);

  const petRuntime = path.join(dshHome(), 'data', 'surfcore', 'pet', 'runtime');
  const petDir = newestDir(petRuntime, 'electron-');
  if (petDir) candidates.push(path.join(petDir, 'electron.exe'));

  if (process.env.LOCALAPPDATA) {
    candidates.push(path.join(process.env.LOCALAPPDATA, 'Programs', 'electron', 'electron.exe'));
  }
  candidates.push(path.join(os.homedir(), 'AppData', 'Local', 'Programs', 'electron', 'electron.exe'));

  for (const c of candidates) {
    try {
      if (c && fs.existsSync(c)) return c;
    } catch {}
  }
  return null;
}

function startApi() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      if (req.method !== 'POST' || !req.url.startsWith('/parse')) {
        res.writeHead(404).end('{}');
        return;
      }
      let body = '';
      req.on('data', (c) => { body += c; if (body.length > 8192) req.destroy(); });
      req.on('end', () => {
        try {
          const { text } = JSON.parse(body || '{}');
          const r = parseQuick(String(text || ''));
          const payload = r
            ? { ok: true, date: r.date, start: r.start, end: r.end, place: r.place, title: r.title }
            : { ok: false };
          res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(payload));
        } catch {
          res.writeHead(200, { 'content-type': 'application/json' }).end('{"ok":false}');
        }
      });
    });
    server.on('error', () => resolve(null));
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

export function apply(ctx, config = {}) {
  const cfg = { ...DEFAULT_CONFIG, ...(config || {}) };
  ensureData();

  const appDir = path.join(import.meta.dirname, '..', 'app');
  const ps1 = path.join(import.meta.dirname, '..', 'win', 'desk-todo.ps1');

  let child = null;
  let server = null;
  let disposed = false;
  let restartTimer = null;
  let apiPort = 0;
  let mode = '';

  function start() {
    if (disposed) return;
    const electronPath = findElectron(cfg);
    if (electronPath) {
      mode = 'electron';
      const env = { ...process.env, DESK_TODO_DATA: dataFile() };
      delete env.ELECTRON_RUN_AS_NODE;
      child = spawn(electronPath, [appDir, '--no-sandbox'], { env, stdio: 'ignore' });
      diag('spawned electron pid=' + (child.pid || '?') + ' app=' + appDir);
    } else {
      mode = 'wpf';
      diag('没找到 Electron，退回 WPF');
      child = spawn('powershell.exe', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ps1,
        '-DataPath', dataFile(),
        '-ApiPort', String(apiPort || 0),
        '-Opacity', String(cfg.opacity),
        '-WinWidth', String(cfg.width),
        '-WinHeight', String(cfg.height),
        '-Top', String(cfg.top),
        '-Right', String(cfg.right),
        '-Topmost', cfg.alwaysOnTop ? 'true' : 'false',
        '-Silent', cfg.silent ? 'true' : 'false'
      ], { windowsHide: true, stdio: 'ignore' });
      diag('spawned powershell pid=' + (child.pid || '?'));
    }
    child.on('exit', (code) => {
      diag(mode + ' 退出 code=' + code);
      child = null;
      if (disposed) return;
      restartTimer = setTimeout(start, 2500);
    });
    child.on('error', (e) => diag(mode + ' 启动失败 ' + (e && e.message)));
  }

  (async () => {
    server = await startApi();
    apiPort = server ? server.address().port : 0;
    diag('api 端口=' + apiPort);
    if (cfg.autoStart !== false) start();
  })();

  const cleanup = () => {
    disposed = true;
    clearTimeout(restartTimer);
    try { if (child) child.kill(); } catch {}
    try { if (server) server.close(); } catch {}
  };

  if (ctx && typeof ctx.effect === 'function') ctx.effect(() => cleanup);
  ctx?.logger?.info?.('[desk-todo] 已启动：' + dataFile());
}
