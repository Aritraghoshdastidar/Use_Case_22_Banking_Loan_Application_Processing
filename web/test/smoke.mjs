// End-to-end check of the website's server against a running backend (Local or CloudHub).
//   node test/smoke.mjs                       uses http://localhost:3000
//   BASE=http://localhost:3100 STAFF_FILE=path\to\initial-credentials.txt node test/smoke.mjs
// It creates real customers and real applications in the selected environment.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const BASE = process.env.BASE || 'http://localhost:3000';
const STAFF_FILE = process.env.STAFF_FILE || path.join(process.cwd(), 'data', 'initial-credentials.txt');
let pass = 0, fail = 0;
const check = (name, ok, detail = '') => { if (ok) { pass++; console.log('[PASS] ' + name); } else { fail++; console.log('[FAIL] ' + name + (detail ? ' (' + detail + ')' : '')); } };

class Client {
  constructor() { this.cookie = ''; }
  async req(method, url, { json, form, headers = {} } = {}) {
    const h = { 'x-requested-with': 'mf', ...headers };
    if (this.cookie) h.cookie = this.cookie;
    let body;
    if (json !== undefined) { body = JSON.stringify(json); h['content-type'] = 'application/json'; }
    if (form) body = form;
    const res = await fetch(BASE + url, { method, headers: h, body });
    const set = res.headers.get('set-cookie');
    if (set) this.cookie = set.split(';')[0].endsWith('=') ? '' : set.split(';')[0];
    const text = await res.text();
    let j = null; try { j = JSON.parse(text); } catch { /* not json */ }
    return { status: res.status, json: j, headers: res.headers };
  }
}

const pdf = (label, extra = '') => `%PDF-1.4\n1 0 obj<< /Title (${label}) >>endobj\n% ${extra}${'-'.repeat(120)}\ntrailer<<>>\n%%EOF\n`;
const file = (name, content, type = 'application/pdf') => ({ name, blob: new Blob([content], { type }) });
function form(files) { const f = new FormData(); files.forEach((x, i) => f.append('f' + i, x.blob, x.name)); return f; }
const goodSet = (tag) => [file('id_proof.pdf', pdf('id ' + tag)), file('address_proof.pdf', pdf('address ' + tag)), file('payslip_1.pdf', pdf('slip1 ' + tag)), file('payslip_2.pdf', pdf('slip2 ' + tag))];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const draftId = () => Math.random().toString(36).slice(2, 12).padEnd(8, 'x');

async function waitStage(c, id, stages, seconds = 150) {
  let v;
  for (let i = 0; i < seconds / 3; i++) {
    v = (await c.req('GET', '/api/applications/' + id)).json;
    if (v && stages.includes(v.stage)) return v;
    await sleep(3000);
  }
  return v;
}

const run = Date.now().toString(36);
const alice = new Client(); const bob = new Client(); const staff = new Client(); const anon = new Client();

console.log('--- 1. accounts and access');
let r = await anon.req('GET', '/api/config');
check('config answers and lists the environments', r.status === 200 && r.json.environments.length >= 1, r.status);
console.log('    backend: ' + r.json.env);
check('products need no login and come from the system', (await anon.req('GET', '/api/products')).json?.length === 2);
r = await anon.req('GET', '/api/applications');
check('applications need a login (401)', r.status === 401);
r = await anon.req('POST', '/api/auth/login', { json: { email: 'x@y.z', password: 'nope-nope' }, headers: { 'x-requested-with': 'other' } });
check('a state-changing call without the site header is refused (403)', r.status === 403);
r = await alice.req('POST', '/api/auth/register', { json: { name: 'Alice Tester', email: `alice.${run}@example.com`, password: 'short' } });
check('weak password is refused with a field error (400)', r.status === 400 && r.json.errors.some((e) => e.field === 'password'));
r = await alice.req('POST', '/api/auth/register', { json: { name: 'Alice Tester', email: `alice.${run}@example.com`, password: 'a-good-password-1' } });
check('customer registers and is signed in (201)', r.status === 201 && r.json.user.role === 'customer');
r = await alice.req('POST', '/api/auth/register', { json: { name: 'Alice Again', email: `ALICE.${run}@example.com`, password: 'a-good-password-1' } });
check('same email twice is refused (409)', r.status === 409);
r = await bob.req('POST', '/api/auth/register', { json: { name: 'Bob Tester', email: `bob.${run}@example.com`, password: 'another-good-pass-2' } });
check('a second customer registers', r.status === 201);
r = await anon.req('POST', '/api/auth/login', { json: { email: `alice.${run}@example.com`, password: 'wrong-password' } });
check('wrong password is refused (401)', r.status === 401);
check('a customer cannot open the staff console (403)', (await alice.req('GET', '/api/staff/overview')).status === 403);

console.log('--- 2. upload gate through the site');
const dA = draftId();
r = await alice.req('POST', `/api/drafts/${dA}/documents?product=PL`, { form: form([file('id_proof.pdf', pdf('x')), file('payslip_1.pdf', 'this is just text'), file('payslip_2.pdf', pdf('y'))]) });
check('one bad file refuses the whole upload (422) with a reason for it', r.status === 422 && r.json.details.files.find((f) => f.file === 'payslip_1.pdf')?.reasonCode === 'UNSUPPORTED_TYPE', JSON.stringify(r.json).slice(0, 200));
r = await alice.req('POST', `/api/drafts/${dA}/documents?product=PL`, { form: form(goodSet(run)) });
check('a good set is stored (201 FILES_STAGED)', r.status === 201 && r.json.code === 'FILES_STAGED', r.status + ' ' + JSON.stringify(r.json).slice(0, 200));
const docs = (r.json?.details?.files || []).map((f) => ({ fileName: f.file, type: f.docType }));
check('the upload answer lists four documents with their types', docs.length === 4 && docs.every((d) => d.type));

console.log('--- 3. apply and follow it');
const base = { draft: dA, product: 'PL', amount: 200000, tenure: 24, fullName: 'Alice Tester', dateOfBirth: '1990-05-15', identityRef: 'ABCDE1234F', monthlyIncome: 90000, monthlyObligations: 10000, employmentMonths: 48, documents: docs };
r = await alice.req('POST', '/api/applications', { json: { ...base, identityRef: 'BAD' } });
check('a bad identity reference is refused with field errors (400)', r.status === 400 && JSON.stringify(r.json).includes('identityRef'), r.status);
r = await alice.req('POST', '/api/applications', { json: { ...base, amount: 5000 } });
check('an amount below the product minimum is refused (422)', r.status === 422, r.status);
r = await alice.req('POST', '/api/applications', { json: base });
check('the application is accepted (202) with a reference', r.status === 202 && r.json.applicationId, r.status);
const appId = r.json?.applicationId;
r = await alice.req('POST', '/api/applications', { json: base });
check('submitting the same draft again returns the same reference (idempotent)', r.status === 202 && r.json.applicationId === appId);
check('the list shows it', (await alice.req('GET', '/api/applications')).json.some((a) => a.applicationId === appId));
check('another customer cannot open it (404)', (await bob.req('GET', '/api/applications/' + appId)).status === 404);
const v = await waitStage(alice, appId, ['APPROVED', 'REFERRED', 'DECLINED', 'DOCUMENTS_INCOMPLETE']);
check('verified, scored and approved', v?.stage === 'APPROVED', v?.stage);
check('the decision shows the approved terms', v?.decision?.outcome === 'APPROVED' && v.decision.instalment === 9414.69, JSON.stringify(v?.decision));
check('the customer view carries no score or rule id', !JSON.stringify(v).match(/HP-0|"score"|SCORE_|BUREAU/));
check('four documents accepted', v?.documents?.filter((d) => d.status === 'ACCEPTED').length === 4);
for (let i = 0; i < 20 && !(v.events || []).some((e) => e.event === 'NOTIFIED'); i++) { await sleep(3000); v.events = (await alice.req('GET', '/api/applications/' + appId)).json.events; }
check('the audit path runs from RECEIVED to NOTIFIED', ['RECEIVED', 'VERIFYING', 'VERIFIED', 'SCORING', 'APPROVED', 'NOTIFIED'].every((e) => (v.events || []).some((x) => x.event === e)), (v.events || []).map((e) => e.event).join('>'));

console.log('--- 4. missing document, then fix it on the same application');
const dB = draftId();
const three = goodSet(run + 'b').slice(0, 3);
r = await alice.req('POST', `/api/drafts/${dB}/documents?product=PL`, { form: form(three) });
check('three files stored', r.status === 201);
const fourDocs = [...three.map((f) => ({ fileName: f.name, type: f.name.startsWith('id_') ? 'ID_PROOF' : f.name.startsWith('address') ? 'ADDRESS_PROOF' : 'PAYSLIP' })), { fileName: 'payslip_2.pdf', type: 'PAYSLIP' }];
r = await alice.req('POST', '/api/applications', { json: { ...base, draft: dB, documents: fourDocs } });
const appB = r.json?.applicationId;
check('second application accepted', r.status === 202 && appB);
const vb = await waitStage(alice, appB, ['DOCUMENTS_INCOMPLETE', 'APPROVED', 'DECLINED', 'REFERRED']);
check('it stops at documents incomplete', vb?.stage === 'DOCUMENTS_INCOMPLETE', vb?.stage);
check('it names the type, required and found', vb?.needed?.missing?.[0]?.docType === 'PAYSLIP' && vb.needed.missing[0].required === 2 && vb.needed.missing[0].found === 1, JSON.stringify(vb?.needed));
r = await alice.req('POST', `/api/applications/${appB}/documents`, { form: form([file('payslip_2.pdf', pdf('slip2 fix ' + run))]) });
check('the missing file is uploaded to the same application (201)', r.status === 201, r.status);
r = await alice.req('POST', `/api/applications/${appB}/resubmit`);
check('resubmit is accepted (202)', r.status === 202, r.status + JSON.stringify(r.json));
const vb2 = await waitStage(alice, appB, ['APPROVED', 'DECLINED', 'REFERRED']);
check('the same application now reaches a decision', vb2?.stage === 'APPROVED', vb2?.stage);

console.log('--- 5. staff console');
let creds = {};
try { for (const l of fs.readFileSync(STAFF_FILE, 'utf8').split(/\r?\n/)) { const m = l.match(/^(underwriter|ops)\s+(\S+)\s+(\S+)$/); if (m) creds[m[1]] = { email: m[2], password: m[3] }; } } catch { /* no file */ }
if (!creds.underwriter) { console.log('    (staff checks skipped: no ' + STAFF_FILE + ')'); }
else {
  r = await staff.req('POST', '/api/auth/login', { json: creds.underwriter });
  check('underwriter signs in', r.status === 200 && r.json.user.role === 'underwriter');
  r = await staff.req('GET', '/api/staff/overview');
  check('overview lists five healthy apps', r.status === 200 && r.json.checks.length === 5 && r.json.checks.every((x) => x.up), JSON.stringify(r.json.checks?.map((x) => x.name + ':' + x.up)));
  check('overview counts applications by stage', r.json.total > 0 && r.json.stages.APPROVED > 0);
  check('overview reads the broker queues', r.json.queues.available === true && r.json.queues.queues.length === 3, JSON.stringify(r.json.queues).slice(0, 200));
  r = await staff.req('GET', '/api/staff/applications/' + appId);
  check('staff see the scorecard factors that add up to the score', r.status === 200 && r.json.application.decision?.ruleHits?.filter((h) => h.ruleType === 'FACTOR').reduce((s, h) => s + h.contribution, 0) === r.json.application.decision.score, r.status);
  check('staff see who applied, with the identity number masked', r.json.owner?.name === 'Alice Tester' && /•/.test(r.json.application.identityRef) && !r.json.application.identityRef.includes('ABCDE'));
  check('staff see the full audit', r.json.audit.length >= 6);
  r = await staff.req('GET', '/api/staff/applications?stage=APPROVED');
  check('staff can filter the list by stage', r.status === 200 && r.json.every((a) => a.stage === 'APPROVED'));
  r = await staff.req('POST', '/api/staff/digest');
  check('staff can send the underwriting digest', r.status === 200 || r.status === 202, r.status);
  r = await staff.req('GET', '/api/staff/bureau');
  check('staff can read the bureau switch', r.status === 200 && typeof r.json.enabled === 'boolean');
  r = await staff.req('GET', '/api/staff/dlq/loan.verify.q.dlq');
  check('staff can look into a dead-letter queue', r.status === 200 && r.json.available === true, r.status);
  r = await staff.req('POST', '/api/staff/dlq/loan.verify.q.dlq/replay');
  check('replaying an empty dead-letter queue is harmless', r.status === 200 && r.json.replayed === 0);
  r = await staff.req('POST', '/api/staff/notifications/999999999/retry');
  check('retrying an unknown notification is a clean 404', r.status === 404, r.status);
  check('staff actions are recorded', (await staff.req('GET', '/api/staff/overview')).json.actions.some((a) => a.action === 'SEND_DIGEST'));
  check('a customer account cannot be used on staff routes', (await alice.req('POST', '/api/staff/digest')).status === 403);
  r = await staff.req('POST', '/api/auth/logout');
  check('staff sign out; the session is gone', r.status === 200 && (await staff.req('GET', '/api/staff/overview')).status === 401);
}
/* ---- Local only: the email a customer is shown, and stopping services from the console (CHAOS=1) ---- */
const cfg = (await anon.req('GET', '/api/config')).json;
const here = cfg.environments.find((e) => e.id === cfg.env);
if (here.mail) {
  console.log('--- 6. the email the customer is shown (Local)');
  let mails = [];
  for (let i = 0; i < 10 && !mails.length; i++) { mails = (await alice.req('GET', `/api/applications/${appId}/messages`)).json?.messages || []; if (!mails.length) await sleep(3000); }
  check('the approval email is shown to its owner', mails.length > 0 && /9,?414/.test(mails[0].text), mails[0]?.subject);
  check('another customer sees none of it', !((await bob.req('GET', `/api/applications/${appId}/messages`)).status === 200));
}
if (here.chaos && process.env.CHAOS === '1' && creds.underwriter) {
  console.log('--- 7. stopping services from the staff console (Local)');
  const s2 = new Client(); await s2.req('POST', '/api/auth/login', { json: creds.underwriter });
  const apply = async (tag) => {
    const d = draftId(); const up = await alice.req('POST', `/api/drafts/${d}/documents?product=PL`, { form: form(goodSet(run + tag)) });
    const dd = (up.json?.details?.files || []).map((f) => ({ fileName: f.file, type: f.docType }));
    return alice.req('POST', '/api/applications', { json: { ...base, draft: d, documents: dd } });
  };
  try {
    r = await s2.req('POST', '/api/staff/chaos/mail/stop');
    check('staff stop the mail server', r.status === 200, r.status + JSON.stringify(r.json));
    r = await apply('mail'); const mailApp = r.json?.applicationId;
    check('an application is still accepted with the mail server down', r.status === 202 && mailApp);
    const dm = await waitStage(alice, mailApp, ['APPROVED', 'REFERRED', 'DECLINED']);
    check('its decision is recorded although nobody can be emailed', dm?.stage === 'APPROVED', dm?.stage);
    let listed = false;
    for (let i = 0; i < 60 && !listed; i++) { listed = ((await s2.req('GET', '/api/staff/overview')).json?.unnotified || []).some((n) => n.applicationId === mailApp); if (!listed) await sleep(4000); }
    check('the console lists it as not yet notified', listed);
    r = await s2.req('POST', '/api/staff/chaos/mail/start');
    check('staff start the mail server again', r.status === 200);
    let notified = false;
    for (let i = 0; i < 90 && !notified; i++) { notified = ((await alice.req('GET', '/api/applications/' + mailApp)).json?.events || []).some((e) => e.event === 'NOTIFIED'); if (!notified) await sleep(4000); }
    check('the email goes out by itself once the server is back (never rescored)', notified);

    r = await s2.req('POST', '/api/staff/chaos/broker/stop');
    check('staff stop the message broker', r.status === 200, r.status + JSON.stringify(r.json));
    await sleep(3000);
    r = await apply('broker'); const brokerApp = r.json?.applicationId;
    check('an application is still accepted with the broker down (202)', r.status === 202 && brokerApp, r.status + JSON.stringify(r.json));
    let waiting = 0;
    for (let i = 0; i < 10 && !waiting; i++) { waiting = (await s2.req('GET', '/api/staff/overview')).json?.outboxPending || 0; if (!waiting) await sleep(2000); }
    check('its message waits in the outbox', waiting >= 1, String(waiting));
    r = await s2.req('POST', '/api/staff/chaos/broker/start');
    check('staff start the broker again', r.status === 200);
    const db2 = await waitStage(alice, brokerApp, ['APPROVED', 'REFERRED', 'DECLINED'], 240);
    check('it is published once the broker is back and reaches a decision', db2?.stage === 'APPROVED', db2?.stage);
  } finally {
    await s2.req('POST', '/api/staff/chaos/mail/start'); await s2.req('POST', '/api/staff/chaos/broker/start');
  }
}
console.log(`\n${fail ? fail + ' check(s) failed.' : 'All web checks passed.'} (${pass} passed)`);
process.exit(fail ? 1 : 0);
