// Shell: header, routing, sessions, environment switch, and proof mode (requirement chips backed by the real exchanges this page made).
import { $, $$, esc, api, flower, waves, paintTextures, toast, openDrawer, closeDrawer, stopPolling, exchanges, when } from './util.js';
import * as customer from './customer.js';
import * as staff from './staff.js';

const ctx = { main: $('#main'), user: null, config: null, refreshUser, route: '/' };

async function loadConfig() { const r = await api('GET', '/api/config'); if (r.ok) { ctx.config = r.data; ctx.user = r.data.user; } return r.ok; }
async function refreshUser() { await loadConfig(); drawHeader(); }

/* ---------- header ---------- */
flower($('#mark')); waves($('#stripSvg'), 1200, 14, 7, 4.2, 70, '#6FB5A5', .7);
const CUSTOMER_NAV = [['/', 'Loans'], ['/apply', 'Apply'], ['/loans', 'My loans']];
const STAFF_NAV = [['/staff', 'Overview'], ['/staff/applications', 'Applications'], ['/staff/underwriting', 'Underwriting'], ['/staff/pipeline', 'Pipeline']];
const isStaff = (u) => !!u && (u.role === 'underwriter' || u.role === 'ops');

function drawHeader() {
  const u = ctx.user; const staffMode = isStaff(u); const nav = staffMode ? STAFF_NAV : CUSTOMER_NAV;
  $('#nav').innerHTML = nav.map(([p, t]) => `<a href="#${p}"${ctx.route === p || (p !== '/' && p !== '/staff' && ctx.route.startsWith(p + '/')) ? ' aria-current="page"' : ''}>${t}</a>`).join('');
  $('#who').innerHTML = u ? `<span class="avatar">${esc(u.name.split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase())}</span><span>${esc(u.name)}${staffMode ? ' · ' + esc(u.role) : ''}</span><button class="linkbtn" id="logout" type="button">Sign out</button>` : '<a href="#/login">Sign in</a><a class="btn sm" href="#/register">Create account</a>';
  const lo = $('#logout'); if (lo) lo.addEventListener('click', async () => { await api('POST', '/api/auth/logout'); ctx.user = null; stopPolling(); location.hash = '#/'; await refreshUser(); route(); });
  $('#areaLabel').textContent = staffMode ? 'Operations console' : 'Personal and home loans';
  $('#subbar').hidden = !staffMode;
  if (staffMode && ctx.config) {
    $('#envSeg').innerHTML = ctx.config.environments.map((e) => `<button aria-pressed="${e.id === ctx.config.env}" data-env="${e.id}">${esc(e.label)}</button>`).join('');
    const cur = ctx.config.environments.find((e) => e.id === ctx.config.env); $('#envNote').textContent = cur ? cur.note : '';
    $$('#envSeg button').forEach((b) => b.addEventListener('click', async () => { if (b.dataset.env === ctx.config.env) return; const r = await api('POST', '/api/staff/env', { json: { env: b.dataset.env } }); if (r.ok) { toast(`Now using the ${b.textContent} environment.`); await refreshUser(); route(); } else toast((r.data && r.data.message) || 'Could not switch.', true); }));
  }
  const env = ctx.config && ctx.config.environments.find((e) => e.id === ctx.config.env);
  $('#footEnv').textContent = env ? `backend: ${env.label}` : '';
}

/* ---------- proof mode ---------- */
const REQS = {
  FR3: ['Idempotent submission', 'The client request id is an idempotency key. A retried submission returns the original application and creates no second one. Here the id is built from your account and the draft, so pressing Submit twice is safe.', ['Intake MUnit suite (51 tests)', 'smoke-intake.ps1', 'web smoke: "submitting the same draft again returns the same reference"']],
  FR4: ['Fast acknowledgement', 'The intake API answers 202 with an application reference without reading a document or scoring. Look at the timing of POST /api/applications below.', ['Intake MUnit suite', 'smoke-intake.ps1']],
  FR7: ['Document validation', 'Each document is checked for extension, real content type, size, non-zero length, a readable first block and completeness, and its SHA-256 is computed during verification. The upload gate refuses the whole set if any file fails.', ['Document MUnit suite (118 tests)', 'smoke-upload.ps1', 'smoke-document.ps1']],
  FR10: ['Incomplete as an outcome', 'Missing or invalid documents are a business outcome: DOCUMENTS_INCOMPLETE, the exact list, an email, and resubmission on the same application.', ['smoke-email.ps1', 'smoke-resilience.ps1', 'cloud-e2e.py missing-payslip']],
  FR11: ['Document custody', 'Verified documents are copied to a per-application folder, never modified in place, with source path, stored path and SHA-256 recorded.', ['Document MUnit suite', 'smoke-document.ps1']],
  FR12: ['Asynchronous scoring', 'Scoring runs in a queue consumer, never in the API flow, so a slow bureau call cannot slow the submission.', ['Scoring MUnit suite (59 tests)', 'cloud-e2e.py complete-ok']],
  FR13: ['Explainable scorecard', 'Every factor is saved with its value, weight and contribution; the contributions add up to the score under a recorded scorecard version. Open an application in the staff console to see them.', ['Scoring MUnit suite', 'smoke-scoring.ps1']],
  FR14: ['Affordability check', 'The indicative instalment is computed at the product rate and compared with income after obligations; the ratio is stored with the decision.', ['Scoring MUnit suite', 'smoke-scoring.ps1']],
  FR16: ['Approved terms and offer validity', 'An approval records amount, tenure, rate and instalment (the amount can be lower than requested) and states that the offer is valid for 30 days.', ['Scoring MUnit suite', 'smoke-scoring.ps1']],
  FR18: ['Decision audit', 'An immutable record of inputs, rules, scorecard version, decision, reason codes and timestamps. The audit table is append-only (a database trigger rejects changes).', ['Database trigger in schema.sql', 'smoke-email.ps1']],
  FR19: ['Applicant notification', 'A distinct email for each outcome. A decline gives plain reasons and the right to a review, with no internal scores or rule ids.', ['Notification MUnit suite (85 tests)', 'smoke-email.ps1 (81 checks)']],
  FR20: ['Underwriting digest', 'Referred applications awaiting a decision are emailed to underwriting with their age and amount, daily at 09:00 and on demand.', ['Notification MUnit suite', 'smoke-email.ps1']],
  FR21: ['Retry, dead letter, privacy', 'Bounded retry (2, 4, 8 seconds), dead-lettering with the failure reason, and no personal data in logs.', ['All consumer MUnit suites', 'smoke-notification.ps1']],
  AC12: ['Hard rule overrides a high score', 'An applicant with a strong score but an active default is declined, and the hard rule is the deciding factor.', ['Scoring MUnit suite', 'smoke-scoring.ps1']],
  AC14: ['SMTP stopped', 'With the mail server stopped, decisions are recorded, unnotified applications are listed and an alert is logged; the email arrives once the server is back.', ['smoke-email.ps1']],
  AC15: ['Audit path RECEIVED to NOTIFIED', 'The decision audit reconstructs the whole path with timestamps and a correlation id. The progress list is built from it.', ['smoke-email.ps1', 'cloud-e2e.py complete-ok']],
  N9: ['Oversized document', 'A file above the per-type limit is refused as FILE_TOO_LARGE, judged from its size and never read in full.', ['Document MUnit suite', 'smoke-document.ps1']],
  N10: ['Unsupported type, including a renamed file', 'A file whose real content is not an allowed type is refused even when its extension is allowed. Try "Add a text file named like a PDF" on the documents step.', ['Document MUnit suite', 'smoke-upload.ps1']],
  N11: ['Zero length or cut-off document', 'An empty or incomplete file is refused rather than passed on as if valid. Try "Add an empty file".', ['Document MUnit suite', 'smoke-upload.ps1']],
  N17: ['Bureau unavailable', 'A failure to read the bureau gives REFERRED with DATA_UNAVAILABLE and never an automatic approval. Switch the bureau off on the Pipeline page and apply.', ['Scoring MUnit suite', 'smoke-scoring.ps1']],
  N18: ['Affordability breach', 'An instalment above the product ceiling is never approved as requested: it is reduced to the largest amount that fits, or declined by HP-03.', ['Scoring MUnit suite', 'smoke-scoring.ps1']],
  N22: ['Broker unavailable', 'The application is not lost: its message waits in the outbox and is published once when the broker returns.', ['smoke-resilience.ps1']],
  N23: ['SMTP unavailable', 'The decision and its audit are kept; only the notification is retried; the application is never rescored.', ['smoke-email.ps1']],
  S12: ['Alerts, logging, monitoring', 'Health on every app, structured logs with correlation ids and masked data, and in-app alerts for unnotified applicants.', ['smoke scripts (log scans)', 'Runtime Manager alert: deployment failed']],
};
function openReq(id) {
  const q = REQS[id];
  const log = exchanges.slice(0, 8).map((x) => `<tr><td class="mono small">${new Date(x.at).toLocaleTimeString('en-IN')}</td><td class="mono small">${x.method} ${esc(x.url.replace(/\?.*$/, ''))}${x.count > 1 ? ` ×${x.count}` : ''}</td><td class="mono small">${x.status}</td><td class="mono small">${x.upstream ?? ''}</td><td class="mono small">${x.ms} ms</td><td class="hash">${x.corr ? esc(x.corr.slice(0, 8)) : ''}</td></tr>`).join('');
  openDrawer(`Requirement ${id}`, q ? q[0] : id, `${q ? `<p>${esc(q[1])}</p><h3 style="font-size:13px;letter-spacing:.07em;text-transform:uppercase;color:var(--ink-3);font-weight:500;margin:20px 0 6px">Guaranteed by</h3><ul style="margin:0;padding-left:18px">${q[2].map((b) => `<li>${esc(b)}</li>`).join('')}</ul>` : '<p class="muted">No description yet.</p>'}
    <h3 style="font-size:13px;letter-spacing:.07em;text-transform:uppercase;color:var(--ink-3);font-weight:500;margin:22px 0 6px">What this page really exchanged</h3>
    ${log ? `<div class="tw"><table><thead><tr><th>Time</th><th>Call</th><th>Site</th><th>System</th><th>Time</th><th>Corr.</th></tr></thead><tbody>${log}</tbody></table></div><p class="small muted" style="margin-top:8px">"Site" is the answer to your browser; "System" is the status the loan system itself returned; "Corr." is the start of its correlation id, found on the audit rows and in the logs.</p>` : '<p class="muted small">Nothing exchanged yet. Use the page, then open this again.</p>'}`);
}
$('#proofSwitch').addEventListener('click', () => {
  const sw = $('#proofSwitch'); const on = sw.getAttribute('aria-checked') !== 'true'; sw.setAttribute('aria-checked', on); document.body.classList.toggle('proof', on);
  try { sessionStorage.setItem('mf-proof', on ? '1' : '0'); } catch { /* ignore */ }
  if (on) toast('Proof mode on. Gold chips link each part of the screen to the requirement it proves.');
});
try { if (sessionStorage.getItem('mf-proof') === '1') { $('#proofSwitch').setAttribute('aria-checked', 'true'); document.body.classList.add('proof'); } } catch { /* ignore */ }
document.addEventListener('click', (e) => { const r = e.target.closest('[data-req]'); if (r) { e.preventDefault(); openReq(r.dataset.req); } });
document.addEventListener('keydown', (e) => {
  if ((e.key === 'Enter' || e.key === ' ') && e.target.matches && e.target.matches('[data-req]')) { e.preventDefault(); openReq(e.target.dataset.req); }
  if (e.key === 'Escape') closeDrawer();
});
$('#dClose').addEventListener('click', closeDrawer); $('#scrim').addEventListener('click', closeDrawer);

/* ---------- routing ---------- */
const routes = [
  [/^\/$/, 'public', () => customer.landing(ctx)],
  [/^\/login$/, 'public', () => customer.authView(ctx, 'login')],
  [/^\/register$/, 'public', () => customer.authView(ctx, 'register')],
  [/^\/apply$/, 'customer', () => customer.applyView(ctx)],
  [/^\/loans$/, 'customer', () => customer.loansView(ctx)],
  [/^\/loans\/([^/]+)$/, 'customer', (m) => customer.trackerView(ctx, decodeURIComponent(m[1]))],
  [/^\/staff$/, 'staff', () => staff.overviewView(ctx)],
  [/^\/staff\/applications$/, 'staff', () => staff.applicationsView(ctx)],
  [/^\/staff\/underwriting$/, 'staff', () => staff.underwritingView(ctx)],
  [/^\/staff\/pipeline$/, 'staff', () => staff.pipelineView(ctx)],
];
let routeSeq = 0;
async function route() {
  const seq = ++routeSeq; stopPolling(); closeDrawer();
  const path = (location.hash.slice(1).split('?')[0]) || '/'; ctx.route = path;
  if (!ctx.config) await loadConfig();
  drawHeader();
  let hit = null; for (const [re, access, fn] of routes) { const m = re.exec(path); if (m) { hit = { access, fn, m }; break; } }
  if (!hit) { ctx.main.innerHTML = '<div class="in page"><h1>Page not found</h1><p class="muted" style="margin-top:8px"><a href="#/">Back to the start</a></p></div>'; return; }
  if (hit.access === 'customer' && !ctx.user) { location.hash = '#/login?next=' + encodeURIComponent('#' + path); return; }
  if (hit.access === 'customer' && isStaff(ctx.user)) { location.hash = '#/staff'; return; }
  if (hit.access === 'staff' && !isStaff(ctx.user)) { location.hash = ctx.user ? '#/loans' : '#/login?next=' + encodeURIComponent('#' + path); return; }
  ctx.main.innerHTML = '<div class="loading">Loading…</div>';
  try { await hit.fn(hit.m); } catch (e) { if (seq === routeSeq) ctx.main.innerHTML = `<div class="in page"><div class="alert bad">Something went wrong showing this page. <a href="#/">Back to the start</a>.</div></div>`; console.error(e); }
  if (seq === routeSeq) { window.scrollTo(0, 0); paintTextures(ctx.main); drawHeader(); }
}
window.addEventListener('hashchange', route);
window.addEventListener('mf:login-required', async () => { if (ctx.user) { ctx.user = null; toast('Your session ended. Sign in again.'); await refreshUser(); location.hash = '#/login'; } });
route();
