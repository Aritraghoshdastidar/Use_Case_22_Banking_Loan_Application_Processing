// Small shared helpers: DOM, formatting, API calls (with a log of real exchanges), textures, drawer, toast.
export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const inr = (x, d = 0) => '₹' + Number(x).toLocaleString('en-IN', { minimumFractionDigits: d, maximumFractionDigits: d });
export const when = (iso) => (iso ? new Date(iso).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '');
export const day = (iso) => (iso ? new Date(iso).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '');
export const age = (min) => (min < 60 ? `${min} min` : min < 1440 ? `${Math.floor(min / 60)} h ${min % 60} m` : `${Math.floor(min / 1440)} d ${Math.floor((min % 1440) / 60)} h`);
export const NS = 'http://www.w3.org/2000/svg';

/* ---------- API with an evidence log (what the site really sent and got back) ---------- */
export const exchanges = [];
export async function api(method, url, { json, form } = {}) {
  const headers = { 'x-requested-with': 'mf', accept: 'application/json' };
  let body;
  if (json !== undefined) { body = JSON.stringify(json); headers['content-type'] = 'application/json'; }
  if (form) body = form;
  const t0 = performance.now();
  let res;
  try { res = await fetch(url, { method, headers, body, credentials: 'same-origin' }); }
  catch { return { status: 0, ok: false, data: { code: 'OFFLINE', message: 'The site could not be reached. Check that the server is running.' } }; }
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  const ms = Math.round(performance.now() - t0);
  const entry = { at: new Date().toISOString(), method, url, status: res.status, ms, upstream: res.headers.get('x-upstream-status'), upMs: res.headers.get('x-upstream-ms'), corr: res.headers.get('x-upstream-correlation'), count: 1 };
  const last = exchanges[0];
  if (method === 'GET' && last && last.method === 'GET' && last.url === url) { entry.count = last.count + 1; exchanges[0] = entry; } // a polled call is one line with a counter
  else { exchanges.unshift(entry); exchanges.length = Math.min(exchanges.length, 40); }
  if (res.status === 401 && data && data.code === 'LOGIN_REQUIRED') window.dispatchEvent(new CustomEvent('mf:login-required'));
  return { status: res.status, ok: res.ok, data };
}

/* ---------- state chips ---------- */
const STAGE = { RECEIVED: ['s-idle', 'Received'], VERIFYING: ['s-info', 'Checking documents'], VERIFIED: ['s-info', 'Documents verified'], SCORING: ['s-info', 'Being assessed'], APPROVED: ['s-ok', 'Approved'], REFERRED: ['s-warn', 'With an underwriter'], DECLINED: ['s-bad', 'Declined'], DOCUMENTS_INCOMPLETE: ['s-info', 'Documents missing'] };
export const stageChip = (s, staff = false) => { const m = STAGE[s]; return m ? `<span class="state ${m[0]}">${staff ? s.replace(/_/g, ' ') : m[1]}</span>` : '<span class="state s-idle">…</span>'; };
export const STAGE_COLOR = { RECEIVED: '#66736E', VERIFYING: '#3F6489', VERIFIED: '#3F6489', SCORING: '#3F6489', DOCUMENTS_INCOMPLETE: '#6C8FB5', APPROVED: '#1E7A4C', REFERRED: '#9A5F08', DECLINED: '#A33A2C' };
export const TERMINAL = ['APPROVED', 'REFERRED', 'DECLINED'];

/* ---------- guilloche line work, drawn in code ---------- */
export function rosette(svg, R, r, d, copies, color, width, opacity) {
  const k = (R - r) / r, steps = 240, pts = [];
  for (let i = 0; i <= steps; i++) {
    const t = (i / steps) * Math.PI * 2;
    pts.push(((R - r) * Math.cos(t) + d * Math.cos(k * t)).toFixed(1) + ' ' + ((R - r) * Math.sin(t) - d * Math.sin(k * t)).toFixed(1));
  }
  const dstr = 'M' + pts.join(' L'), g = document.createElementNS(NS, 'g');
  g.setAttribute('fill', 'none'); g.setAttribute('stroke', color); g.setAttribute('stroke-width', width); g.setAttribute('opacity', opacity);
  for (let i = 0; i < copies; i++) {
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', dstr); p.setAttribute('transform', 'rotate(' + ((i * 360) / copies).toFixed(2) + ')');
    g.appendChild(p);
  }
  svg.appendChild(g);
}
export function waves(svg, w, h, n, amp, wl, color, width) {
  svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
  for (let k = 0; k < n; k++) {
    let d = '';
    for (let x = 0; x <= w; x += 4) d += (x ? ' L' : 'M') + x + ' ' + (h / 2 + amp * Math.sin((x / wl) * Math.PI * 2 + (k * Math.PI * 2) / n)).toFixed(1);
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', d); p.setAttribute('fill', 'none'); p.setAttribute('stroke', color); p.setAttribute('stroke-width', width); p.setAttribute('opacity', '.8');
    svg.appendChild(p);
  }
}
export function flower(svg) {
  for (let i = 0; i < 8; i++) {
    const e = document.createElementNS(NS, 'ellipse');
    e.setAttribute('cx', 0); e.setAttribute('cy', -7); e.setAttribute('rx', 3.6); e.setAttribute('ry', 7.4);
    e.setAttribute('fill', i % 2 ? '#B98319' : '#D6A23A'); e.setAttribute('opacity', '.92'); e.setAttribute('transform', 'rotate(' + i * 45 + ')');
    svg.appendChild(e);
  }
  const c = document.createElementNS(NS, 'circle'); c.setAttribute('r', 3.2); c.setAttribute('fill', '#0D5A4E'); svg.appendChild(c);
}
export function paintTextures(root = document) {
  $$('[data-guil]', root).forEach((s) => { if (s.childElementCount) return; rosette(s, 180, 22.5, 52, 56, '#0D5A4E', .55, 1); rosette(s, 118, 23.6, 30, 44, '#B98319', .5, .8); rosette(s, 64, 16, 15, 30, '#0D5A4E', .5, .9); });
  $$('[data-wave]', root).forEach((s) => { if (!s.childElementCount) waves(s, 900, 22, 6, 5, 60, '#6FB5A5', .7); });
}

/* ---------- toast and drawer ---------- */
let toastTimer;
export function toast(message, bad = false) {
  const t = $('#toast'); t.textContent = message; t.className = 'toast' + (bad ? ' bad' : ''); t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 4200);
}
let lastFocus = null;
export function openDrawer(eyebrow, title, html) {
  lastFocus = document.activeElement;
  $('#dEyebrow').textContent = eyebrow; $('#dTitle').textContent = title; $('#dBody').innerHTML = html;
  $('#drawer').classList.add('open'); $('#drawer').setAttribute('aria-hidden', 'false'); $('#scrim').hidden = false; $('#dClose').focus();
}
export function setDrawerBody(html) { $('#dBody').innerHTML = html; }
export function closeDrawer() {
  $('#drawer').classList.remove('open'); $('#drawer').setAttribute('aria-hidden', 'true'); $('#scrim').hidden = true;
  if (lastFocus && document.contains(lastFocus)) lastFocus.focus();
  window.dispatchEvent(new CustomEvent('mf:drawer-closed'));
}
export const drawerOpen = () => $('#drawer').classList.contains('open');

/* ---------- polling that stops when the page changes or the tab is hidden ---------- */
let pollTimer = null;
export function startPolling(fn, ms) {
  stopPolling();
  const tick = async () => { if (!document.hidden) { try { await fn(); } catch { /* next tick tries again */ } } pollTimer = setTimeout(tick, ms); };
  pollTimer = setTimeout(tick, ms);
}
export function stopPolling() { clearTimeout(pollTimer); pollTimer = null; }

/* ---------- requirement chips (proof mode) ---------- */
export const req = (id) => `<span class="req" data-req="${id}" role="button" tabindex="0" title="Show what proves ${id}">${id}</span>`;
export function fieldHtml({ id, label, type = 'text', value = '', hint = '', error = '', attrs = '' }) {
  return `<div class="field${error ? ' err' : ''}"><label for="${id}">${label}</label><input id="${id}" name="${id}" type="${type}" value="${esc(value)}" ${attrs} ${error ? `aria-invalid="true" aria-describedby="${id}-m"` : ''}>${hint && !error ? `<span class="hint">${hint}</span>` : ''}${error ? `<span class="msg" id="${id}-m">${esc(error)}</span>` : ''}</div>`;
}
