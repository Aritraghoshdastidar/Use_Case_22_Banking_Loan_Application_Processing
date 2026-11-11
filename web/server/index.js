// The site's server: login and roles, the customer journey, the staff console, and the only place that talks to the Mule apps.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { PORT, ROOT, environments, defaultEnv } from './config.js';
import { q, logAction } from './store.js';
import { hashPassword, checkPassword, startSession, endSession, userFrom, seedStaff, tooManyMisses, recordMiss, clearMisses } from './auth.js';
import { call, proxyUpload, mq, mailFor } from './upstream.js';
import { customerView, staffApplication, maskId, validProduct, validDraft } from './domain.js';

const state = { env: defaultEnv };
const envNow = () => environments[state.env];
const CLIENT_DIR = path.join(ROOT, 'client');
const STAFF = new Set(['underwriter', 'ops']);

/* ------------------------------------------------------------------ routing */
const routes = [];
function add(method, pattern, access, handler) {
  const keys = [];
  const re = new RegExp('^' + pattern.replace(/:([a-zA-Z]+)/g, (_, k) => { keys.push(k); return '([^/]+)'; }) + '$');
  routes.push({ method, re, keys, access, handler });
}

const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml', '.json': 'application/json', '.ico': 'image/x-icon' };
const SECURITY = {
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'same-origin',
  'content-security-policy': "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
};

function send(res, status, body, extra = {}) {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...SECURITY, ...extra });
  res.end(text);
}

function readJson(req, limit = 100_000) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => { size += c.length; if (size > limit) { reject(Object.assign(new Error('too large'), { status: 413 })); req.destroy(); } else chunks.push(c); });
    req.on('end', () => { try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch { reject(Object.assign(new Error('bad json'), { status: 400 })); } });
    req.on('error', reject);
  });
}

/** Pass an upstream answer to the browser with evidence headers (no secrets). */
function relay(res, r, extra = {}) {
  const evidence = { 'x-upstream-status': String(r.status), 'x-upstream-ms': String(r.ms) };
  if (r.correlationId) evidence['x-upstream-correlation'] = r.correlationId;
  return send(res, r.status >= 100 ? r.status : 502, r.json !== null ? r.json : { code: 'UPSTREAM_ERROR', message: 'Unexpected answer from the service.' }, { ...evidence, ...extra });
}

const toClient = (u) => ({ id: u.id, name: u.name, email: u.email, role: u.role });
const isStaff = (u) => !!u && STAFF.has(u.role);

/* ------------------------------------------------------------------ public */
add('GET', '/api/health', null, async (c) => send(c.res, 200, { status: 'UP', env: state.env }));

add('GET', '/api/config', null, async (c) => send(c.res, 200, {
  brand: 'Marigold Finance',
  env: state.env,
  environments: Object.values(environments).map((e) => ({ id: e.id, label: e.label, note: e.note, chaos: e.chaos, mail: !!e.mail })),
  user: c.user ? toClient(c.user) : null,
}));

add('POST', '/api/auth/register', null, async (c) => {
  const b = await readJson(c.req);
  const name = String(b.name || '').trim(); const email = String(b.email || '').trim().toLowerCase(); const password = String(b.password || '');
  const errors = [];
  if (name.length < 2 || name.length > 80) errors.push({ field: 'name', message: 'Enter your full name.' });
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 120) errors.push({ field: 'email', message: 'Enter a valid email address.' });
  if (password.length < 8 || password.length > 100) errors.push({ field: 'password', message: 'Use at least 8 characters.' });
  if (errors.length) return send(c.res, 400, { code: 'VALIDATION', message: 'Check the highlighted fields.', errors });
  if (q.userByEmail.get(email)) return send(c.res, 409, { code: 'EMAIL_TAKEN', message: 'An account with this email already exists. Sign in instead.' });
  const r = q.insertUser.run(email, name, hashPassword(password), 'customer');
  startSession(c.res, Number(r.lastInsertRowid));
  return send(c.res, 201, { user: { id: Number(r.lastInsertRowid), name, email, role: 'customer' } });
});

add('POST', '/api/auth/login', null, async (c) => {
  const b = await readJson(c.req);
  const email = String(b.email || '').trim().toLowerCase(); const key = c.req.socket.remoteAddress + '|' + email;
  if (tooManyMisses(key)) return send(c.res, 429, { code: 'TOO_MANY_ATTEMPTS', message: 'Too many wrong passwords. Try again in ten minutes.' });
  const u = q.userByEmail.get(email);
  if (!u || !checkPassword(String(b.password || ''), u.password_hash)) { recordMiss(key); return send(c.res, 401, { code: 'BAD_LOGIN', message: 'Email or password is not right.' }); }
  clearMisses(key); startSession(c.res, u.id);
  return send(c.res, 200, { user: toClient(u) });
});

add('POST', '/api/auth/logout', null, async (c) => { endSession(c.req, c.res); return send(c.res, 200, { ok: true }); });
add('GET', '/api/me', 'any', async (c) => send(c.res, 200, { user: toClient(c.user) }));

let productCache = { at: 0, data: null };
add('GET', '/api/products', null, async (c) => {
  if (productCache.data && Date.now() - productCache.at < 60000 && productCache.env === state.env) return send(c.res, 200, productCache.data);
  const env = envNow();
  const out = [];
  for (const code of ['PL', 'HL']) {
    const [p, r] = await Promise.all([call(env, 'system', 'GET', `/products/${code}`), call(env, 'system', 'GET', `/products/${code}/document-rules`)]);
    if (!p.ok) return send(c.res, 503, { code: 'UPSTREAM_UNAVAILABLE', message: 'Product details are not available right now.' });
    out.push({ ...p.json, documents: r.ok ? (r.json.rules || r.json) : [] });
  }
  productCache = { at: Date.now(), data: out, env: state.env };
  return send(c.res, 200, out);
});

/* ------------------------------------------------------------------ customer */
function ownApplication(c, id) {
  const m = q.appById.get(state.env, id);
  if (!m || m.user_id !== c.user.id) return null;
  return m;
}

add('POST', '/api/drafts/:draft/documents', 'customer', async (c) => {
  const draft = c.params.draft; const product = c.url.searchParams.get('product');
  if (!validDraft(draft) || !validProduct(product)) { c.req.resume(); return send(c.res, 400, { code: 'BAD_REQUEST', message: 'Start the application again.' }); }
  const r = await proxyUpload(envNow(), `/staging/w${c.user.id}-${draft}/documents?product=${product}`, c.req);
  return relay(c.res, r);
});

add('POST', '/api/applications', 'customer', async (c) => {
  const b = await readJson(c.req);
  if (!validDraft(b.draft) || !validProduct(b.product)) return send(c.res, 400, { code: 'BAD_REQUEST', message: 'Start the application again.' });
  const docs = Array.isArray(b.documents) ? b.documents.filter((d) => d && typeof d.fileName === 'string' && typeof d.type === 'string').slice(0, 20) : [];
  const folder = `w${c.user.id}-${b.draft}`;
  const payload = {
    requestId: `WEB-${c.user.id}-${b.draft}`,
    productCode: b.product,
    amount: Number(b.amount),
    tenureMonths: Number(b.tenure),
    applicant: {
      fullName: String(b.fullName || '').trim(),
      dateOfBirth: String(b.dateOfBirth || ''),
      identityRef: String(b.identityRef || '').trim().toUpperCase(),
      email: c.user.email,
      monthlyIncome: Number(b.monthlyIncome),
      monthlyObligations: Number(b.monthlyObligations || 0),
      employmentMonths: Number(b.employmentMonths || 0),
    },
    documents: { folder, documentCount: docs.length, documents: docs.map((d) => ({ fileName: d.fileName, type: d.type })) },
  };
  const r = await call(envNow(), 'intake', 'POST', '/applications', { json: payload });
  if (r.status === 202 && r.json && r.json.applicationId) {
    q.upsertApp.run(state.env, r.json.applicationId, c.user.id, folder, b.product, payload.amount, payload.tenureMonths);
  }
  return relay(c.res, r);
});

add('GET', '/api/applications', 'customer', async (c) => {
  const env = envNow();
  const rows = q.appsOf.all(state.env, c.user.id);
  const list = await Promise.all(rows.map(async (m) => {
    const s = await call(env, 'intake', 'GET', `/applications/${m.application_id}/status`);
    return { applicationId: m.application_id, product: m.product, amount: m.amount, tenure: m.tenure, createdAt: m.created_at, stage: s.ok ? s.json.stage : null, outcome: s.ok && s.json.decision ? s.json.decision.decision : null };
  }));
  return send(c.res, 200, list);
});

add('GET', '/api/applications/:id', 'customer', async (c) => {
  const m = ownApplication(c, c.params.id);
  if (!m) return send(c.res, 404, { code: 'NOT_FOUND', message: 'We could not find that application.' });
  const env = envNow();
  const [s, a] = await Promise.all([call(env, 'intake', 'GET', `/applications/${m.application_id}/status`), call(env, 'system', 'GET', `/applications/${m.application_id}/audit`)]);
  if (!s.ok) return relay(c.res, s);
  return send(c.res, 200, customerView(m, s.json, a.ok ? a.json : null), { 'x-upstream-status': String(s.status), 'x-upstream-ms': String(s.ms), ...(s.correlationId ? { 'x-upstream-correlation': s.correlationId } : {}) });
});

add('GET', '/api/applications/:id/messages', 'customer', async (c) => {
  const m = ownApplication(c, c.params.id);
  if (!m) return send(c.res, 404, { code: 'NOT_FOUND', message: 'We could not find that application.' });
  const r = await mailFor(envNow(), c.user.email);
  return send(c.res, 200, r);
});

add('POST', '/api/applications/:id/documents', 'customer', async (c) => {
  const m = ownApplication(c, c.params.id);
  if (!m) { c.req.resume(); return send(c.res, 404, { code: 'NOT_FOUND', message: 'We could not find that application.' }); }
  const r = await proxyUpload(envNow(), `/staging/${m.folder}/documents?product=${m.product}`, c.req);
  return relay(c.res, r);
});

add('POST', '/api/applications/:id/resubmit', 'customer', async (c) => {
  const m = ownApplication(c, c.params.id);
  if (!m) return send(c.res, 404, { code: 'NOT_FOUND', message: 'We could not find that application.' });
  return relay(c.res, await call(envNow(), 'intake', 'POST', `/applications/${m.application_id}/resubmit`));
});

/* ------------------------------------------------------------------ staff */
const SERVICES = [
  { key: 'system', name: 'loan-system-api', layer: 'System', path: '/health' },
  { key: 'intake', name: 'loan-intake-exp-api', layer: 'Experience', path: '/applications/APP-HEALTH/status', anyAnswer: true },
  { key: 'document', name: 'loan-document-proc', layer: 'Process', path: '/health' },
  { key: 'scoring', name: 'loan-scoring-proc', layer: 'Process', path: '/health' },
  { key: 'notification', name: 'loan-notification-proc', layer: 'Process', path: '/health' },
];
const LOAN_QUEUES = ['loan.verify.q', 'loan.score.q', 'loan.decision.q'];
const vh = (env) => encodeURIComponent(env.mq.vhost);

async function queueDepths(env) {
  if (!env.mq) return { available: false, queues: [] };
  const r = await mq(env, 'GET', `/queues/${vh(env)}`);
  if (!r.ok || !Array.isArray(r.json)) return { available: false, queues: [] };
  const byName = Object.fromEntries(r.json.map((x) => [x.name, x]));
  return {
    available: true,
    queues: LOAN_QUEUES.map((name) => ({
      name,
      ready: (byName[name] || {}).messages_ready ?? 0,
      unacked: (byName[name] || {}).messages_unacknowledged ?? 0,
      consumers: (byName[name] || {}).consumers ?? 0,
      dlq: name + '.dlq',
      dead: (byName[name + '.dlq'] || {}).messages ?? 0,
    })),
  };
}

add('GET', '/api/staff/overview', 'staff', async (c) => {
  const env = envNow();
  const [checks, list, depth, unnotified, outbox, bureau] = await Promise.all([
    Promise.all(SERVICES.map(async (s) => {
      const r = await call(env, s.key, 'GET', s.path, { timeoutMs: 12000 });
      const up = s.anyAnswer ? r.status < 500 && r.status !== 503 : r.ok;
      return { key: s.key, name: s.name, layer: s.layer, up, status: r.status, ms: r.ms };
    })),
    call(env, 'system', 'GET', '/applications', { query: { limit: '500' } }),
    queueDepths(env),
    call(env, 'system', 'GET', '/notifications'),
    call(env, 'system', 'GET', '/outbox/pending'),
    call(env, 'system', 'GET', '/bureau/switch'),
  ]);
  const apps = Array.isArray(list.json) ? [...list.json].sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt))) : [];
  const stages = {};
  for (const a of apps) stages[a.stage] = (stages[a.stage] || 0) + 1;
  const owners = new Map(db_owners(state.env));
  return send(c.res, 200, {
    env: state.env,
    checks,
    stages,
    total: apps.length,
    recent: apps.slice(0, 8).map((a) => ({ ...a, owner: owners.get(a.applicationId) || null })),
    queues: depth,
    unnotified: Array.isArray(unnotified.json) ? unnotified.json : [],
    outboxPending: Array.isArray(outbox.json) ? outbox.json.length : null,
    bureauEnabled: bureau.ok ? bureau.json.enabled : null,
    actions: q.recentActions.all(),
    at: new Date().toISOString(),
  });
});

import { db } from './store.js';
const ownersStmt = db.prepare('SELECT a.application_id AS id, u.name AS name FROM applications a JOIN users u ON u.id = a.user_id WHERE a.env = ?');
function db_owners(envId) { return ownersStmt.all(envId).map((r) => [r.id, r.name]); }

add('GET', '/api/staff/applications', 'staff', async (c) => {
  const stage = c.url.searchParams.get('stage');
  const r = await call(envNow(), 'system', 'GET', '/applications', { query: { limit: '500', ...(stage ? { stage } : {}) } });
  if (!r.ok) return relay(c.res, r);
  const owners = new Map(db_owners(state.env));
  return send(c.res, 200, [...r.json].sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt))).map((a) => ({ ...a, owner: owners.get(a.applicationId) || null })));
});

add('GET', '/api/staff/applications/:id', 'staff', async (c) => {
  const env = envNow();
  const [s, a] = await Promise.all([call(env, 'system', 'GET', `/applications/${c.params.id}`), call(env, 'system', 'GET', `/applications/${c.params.id}/audit`)]);
  if (!s.ok) return relay(c.res, s);
  return send(c.res, 200, staffApplication(s.json, a.ok ? a.json : null, q.appById.get(state.env, c.params.id)));
});

add('POST', '/api/staff/applications/:id/resubmit', 'staff', async (c) => {
  const r = await call(envNow(), 'intake', 'POST', `/applications/${c.params.id}/resubmit`);
  logAction(c.user.id, state.env, c.params.id, 'RESUBMIT', `HTTP ${r.status}`);
  return relay(c.res, r);
});

add('POST', '/api/staff/applications/:id/documents', 'staff', async (c) => {
  const env = envNow();
  const s = await call(env, 'system', 'GET', `/applications/${c.params.id}`);
  if (!s.ok) { c.req.resume(); return relay(c.res, s); }
  const folder = s.json.manifest && s.json.manifest.folder;
  if (!folder) { c.req.resume(); return send(c.res, 409, { code: 'NO_FOLDER', message: 'This application has no document folder.' }); }
  const r = await proxyUpload(env, `/staging/${encodeURIComponent(folder)}/documents?product=${s.json.productCode}`, c.req);
  logAction(c.user.id, state.env, c.params.id, 'UPLOAD_FOR_APPLICANT', `HTTP ${r.status}`);
  return relay(c.res, r);
});

add('POST', '/api/staff/notifications/:id/retry', 'staff', async (c) => {
  if (!/^[0-9]{1,18}$/.test(c.params.id)) return send(c.res, 400, { code: 'BAD_REQUEST', message: 'Bad notification id.' });
  // a failed notification set back to PENDING is picked up by the notification app's retry job; the decision is never touched
  const r = await call(envNow(), 'system', 'PUT', `/notifications/${c.params.id}`, { json: { status: 'PENDING', lastError: 'Retry requested by staff' } });
  logAction(c.user.id, state.env, r.json && r.json.applicationId, 'RETRY_EMAIL', `notification ${c.params.id}: HTTP ${r.status}`);
  return relay(c.res, r);
});

add('POST', '/api/staff/digest', 'staff', async (c) => {
  const r = await call(envNow(), 'notification', 'POST', '/digest');
  logAction(c.user.id, state.env, null, 'SEND_DIGEST', `HTTP ${r.status}`);
  return relay(c.res, r);
});

add('GET', '/api/staff/bureau', 'staff', async (c) => relay(c.res, await call(envNow(), 'system', 'GET', '/bureau/switch')));
add('PUT', '/api/staff/bureau', 'staff', async (c) => {
  const b = await readJson(c.req);
  const r = await call(envNow(), 'system', 'PUT', '/bureau/switch', { json: { enabled: !!b.enabled } });
  logAction(c.user.id, state.env, null, b.enabled ? 'BUREAU_ON' : 'BUREAU_OFF', `HTTP ${r.status}`);
  return relay(c.res, r);
});

add('GET', '/api/staff/dlq/:queue', 'staff', async (c) => {
  const env = envNow(); const name = c.params.queue;
  if (!LOAN_QUEUES.map((x) => x + '.dlq').includes(name)) return send(c.res, 404, { code: 'NOT_FOUND', message: 'Unknown queue.' });
  const r = await mq(env, 'POST', `/queues/${vh(env)}/${encodeURIComponent(name)}/get`, { count: 50, ackmode: 'ack_requeue_true', encoding: 'auto', truncate: 20000 });
  if (!r.ok || !Array.isArray(r.json)) return send(c.res, 200, { available: false, messages: [] });
  return send(c.res, 200, {
    available: true,
    messages: r.json.map((m) => {
      let p = {}; try { p = JSON.parse(m.payload); } catch { /* not JSON: shown without details */ }
      const h = (m.properties && m.properties.headers) || {};
      return { applicationId: p.applicationId || null, type: p.type || null, reason: h['x-reason'] || h['x-failure'] || null, attempts: h['x-attempts'] || null, consumer: h['x-consumer'] || null, source: h['x-source-queue'] || null };
    }),
  });
});

add('POST', '/api/staff/dlq/:queue/replay', 'staff', async (c) => {
  const env = envNow(); const name = c.params.queue;
  if (!LOAN_QUEUES.map((x) => x + '.dlq').includes(name)) return send(c.res, 404, { code: 'NOT_FOUND', message: 'Unknown queue.' });
  const got = await mq(env, 'POST', `/queues/${vh(env)}/${encodeURIComponent(name)}/get`, { count: 100, ackmode: 'ack_requeue_true', encoding: 'auto' });
  const msgs = got.ok && Array.isArray(got.json) ? got.json : [];
  if (!msgs.length) return send(c.res, 200, { replayed: 0, left: 0, message: 'Nothing to replay.' });
  let replayed = 0;
  for (const m of msgs) {
    let p; try { p = JSON.parse(m.payload); } catch { continue; }
    const h = (m.properties && m.properties.headers) || {};
    const source = h['x-source-queue']; const consumer = h['x-consumer'];
    if (!source || !consumer || !p.messageId) continue;
    // 1. release the claim a failed attempt may have left behind, so the consumer does not skip the message as already handled
    await call(env, 'system', 'DELETE', `/processed-messages/${encodeURIComponent(consumer)}/${encodeURIComponent(p.messageId)}`);
    // 2. publish the same message again to the queue it came from
    const pub = await mq(env, 'POST', `/exchanges/${vh(env)}/loan.exchange/publish`, { properties: { delivery_mode: 2, content_type: 'application/json' }, routing_key: source, payload: m.payload, payload_encoding: 'string' });
    if (pub.ok && pub.json && pub.json.routed) replayed++;
  }
  // 3. empty the dead-letter queue only when every message went back
  if (replayed === msgs.length) await mq(env, 'DELETE', `/queues/${vh(env)}/${encodeURIComponent(name)}/contents`);
  logAction(c.user.id, state.env, null, 'REPLAY_DEAD_LETTERS', `${name}: ${replayed} of ${msgs.length}`);
  return send(c.res, 200, { replayed, left: msgs.length - replayed, message: replayed === msgs.length ? `Replayed ${replayed} message(s); the dead-letter queue is empty.` : 'Not every message could be replayed; the queue was left as it is.' });
});

add('POST', '/api/staff/env', 'staff', async (c) => {
  const b = await readJson(c.req);
  if (!environments[b.env]) return send(c.res, 400, { code: 'BAD_REQUEST', message: 'Unknown environment.' });
  state.env = b.env; productCache = { at: 0, data: null };
  logAction(c.user.id, state.env, null, 'SWITCH_ENV', state.env);
  return send(c.res, 200, { env: state.env });
});

const CHAOS = { mail: 'loan-mailhog', broker: 'loan-rabbitmq' };
add('POST', '/api/staff/chaos/:target/:action', 'staff', async (c) => {
  const env = envNow();
  if (!env.chaos) return send(c.res, 403, { code: 'LOCAL_ONLY', message: 'Stopping services is only available in the Local environment.' });
  const container = CHAOS[c.params.target]; const action = c.params.action;
  if (!container || !['stop', 'start'].includes(action)) return send(c.res, 400, { code: 'BAD_REQUEST', message: 'Unknown target or action.' });
  await new Promise((resolve) => execFile('docker', [action, container], { timeout: 60000 }, (err, out, errOut) => {
    logAction(c.user.id, state.env, null, `${action.toUpperCase()}_${c.params.target.toUpperCase()}`, err ? String(errOut || err.message).slice(0, 200) : 'ok');
    send(c.res, err ? 502 : 200, err ? { code: 'DOCKER_FAILED', message: 'Docker could not do that. Is Docker Desktop running?' } : { ok: true, container, action });
    resolve();
  }));
});

/* ------------------------------------------------------------------ static files and the dispatcher */
function serveStatic(req, res, pathname) {
  let rel = pathname === '/' ? '/index.html' : pathname;
  const file = path.normalize(path.join(CLIENT_DIR, rel));
  if (!file.startsWith(CLIENT_DIR)) return send(res, 404, { code: 'NOT_FOUND' });
  fs.readFile(file, (err, data) => {
    if (err) {
      // single-page app: unknown paths without an extension get the shell
      if (!path.extname(rel)) return fs.readFile(path.join(CLIENT_DIR, 'index.html'), (e2, d2) => (e2 ? send(res, 404, { code: 'NOT_FOUND' }) : (res.writeHead(200, { 'content-type': MIME['.html'], 'cache-control': 'no-cache', ...SECURITY }), res.end(d2))));
      return send(res, 404, { code: 'NOT_FOUND' });
    }
    res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-cache', ...SECURITY });
    res.end(data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const id = crypto.randomUUID();
  res.setHeader('x-request-id', id);
  try {
    if (!url.pathname.startsWith('/api/')) return serveStatic(req, res, url.pathname);
    const route = routes.map((r) => ({ r, m: r.re.exec(url.pathname) })).find((x) => x.m && x.r.method === req.method);
    if (!route) return send(res, routes.some((r) => r.re.test(url.pathname)) ? 405 : 404, { code: 'NOT_FOUND', message: 'No such endpoint.' });
    // state-changing calls must come from this site: custom header plus a matching Origin
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      const origin = req.headers.origin;
      if (req.headers['x-requested-with'] !== 'mf' || (origin && new URL(origin).host !== req.headers.host)) { req.resume(); return send(res, 403, { code: 'FORBIDDEN', message: 'Request not allowed.' }); }
    }
    const user = userFrom(req);
    const access = route.r.access;
    if (access) {
      if (!user) { req.resume(); return send(res, 401, { code: 'LOGIN_REQUIRED', message: 'Sign in to continue.' }); }
      if (access === 'customer' && user.role !== 'customer') { req.resume(); return send(res, 403, { code: 'FORBIDDEN', message: 'This is for customers.' }); }
      if (access === 'staff' && !isStaff(user)) { req.resume(); return send(res, 403, { code: 'FORBIDDEN', message: 'This is for staff.' }); }
    }
    const params = Object.fromEntries(route.r.keys.map((k, i) => [k, decodeURIComponent(route.m[i + 1])]));
    await route.r.handler({ req, res, url, params, user });
  } catch (e) {
    console.error(`[${id}] ${req.method} ${url.pathname} failed: ${e && e.message}`);
    if (!res.headersSent) send(res, e.status || 500, { code: e.status === 413 ? 'TOO_LARGE' : e.status === 400 ? 'BAD_REQUEST' : 'INTERNAL_ERROR', message: e.status === 400 ? 'The request could not be read.' : 'Something went wrong on our side.', requestId: id });
  }
});

const creds = seedStaff();
setInterval(() => q.purgeSessions.run(Date.now()), 3600000).unref();
server.listen(PORT, () => {
  console.log(`Marigold Finance site on http://localhost:${PORT}  (backend: ${state.env}; available: ${Object.keys(environments).join(', ')})`);
  if (creds) console.log(`First start: staff accounts written to ${creds}`);
});
