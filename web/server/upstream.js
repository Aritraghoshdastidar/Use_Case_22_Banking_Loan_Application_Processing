// Calls to the Mule apps, the message broker and the mail catcher. Credentials are added here, never in the browser.
import { Readable } from 'node:stream';

const MAX_PREVIEW = 4000;

function parse(text) {
  if (!text) return null;
  try { return JSON.parse(text); } catch { return null; }
}

function result(res, text, started) {
  const json = parse(text);
  return {
    status: res.status,
    ok: res.ok,
    json,
    text: json === null ? text.slice(0, MAX_PREVIEW) : '',
    correlationId: res.headers.get('x-correlation-id') || (json && json.correlationId) || null,
    ms: Date.now() - started,
  };
}

function down(error, started) {
  return { status: 503, ok: false, json: { code: 'UPSTREAM_UNAVAILABLE', message: 'The service did not answer.' }, text: '', correlationId: null, ms: Date.now() - started, error: String(error && error.message || error) };
}

/** JSON call to one of the five Mule apps. */
export async function call(env, service, method, path, { json, query, timeoutMs = 25000 } = {}) {
  const base = env.urls[service];
  const started = Date.now();
  if (!base) return down(new Error(`no address for ${service}`), started);
  const url = base + path + (query ? '?' + new URLSearchParams(query) : '');
  const headers = { accept: 'application/json', ...(env.headers[service] || {}) };
  let body;
  if (json !== undefined) { body = JSON.stringify(json); headers['content-type'] = 'application/json'; }
  try {
    const res = await fetch(url, { method, headers, body, signal: AbortSignal.timeout(timeoutMs) });
    return result(res, await res.text(), started);
  } catch (e) { return down(e, started); }
}

/** Streams a multipart upload from the browser straight to the document app (nothing is parsed or kept here). */
export async function proxyUpload(env, path, req, { timeoutMs = 60000 } = {}) {
  const base = env.urls.document;
  const started = Date.now();
  if (!base) return down(new Error('no address for document'), started);
  const headers = { accept: 'application/json', ...(env.headers.document || {}) };
  for (const h of ['content-type', 'content-length']) if (req.headers[h]) headers[h] = req.headers[h];
  try {
    const res = await fetch(base + path, { method: 'POST', headers, body: Readable.toWeb(req), duplex: 'half', signal: AbortSignal.timeout(timeoutMs) });
    return result(res, await res.text(), started);
  } catch (e) { return down(e, started); }
}

/** RabbitMQ management API (queue depths, dead letters, replay). */
export async function mq(env, method, path, json, timeoutMs = 15000) {
  const started = Date.now();
  if (!env.mq) return down(new Error('no broker settings'), started);
  const headers = { accept: 'application/json', authorization: 'Basic ' + Buffer.from(`${env.mq.user}:${env.mq.pass}`).toString('base64') };
  let body;
  if (json !== undefined) { body = JSON.stringify(json); headers['content-type'] = 'application/json'; }
  try {
    const res = await fetch(env.mq.base + path, { method, headers, body, signal: AbortSignal.timeout(timeoutMs) });
    return result(res, await res.text(), started);
  } catch (e) { return down(e, started); }
}

/** Quoted-printable decoding for the mail catcher's raw bodies. */
function qp(s) {
  return s.replace(/=\r?\n/g, '').replace(/=([0-9A-F]{2})/gi, (_, h) => String.fromCharCode(parseInt(h, 16)));
}

/** Emails the mail catcher holds for one address (local environment only). */
export async function mailFor(env, email) {
  if (!env.mail) return { available: false, messages: [] };
  const started = Date.now();
  try {
    const url = `${env.mail}/search?kind=to&query=${encodeURIComponent(email)}&limit=20`;
    const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
    const j = parse(await res.text());
    const items = (j && j.items) || [];
    return {
      available: true,
      ms: Date.now() - started,
      messages: items.map((m) => {
        const h = m.Content.Headers || {};
        const raw = m.Content.Body || '';
        const enc = (h['Content-Transfer-Encoding'] || [''])[0].toLowerCase();
        let subject = (h.Subject || [''])[0];
        subject = subject.replace(/=\?utf-8\?([qb])\?(.*?)\?=/gi, (_, kind, t) => (kind.toLowerCase() === 'b' ? Buffer.from(t, 'base64').toString('utf8') : qp(t.replace(/_/g, ' '))));
        const body = enc.includes('base64') ? Buffer.from(raw.replace(/\s+/g, ''), 'base64').toString('utf8') : enc.includes('quoted') ? qp(raw) : raw;
        return { id: m.ID, subject, date: m.Created, text: body.replace(/<[^>]+>/g, '').trim().slice(0, 2500) };
      }),
    };
  } catch (e) { return { available: false, messages: [], error: String(e.message || e) }; }
}
