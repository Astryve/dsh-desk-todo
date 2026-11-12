let state = null;
let view = 'week'; // week | long（仅小尺寸用）

const $ = (s) => document.querySelector(s);
const pad = (n) => String(n).padStart(2, '0');
const dayKey = (d) => d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
const WD = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

function applyMode() {
  const w = window.innerWidth, h = window.innerHeight;
  const b = document.body;
  b.classList.remove('mode-s', 'mode-m');
  if (w < 400 || h < 190) b.classList.add('mode-s'); else b.classList.add('mode-m');
  b.classList.toggle('view-week', view === 'week');
  b.classList.toggle('view-long', view === 'long');
  $('#btnView').style.display = b.classList.contains('mode-s') ? '' : 'none';
  $('#btnView').textContent = view === 'week' ? '长期' : '本周';
}

function abbreviatePlace(place) {
  return String(place || '')
    .replace(/^武进/, '')
    .replace(/东区国际教室/g, '东区')
    .replace(/教学主楼/g, '主楼')
    .replace(/教学辅楼/g, '辅楼')
    .replace(/阶教楼/g, '')
    .trim();
}

function semesterWeek(date) {
  const base = state.semester && state.semester.week1Monday;
  if (!base) return null;
  const b = new Date(base + 'T00:00:00');
  const mon = new Date(date); mon.setHours(0, 0, 0, 0);
  mon.setDate(mon.getDate() - ((mon.getDay() + 6) % 7));
  return Math.floor((mon - b) / (7 * 86400000)) + 1;
}

function weekLabel() {
  const now = new Date();
  const start = new Date(now); start.setDate(now.getDate() - ((now.getDay() + 6) % 7));
  const end = new Date(start); end.setDate(start.getDate() + 6);
  const wk = semesterWeek(now);
  return (wk ? '第' + wk + '周 · ' : '') + (start.getMonth() + 1) + '/' + start.getDate() + '–' + (end.getMonth() + 1) + '/' + end.getDate();
}

function occursOn(ev, date) {
  const t = dayKey(date);
  if (ev.day === t) return true;
  if (ev.repeat !== 'weekly') return false;
  const base = new Date(ev.day + 'T00:00:00');
  return base.getDay() === date.getDay() && date >= base;
}

function mins(hhmm) { const p = String(hhmm || '00:00').split(':'); return (Number(p[0]) || 0) * 60 + (Number(p[1]) || 0); }

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function renderWeek() {
  const box = $('#weekList');
  box.innerHTML = '';
  const now = new Date();
  const nowMin = now.getHours() * 60 + now.getMinutes();
  for (let i = 0; i < 7; i++) {
    const d = new Date(now); d.setDate(now.getDate() + i);
    const list = (state.events || [])
      .filter((e) => occursOn(e, d))
      .filter((e) => e.doneOn !== dayKey(d))
      .sort((a, b) => mins(a.start) - mins(b.start));
    const day = document.createElement('div');
    const weekend = d.getDay() === 0 || d.getDay() === 6;
    day.className = 'day' + (i === 0 ? ' today' : '') + (weekend ? ' weekend' : '') + (list.length ? '' : ' blank');
    const head = i === 0 ? '今天' : i === 1 ? '明天' : WD[d.getDay()];
    day.innerHTML = '<div class="day-h">' + head + ' · ' + (d.getMonth() + 1) + '/' + d.getDate() + '</div>';
    if (!list.length) {
      const empty = document.createElement('div');
      empty.className = 'day-empty';
      empty.textContent = '—';
      day.appendChild(empty);
    }
    for (const ev of list) {
      const past = i === 0 && mins(ev.end || ev.start) < nowMin;
      const el = document.createElement('div');
      el.className = 'ev ' + (ev.color || '') + (past ? ' past' : '');
      el.dataset.id = ev.id;
      const place = abbreviatePlace(ev.place);
      el.innerHTML = '<div class="t">' + (ev.start || '') + '</div>' +
        '<div class="body"><div class="n">' + escapeHtml(ev.title || '') + '</div>' +
        (place ? '<div class="m">' + escapeHtml(place) + '</div>' : '') + '</div>';
      el.addEventListener('click', () => openDetail('event', ev.id, dayKey(d)));
      day.appendChild(el);
    }
    box.appendChild(day);
  }
}

function renderLong() {
  const box = $('#longList');
  box.innerHTML = '';
  const items = (state.longterm || []).slice().sort((a, b) => String(a.due || '9999').localeCompare(String(b.due || '9999')));
  if (!items.length) { box.innerHTML = '<div class="empty">暂无</div>'; return; }
  const today = new Date(); today.setHours(0, 0, 0, 0);
  for (const it of items) {
    const el = document.createElement('div');
    el.className = 'lt' + (it.done ? ' done' : '');
    let dueTxt = '', cls = 'due';
    if (it.due) {
      const dd = new Date(it.due + 'T00:00:00');
      const left = Math.ceil((dd - today) / 86400000);
      dueTxt = left < 0 ? (-left) + '天前' : left === 0 ? '今天' : left + '天';
      if (left <= 3) cls += ' hot'; else if (left <= 10) cls += ' warn';
    }
    el.innerHTML = '<div class="n">' + escapeHtml(it.title || '') + '</div><div class="' + cls + '">' + dueTxt + '</div>';
    el.addEventListener('click', () => openDetail('long', it.id));
    box.appendChild(el);
  }
}

/* ───── 时间选择：滚轮式，打开时把当前值滚到正中，上下滚动选 ───── */
const TP_ROW = 30;   // 单行高度
const TP_ROWS = 5;   // 可视行数（奇数，正中那行 = 选中项）
let tp = null;

function tpPad(btn, v) {
  btn.dataset.value = pad(v);
  btn.textContent = pad(v);
}

/* 打开前先把当前值写进按钮（首次 / 快捷识别后） */
function fillTimeSelects() {
  ['eStartH', 'eStartM', 'eEndH', 'eEndM'].forEach((id) => {
    const b = $('#' + id);
    if (!b || b.dataset.ready) return;
    b.dataset.ready = '1';
    if (!b.dataset.value) tpPad(b, 0);
    b.addEventListener('click', (e) => { e.stopPropagation(); tpOpen(b); });
  });
}

function setTime(prefix, value) {
  const s = String(value || '00:00').split(':');
  const h = $('#' + prefix + 'H'), m = $('#' + prefix + 'M');
  if (h) tpPad(h, Math.min(23, Number(s[0]) || 0));
  if (m) tpPad(m, Math.min(59, Number(s[1]) || 0));
}
function getTime(prefix) {
  const h = $('#' + prefix + 'H'), m = $('#' + prefix + 'M');
  return pad(Number(h && h.dataset.value) || 0) + ':' + pad(Number(m && m.dataset.value) || 0);
}

function tpBuild() {
  if (tp) return tp;
  const el = document.createElement('div');
  el.className = 'tp hidden';
  el.innerHTML = '<div class="tp-band"></div><div class="tp-list" tabindex="-1"></div>';
  document.body.appendChild(el);
  const list = el.querySelector('.tp-list');
  tp = { el, list, btn: null, unit: 'hour', max: 24, value: 0, timer: 0, openedAt: 0 };

  el.addEventListener('pointerdown', (e) => e.stopPropagation());
  // 滚动停下 110ms 后吸附到最近一行
  list.addEventListener('scroll', () => {
    if (tp.el.classList.contains('hidden')) return;
    clearTimeout(tp.timer);
    tp.timer = setTimeout(() => {
      const i = Math.max(0, Math.min(tp.max - 1, Math.round(list.scrollTop / TP_ROW)));
      list.scrollTo({ top: i * TP_ROW, behavior: 'smooth' });
      tpCommit(i);
    }, 110);
  }, { passive: true });

  list.addEventListener('click', (e) => {
    const it = e.target.closest('.tp-i');
    if (!it) return;
    const i = Number(it.dataset.v) || 0;
    list.scrollTo({ top: i * TP_ROW, behavior: 'smooth' });
    tpCommit(i);
    tpClose();
  });

  document.addEventListener('pointerdown', (e) => {
    if (!tp || tp.el.classList.contains('hidden')) return;
    if (tp.el.contains(e.target) || (tp.btn && tp.btn.contains(e.target))) return;
    tpClose();
  }, true);

  window.addEventListener('keydown', (e) => {
    if (!tp || tp.el.classList.contains('hidden')) return;
    if (e.key === 'Escape') { e.preventDefault(); tpClose(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); tpStep(-1); }
    else if (e.key === 'ArrowDown') { e.preventDefault(); tpStep(1); }
    else if (e.key === 'Enter') { e.preventDefault(); tpClose(); }
  });

  window.addEventListener('resize', () => {
    if (tp && !tp.el.classList.contains('hidden') && tp.btn) tpPlace();
  });
  return tp;
}

function tpCommit(i) {
  const v = Math.max(0, Math.min((tp.max || 24) - 1, Number(i) || 0));
  tp.value = v;
  if (tp.btn) tpPad(tp.btn, v);
  tp.el.querySelectorAll('.tp-i').forEach((n) => n.classList.toggle('on', Number(n.dataset.v) === v));
}

function tpStep(d) {
  const i = Math.max(0, Math.min(tp.max - 1, (tp.value || 0) + d));
  tp.list.scrollTo({ top: i * TP_ROW, behavior: 'smooth' });
  tpCommit(i);
}

function tpPlace() {
  const r = tp.btn.getBoundingClientRect();
  const w = tp.el.offsetWidth || 66, h = tp.el.offsetHeight || TP_ROWS * TP_ROW;
  let x = r.left + r.width / 2 - w / 2;
  x = Math.max(4, Math.min(window.innerWidth - w - 4, x));
  let y = r.bottom + 6;
  if (y + h > window.innerHeight - 4) y = r.top - h - 6;
  y = Math.max(4, Math.min(window.innerHeight - h - 4, y));
  tp.el.style.left = Math.round(x) + 'px';
  tp.el.style.top = Math.round(y) + 'px';
}

function tpOpen(btn) {
  if (!btn) return;
  if (tp && !tp.el.classList.contains('hidden') && tp.btn === btn) { tpClose(); return; }
  tpBuild();
  const unit = btn.dataset.unit === 'min' ? 'min' : 'hour';
  const max = unit === 'hour' ? 24 : 60;
  const cur = Math.min(max - 1, Number(btn.dataset.value) || 0);

  tp.btn = btn; tp.unit = unit; tp.max = max; tp.value = cur;
  const padTop = ((TP_ROWS - 1) / 2) * TP_ROW;
  tp.list.innerHTML = '';
  tp.list.style.paddingTop = padTop + 'px';
  tp.list.style.paddingBottom = padTop + 'px';
  const frag = document.createDocumentFragment();
  for (let i = 0; i < max; i++) {
    const d = document.createElement('div');
    d.className = 'tp-i';
    d.dataset.v = i;
    d.textContent = pad(i);
    frag.appendChild(d);
  }
  tp.list.appendChild(frag);

  tp.el.style.width = unit === 'hour' ? '64px' : '64px';
  tp.el.style.height = (TP_ROWS * TP_ROW) + 'px';
  tp.el.classList.remove('hidden');
  tpPlace();
  // 关键：打开时当前值就在正中
  tp.list.scrollTop = cur * TP_ROW;
  tpCommit(cur);
}

function tpClose() {
  if (!tp) return;
  tp.el.classList.add('hidden');
  tp.btn = null;
}

/* ───── 详情 ───── */
let curDetail = null;
function openDetail(kind, id, dateKeyStr) {
  const isEv = kind === 'event';
  const item = (isEv ? state.events : state.longterm).find((x) => x.id === id);
  if (!item) return;
  curDetail = { kind, id, dateKeyStr };
  $('#dTitle').textContent = item.title || '';
  if (isEv) {
    $('#dMeta').innerHTML = [
      (item.start || '') + (item.end ? ' – ' + item.end : ''),
      item.place ? '地点：' + escapeHtml(abbreviatePlace(item.place)) : '',
      item.remindMin ? '提前 ' + item.remindMin + ' 分钟提醒' : '到点提醒'
    ].filter(Boolean).join('<br>');
  } else {
    $('#dMeta').innerHTML = [
      item.due ? 'DDL：' + item.due : '没有明确 DDL',
      item.done ? '状态：已完成' : '状态：进行中'
    ].join('<br>');
  }
  $('#dNote').value = item.note || '';
  $('#dDone').textContent = (item.done || (isEv && item.doneOn)) ? '取消完成' : '标记完成';
  $('#detail').classList.remove('hidden');
}
function closeDetail() { $('#detail').classList.add('hidden'); curDetail = null; }

async function saveNote(text) {
  if (!curDetail) return;
  const arr = curDetail.kind === 'event' ? state.events : state.longterm;
  const item = arr.find((x) => x.id === curDetail.id);
  if (!item) return;
  item.note = text;
  await window.deskTodo.saveData(state);
}


/* ───── 备注里的一句话 → 结构化待办 ───── */
const CN_NUM = { '一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9,'十':10,
  '十一':11,'十二':12,'十三':13,'十四':14,'十五':15,'十六':16,'十七':17,'十八':18,'十九':19,'二十':20,
  '二十一':21,'二十二':22,'二十三':23,'二十四':24,'三十':30,'三十一':31 };
function toNum(t) {
  t = String(t || '').trim();
  if (/^\d+$/.test(t)) return Number(t);
  if (CN_NUM[t] != null) return CN_NUM[t];
  if (/^十[一二三四五六七八九]$/.test(t)) return 10 + CN_NUM[t[1]];
  if (/^[一二三四五六七八九]十$/.test(t)) return CN_NUM[t[0]] * 10;
  if (/^[一二三四五六七八九]十[一二三四五六七八九]$/.test(t)) return CN_NUM[t[0]] * 10 + CN_NUM[t[2]];
  return null;
}
function padNum(n) { return String(n).padStart(2, '0'); }
function dateStr(d) { return d.getFullYear() + '-' + padNum(d.getMonth() + 1) + '-' + padNum(d.getDate()); }
function stripVerbs(s) {
  return String(s || '').replace(/(交|去|见|开|拿|上|办|找|吃|取|送|还|买|课|会|作业|活动|面试|体检|报名|唱歌|玩|看|听|学|复习|跑步|运动).*$/, '').trim();
}

function parseQuick(raw, base) {
  let work = String(raw || '').trim();
  if (!work) return null;
  const now = base || new Date();
  const out = { date: null, start: null, end: null, place: '', title: '', tokens: [] };
  const mark = (t) => { if (t) out.tokens.push(t); };

  /* 0) 先认出「今晚/明晚/明早」这类带时段的日期词 */
  let ampm = null;      // 'pm' | 'am' | null
  let relDay = null;    // 相对天数
  const relMap = [
    [/大后天/, 3, null], [/后天/, 2, null],
    [/明晚|明天晚上/, 1, 'pm'], [/明早|明天早上|明天上午/, 1, 'am'], [/明天|明日/, 1, null],
    [/今晚|今天晚上/, 0, 'pm'], [/今早|今天早上|今天上午/, 0, 'am'], [/今天|今日/, 0, null]
  ];
  for (const [re, off, ap] of relMap) {
    const m = work.match(re);
    if (m) { relDay = off; if (ap) ampm = ap; work = work.replace(m[0], ' '); mark(m[0]); break; }
  }

  /* 1) 时段词 */
  if (!ampm) {
    const apRules = [[/凌晨|早上|早晨|上午|清晨/, 'am'], [/下午|午后|傍晚/, 'pm'], [/晚上|夜里|晚间/, 'pm'], [/中午|正午/, 'noon']];
    for (const [re, ap] of apRules) {
      const m = work.match(re);
      if (m) { ampm = ap; work = work.replace(m[0], ' '); mark(m[0]); break; }
    }
  }

  /* 2) 绝对日期 */
  let m;
  if ((m = work.match(/(\d{4})[-\/年](\d{1,2})[-\/月](\d{1,2})[日号]?/))) {
    out.date = m[1] + '-' + padNum(Number(m[2])) + '-' + padNum(Number(m[3]));
    work = work.replace(m[0], ' '); mark(m[0]);
  } else if ((m = work.match(/(\d{1,2})月(\d{1,2})[日号]/))) {
    out.date = now.getFullYear() + '-' + padNum(Number(m[1])) + '-' + padNum(Number(m[2]));
    work = work.replace(m[0], ' '); mark(m[0]);
  } else if ((m = work.match(/(本|这)?月?\s*(\d{1,2}|[一二三四五六七八九十]{1,3})\s*[日号]/))) {
    const day = toNum(m[2]);
    if (day && day <= 31) {
      const d = new Date(now.getFullYear(), now.getMonth(), day);
      if (d < new Date(now.getFullYear(), now.getMonth(), now.getDate())) d.setMonth(d.getMonth() + 1);
      out.date = dateStr(d);
      work = work.replace(m[0], ' '); mark(m[0]);
    }
  }

  /* 3) 相对日期 */
  if (!out.date && relDay != null) {
    const d = new Date(now); d.setDate(d.getDate() + relDay);
    out.date = dateStr(d);
  }

  /* 4) 周几 */
  if (!out.date && (m = work.match(/(下)?(?:周|星期|礼拜)([一二三四五六日天1-7])/))) {
    const map = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 0, '天': 0, '1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 0 };
    const d = new Date(now); d.setHours(0, 0, 0, 0);
    let diff = (map[m[2]] - d.getDay() + 7) % 7;
    if (diff === 0) diff = 7;
    if (m[1]) diff += 7;
    d.setDate(d.getDate() + diff);
    out.date = dateStr(d);
    work = work.replace(m[0], ' '); mark(m[0]);
  }

  /* 5) 时间段 */
  const rangeRe = /(\d{1,2}|[一二三四五六七八九十]{1,3})\s*[点时](半|\d{1,2}\s*分|[一二三四五六七八九十]{1,3}\s*分)?\s*(?:到|至|~|-|—|－)\s*(\d{1,2}|[一二三四五六七八九十]{1,3})\s*[点时](半|\d{1,2}\s*分|[一二三四五六七八九十]{1,3}\s*分)?/;
  if ((m = work.match(rangeRe))) {
    const h1 = toNum(m[1]), h2 = toNum(m[3]);
    const m1 = m[2] ? (m[2].indexOf('半') >= 0 ? 30 : (toNum(m[2].replace(/[^\d一二三四五六七八九十]/g, '')) || 0)) : 0;
    const m2 = m[4] ? (m[4].indexOf('半') >= 0 ? 30 : (toNum(m[4].replace(/[^\d一二三四五六七八九十]/g, '')) || 0)) : 0;
    if (h1 != null && h2 != null) {
      let s1 = h1, s2 = h2;
      if (ampm === 'pm') { if (s1 < 12) s1 += 12; if (s2 < 12) s2 += 12; }
      if (ampm === 'noon') { if (s1 < 11) s1 += 12; if (s2 < 11) s2 += 12; }
      if (s2 <= s1) s2 += 12;
      out.start = padNum(s1 % 24) + ':' + padNum(m1);
      out.end = padNum(s2 % 24) + ':' + padNum(m2);
      work = work.replace(m[0], ' '); mark(m[0]);
    }
  }

  /* 6) 单个时间 */
  if (!out.start && (m = work.match(/(\d{1,2}|[一二三四五六七八九十]{1,3})\s*[点时](半|\d{1,2}\s*分|[一二三四五六七八九十]{1,3}\s*分)?/))) {
    let h = toNum(m[1]);
    let mi = m[2] ? (m[2].indexOf('半') >= 0 ? 30 : (toNum(m[2].replace(/[^\d一二三四五六七八九十]/g, '')) || 0)) : 0;
    if (h != null) {
      if (ampm === 'pm' && h < 12) h += 12;
      if (ampm === 'noon' && h < 11) h += 12;
      if (ampm === 'am' && h === 12) h = 0;
      out.start = padNum(h % 24) + ':' + padNum(mi);
      const e = h * 60 + mi + 60;
      out.end = padNum(Math.floor(e / 60) % 24) + ':' + padNum(e % 60);
      work = work.replace(m[0], ' '); mark(m[0]);
    }
  }

  /* 7) 地点 */
  let place = '';
  if ((m = work.match(/地点[:：]\s*([^，,。.；;！!？?\s]{1,20})/))) {
    place = stripVerbs(m[1]);
    work = work.replace(m[0], ' '); mark(m[0]);
  }
  if (!place) {
    const pz = work.match(/(?:在|于)\s*([\u4e00-\u9fa5A-Za-z0-9\-—#（）()]{1,14})/);
    if (pz) {
      const cand = stripVerbs(pz[1]);
      if (cand.length >= 2) {
        place = cand;
        work = work.replace('在' + cand, ' ').replace('于' + cand, ' ');
      }
    }
  }
  if (!place) {
    const kw = work.match(/(东区|西区|南区|北区|主楼|辅楼|阶教楼|图书馆|教学楼|综合楼|实验楼|体育馆|食堂|宿舍|超市|KTV)(楼下|门口|旁边|附近|对面|W\d阶|W\d{3,4}|\d{3,4}|[\u4e00-\u9fa5]{1,3}楼|教室)?/);
    if (kw) {
      place = kw[0].trim();
      work = work.replace(kw[0], ' ');
      mark(kw[0]);
    }
  }
  out.place = place;

  /* 8) 标题 */
  let title = work.replace(/[，,。.；;！!？?、]/g, ' ').replace(/\s+/g, ' ').trim();
  title = title.replace(/^(去|要|在|于|到|的|记得|顺便|然后|再)\s*/, '').trim();
  if (!title) {
    title = String(raw).replace(/[，,。.；;！!？?、]/g, ' ').replace(/\s+/g, ' ').trim();
  }
  out.title = title.slice(0, 40);

  if (!out.date && !out.start && !out.place) return null;
  return out;
}

function quickFill() {
  const raw = $('#eNote').value;
  const hint = $('#eHint');
  hint.classList.remove('err');
  const r = parseQuick(raw);
  if (!r) { hint.classList.add('err'); hint.textContent = '没认出时间或地点，请手动选'; return; }
  if (r.date) $('#eDate').value = r.date;
  if (r.start) setTime('eStart', r.start);
  if (r.end) setTime('eEnd', r.end);
  if (r.place) $('#ePlace').value = r.place;
  if (r.title) $('#eTitle').value = r.title;
  const bits = [];
  if (r.date) bits.push(r.date.slice(5));
  if (r.start) bits.push(r.start + (r.end ? '–' + r.end : ''));
  if (r.place) bits.push(r.place);
  if (r.title) bits.push(r.title);
  hint.textContent = '识别为：' + bits.join(' · ');
}

/* ───── 新增 / 编辑 ───── */
let editing = null;
function openEditor(kind, id) {
  fillTimeSelects();
  editing = { kind: kind || 'event', id: id || null };
  const isEv = editing.kind === 'event';
  const item = id ? (isEv ? state.events : state.longterm).find((x) => x.id === id) : null;
  $('#eKind').textContent = id ? '编辑' : (isEv ? '新增待办' : '新增长期任务');
  document.querySelectorAll('.only-event').forEach((el) => { el.style.display = isEv ? '' : 'none'; });
  document.querySelectorAll('.only-long').forEach((el) => { el.style.display = isEv ? 'none' : ''; });
  $('#eTitle').value = item ? (item.title || '') : '';
  $('#eDate').value = item ? (item.day || '') : dayKey(new Date());
  setTime('eStart', item ? (item.start || '') : '08:00');
  setTime('eEnd', item ? (item.end || '') : '09:35');
  $('#ePlace').value = item ? (item.place || '') : '';
  $('#eRemind').value = (item && Number.isFinite(Number(item.remindMin))) ? item.remindMin : 15;
  $('#eRepeat').value = item ? (item.repeat || 'weekly') : 'weekly';
  $('#eDue').value = item ? (item.due || '') : '';
  $('#eNote').value = item ? (item.note || '') : '';
  $('#eHint').textContent = '';
  $('#eHint').classList.remove('err');
  $('#editor').classList.remove('hidden');
}
function closeEditor() { tpClose(); $('#editor').classList.add('hidden'); editing = null; }

async function submitEditor() {
  if (!editing) return;
  const isEv = editing.kind === 'event';
  const title = $('#eTitle').value.trim();
  if (!title) { $('#eTitle').focus(); return; }
  const arr = isEv ? state.events : state.longterm;
  let item = editing.id ? arr.find((x) => x.id === editing.id) : null;
  if (!item) { item = { id: (isEv ? 'e' : 'l') + Date.now().toString(36) }; arr.push(item); }
  item.title = title;
  item.note = $('#eNote').value;
  if (isEv) {
    item.day = $('#eDate').value || dayKey(new Date());
    item.start = getTime('eStart');
    item.end = getTime('eEnd');
    item.place = $('#ePlace').value.trim();
    item.remindMin = Number($('#eRemind').value) || 0;
    item.repeat = $('#eRepeat').value || 'none';
    delete item.who; delete item.weeksFrom; delete item.weeksTo;
    if (!item.color) item.color = 'blue';
  } else {
    item.due = $('#eDue').value || '';
  }
  await window.deskTodo.saveData(state);
  closeEditor();
  render();
}

function render() {
  $('#weekLabel').textContent = weekLabel();
  renderWeek();
  renderLong();
}

window.deskTodo.onState(async () => {
  state = await window.deskTodo.getState();
  applyMode();
  render();
});

window.deskTodo.onSound(function (urgent) {
  try {
    const audio = new Audio('../../assets/chime.wav');
    audio.volume = urgent ? 0.9 : 0.55;
    audio.play().catch(function () {});
  } catch (e) {}
});

window.addEventListener('resize', function () { applyMode(); });

function bind() {
  $('#dNote').addEventListener('input', (e) => { clearTimeout(window._nt); window._nt = setTimeout(() => saveNote(e.target.value), 600); });
  $('#dClose').addEventListener('click', closeDetail);
  $('#dDone').addEventListener('click', async () => {
    if (!curDetail) return;
    const isEv = curDetail.kind === 'event';
    const arr = isEv ? state.events : state.longterm;
    const item = arr.find((x) => x.id === curDetail.id);
    if (!item) return;
    if (isEv) { const t = curDetail.dateKeyStr || dayKey(new Date()); item.doneOn = item.doneOn === t ? null : t; }
    else { item.done = !item.done; }
    await window.deskTodo.saveData(state);
    closeDetail(); render();
  });
  $('#dEdit').addEventListener('click', () => { if (!curDetail) return; const c = curDetail; closeDetail(); openEditor(c.kind, c.id); });
  $('#dDel').addEventListener('click', async () => {
    if (!curDetail) return;
    const isEv = curDetail.kind === 'event';
    state[isEv ? 'events' : 'longterm'] = state[isEv ? 'events' : 'longterm'].filter((x) => x.id !== curDetail.id);
    await window.deskTodo.saveData(state);
    closeDetail(); render();
  });
  $('#dOpenData').addEventListener('click', () => window.deskTodo.openData());

  $('#eParse').addEventListener('click', quickFill);
  $('#eSave').addEventListener('click', submitEditor);
  $('#eCancel').addEventListener('click', closeEditor);
  $('#eCancel2').addEventListener('click', closeEditor);
  $('#eDelete').addEventListener('click', async () => {
    if (!editing || !editing.id) { closeEditor(); return; }
    const isEv = editing.kind === 'event';
    state[isEv ? 'events' : 'longterm'] = state[isEv ? 'events' : 'longterm'].filter((x) => x.id !== editing.id);
    await window.deskTodo.saveData(state);
    closeEditor(); render();
  });

  $('#btnAdd').addEventListener('click', () => openEditor('event'));
  $('#btnAdd').addEventListener('contextmenu', (e) => { e.preventDefault(); openEditor('long'); });
  $('#btnView').addEventListener('click', () => { view = view === 'week' ? 'long' : 'week'; applyMode(); render(); });
  $('#btnHide').addEventListener('click', () => window.deskTodo.hide());
  $('#btnCfg').addEventListener('click', () => {
    const s = state.settings || {};
    $('#cW').value = s.w || 520; $('#cH').value = s.h || 330;
    const op = Number.isFinite(Number(s.opacity)) ? Number(s.opacity) : 0.85;
    $('#cOpacity').value = op; $('#cOpV').textContent = Math.round(op * 100) + '%';
    $('#cfg').classList.remove('hidden');
  });
  $('#cClose').addEventListener('click', () => $('#cfg').classList.add('hidden'));
  document.querySelectorAll('[data-preset]').forEach((b) => b.addEventListener('click', () => {
    const wh = b.dataset.preset.split('x');
    $('#cW').value = wh[0]; $('#cH').value = wh[1];
    window.deskTodo.setBounds({ w: Number(wh[0]), h: Number(wh[1]) });
    setTimeout(function () { applyMode(); render(); }, 150);
  }));
  $('#cOpacity').addEventListener('input', (e) => {
    $('#cOpV').textContent = Math.round(e.target.value * 100) + '%';
    document.documentElement.style.setProperty('--op', e.target.value);
  });
  $('#cApply').addEventListener('click', () => {
    const w = Number($('#cW').value) || 520, h = Number($('#cH').value) || 330;
    const op = Number($('#cOpacity').value) || 0.85;
    window.deskTodo.setBounds({ w, h });
    window.deskTodo.setOpacity(op);
    setTimeout(function () { applyMode(); render(); }, 150);
  });
}

(async function boot() {
  state = await window.deskTodo.getState();
  const op = (state.settings && state.settings.opacity) || 0.85;
  document.documentElement.style.setProperty('--op', String(op));
  applyMode();
  render();
  bind();
})();
