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


export { parseQuick };
