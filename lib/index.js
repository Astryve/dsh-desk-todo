/**
 * dsh-desk-todo — 宿主半身（Node 侧）
 *
 * 事实：DSH 的插件宿主跑在 ELECTRON_RUN_AS_NODE 模式里（dsh-desktop-host），
 * 拿不到 app / BrowserWindow，所以插件**不能**自己开 Electron 窗口。
 *
 * 因此界面交给 Windows 自带的 WPF（PowerShell + XAML），插件负责三件事：
 *   1. 把 win/desk-todo.ps1 拉起来，崩了自动重启；
 *   2. 起一个 127.0.0.1 的极小 HTTP 服务，给界面提供「一句话识别」（JS 解析器）；
 *   3. 卸载时清理子进程。
 *
 * 数据和界面之间只靠 data.json 一个文件，WPF 每 3 秒看一次 mtime。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { parseQuick } from './parse.js';

export const name = 'dsh-desk-todo';

const DEFAULT_CONFIG = {
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

function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
}
function dataDir() {
  return path.join(dshHome(), 'desk-todo');
}
function dataFile() {
  return path.join(dataDir(), 'data.json');
}

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

  const ps1 = path.join(import.meta.dirname, '..', 'win', 'desk-todo.ps1');
  let child = null;
  let server = null;
  let disposed = false;
  let restartTimer = null;

  function spawnWidget(apiPort) {
    if (disposed) return;
    const args = [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
      '-File', ps1,
      '-DataPath', dataFile(),
      '-ApiPort', String(apiPort || 0),
      '-Opacity', String(cfg.opacity),
      '-WinWidth', String(cfg.width),
      '-WinHeight', String(cfg.height),
      '-Top', String(cfg.top),
      '-Right', String(cfg.right),
      '-Topmost', cfg.alwaysOnTop ? 'true' : 'false',
      '-Silent', cfg.silent ? 'true' : 'false'
    ];
    try {
      child = spawn('powershell.exe', args, { windowsHide: true, stdio: 'ignore' });
      diag('spawned powershell pid=' + (child.pid || '?') + ' apiPort=' + apiPort);
      child.on('exit', (code) => {
        diag('powershell 退出 code=' + code);
        child = null;
        if (disposed) return;
        restartTimer = setTimeout(() => {
          const port = server ? server.address().port : 0;
          spawnWidget(port);
        }, 2500);
      });
      child.on('error', (e) => diag('powershell spawn 失败 ' + (e && e.message)));
    } catch (e) {
      diag('spawn 异常 ' + (e && e.message));
    }
  }

  (async () => {
    server = await startApi();
    const port = server ? server.address().port : 0;
    diag('api 端口=' + port);
    if (cfg.autoStart !== false) spawnWidget(port);
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
