// Drives a real headless Chrome through the site: register, apply with documents, watch the tracker, then the staff console.
//   node test/ui.mjs                       (server on http://localhost:3000)
//   BASE=http://localhost:3100 STAFF_FILE=... SHOTS=C:\folder node test/ui.mjs
// No dependencies: it speaks the Chrome DevTools protocol over Node's built-in WebSocket.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const BASE = process.env.BASE || 'http://localhost:3000';
const STAFF_FILE = process.env.STAFF_FILE || path.join(process.cwd(), 'data', 'initial-credentials.txt');
const SHOTS = process.env.SHOTS || path.join(os.tmpdir(), 'marigold-shots');
const CHROME = [process.env.CHROME, 'C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'].find((p) => p && fs.existsSync(p));
const PORT = 9400 + Math.floor(Math.random() * 300);
fs.mkdirSync(SHOTS, { recursive: true });
let pass = 0, fail = 0;
const check = (name, ok, detail = '') => { if (ok) { pass++; console.log('[PASS] ' + name); } else { fail++; console.log('[FAIL] ' + name + (detail ? ' (' + detail + ')' : '')); } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'mf-chrome-'));
const chrome = spawn(CHROME, [`--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, '--headless=new', '--no-first-run', '--disable-gpu', '--window-size=1360,1000', 'about:blank'], { stdio: 'ignore' });
let ws, nextId = 1; const pending = new Map(); const consoleErrors = [];
async function connect() {
  for (let i = 0; i < 50; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
      const page = list.find((t) => t.type === 'page');
      if (page) {
        ws = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
        ws.onmessage = (m) => {
          const d = JSON.parse(m.data);
          if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
          if (d.method === 'Runtime.exceptionThrown') consoleErrors.push(d.params.exceptionDetails.exception?.description || d.params.exceptionDetails.text);
          if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') consoleErrors.push(d.params.args.map((a) => a.value || a.description).join(' '));
        };
        return;
      }
    } catch { /* chrome still starting */ }
    await sleep(200);
  }
  throw new Error('Chrome did not start');
}
const send = (method, params = {}) => new Promise((res) => { const id = nextId++; pending.set(id, res); ws.send(JSON.stringify({ id, method, params })); });
async function ev(expr) { const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }); if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception?.description || 'eval failed: ' + expr.slice(0, 80)); return r.result.result.value; }
async function waitFor(expr, ms = 20000, what = expr) { const end = Date.now() + ms; while (Date.now() < end) { try { if (await ev(expr)) return true; } catch { /* page navigating */ } await sleep(250); } console.log('    (timeout waiting for ' + what.slice(0, 90) + ')'); return false; }
const goto = async (hash) => { await send('Page.navigate', { url: BASE + '/' + (hash || '') }); await sleep(400); };
const click = (sel) => ev(`(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) throw new Error('no ' + ${JSON.stringify(sel)}); e.click(); return true; })()`);
const setVal = (sel, v) => ev(`(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) throw new Error('no ' + ${JSON.stringify(sel)}); e.value = ${JSON.stringify(v)}; e.dispatchEvent(new Event('input', {bubbles:true})); e.dispatchEvent(new Event('change', {bubbles:true})); return true; })()`);
const text = (sel) => ev(`(document.querySelector(${JSON.stringify(sel)}) || {}).innerText || ''`);
async function shot(name, full = true) {
  let params = { format: 'png' };
  if (full) { const m = await send('Page.getLayoutMetrics'); const h = Math.min(Math.ceil(m.result.cssContentSize.height), 3200); params = { format: 'png', clip: { x: 0, y: 0, width: 1360, height: h, scale: 1 }, captureBeyondViewport: true }; }
  const r = await send('Page.captureScreenshot', params); fs.writeFileSync(path.join(SHOTS, name + '.png'), Buffer.from(r.result.data, 'base64'));
}
async function phone(on) { await send('Emulation.setDeviceMetricsOverride', on ? { width: 390, height: 844, deviceScaleFactor: 2, mobile: true } : { width: 1360, height: 1000, deviceScaleFactor: 1, mobile: false }); }

try {
  await connect(); await send('Runtime.enable'); await send('Page.enable'); await send('Emulation.setDeviceMetricsOverride', { width: 1360, height: 1000, deviceScaleFactor: 1, mobile: false });
  const run = Date.now().toString(36); const email = `ui.${run}@example.com`;

  console.log('--- landing');
  await goto('#/');
  check('landing renders the hero and the calculator', await waitFor("document.querySelector('.hero h1') && document.querySelector('#emiOut') && document.querySelector('#emiOut').textContent.includes('₹')"));
  check('the calculator shows the real instalment for 2,00,000 over 24 months', (await text('#emiOut')).includes('9,414.69'), await text('#emiOut'));
  await setVal('#amt', 500000); check('moving the slider recomputes the instalment', !(await text('#emiOut')).includes('9,414.69'));
  await shot('01-landing');

  console.log('--- register and sign in');
  await goto('#/register'); await waitFor("document.querySelector('#authForm')");
  await setVal('#name', 'Ui Tester'); await setVal('#email', email); await setVal('#password', 'short');
  await click('#authGo'); check('a weak password shows a field error', await waitFor("document.querySelector('.field.err #password') || document.querySelector('.field.err .msg')"));
  await setVal('#password', 'a-good-password-1'); await click('#authGo');
  check('registering lands on My loans, signed in', await waitFor("location.hash === '#/loans' && document.querySelector('#who').innerText.includes('Ui Tester')"));
  check('an empty list invites the first application', (await text('#list')).includes('Start your first application'));
  await shot('02-my-loans-empty');

  console.log('--- apply: details');
  await goto('#/apply'); await waitFor("document.querySelector('#f1')");
  await setVal('#preset', 'approved');
  check('a demo applicant fills the form', await waitFor("document.querySelector('#identityRef') && document.querySelector('#identityRef').value === 'ABCDE1234F'"));
  await setVal('#identityRef', 'BAD'); await click('#f1 button[type=submit]');
  check('a bad identity reference is caught before moving on', await waitFor("document.querySelector('.field.err #identityRef')"));
  await setVal('#preset', 'approved'); await waitFor("document.querySelector('#identityRef').value === 'ABCDE1234F'");
  await shot('03-apply-details');
  await click('#f1 button[type=submit]');
  check('valid details move to the documents step', await waitFor("document.querySelector('#drop')"));

  console.log('--- apply: documents (the upload gate, live)');
  await click('#hSample'); await click('#hText');
  check('files are listed', await waitFor("document.querySelectorAll('#fileList li').length >= 4"));
  await click('#doUpload');
  check('a renamed text file refuses the whole set, with the reason shown', await waitFor("document.querySelector('#upAlert .alert.bad') && document.querySelector('#fileList .why')", 30000));
  await shot('04-apply-documents-refused');
  check('the refused file shows a plain-language reason', (await text('#fileList .why')).toLowerCase().includes('pdf'));
  await click('#hSample'); await waitFor("!document.querySelector('#fileList .why')");
  await click('#doUpload');
  check('after fixing it the whole set is accepted and review opens', await waitFor("document.querySelector('#submit')", 30000));
  await shot('05-apply-review');

  console.log('--- submit and watch it live');
  await click('#submit');
  check('submitting opens the tracker with a reference', await waitFor("/^#\\/loans\\/APP-/.test(location.hash)", 40000));
  const ref = await ev('location.hash.split("/").pop()');
  console.log('    application ' + ref);
  check('the first step appears at once', await waitFor("document.querySelectorAll('.timeline li').length >= 1", 20000));
  await shot('06-tracker-start', false);
  check('it reaches an approved offer on its own', await waitFor("document.querySelector('.letter .amount')", 150000, 'offer letter'));
  check('the offer shows the approved terms', (await text('.letter')).includes('9,414.69') && (await text('.letter')).includes('2,00,000'));
  check('progress goes all the way to the email', await waitFor("document.querySelector('.timeline').innerText.includes('Email sent to you')", 90000));
  await shot('07-tracker-approved');
  await ev("document.querySelector('#proofSwitch').click(); true");
  check('proof mode shows requirement chips', await waitFor("getComputedStyle(document.querySelector('.req')).display !== 'none'"));
  await click('.req[data-req="AC15"]');
  check('a chip opens its requirement with the real calls this page made', await waitFor("document.querySelector('#drawer.open') && document.querySelector('#dBody table')") && (await text('#dBody')).includes('/api/applications'));
  await shot('08-proof-evidence', false);
  await click('#dClose'); await ev("document.querySelector('#proofSwitch').click(); true");
  await phone(true); await sleep(500); await shot('09-tracker-phone'); await phone(false);

  console.log('--- staff console');
  await ev("fetch('/api/auth/logout',{method:'POST',headers:{'x-requested-with':'mf'}}).then(()=>true)");
  const creds = {};
  try { for (const l of fs.readFileSync(STAFF_FILE, 'utf8').split(/\r?\n/)) { const m = l.match(/^(underwriter|ops)\s+(\S+)\s+(\S+)$/); if (m) creds[m[1]] = { email: m[2], password: m[3] }; } } catch { /* no file */ }
  if (!creds.underwriter) console.log('    (staff steps skipped: no credentials file)');
  else {
    await goto('#/login'); await sleep(500); await ev('location.reload()'); await waitFor("document.querySelector('#authForm')");
    await setVal('#email', creds.underwriter.email); await setVal('#password', creds.underwriter.password); await click('#authGo');
    check('staff sign in lands on the console', await waitFor("location.hash === '#/staff'", 20000));
    check('the overview shows the apps as UP, read live', await waitFor("document.querySelectorAll('.tile .state.s-ok').length >= 5", 30000));
    await shot('10-staff-overview');
    await goto('#/staff/applications'); await waitFor("document.querySelector('#rows tr[data-app]')", 30000);
    check('the applications table lists the system\'s real applications', (await ev("document.querySelectorAll('#rows tr[data-app]').length")) > 0);
    await ev(`(() => { const t = [...document.querySelectorAll('#rows tr[data-app]')].find(r => r.dataset.app === ${JSON.stringify(ref)}); (t || document.querySelector('#rows tr[data-app]')).click(); return true; })()`);
    check('clicking a row opens the drawer with the application', await waitFor("document.querySelector('#drawer.open') && document.querySelector('#dBody .tabs')", 30000));
    await shot('11-staff-drawer-overview', false);
    await click('#dBody .tabs button[data-t="score"]');
    check('the scorecard shows the factors adding up to the score', await waitFor("document.querySelector('#dBody .sumrow')"));
    await shot('12-staff-scorecard', false);
    await click('#dBody .tabs button[data-t="audit"]'); await sleep(300); await shot('13-staff-audit', false);
    await click('#dClose');
    await goto('#/staff/pipeline'); await waitFor("document.querySelector('#qrows .mono')", 30000);
    check('the pipeline shows the three queues with their dead letters', (await ev("document.querySelectorAll('#qrows tr').length")) === 3);
    await shot('14-staff-pipeline');
    await goto('#/staff/underwriting'); await waitFor("document.querySelector('#ref')"); await sleep(1500); await shot('15-staff-underwriting');
  }
  check('no JavaScript errors in the console', consoleErrors.length === 0, consoleErrors.slice(0, 3).join(' | '));
} catch (e) {
  fail++; console.log('[FAIL] ' + (e && e.stack || e)); try { await shot('zz-failure', false); } catch { /* ignore */ }
} finally {
  try { ws && ws.close(); } catch { /* ignore */ }
  chrome.kill();
  console.log(`\n${fail ? fail + ' check(s) failed.' : 'All UI checks passed.'} (${pass} passed). Screenshots: ${SHOTS}`);
  setTimeout(() => process.exit(fail ? 1 : 0), 500);
}
