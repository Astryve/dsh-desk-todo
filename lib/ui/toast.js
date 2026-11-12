const q = new URLSearchParams(location.search);
document.getElementById('t').textContent = q.get('t') || '提醒';
document.getElementById('b').textContent = q.get('b') || '';
if (q.get('u') === '1') document.getElementById('box').classList.add('urgent');
document.getElementById('x').addEventListener('click', () => window.close());
setTimeout(() => window.close(), Number(q.get('ms') || 9000));
