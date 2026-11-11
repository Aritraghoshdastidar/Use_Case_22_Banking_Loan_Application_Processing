// Staff console: live overview, applications with a detail drawer and real actions, underwriting queue, pipeline.
import { $, $$, esc, inr, when, age, api, stageChip, STAGE_COLOR, req, toast, startPolling, stopPolling, openDrawer, setDrawerBody, closeDrawer, drawerOpen } from './util.js';

const STAGES = ['RECEIVED', 'VERIFYING', 'VERIFIED', 'SCORING', 'DOCUMENTS_INCOMPLETE', 'APPROVED', 'REFERRED', 'DECLINED'];
const err = (r) => esc((r.data && r.data.message) || 'That did not work.');
const productName = (c) => (c === 'HL' ? 'Home loan' : 'Personal loan');

/* ---------------------------------------------------------------- overview */
export async function overviewView(ctx) {
  ctx.main.innerHTML = `<div class="in page"><div class="title-row"><div><h1>Operations overview</h1><p class="muted">Everything the system is doing right now, read live from the running apps.</p></div><div class="live small" id="stamp">Live</div></div><div id="ov"><div class="loading">Reading the system…</div></div></div>`;
  const draw = async () => {
    const r = await api('GET', '/api/staff/overview');
    if (!r.ok) { $('#ov').innerHTML = `<div class="alert bad">${err(r)}</div>`; return; }
    const o = r.data; const total = Object.values(o.stages).reduce((s, n) => s + n, 0) || 1;
    $('#stamp').textContent = 'Live · updated ' + new Date(o.at).toLocaleTimeString('en-IN');
    const q = o.queues;
    $('#ov').innerHTML = `
      <div class="group-title"><h2>Applications (Mule 4)</h2>${req('S12')}</div>
      <div class="tiles">${o.checks.map((c) => `<div class="tile"><div class="nm"><span>${esc(c.name)}</span><span class="state ${c.up ? 's-ok' : 's-bad'}">${c.up ? 'UP' : 'DOWN'}</span></div><div class="sub">${esc(c.layer)} · ${c.ms} ms</div></div>`).join('')}</div>
      <div class="group-title"><h2>Messaging and reliability</h2>${req('N22')}${req('N23')}</div>
      <div class="tiles">
        <div class="tile"><div class="nm"><span style="font-family:var(--sans);font-weight:600">Message broker</span><span class="state ${q.available ? 's-ok' : 's-idle'}">${q.available ? 'OK' : 'No access'}</span></div><div class="sub">${q.available ? q.queues.map((x) => `${x.name.replace('loan.', '').replace('.q', '')}: ${x.ready + x.unacked} waiting`).join('<br>') : 'Queue depths need broker access.'}</div></div>
        <div class="tile"><div class="nm"><span style="font-family:var(--sans);font-weight:600">Dead letters</span><span class="state ${q.available && q.queues.some((x) => x.dead) ? 's-bad' : 's-ok'}">${q.available ? q.queues.reduce((s, x) => s + x.dead, 0) : '?'}</span></div><div class="sub"><a href="#/staff/pipeline">Open the pipeline</a></div></div>
        <div class="tile"><div class="nm"><span style="font-family:var(--sans);font-weight:600">Outbox waiting</span><span class="state ${o.outboxPending ? 's-warn' : 's-ok'}">${o.outboxPending ?? '?'}</span></div><div class="sub">Messages written but not yet published</div></div>
        <div class="tile"><div class="nm"><span style="font-family:var(--sans);font-weight:600">Not yet notified</span><span class="state ${o.unnotified.length ? 's-warn' : 's-ok'}">${o.unnotified.length}</span></div><div class="sub">Decisions whose applicant has no email yet</div></div>
        <div class="tile"><div class="nm"><span style="font-family:var(--sans);font-weight:600">Credit bureau</span><span class="state ${o.bureauEnabled === false ? 's-bad' : 's-ok'}">${o.bureauEnabled === false ? 'OFF' : 'ON'}</span></div><div class="sub">${o.bureauEnabled === false ? 'New applications will be referred as DATA_UNAVAILABLE' : 'Scoring reads the test bureau'}</div></div>
      </div>
      <div class="two" style="margin-top:28px">
        <div class="panel"><div class="ph"><h3>Applications by stage</h3><span class="small muted">${o.total} in total</span></div><div class="pb">
          <div class="funnel" role="img" aria-label="Applications by stage">${STAGES.filter((s) => o.stages[s]).map((s) => `<i style="width:${(o.stages[s] / total) * 100}%;background:${STAGE_COLOR[s]}" title="${s}">${o.stages[s]}</i>`).join('')}</div>
          <div class="legend">${STAGES.filter((s) => o.stages[s]).map((s) => `<span style="--c:${STAGE_COLOR[s]}">${s.replace(/_/g, ' ').toLowerCase()} ${o.stages[s]}</span>`).join('')}</div></div></div>
        <div class="panel"><div class="ph"><h3>Latest applications</h3><a class="small" href="#/staff/applications">All applications</a></div>
          ${o.recent.length ? `<div class="tw"><table><tbody>${o.recent.map((a) => `<tr class="click" data-app="${esc(a.applicationId)}"><td class="mono">${esc(a.applicationId)}</td><td>${stageChip(a.stage, true)}</td><td class="r">${inr(a.requestedAmount)}</td></tr>`).join('')}</tbody></table></div>` : '<div class="empty">No applications yet.</div>'}</div>
      </div>
      <div class="panel" style="margin-top:24px"><div class="ph"><h3>What staff did</h3><span class="small muted">every action here is recorded</span></div>${o.actions.length ? `<ul class="feed">${o.actions.slice(0, 8).map((a) => `<li><span>${new Date(a.at).toLocaleTimeString('en-IN')}</span><span>${esc(a.who)} · ${esc(a.action.replace(/_/g, ' ').toLowerCase())}${a.application_id ? ' · ' + esc(a.application_id) : ''}<br><span class="c">${esc(a.detail || '')} (${esc(a.env)})</span></span></li>`).join('')}</ul>` : '<div class="empty">Nothing yet.</div>'}</div>`;
    $$('#ov tr[data-app]').forEach((tr) => tr.addEventListener('click', () => openApp(ctx, tr.dataset.app)));
  };
  await draw(); startPolling(draw, 4000);
}

/* ---------------------------------------------------------------- applications */
let filter = 'ALL';
export async function applicationsView(ctx) {
  ctx.main.innerHTML = `<div class="in page"><div class="title-row"><div><h1>Applications</h1><p class="muted">Select a row to see the scorecard, the documents, the audit trail, and to act on it.</p></div></div>
    <div class="pills" id="pills"></div><div class="panel"><div class="tw"><table><thead><tr><th>Reference</th><th>Applicant</th><th>Product</th><th class="r">Requested</th><th>Stage</th><th>Reason</th><th class="r">Age</th></tr></thead><tbody id="rows"><tr><td colspan="7" class="loading">Loading…</td></tr></tbody></table></div></div></div>`;
  const draw = async () => {
    const r = await api('GET', '/api/staff/applications' + (filter !== 'ALL' ? `?stage=${filter}` : ''));
    $('#pills').innerHTML = ['ALL', 'DOCUMENTS_INCOMPLETE', 'REFERRED', 'DECLINED', 'APPROVED'].map((s) => `<button aria-pressed="${s === filter}" data-f="${s}">${s === 'ALL' ? 'All stages' : s.replace(/_/g, ' ').toLowerCase()}</button>`).join('');
    $$('#pills button').forEach((b) => b.addEventListener('click', () => { filter = b.dataset.f; draw(); }));
    if (!r.ok) { $('#rows').innerHTML = `<tr><td colspan="7"><div class="alert bad">${err(r)}</div></td></tr>`; return; }
    $('#rows').innerHTML = r.data.length ? r.data.map((a) => `<tr class="click" tabindex="0" data-app="${esc(a.applicationId)}"><td class="mono">${esc(a.applicationId)}</td><td>${esc(a.owner || '—')}</td><td>${productName(a.productCode)}</td><td class="r">${inr(a.requestedAmount)}</td><td>${stageChip(a.stage, true)}</td><td class="small muted">${esc(a.stageReason || '')}</td><td class="r mono small">${age(a.ageMinutes)}</td></tr>`).join('') : '<tr><td colspan="7" class="empty">No applications in this stage.</td></tr>';
    $$('#rows tr[data-app]').forEach((tr) => { const go = () => openApp(ctx, tr.dataset.app); tr.addEventListener('click', go); tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); }); });
  };
  await draw(); startPolling(() => { if (!drawerOpen()) return draw(); }, 5000);
}

/* ---------------------------------------------------------------- application drawer */
let cur = null; let curTab = 'overview';
export async function openApp(ctx, id) {
  openDrawer('Application', id, '<div class="loading">Loading…</div>');
  curTab = 'overview';
  await loadApp(ctx, id);
}
async function loadApp(ctx, id) {
  const r = await api('GET', `/api/staff/applications/${encodeURIComponent(id)}`);
  if (!r.ok) { setDrawerBody(`<div class="alert bad">${err(r)}</div>`); return; }
  cur = { id, ...r.data }; paintApp(ctx);
}
function factorTable(d) {
  const f = (d.ruleHits || []).filter((h) => h.ruleType === 'FACTOR'); const hard = (d.ruleHits || []).filter((h) => h.ruleType === 'HARD_RULE');
  const sum = f.reduce((s, h) => s + (h.contribution || 0), 0);
  const label = { BUREAU_SCORE: 'Credit bureau score', DEBT_TO_INCOME: 'Debt-to-income', LOAN_TO_INCOME: 'Loan-to-income', EMPLOYMENT_STABILITY: 'Employment stability', REPAYMENT_HISTORY: 'Repayment history' };
  const hl = { 'HP-01': 'Age at maturity above the product maximum', 'HP-02': 'Active default on the applicant record', 'HP-03': 'Instalment above the ceiling, no valid reduction' };
  return `<div class="eyebrow">Scorecard ${esc(d.scorecardVersion || '')} ${req('FR13')}</div>${f.length ? `<div class="tw"><table><thead><tr><th>Factor</th><th class="r">Input</th><th class="r">Weight</th><th class="r">Points</th><th class="r">Contribution</th></tr></thead><tbody>${f.map((h) => `<tr><td>${esc(label[h.ruleCode] || h.ruleCode)}</td><td class="r mono">${h.inputValue}</td><td class="r mono">${h.weight}</td><td class="r mono">${Number(h.points).toFixed(1)}</td><td class="r mono">${Number(h.contribution).toFixed(2)}</td></tr>`).join('')}<tr class="sumrow"><td colspan="4">Score</td><td class="r mono">${sum.toFixed(2)}</td></tr></tbody></table></div>` : '<p class="muted small">No factors were scored for this application.</p>'}
    <div class="eyebrow" style="margin-top:22px">Hard rules ${req('AC12')}</div><div class="tw"><table><tbody>${hard.map((h) => `<tr><td class="mono">${esc(h.ruleCode)}</td><td>${esc(hl[h.ruleCode] || '')}</td><td>${h.triggered ? '<span class="state s-bad">Triggered</span>' : '<span class="state s-idle">Clear</span>'}</td></tr>`).join('')}</tbody></table></div>`;
}
function paintApp(ctx) {
  const a = cur.application; const d = a.decision; const tabs = [['overview', 'Overview'], ['score', 'Scorecard and rules'], ['docs', 'Documents'], ['audit', 'Audit trail'], ['act', 'Act']];
  const body = {
    overview: () => `<dl class="kv"><dt>Stage</dt><dd>${stageChip(a.stage, true)} <span class="small muted">${esc(a.stageReason || '')}</span></dd>
      <dt>Applicant</dt><dd>${esc(a.applicantName)}${cur.owner ? ` <span class="small muted">(account: ${esc(cur.owner.email)})</span>` : ''}</dd><dt>Email</dt><dd>${esc(a.email)}</dd>
      <dt>Identity reference</dt><dd class="mono">${esc(a.identityRef)}</dd><dt>Date of birth</dt><dd>${esc(a.dateOfBirth)}</dd>
      <dt>Product</dt><dd>${productName(a.productCode)} · ${inr(a.requestedAmount)} over ${a.requestedTenure} months</dd>
      <dt>Income / obligations</dt><dd>${inr(a.monthlyIncome)} / ${inr(a.monthlyObligations || 0)} a month · ${a.employmentMonths} months in job</dd>
      <dt>Verification round</dt><dd>${a.verificationRound}</dd><dt>Received</dt><dd>${when(a.createdAt)}</dd>
      ${d ? `<dt>Decision</dt><dd><b>${esc(d.decision)}</b> · score ${d.score ?? '—'} · ${esc((d.reasonCodes || []).join(', '))}</dd>${d.approvedAmount ? `<dt>Terms</dt><dd>${inr(d.approvedAmount)} over ${d.approvedTenure} months at ${d.approvedRatePct}% · instalment ${inr(d.instalment, 2)}</dd>` : ''}${d.reductionReason ? `<dt>Reduction</dt><dd>${esc(d.reductionReason)}</dd>` : ''}${d.affordabilityRatio != null ? `<dt>Affordability</dt><dd>${(d.affordabilityRatio * 100).toFixed(1)}% of net income</dd>` : ''}` : ''}</dl>`,
    score: () => (d ? factorTable(d) : '<div class="notice" style="margin-top:0">This application has no decision yet.</div>'),
    docs: () => `<div class="tw"><table><thead><tr><th>File</th><th>Type</th><th>Result</th><th class="r">Size</th><th>SHA-256</th></tr></thead><tbody>${(a.documents || []).map((x) => `<tr><td class="mono">${esc(x.fileName)}</td><td>${esc((x.docType || '').replace(/_/g, ' ').toLowerCase())}</td><td>${x.status === 'ACCEPTED' ? '<span class="state s-ok">Accepted</span>' : `<span class="state s-bad">${esc(x.status.toLowerCase())}</span>`} <span class="small muted">${esc(x.reason || '')}</span></td><td class="r small">${x.sizeBytes ?? ''}</td><td class="hash">${x.sha256 ? esc(x.sha256.slice(0, 12)) + '…' : ''}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">No documents recorded yet.</td></tr>'}</tbody></table></div>
      ${a.documents && a.documents.some((x) => x.storedPath) ? `<p class="small muted" style="margin-top:10px">Verified copies are kept under <span class="mono">${esc(a.documents.find((x) => x.storedPath).storedPath.replace(/[^/]*$/, ''))}</span>. Files are never changed in place. ${req('FR11')}</p>` : ''}`,
    audit: () => `<div class="eyebrow">Decision audit ${req('FR18')}${req('AC15')}</div><div class="tw"><table><thead><tr><th>Time</th><th>Event</th><th>Stage change</th><th>Source</th></tr></thead><tbody>${cur.audit.map((e) => `<tr><td class="mono small">${when(e.createdAt)}</td><td class="mono">${esc(e.event)}</td><td class="mono small muted">${e.fromStage ? esc(e.fromStage) + ' → ' : ''}${esc(e.toStage || '')}</td><td class="small">${esc(e.sourceApp.replace('loan-', ''))}</td></tr>`).join('')}</tbody></table></div>
      <p class="small muted" style="margin-top:8px">Correlation id <span class="mono">${esc(a.correlationId)}</span> on every row. The table is append-only.</p>`,
    act: () => actHtml(a),
  }[curTab]();
  setDrawerBody(`<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">${stageChip(a.stage, true)}<span class="muted">${esc(a.applicantName)} · ${productName(a.productCode)} · ${inr(a.requestedAmount)}</span></div>
    <div class="tabs" role="tablist">${tabs.map((t) => `<button role="tab" aria-selected="${t[0] === curTab}" data-t="${t[0]}">${t[1]}</button>`).join('')}</div>${body}`);
  $$('#dBody .tabs button').forEach((b) => b.addEventListener('click', () => { curTab = b.dataset.t; paintApp(ctx); }));
  wireActions(ctx, a);
}
function actHtml(a) {
  if (a.stage === 'DOCUMENTS_INCOMPLETE') {
    const n = cur.needed || {};
    const rows = (n.missing || []).map((m) => `<tr><td>${esc(m.docType.replace(/_/g, ' ').toLowerCase())}</td><td class="r">${m.required}</td><td class="r"><b>${m.found}</b></td></tr>`).join('');
    return `<div class="alert info"><b>Waiting for documents.</b> ${n.reason ? esc(n.reason.replace(/_/g, ' ').toLowerCase()) + '. ' : ''}The applicant has been emailed the list.</div>
      ${rows ? `<table style="margin-top:12px"><thead><tr><th>Type</th><th class="r">Required</th><th class="r">Found</th></tr></thead><tbody>${rows}</tbody></table>` : ''}
      ${(n.missingFiles || []).length ? `<p class="small muted" style="margin-top:8px">Expected files not found: ${n.missingFiles.map((f) => `<span class="mono">${esc(f.fileName)}</span>`).join(', ')}</p>` : ''}
      <h3 style="font-size:15px;margin-top:22px">Supply the file for the applicant, then resubmit</h3>
      <p class="small muted" style="margin-top:4px">Every file goes through the same ten upload checks. Resubmitting continues the same application; accepted files are not checked again.</p>
      <div class="drop" style="margin-top:12px"><label for="staffFile" style="cursor:pointer"><b>Choose file(s)</b></label><input id="staffFile" type="file" multiple accept=".pdf,.jpg,.jpeg,.png" style="position:absolute;left:-9999px"><div class="small" id="staffNames" style="margin-top:6px"></div></div>
      <div id="actAlert" style="margin-top:12px"></div>
      <div class="actions" style="margin-top:14px"><button class="btn" id="actUpload" type="button">Upload and resubmit</button><button class="btn ghost" id="actResubmit" type="button">Resubmit without a new file</button></div>`;
  }
  if (a.stage === 'REFERRED') return `<div class="alert info"><b>With an underwriter.</b> ${esc(((a.decision && a.decision.reasonCodes) || []).join(', '))}. The applicant was emailed that a person will decide within 3 working days. The daily digest lists this application.</div>
    <div class="actions" style="margin-top:16px"><button class="btn" id="actDigest" type="button">Send the underwriting digest now</button></div>
    <p class="small muted" style="margin-top:12px">Recording a manual decision is not part of this console yet: the loan system keeps one decision per application and has no review step to call.</p>`;
  return `<div class="alert ok">Nothing to resolve. The application is at <b>${esc(a.stage.replace(/_/g, ' ').toLowerCase())}</b> and the decision cannot be changed: one decision per application is enforced by the database.</div>`;
}
function wireActions(ctx, a) {
  const names = $('#staffNames'); let picked = [];
  const f = $('#staffFile'); if (f) f.addEventListener('change', (e) => { picked = Array.from(e.target.files); names.textContent = picked.map((x) => x.name).join(', '); });
  const done = async (msg) => { toast(msg); await loadApp(ctx, a.applicationId); };
  const resubmit = async () => { const r = await api('POST', `/api/staff/applications/${encodeURIComponent(a.applicationId)}/resubmit`); if (r.status === 202) await done('Resubmitted. Verification started again.'); else toast((r.data && r.data.message) || 'Resubmit failed.', true); };
  const up = $('#actUpload'); if (up) up.addEventListener('click', async () => {
    if (!picked.length) { $('#actAlert').innerHTML = '<div class="alert bad">Choose a file first.</div>'; return; }
    up.disabled = true; const fd = new FormData(); picked.forEach((x, i) => fd.append('f' + i, x, x.name));
    const r = await api('POST', `/api/staff/applications/${encodeURIComponent(a.applicationId)}/documents`, { form: fd }); up.disabled = false;
    if (r.status === 201) return resubmit();
    const files = r.data && r.data.details && r.data.details.files ? `<ul>${r.data.details.files.filter((x) => x.message).map((x) => `<li><span class="mono">${esc(x.file)}</span>: ${esc(x.message)}</li>`).join('')}</ul>` : '';
    $('#actAlert').innerHTML = `<div class="alert bad"><b>Nothing was stored.</b> ${r.status === 422 ? 'Fix the files below and try again.' : err(r)}${files}</div>`;
  });
  const rs = $('#actResubmit'); if (rs) rs.addEventListener('click', resubmit);
  const dg = $('#actDigest'); if (dg) dg.addEventListener('click', async () => { const r = await api('POST', '/api/staff/digest'); toast(r.ok ? 'Digest sent to the underwriting team.' : (r.data && r.data.message) || 'Digest failed.', !r.ok); });
}

/* ---------------------------------------------------------------- underwriting */
export async function underwritingView(ctx) {
  ctx.main.innerHTML = `<div class="in page"><div class="title-row"><div><h1>Underwriting queue ${req('FR20')}</h1><p class="muted">Applications that need a person, oldest first, and applications waiting for documents.</p></div><button class="btn" id="digest">Send digest now</button></div>
    <div class="panel"><div class="ph"><h3>Referred</h3><span class="small muted">emailed to underwriting daily at 09:00</span></div><div class="tw"><table><thead><tr><th>Reference</th><th>Applicant</th><th>Product</th><th class="r">Amount</th><th class="r">Waiting</th><th>Why</th></tr></thead><tbody id="ref"><tr><td colspan="6" class="loading">Loading…</td></tr></tbody></table></div></div>
    <div class="panel" style="margin-top:24px"><div class="ph"><h3>Waiting for documents</h3><span class="small muted">open one to supply the file and resubmit</span></div><div class="tw"><table><thead><tr><th>Reference</th><th>Applicant</th><th>Product</th><th class="r">Amount</th><th class="r">Waiting</th><th>Reason</th></tr></thead><tbody id="inc"></tbody></table></div></div></div>`;
  $('#digest').addEventListener('click', async () => { const r = await api('POST', '/api/staff/digest'); toast(r.ok ? 'Digest sent to the underwriting team.' : (r.data && r.data.message) || 'Digest failed.', !r.ok); });
  const rows = (list, why) => list.length ? list.map((a) => `<tr class="click" tabindex="0" data-app="${esc(a.applicationId)}"><td class="mono">${esc(a.applicationId)}</td><td>${esc(a.owner || '—')}</td><td>${productName(a.productCode)}</td><td class="r">${inr(a.requestedAmount)}</td><td class="r mono small">${age(a.ageMinutes)}</td><td class="small muted">${esc(why(a))}</td></tr>`).join('') : '<tr><td colspan="6" class="empty">Nothing waiting.</td></tr>';
  const draw = async () => {
    const [a, b] = await Promise.all([api('GET', '/api/staff/applications?stage=REFERRED'), api('GET', '/api/staff/applications?stage=DOCUMENTS_INCOMPLETE')]);
    const sort = (l) => (Array.isArray(l) ? [...l].sort((x, y) => y.ageMinutes - x.ageMinutes) : []);
    $('#ref').innerHTML = rows(sort(a.data), (x) => x.stageReason === 'DATA_UNAVAILABLE' ? 'Credit data unavailable' : 'Score in the review band');
    $('#inc').innerHTML = rows(sort(b.data), (x) => (x.stageReason || '').replace(/_/g, ' ').toLowerCase());
    $$('#ref tr[data-app], #inc tr[data-app]').forEach((tr) => { const go = () => openApp(ctx, tr.dataset.app); tr.addEventListener('click', go); tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); }); });
  };
  await draw(); startPolling(() => { if (!drawerOpen()) return draw(); }, 6000);
}

/* ---------------------------------------------------------------- pipeline */
export async function pipelineView(ctx) {
  const env = ctx.config.environments.find((e) => e.id === ctx.config.env) || {};
  ctx.main.innerHTML = `<div class="in page"><div class="title-row"><div><h1>Pipeline ${req('FR12')}</h1><p class="muted">Messages between the applications, what is waiting, and what to do when something is stuck.</p></div></div>
    <div class="two"><div class="panel"><div class="ph"><h3>Queues</h3><span class="small muted">loan.exchange</span></div><div class="tw"><table><thead><tr><th>Queue</th><th class="r">Ready</th><th class="r">In flight</th><th class="r">Consumers</th><th>Dead letters</th></tr></thead><tbody id="qrows"><tr><td colspan="5" class="loading">Loading…</td></tr></tbody></table></div></div>
    <div class="panel"><div class="ph"><h3>Controls</h3></div><div class="pb" id="controls"></div></div></div>
    <div class="panel" style="margin-top:24px" id="dlqPanel" hidden><div class="ph"><h3 id="dlqTitle">Dead letters</h3><div class="actions"><button class="btn sm" id="dlqReplay" type="button">Replay all</button><button class="btn ghost sm" id="dlqClose" type="button">Close</button></div></div><div class="tw"><table><thead><tr><th>Application</th><th>Message</th><th>Failed with</th><th>Attempts</th><th>Back to</th></tr></thead><tbody id="dlqRows"></tbody></table></div></div>
    <div class="panel" style="margin-top:24px"><div class="ph"><h3>Decisions not yet notified ${req('AC14')}</h3><span class="small muted">retried automatically; after five failures it is marked failed and staff can retry it</span></div><div class="tw"><table><thead><tr><th>Application</th><th>Outcome</th><th>Status</th><th class="r">Attempts</th><th class="r">Waiting</th><th>Last problem</th><th></th></tr></thead><tbody id="unn"></tbody></table></div></div></div>`;
  let openDlq = null;
  const draw = async () => {
    const r = await api('GET', '/api/staff/overview');
    if (!r.ok) return;
    const o = r.data;
    $('#qrows').innerHTML = o.queues.available ? o.queues.queues.map((x) => `<tr><td class="mono">${esc(x.name)}</td><td class="r mono">${x.ready}</td><td class="r mono">${x.unacked}</td><td class="r mono">${x.consumers}</td><td style="white-space:nowrap"><span class="mono small">${esc(x.dlq)}</span> · <b class="${x.dead ? '' : 'muted'}">${x.dead}</b> ${x.dead ? `<button class="linkbtn" data-look="${esc(x.dlq)}">Look</button>` : ''}</td></tr>`).join('') : '<tr><td colspan="5" class="empty">Queue depths are not available: this deployment has no broker access.</td></tr>';
    $$('#qrows [data-look]').forEach((b) => b.addEventListener('click', () => look(b.dataset.look)));
    $('#unn').innerHTML = o.unnotified.length ? o.unnotified.map((n) => `<tr><td class="mono">${esc(n.applicationId)}</td><td>${esc((n.template || '').replace(/_/g, ' ').toLowerCase())}</td><td><span class="state ${n.status === 'FAILED' ? 's-bad' : 's-warn'}">${esc(n.status)}</span></td><td class="r mono">${esc(n.attempts ?? '')}</td><td class="r mono small">${age(Math.round((n.ageSeconds || 0) / 60))}</td><td class="small muted">${esc(n.lastError || '')}</td><td class="r">${n.status === 'FAILED' ? `<button class="btn ghost sm" data-retry="${esc(n.id)}" type="button">Retry the email</button>` : ''}</td></tr>`).join('') : '<tr><td colspan="7" class="empty">Everyone with a decision has been told.</td></tr>';
    $$('#unn [data-retry]').forEach((b) => b.addEventListener('click', async () => { b.disabled = true; const r2 = await api('POST', `/api/staff/notifications/${b.dataset.retry}/retry`); toast(r2.ok ? 'Queued. The notification app sends it again within a minute; the decision is not touched.' : (r2.data && r2.data.message) || 'Could not retry.', !r2.ok); draw(); }));
    const chaos = env.chaos ? `<div class="actions" style="margin-top:8px"><button class="btn warn sm" data-chaos="mail/stop">Stop mail server</button><button class="btn ghost sm" data-chaos="mail/start">Start mail server</button><button class="btn warn sm" data-chaos="broker/stop">Stop broker</button><button class="btn ghost sm" data-chaos="broker/start">Start broker</button></div><p class="small muted" style="margin-top:8px">Local only. Stopping the mail server proves that decisions are kept and only the email is retried.${req('N23')} Stopping the broker proves that accepted applications wait in the outbox.${req('N22')}</p>` : '<p class="small muted" style="margin-top:12px">Stopping services is only available in the Local environment.</p>';
    $('#controls').innerHTML = `<dl class="kv"><dt>Outbox rows waiting</dt><dd class="mono">${o.outboxPending ?? '?'}</dd><dt>Credit bureau</dt><dd>${o.bureauEnabled === false ? '<span class="state s-bad">OFF</span>' : '<span class="state s-ok">ON</span>'} <button class="btn ghost sm" id="bureau" type="button">Turn ${o.bureauEnabled === false ? 'on' : 'off'}</button></dd><dt>Retry pattern${req('FR21')}</dt><dd>2 s, 4 s, 8 s, then dead letter with the reason</dd></dl>
      <p class="small muted" style="margin-top:12px">With the bureau off, new applications are referred with DATA_UNAVAILABLE and never approved.${req('N17')}</p>${chaos}`;
    $('#bureau').addEventListener('click', async () => { const r2 = await api('PUT', '/api/staff/bureau', { json: { enabled: o.bureauEnabled === false } }); toast(r2.ok ? 'Credit bureau switched ' + (o.bureauEnabled === false ? 'on' : 'off') + '.' : (r2.data && r2.data.message) || 'Failed.', !r2.ok); draw(); });
    $$('#controls [data-chaos]').forEach((b) => b.addEventListener('click', async () => { b.disabled = true; const r2 = await api('POST', `/api/staff/chaos/${b.dataset.chaos}`); toast(r2.ok ? 'Done: ' + b.dataset.chaos.replace('/', ' ') : (r2.data && r2.data.message) || 'Failed.', !r2.ok); b.disabled = false; draw(); }));
    if (openDlq) look(openDlq, true);
  };
  async function look(q, quiet) {
    openDlq = q; const r = await api('GET', `/api/staff/dlq/${q}`);
    $('#dlqPanel').hidden = false; $('#dlqTitle').textContent = q;
    $('#dlqRows').innerHTML = r.ok && r.data.messages.length ? r.data.messages.map((m) => `<tr><td class="mono">${esc(m.applicationId || '—')}</td><td>${esc(m.type || '')}</td><td class="small">${esc(m.reason || '')}</td><td class="r mono">${esc(m.attempts ?? '')}</td><td class="mono small">${esc(m.source || '')}</td></tr>`).join('') : '<tr><td colspan="5" class="empty">Empty.</td></tr>';
    if (!quiet) $('#dlqPanel').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }
  $('#dlqClose').addEventListener('click', () => { openDlq = null; $('#dlqPanel').hidden = true; });
  $('#dlqReplay').addEventListener('click', async () => { if (!openDlq) return; const r = await api('POST', `/api/staff/dlq/${openDlq}/replay`); toast((r.data && r.data.message) || 'Done.', !r.ok); draw(); });
  await draw(); startPolling(draw, 4000);
}
