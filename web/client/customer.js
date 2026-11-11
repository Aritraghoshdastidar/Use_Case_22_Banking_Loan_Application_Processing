// Customer side: landing, sign in, apply (details, documents, review), my loans, and the live tracker.
import { $, $$, esc, inr, when, day, api, stageChip, TERMINAL, req, fieldHtml, toast, startPolling, stopPolling, paintTextures } from './util.js';

const emi = (P, n, rate) => { const r = rate / 1200, f = Math.pow(1 + r, n); return Math.round(((P * r * f) / (f - 1) + Number.EPSILON) * 100) / 100; };
const tenText = (n) => (n >= 24 && n % 12 === 0 ? `${n} months (${n / 12} years)` : `${n} months`);

/* demo applicants: the mock credit bureau knows these identity references, so each gives a different real outcome */
const PRESETS = [
  { id: 'approved', label: 'Strong applicant → approved', v: { product: 'PL', amount: 200000, tenure: 24, identityRef: 'ABCDE1234F', monthlyIncome: 90000, monthlyObligations: 10000, employmentMonths: 48, dateOfBirth: '1990-05-15' } },
  { id: 'reduced', label: 'Instalment too high → reduced offer', v: { product: 'PL', amount: 500000, tenure: 36, identityRef: 'ABCDE1234F', monthlyIncome: 50000, monthlyObligations: 20000, employmentMonths: 48, dateOfBirth: '1990-05-15' } },
  { id: 'referred', label: 'Middle score → underwriter', v: { product: 'PL', amount: 300000, tenure: 36, identityRef: 'FGHIJ5678K', monthlyIncome: 70000, monthlyObligations: 15000, employmentMonths: 20, dateOfBirth: '1990-05-15' } },
  { id: 'declined', label: 'Weak score → declined', v: { product: 'PL', amount: 200000, tenure: 24, identityRef: 'LMNOP9012Q', monthlyIncome: 90000, monthlyObligations: 10000, employmentMonths: 12, dateOfBirth: '1990-05-15' } },
  { id: 'default', label: 'Active default → declined by a hard rule', v: { product: 'PL', amount: 200000, tenure: 24, identityRef: 'RSTUV3456W', monthlyIncome: 90000, monthlyObligations: 10000, employmentMonths: 48, dateOfBirth: '1990-05-15' } },
  { id: 'nobureau', label: 'No credit record → referred (data unavailable)', v: { product: 'PL', amount: 200000, tenure: 24, identityRef: 'ZZZZZ9999Z', monthlyIncome: 90000, monthlyObligations: 10000, employmentMonths: 48, dateOfBirth: '1990-05-15' } },
];

/* ---------------------------------------------------------------- landing */
export async function landing(ctx) {
  const { data: products } = await api('GET', '/api/products');
  const ok = Array.isArray(products) && products.length;
  const P = ok ? Object.fromEntries(products.map((p) => [p.code, p])) : null;
  ctx.main.innerHTML = `
  <div class="hero"><svg class="guil" data-guil viewBox="-250 -250 500 500" aria-hidden="true"></svg>
    <div class="in">
      <div>
        <span class="eyebrow">Personal loans and home loans</span>
        <h1>Apply once. Watch every step.</h1>
        <p class="lead">We check each document as you upload it, tell you exactly what is missing, and show the decision with its reasons. An approved offer stays valid for 30 days.</p>
        <div class="cta"><a class="btn" href="#/apply">Apply now</a>${ctx.user ? '<a class="btn ghost" href="#/loans">My loans</a>' : '<a class="btn ghost" href="#/login">Sign in</a>'}</div>
        <div class="facts">
          <div><b>10</b><span>checks on every file${req('FR7')}</span></div>
          <div><b>0</b><span>files kept if one fails${req('N9')}</span></div>
          <div><b>30 days</b><span>offer validity${req('FR16')}</span></div>
        </div>
      </div>
      ${ok ? `<div class="calc" aria-labelledby="calcT">
        <div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
          <h2 id="calcT" style="font-size:17px">Estimate your monthly instalment</h2>
          <div class="seg" id="prodSeg" role="group" aria-label="Product">${products.map((p, i) => `<button aria-pressed="${i === 0}" data-p="${p.code}">${esc(p.name)}</button>`).join('')}</div>
        </div>
        <div class="row"><label for="amt">Loan amount <output id="amtOut"></output></label><input type="range" id="amt"></div>
        <div class="row"><label for="ten">Tenure <output id="tenOut"></output></label><input type="range" id="ten"></div>
        <div class="emi"><div class="eyebrow">Monthly instalment ${req('FR14')}</div><div class="big" id="emiOut"></div>
          <div class="bar2"><i id="barP"></i></div>
          <div class="split"><span>Principal <b id="pOut"></b></span><span>Interest <b id="iOut"></b></span><span>Rate <b id="rOut"></b></span></div></div>
        <p class="small muted" style="margin-top:14px">Indicative. The final instalment is set when we decide your application.</p>
      </div>` : '<div class="calc"><p class="muted">Product details are not available right now. Try again in a moment.</p></div>'}
    </div></div>
  <div class="band"><div class="in">
    <div class="sec-head"><span class="eyebrow">What happens after you apply</span><h2>Four steps, each one visible to you</h2></div>
    <div class="steps">
      <div><span class="n">STEP 1</span><h3>Details</h3><p>You enter your details and the amount. Mistakes are shown field by field. We answer straight away with a reference.</p></div>
      <div><span class="n">STEP 2</span><h3>Documents</h3><p>You upload ID, address proof and payslips. Every file is checked before it is stored. If one fails, none is kept and you see why.</p></div>
      <div><span class="n">STEP 3</span><h3>Verification</h3><p>We match your files with the checklist. Short of a payslip? You get the exact list and add it to the same application.</p></div>
      <div><span class="n">STEP 4</span><h3>Decision</h3><p>You get one of four emails: approved with terms, referred to a person, declined with reasons, or documents missing.</p></div>
    </div></div></div>
  ${ok ? `<div class="band alt"><div class="in">
    <div class="sec-head"><span class="eyebrow">Products and limits</span><h2>What you can borrow</h2></div>
    <div class="two">${products.map((p) => `<div class="panel"><div class="ph"><h3>${esc(p.name)}</h3><span class="state s-ok">Open</span></div><div class="pb"><dl class="kv">
      <dt>Amount</dt><dd>${inr(p.minAmount)} to ${inr(p.maxAmount)}</dd><dt>Tenure</dt><dd>${p.minTenureMonths} to ${p.maxTenureMonths} months</dd>
      <dt>Rate</dt><dd>${Number(p.annualRatePct).toFixed(2)}% a year</dd><dt>Applicant age</dt><dd>${p.minAgeAtApplication} to ${p.maxAgeAtApplication} (${p.maxAgeAtMaturity} at the end of the loan)</dd>
      <dt>Instalment limit</dt><dd>Up to ${p.emiCeilingPct}% of income after obligations</dd>
      <dt>Documents</dt><dd>${(p.documents || []).map((d) => `${d.requiredCount > 1 ? d.requiredCount + ' × ' : ''}${esc(String(d.description || d.docType).toLowerCase())}`).join(', ')}</dd></dl></div></div>`).join('')}</div></div></div>` : ''}
  <div class="band"><div class="in">
    <div class="sec-head"><span class="eyebrow">Upload checks</span><h2>Ten checks before a file is kept ${req('FR7')}</h2><p class="muted" style="margin-top:6px">The first failure wins for each file. If any file fails, the whole upload is refused and nothing is stored, so you never end up with half a set.</p></div>
    <ol class="checks">
      <li>The file name is safe<small>Letters, digits, dot, underscore and hyphen only.</small></li>
      <li>The name starts with a document type<small>For example id_proof, address_proof, payslip_1.</small></li>
      <li>The file is not empty<small>Zero-byte files are refused.</small></li>
      <li>The size is within the limit<small>5 MB for ID and address, 2 MB for payslips.</small></li>
      <li>The extension is allowed<small>PDF, JPG or PNG for most; PDF only for payslips.</small></li>
      <li>The content is really a PDF, JPEG or PNG<small>A renamed program is caught by its first bytes. ${req('N10')}</small></li>
      <li>The extension matches the content<small>A PNG named .pdf is refused.</small></li>
      <li>The declared type matches the content<small>What your browser says must agree with the bytes.</small></li>
      <li>The file is complete<small>A document cut short is refused. ${req('N11')}</small></li>
      <li>No duplicate content in the upload<small>The same file under two names counts once.</small></li>
    </ol></div></div>`;
  paintTextures(ctx.main);
  if (!ok) return;
  const amt = $('#amt'), ten = $('#ten'); let cp = products[0].code;
  const defaults = { PL: [200000, 24], HL: [2500000, 180] };
  const set = (code) => {
    cp = code; const p = P[code], d = defaults[code] || [p.minAmount, p.minTenureMonths];
    amt.min = p.minAmount; amt.max = p.maxAmount; amt.step = p.amountStep || 1000; amt.value = d[0]; ten.min = p.minTenureMonths; ten.max = p.maxTenureMonths; ten.step = 1; ten.value = d[1];
    $$('#prodSeg button').forEach((b) => b.setAttribute('aria-pressed', b.dataset.p === code)); calc();
  };
  const calc = () => {
    const p = P[cp], A = +amt.value, n = +ten.value, e = emi(A, n, p.annualRatePct), tot = e * n;
    $('#amtOut').textContent = inr(A); $('#tenOut').textContent = tenText(n); $('#emiOut').textContent = inr(e, 2);
    $('#pOut').textContent = inr(A); $('#iOut').textContent = inr(Math.round(tot - A)); $('#rOut').textContent = Number(p.annualRatePct).toFixed(2) + '%';
    $('#barP').style.width = ((A / tot) * 100).toFixed(1) + '%';
  };
  amt.addEventListener('input', calc); ten.addEventListener('input', calc);
  $$('#prodSeg button').forEach((b) => b.addEventListener('click', () => set(b.dataset.p)));
  set(cp);
}

/* ---------------------------------------------------------------- sign in / register */
export function authView(ctx, mode) {
  const reg = mode === 'register';
  ctx.main.innerHTML = `<div class="auth"><svg class="guil" data-guil viewBox="-250 -250 500 500" aria-hidden="true"></svg>
    <div class="box"><h1>${reg ? 'Create your account' : 'Sign in'}</h1>
    <p class="muted small">${reg ? 'One account for all your applications.' : 'Customers and staff sign in here.'}</p>
    <form class="form" id="authForm" novalidate>
      <div id="authAlert"></div>
      ${reg ? fieldHtml({ id: 'name', label: 'Full name', attrs: 'autocomplete="name" required' }) : ''}
      ${fieldHtml({ id: 'email', label: 'Email', type: 'email', attrs: 'autocomplete="email" required' })}
      ${fieldHtml({ id: 'password', label: 'Password', type: 'password', hint: reg ? 'At least 8 characters.' : '', attrs: `autocomplete="${reg ? 'new-password' : 'current-password'}" required` })}
      <button class="btn" id="authGo" type="submit">${reg ? 'Create account' : 'Sign in'}</button>
    </form>
    <p class="small muted" style="margin-top:16px">${reg ? 'Already have an account? <a href="#/login">Sign in</a>' : 'New here? <a href="#/register">Create an account</a>'}</p></div></div>`;
  paintTextures(ctx.main);
  $('#authForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const body = { email: $('#email').value, password: $('#password').value, ...(reg ? { name: $('#name').value } : {}) };
    $('#authGo').disabled = true; $('#authAlert').innerHTML = '';
    const r = await api('POST', reg ? '/api/auth/register' : '/api/auth/login', { json: body });
    $('#authGo').disabled = false;
    if (r.ok) { await ctx.refreshUser(); const next = new URLSearchParams(location.hash.split('?')[1] || '').get('next'); location.hash = next || (r.data.user.role === 'customer' ? '#/loans' : '#/staff'); return; }
    $$('.field').forEach((f) => f.classList.remove('err')); $$('.field .msg').forEach((m) => m.remove());
    const errs = (r.data && r.data.errors) || [];
    errs.forEach((er) => { const f = $('#' + er.field); if (f) { f.parentElement.classList.add('err'); f.parentElement.insertAdjacentHTML('beforeend', `<span class="msg">${esc(er.message)}</span>`); } });
    if (!errs.length || r.status !== 400) $('#authAlert').innerHTML = `<div class="alert bad">${esc((r.data && r.data.message) || 'That did not work. Try again.')}</div>`;
  });
}

/* ---------------------------------------------------------------- apply */
const draftKey = (u) => `mf-draft-${u.id}`;
const newDraftId = () => Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => (b % 36).toString(36)).join('');
function loadDraft(user) {
  try { const d = JSON.parse(sessionStorage.getItem(draftKey(user))); if (d && d.id) return d; } catch { /* start fresh */ }
  return { id: newDraftId(), step: 1, v: { product: 'PL', amount: 200000, tenure: 24, fullName: user.name, dateOfBirth: '', identityRef: '', monthlyIncome: '', monthlyObligations: 0, employmentMonths: 0 }, uploaded: null };
}
const saveDraft = (user, d) => { try { sessionStorage.setItem(draftKey(user), JSON.stringify(d)); } catch { /* private mode */ } };

function samplePdf(label) {
  const body = `%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 144] >>\nendobj\n% sample ${label} ${new Date().toISOString()} ${Math.random().toString(36).slice(2)}\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n`;
  return new Blob([body], { type: 'application/pdf' });
}

export async function applyView(ctx) {
  const user = ctx.user; const draft = loadDraft(user);
  const { data: products } = await api('GET', '/api/products');
  if (!Array.isArray(products)) { ctx.main.innerHTML = '<div class="in page"><div class="alert bad">Product details are not available right now. Try again in a moment.</div></div>'; return; }
  const P = Object.fromEntries(products.map((p) => [p.code, p]));
  let files = []; // File objects chosen in step 2
  let uploadResult = null; let submitError = null; let fieldErrors = {}; let busy = false;

  const stepper = () => `<div class="stepper" aria-label="Progress">${['Details', 'Documents', 'Review and submit'].map((t, i) => `<div class="${draft.step === i + 1 ? 'on' : draft.step > i + 1 ? 'done' : ''}"><b>${i + 1}</b>${t}</div>`).join('')}</div>`;

  function clientErrors(v) {
    const e = {}; const p = P[v.product];
    if (!v.fullName.trim()) e.fullName = 'Enter your full name.';
    if (!v.dateOfBirth) e.dateOfBirth = 'Enter your date of birth.';
    else { const a = (Date.now() - new Date(v.dateOfBirth)) / 31557600000; if (a < p.minAgeAtApplication || a > p.maxAgeAtApplication) e.dateOfBirth = `You must be between ${p.minAgeAtApplication} and ${p.maxAgeAtApplication} to apply for this loan.`; }
    if (!/^[A-Z]{5}[0-9]{4}[A-Z]$/.test(v.identityRef.trim().toUpperCase())) e.identityRef = 'Five letters, four digits, one letter. For example ABCDE1234F.';
    if (!(v.amount >= p.minAmount && v.amount <= p.maxAmount)) e.amount = `Between ${inr(p.minAmount)} and ${inr(p.maxAmount)}.`;
    if (!(v.tenure >= p.minTenureMonths && v.tenure <= p.maxTenureMonths)) e.tenure = `Between ${p.minTenureMonths} and ${p.maxTenureMonths} months.`;
    if (!(Number(v.monthlyIncome) > 0)) e.monthlyIncome = 'Enter your monthly income.';
    if (Number(v.monthlyObligations) < 0 || v.monthlyObligations === '') e.monthlyObligations = 'Enter 0 if you have none.';
    return e;
  }

  function render() {
    saveDraft(user, draft);
    ctx.main.innerHTML = `<div class="in page"><div class="crumb"><a href="#/loans">My loans</a> / New application</div>
      <div class="title-row"><div><h1>Apply for a loan</h1><p class="muted">Draft <span class="mono">${esc(draft.id)}</span>. Your answers are kept if you reload.</p></div>
      <button class="linkbtn" id="restart">Start again</button></div>${stepper()}<div id="stepBody"></div></div>`;
    $('#restart').addEventListener('click', () => { sessionStorage.removeItem(draftKey(user)); location.reload(); });
    if (draft.step === 1) step1(); else if (draft.step === 2) step2(); else step3();
  }

  function step1() {
    const v = draft.v; const p = P[v.product]; const e = fieldErrors;
    $('#stepBody').innerHTML = `<form class="panel" id="f1" novalidate><div class="pb"><div class="form" style="margin-top:0">
      <div class="helper" style="margin-top:0"><label for="preset"><b>Demo applicant</b></label>
        <select id="preset"><option value="">Choose one to fill the form…</option>${PRESETS.map((x) => `<option value="${x.id}">${esc(x.label)}</option>`).join('')}</select>
        <span>The test credit bureau knows these identity references, so each one gives a different real result.</span></div>
      <div class="row2"><div class="field"><label for="product">Product</label><select id="product">${products.map((x) => `<option value="${x.code}" ${x.code === v.product ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select></div>
        ${fieldHtml({ id: 'amount', label: 'Loan amount (₹)', type: 'number', value: v.amount, error: e.amount, hint: `${inr(p.minAmount)} to ${inr(p.maxAmount)}`, attrs: `min="${p.minAmount}" max="${p.maxAmount}" step="${p.amountStep || 1}" inputmode="numeric"` })}</div>
      <div class="row2">${fieldHtml({ id: 'tenure', label: 'Tenure (months)', type: 'number', value: v.tenure, error: e.tenure, hint: `${p.minTenureMonths} to ${p.maxTenureMonths} months`, attrs: `min="${p.minTenureMonths}" max="${p.maxTenureMonths}" inputmode="numeric"` })}
        <div class="field"><label>Indicative instalment</label><div class="mono" id="emiLine" style="padding:9px 0;font-size:18px"></div></div></div>
      <hr style="border:0;border-top:1px solid var(--rule);width:100%">
      <div class="row2">${fieldHtml({ id: 'fullName', label: 'Full name', value: v.fullName, error: e.fullName, attrs: 'autocomplete="name"' })}
        ${fieldHtml({ id: 'dateOfBirth', label: 'Date of birth', type: 'date', value: v.dateOfBirth, error: e.dateOfBirth })}</div>
      ${fieldHtml({ id: 'identityRef', label: 'Identity reference (PAN)', value: v.identityRef, error: e.identityRef, hint: 'Five letters, four digits, one letter.', attrs: 'maxlength="10" autocapitalize="characters" spellcheck="false"' })}
      <div class="row2">${fieldHtml({ id: 'monthlyIncome', label: 'Monthly income (₹)', type: 'number', value: v.monthlyIncome, error: e.monthlyIncome, attrs: 'min="0" inputmode="numeric"' })}
        ${fieldHtml({ id: 'monthlyObligations', label: 'Monthly obligations (₹)', type: 'number', value: v.monthlyObligations, error: e.monthlyObligations, hint: 'Existing loan repayments and similar. 0 if none.', attrs: 'min="0" inputmode="numeric"' })}</div>
      ${fieldHtml({ id: 'employmentMonths', label: 'Months in current job', type: 'number', value: v.employmentMonths, attrs: 'min="0" inputmode="numeric"' })}
      <div><button class="btn" type="submit">Continue to documents</button></div></div></div></form>`;
    const read = () => { const g = (id) => $('#' + id).value; Object.assign(draft.v, { product: g('product'), amount: Number(g('amount')), tenure: Number(g('tenure')), fullName: g('fullName'), dateOfBirth: g('dateOfBirth'), identityRef: g('identityRef').toUpperCase(), monthlyIncome: g('monthlyIncome') === '' ? '' : Number(g('monthlyIncome')), monthlyObligations: g('monthlyObligations') === '' ? '' : Number(g('monthlyObligations')), employmentMonths: Number(g('employmentMonths') || 0) }); };
    const line = () => { const a = Number($('#amount').value), n = Number($('#tenure').value); $('#emiLine').textContent = a > 0 && n > 0 ? inr(emi(a, n, P[$('#product').value].annualRatePct), 2) + ' a month' : '—'; };
    line(); $('#amount').addEventListener('input', line); $('#tenure').addEventListener('input', line);
    $('#product').addEventListener('change', () => { read(); const np = P[draft.v.product]; draft.v.amount = np.code === 'HL' ? 2500000 : 200000; draft.v.tenure = np.code === 'HL' ? 180 : 24; fieldErrors = {}; render(); });
    $('#preset').addEventListener('change', (ev) => { const x = PRESETS.find((y) => y.id === ev.target.value); if (!x) return; Object.assign(draft.v, x.v, { fullName: draft.v.fullName || user.name }); fieldErrors = {}; render(); });
    $('#f1').addEventListener('submit', (ev) => { ev.preventDefault(); read(); fieldErrors = clientErrors(draft.v); if (Object.keys(fieldErrors).length) { render(); const first = $('.field.err input, .field.err select'); if (first) first.focus(); return; } draft.step = 2; render(); });
  }

  function step2() {
    const p = P[draft.v.product]; const docs = p.documents || [];
    $('#stepBody').innerHTML = `<div class="grid-tr"><div class="panel"><div class="ph"><h3>Your documents ${req('FR7')}</h3><span class="small muted">${esc(p.name)}</span></div><div class="pb">
      <p class="small muted" style="margin-bottom:12px">Name each file so it starts with its document type: <span class="mono">${docs.map((d) => esc(d.docType.toLowerCase())).join('</span>, <span class="mono">')}</span> (for example <span class="mono">payslip_1.pdf</span>). PDF, JPG or PNG.</p>
      <div class="drop" id="drop"><b>Drop files here</b> or <label for="pick" style="text-decoration:underline;cursor:pointer">choose files</label><input id="pick" type="file" multiple accept=".pdf,.jpg,.jpeg,.png" style="position:absolute;left:-9999px" aria-label="Choose files"></div>
      <ul class="files" id="fileList"></ul>
      <div class="helper"><b>Demo helpers</b><button class="btn ghost sm" type="button" id="hSample">Add 4 sample documents</button><button class="btn ghost sm" type="button" id="hText">Add a text file named like a PDF</button><button class="btn ghost sm" type="button" id="hEmpty">Add an empty file</button></div>
      <div id="upAlert" style="margin-top:14px"></div>
      <div class="actions" style="margin-top:18px"><button class="btn" id="doUpload" type="button">Check and upload</button><button class="btn ghost" id="back1" type="button">Back</button></div></div></div>
      <div class="panel"><div class="ph"><h3>What we need</h3></div><div class="pb"><dl class="kv">${docs.map((d) => `<dt>${esc(d.docType.replace(/_/g, ' ').toLowerCase())}</dt><dd>${d.requiredCount} × · up to ${(d.maxSizeBytes / 1048576).toFixed(0)} MB · ${esc((d.allowedExtensions || []).join(', '))}</dd>`).join('')}</dl>
      <p class="small muted" style="margin-top:14px">If one file fails, none is stored and each file shows its result, so you can fix it and upload the whole set again.</p></div></div></div>`;
    const list = () => {
      const res = uploadResult && uploadResult.details ? Object.fromEntries(uploadResult.details.files.map((f) => [f.file, f])) : {};
      $('#fileList').innerHTML = files.length ? files.map((f, i) => { const r = res[f.name]; return `<li><span class="mono">${esc(f.name)}</span><span class="small muted">${(f.size / 1024).toFixed(1)} KB</span><span>${r ? (r.status === 'STAGED' || r.status === 'OK' ? '<span class="state s-ok">Accepted</span>' : '<span class="state s-bad">Refused</span>') : `<button class="linkbtn" data-rm="${i}">Remove</button>`}</span>${r && r.message ? `<span class="why">${esc(r.message)}</span>` : ''}</li>`; }).join('') : '<li class="small muted" style="display:block">No files yet.</li>';
      $$('#fileList [data-rm]').forEach((b) => b.addEventListener('click', () => { files.splice(Number(b.dataset.rm), 1); uploadResult = null; list(); }));
    };
    const add = (arr) => { for (const f of arr) { const dup = files.findIndex((x) => x.name === f.name); if (dup >= 0) files[dup] = f; else files.push(f); } uploadResult = null; $('#upAlert').innerHTML = ''; list(); };
    list();
    $('#pick').addEventListener('change', (e) => { add(Array.from(e.target.files)); e.target.value = ''; });
    const drop = $('#drop');
    ['dragenter', 'dragover'].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add('over'); }));
    ['dragleave', 'drop'].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
    drop.addEventListener('drop', (e) => add(Array.from(e.dataTransfer.files)));
    $('#hSample').addEventListener('click', () => {
      const names = ['id_proof.pdf', 'address_proof.pdf', 'payslip_1.pdf', 'payslip_2.pdf'];
      files = files.filter((f) => !names.includes(f.name)); add(names.map((n) => new File([samplePdf(n)], n, { type: 'application/pdf' })));
    });
    $('#hText').addEventListener('click', () => add([new File(['This is plain text, not a PDF.'], 'payslip_2.pdf', { type: 'application/pdf' })]));
    $('#hEmpty').addEventListener('click', () => add([new File([], 'address_proof.pdf', { type: 'application/pdf' })]));
    $('#back1').addEventListener('click', () => { draft.step = 1; render(); });
    $('#doUpload').addEventListener('click', async () => {
      if (!files.length) { $('#upAlert').innerHTML = '<div class="alert bad">Add at least one file first.</div>'; return; }
      const btn = $('#doUpload'); btn.disabled = true; btn.textContent = 'Checking…';
      const fd = new FormData(); files.forEach((f, i) => fd.append('f' + i, f, f.name));
      const r = await api('POST', `/api/drafts/${draft.id}/documents?product=${draft.v.product}`, { form: fd });
      btn.disabled = false; btn.textContent = 'Check and upload'; uploadResult = r.data; list();
      if (r.status === 201) {
        draft.uploaded = r.data.details.files.map((f) => ({ fileName: f.file, type: f.docType })); draft.step = 3; render();
      } else if (r.status === 422 && r.data.details) {
        $('#upAlert').innerHTML = '<div class="alert bad"><b>Nothing was stored.</b> Fix the files marked Refused, then check and upload the whole set again.</div>';
      } else $('#upAlert').innerHTML = `<div class="alert bad">${esc((r.data && r.data.message) || 'The upload failed. Try again.')}</div>`;
    });
  }

  function step3() {
    const v = draft.v; const p = P[v.product];
    // Documents the product needs that were not uploaded yet. They are declared with the application (the system only
    // recognises files it was told about), so the file can be added later on the same application and resubmitted.
    const todo = [];
    for (const r of p.documents || []) {
      const have = (draft.uploaded || []).filter((d) => d.type === r.docType).length;
      for (let n = have + 1; n <= r.requiredCount; n++) todo.push({ fileName: `${r.docType.toLowerCase()}${r.requiredCount > 1 ? '_' + n : ''}.pdf`, type: r.docType });
    }
    const errs = submitError && submitError.errors ? `<ul>${submitError.errors.map((x) => `<li>${esc(x.field)}: ${esc(x.message)}</li>`).join('')}</ul>` : '';
    $('#stepBody').innerHTML = `<div class="grid-tr"><div class="panel"><div class="ph"><h3>Review</h3></div><div class="pb"><dl class="kv">
      <dt>Product</dt><dd>${esc(p.name)}</dd><dt>Amount</dt><dd>${inr(v.amount)} over ${tenText(v.tenure)}</dd><dt>Indicative instalment</dt><dd>${inr(emi(v.amount, v.tenure, p.annualRatePct), 2)} a month at ${Number(p.annualRatePct).toFixed(2)}%</dd>
      <dt>Name</dt><dd>${esc(v.fullName)}</dd><dt>Date of birth</dt><dd>${esc(v.dateOfBirth)}</dd><dt>Identity reference</dt><dd class="mono">${esc(v.identityRef)}</dd>
      <dt>Income / obligations</dt><dd>${inr(v.monthlyIncome)} / ${inr(v.monthlyObligations || 0)} a month</dd><dt>Months in job</dt><dd>${esc(v.employmentMonths)}</dd>
      <dt>Documents</dt><dd>${(draft.uploaded || []).map((d) => `<span class="mono">${esc(d.fileName)}</span>`).join('<br>')}</dd>${todo.length ? `<dt>Still to send</dt><dd>${todo.map((d) => `<span class="mono">${esc(d.fileName)}</span>`).join('<br>')}<div class="small muted" style="margin-top:6px">You can submit now and add these on the same application. Name each file exactly as shown.</div></dd>` : ''}</dl></div></div>
      <div class="panel"><div class="ph"><h3>Submit ${req('FR4')}</h3></div><div class="pb">
      ${submitError ? `<div class="alert bad" style="margin-bottom:14px">${esc(submitError.message)}${errs}</div>` : ''}
      <p class="muted">We check your details and answer straight away with a reference. Your documents are verified and your application scored in the background; you can watch every step.</p>
      <div class="actions" style="margin-top:18px"><button class="btn" id="submit" type="button">Submit application</button><button class="btn ghost" id="back2" type="button">Back</button><button class="btn ghost" id="back1" type="button">Change details</button></div></div></div></div>`;
    $('#back2').addEventListener('click', () => { draft.step = 2; render(); });
    $('#back1').addEventListener('click', () => { draft.step = 1; render(); });
    $('#submit').addEventListener('click', async () => {
      if (busy) return; busy = true; $('#submit').disabled = true; $('#submit').textContent = 'Submitting…';
      const r = await api('POST', '/api/applications', { json: { draft: draft.id, product: v.product, amount: v.amount, tenure: v.tenure, fullName: v.fullName, dateOfBirth: v.dateOfBirth, identityRef: v.identityRef, monthlyIncome: v.monthlyIncome, monthlyObligations: v.monthlyObligations || 0, employmentMonths: v.employmentMonths || 0, documents: (draft.uploaded || []).concat(todo) } });
      busy = false;
      if (r.status === 202) { sessionStorage.removeItem(draftKey(user)); toast(`Application ${r.data.applicationId} received.`); location.hash = `#/loans/${r.data.applicationId}`; return; }
      submitError = { message: (r.data && r.data.message) || 'The application could not be submitted.', errors: r.data && r.data.details && r.data.details.errors };
      render();
    });
  }
  render();
}

/* ---------------------------------------------------------------- my loans */
export async function loansView(ctx) {
  ctx.main.innerHTML = '<div class="in page"><div class="title-row"><div><h1>My loans</h1><p class="muted">Every application you have made, with its current stage.</p></div><a class="btn" href="#/apply">New application</a></div><div id="list"><div class="loading">Loading…</div></div></div>';
  const draw = async () => {
    const r = await api('GET', '/api/applications');
    if (!r.ok) { $('#list').innerHTML = `<div class="alert bad">${esc((r.data && r.data.message) || 'Could not load your applications.')}</div>`; return; }
    $('#list').innerHTML = r.data.length ? `<div class="cards">${r.data.map((a) => `<a class="card" href="#/loans/${esc(a.applicationId)}"><div class="top"><h3>${a.product === 'HL' ? 'Home loan' : 'Personal loan'}</h3>${stageChip(a.stage)}</div><p class="mono small muted" style="margin-top:6px">${esc(a.applicationId)}</p><p style="margin-top:10px;font-size:20px;font-family:var(--serif);font-weight:600">${inr(a.amount)}</p><p class="small muted">${a.tenure} months · applied ${day(a.createdAt)}</p></a>`).join('')}</div>`
      : '<div class="panel"><div class="empty">You have not applied yet. <a href="#/apply">Start your first application</a>.</div></div>';
  };
  await draw(); startPolling(draw, 5000);
}

/* ---------------------------------------------------------------- tracker */
const LABEL = {
  RECEIVED: ['Application received', 'Your reference is recorded. We answered in under a second.'],
  VERIFYING: ['Checking your documents', 'We are matching your files with the checklist and checking each one.'],
  VERIFIED: ['Documents verified', 'Every required document was accepted. A digest of each file is stored so we can identify what was reviewed.'],
  DOCUMENTS_INCOMPLETE: ['Documents missing', 'We could not move forward yet. The exact list is below.'],
  SCORING: ['Assessing your application', 'We are scoring your application against our lending criteria.'],
  APPROVED: ['Decision reached: approved', 'Your offer is below.'], DECLINED: ['Decision reached: not approved', 'The reasons are below.'], REFERRED: ['Sent to an underwriter', 'A person will look at your application.'],
  NOTIFIED: ['Email sent to you', 'The email has your result and next steps.'],
};
const NEXT = { RECEIVED: 'Checking your documents', VERIFYING: 'Verifying each file', VERIFIED: 'Assessing your application', SCORING: 'Reaching a decision', APPROVED: 'Sending you an email', DECLINED: 'Sending you an email', REFERRED: 'Sending you an email', DOCUMENTS_INCOMPLETE: 'Sending you an email' };

export async function trackerView(ctx, id) {
  ctx.main.innerHTML = `<div class="in page"><div class="crumb"><a href="#/loans">My loans</a> / <span class="mono">${esc(id)}</span></div><div id="trk"><div class="loading">Loading…</div></div></div>`;
  let seenEvents = 0; let mail = null; let busy = false; let picked = []; let upMsg = '';
  const render = (v) => {
    const events = v.events; const last = events.length ? events[events.length - 1] : null; const notified = events.some((e) => e.event === 'NOTIFIED');
    const finished = TERMINAL.includes(v.stage) && notified;
    const tl = events.map((e, i) => {
      const lab = LABEL[e.event] || [e.event, '']; const cls = e.event === 'DECLINED' ? 'bad' : e.event === 'REFERRED' || e.event === 'DOCUMENTS_INCOMPLETE' ? 'stop' : 'done';
      return `<li class="${cls}"><span class="t">${when(e.at)}</span><h4>${esc(lab[0])}<span class="ev">${esc(e.event)}</span></h4><p>${esc(lab[1])}</p></li>`;
    }).join('') + (!finished && last && NEXT[last.event] && !(last.event === 'DOCUMENTS_INCOMPLETE' && notified) ? `<li class="now"><span class="t">now</span><h4>${esc(NEXT[last.event])}…</h4><p>This page updates by itself.</p></li>` : '')
      + (v.stage === 'DOCUMENTS_INCOMPLETE' ? '<li class="wait"><span class="t">next</span><h4>Add the missing file and resubmit</h4><p>Your application keeps its reference.</p></li>' : '');
    const docs = v.documents.map((d) => `<tr><td class="mono">${esc(d.fileName)}</td><td>${esc((d.docType || '').replace(/_/g, ' ').toLowerCase())}</td><td>${d.status === 'ACCEPTED' ? '<span class="state s-ok">Accepted</span>' : d.status === 'QUARANTINED' ? '<span class="state s-bad">Refused</span>' : `<span class="state s-idle">${esc(d.status.toLowerCase())}</span>`}${d.reason ? ` <span class="small muted">${esc(d.reason)}</span>` : ''}</td></tr>`).join('');
    $('#trk').innerHTML = `<div class="title-row"><div><h1>${v.product === 'HL' ? 'Home loan' : 'Personal loan'}</h1><p class="muted">${inr(v.amount)} over ${tenText(v.tenure)} · applied ${when(v.createdAt)}</p></div><div style="text-align:right">${stageChip(v.stage)}<div class="live${finished ? ' off' : ''}" style="margin-top:8px">${finished ? 'Complete' : 'Live'}</div></div></div>
      <div class="grid-tr"><div class="stack">
        <div class="panel"><div class="ph"><h3>Progress ${req('AC15')}</h3><span class="small muted">${events.length} step${events.length === 1 ? '' : 's'} recorded</span></div><div class="pb"><ul class="timeline">${tl}</ul></div></div>
        <div class="panel"><div class="ph"><h3>Your documents ${req('FR11')}</h3></div><div class="tw"><table><thead><tr><th>File</th><th>Type</th><th>Result</th></tr></thead><tbody>${docs || '<tr><td colspan="3" class="muted">Documents appear here once verification starts.</td></tr>'}</tbody></table></div></div>
      </div><div class="stack" id="side">${decisionHtml(v)}<div id="mailBox"></div></div></div>`;
    paintTextures($('#trk')); wireSide(v); drawMail();
    seenEvents = events.length;
  };

  function decisionHtml(v) {
    const d = v.decision;
    if (v.stage === 'DOCUMENTS_INCOMPLETE') {
      const n = v.needed || {};
      const rows = (n.missing || []).map((m) => `<tr><td>${esc(m.docType.replace(/_/g, ' ').toLowerCase())}</td><td class="r">${m.required}</td><td class="r"><b>${m.found}</b></td></tr>`).join('');
      const files = (n.missingFiles || []).map((f) => `<span class="mono">${esc(f.fileName)}</span>`).join(', ');
      const bad = (n.quarantined || []).map((f) => `<li><span class="mono">${esc(f.fileName)}</span>: ${esc(f.reason || 'refused')}</li>`).join('');
      return `<div class="plain info-b"><span class="state s-info">Documents missing</span><h2>We need ${(n.missing || []).length > 1 ? 'more documents' : 'one more document'}</h2>
        ${rows ? `<table style="margin-top:8px"><thead><tr><th>Type</th><th class="r">Required</th><th class="r">Found</th></tr></thead><tbody>${rows}</tbody></table>` : ''}
        ${files ? `<p class="muted" style="margin-top:12px">Expected but not found: ${files}</p>` : ''}${bad ? `<ul class="small" style="margin:10px 0 0;padding-left:18px">${bad}</ul>` : ''}
        <p class="muted" style="margin-top:12px">Add the missing file as a PDF, JPG or PNG. Your other files are already accepted and will not be checked again. ${req('FR10')}</p>
        <div class="drop" style="margin-top:14px"><label for="fix" style="cursor:pointer"><b>Choose the missing file</b></label><input id="fix" type="file" multiple accept=".pdf,.jpg,.jpeg,.png" style="position:absolute;left:-9999px"><div class="small" id="fixNames" style="margin-top:6px"></div></div>
        <div id="fixAlert" style="margin-top:12px"></div>
        <div class="actions" style="margin-top:14px"><button class="btn" id="fixGo" type="button">Upload and resubmit</button>${v.stage === 'DOCUMENTS_INCOMPLETE' ? '<button class="btn ghost" id="fixSample" type="button">Use a sample file (demo)</button>' : ''}</div></div>`;
    }
    if (!d) return `<div class="plain wait-b"><span class="state s-info">In progress</span><h2>${v.stage === 'RECEIVED' ? 'We have your application' : 'Your application is being processed'}</h2><p class="muted">The decision appears here as soon as it is reached. Nothing else is needed from you.</p></div>`;
    if (d.outcome === 'APPROVED') {
      return `<div class="letter"><div class="wave"><svg preserveAspectRatio="none" data-wave></svg></div><div class="body"><svg class="guil" data-guil viewBox="-250 -250 500 500" aria-hidden="true"></svg>
        <div style="display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;align-items:flex-start;position:relative"><div><span class="eyebrow">Offer letter ${req('FR16')}</span><div class="amount">${inr(d.approvedAmount)}</div><div class="muted">over ${tenText(d.approvedTenure)}${d.reduced ? ` · you asked for ${inr(v.amount)}` : ''}</div></div><span class="stamp">Valid until ${day(d.offerExpiresAt)}</span></div>
        <dl class="kv" style="margin-top:18px;position:relative"><dt>Interest rate</dt><dd>${Number(d.ratePct).toFixed(2)}% a year</dd><dt>Monthly instalment</dt><dd><b>${inr(d.instalment, 2)}</b></dd><dt>Offer valid for</dt><dd>30 days from the decision</dd><dt>Reference</dt><dd class="mono">${esc(v.applicationId)}</dd></dl>
        ${d.reduced ? `<div class="notice" style="margin-top:16px"><b>Why the amount is lower.</b> ${esc(d.reasons.find((x) => /reduced/i.test(x)) || 'The instalment must stay within half of your income after existing payments.')} ${req('N18')}</div>` : ''}
        <p class="small muted" style="margin-top:14px;position:relative">Next steps: accept within 30 days and we will contact you to complete the agreement.</p></div><div class="wave"><svg preserveAspectRatio="none" data-wave></svg></div></div>`;
    }
    if (d.outcome === 'REFERRED') return `<div class="plain warn-b"><span class="state s-warn">Under review</span><h2>A specialist will review your application</h2><p class="muted">Your documents are in order. ${esc(d.reasons[0] || 'Your application needs a person to look at it before we can decide.')}</p><dl class="kv" style="margin-top:18px"><dt>Expected answer</dt><dd>Within 3 working days</dd><dt>How you will hear</dt><dd>By email, with the decision and its reasons</dd><dt>Reference</dt><dd class="mono">${esc(v.applicationId)}</dd></dl></div>`;
    return `<div class="plain bad-b"><span class="state s-bad">Not approved</span><h2>We cannot offer this loan right now</h2><p class="muted">These are the main reasons, in plain words:</p><ul style="margin:10px 0 0;padding-left:18px">${d.reasons.map((x) => `<li>${esc(x)}</li>`).join('') || '<li>Your application did not meet our lending criteria.</li>'}</ul><div class="notice" style="margin-top:16px"><b>You can ask for a review.</b> Write to loan.review@marigold.example within 30 days and quote your reference. ${req('FR19')}</div></div>`;
  }

  function wireSide(v) {
    const fix = $('#fix'); if (!fix) return;
    fix.addEventListener('change', (e) => { picked = Array.from(e.target.files); $('#fixNames').textContent = picked.map((f) => f.name).join(', '); });
    $('#fixNames').textContent = picked.map((f) => f.name).join(', ');
    const go = async (fileList) => {
      if (busy) return; if (!fileList.length) { $('#fixAlert').innerHTML = '<div class="alert bad">Choose the missing file first.</div>'; return; }
      busy = true; $('#fixGo').disabled = true;
      const fd = new FormData(); fileList.forEach((f, i) => fd.append('f' + i, f, f.name));
      const up = await api('POST', `/api/applications/${id}/documents`, { form: fd });
      if (up.status !== 201) {
        busy = false; $('#fixGo').disabled = false;
        const files = up.data && up.data.details && up.data.details.files ? `<ul>${up.data.details.files.filter((f) => f.message).map((f) => `<li><span class="mono">${esc(f.file)}</span>: ${esc(f.message)}</li>`).join('')}</ul>` : '';
        $('#fixAlert').innerHTML = `<div class="alert bad"><b>Nothing was stored.</b> ${up.status === 422 ? 'Fix the files below and try again.' : esc((up.data && up.data.message) || 'The upload failed.')}${files}</div>`; return;
      }
      const rs = await api('POST', `/api/applications/${id}/resubmit`);
      busy = false; picked = [];
      if (rs.status === 202) toast('Resubmitted. Verification has started again on the same application.'); else toast((rs.data && rs.data.message) || 'Resubmit failed.', true);
      await poll();
    };
    $('#fixGo').addEventListener('click', () => go(picked));
    const s = $('#fixSample');
    if (s) s.addEventListener('click', () => {
      const need = ((v.needed && v.needed.missingFiles) || []).map((f) => f.fileName); const names = need.length ? need : ['payslip_2.pdf'];
      go(names.map((n) => new File([samplePdf(n)], n, { type: 'application/pdf' })));
    });
  }

  function drawMail() {
    const box = $('#mailBox'); if (!box) return;
    if (!mail || !mail.available) { box.innerHTML = mail && mail.checked ? '<div class="small muted">Email is delivered to the test inbox of this deployment (not shown here).</div>' : ''; return; }
    box.innerHTML = `<div class="mail"><div class="eyebrow">Emails we sent you ${req('FR19')}</div>${mail.messages.length ? mail.messages.slice(0, 4).map((m) => `<div class="m"><header><b>${esc(m.subject)}</b><span class="mono">${when(m.date)}</span></header><div class="t">${esc(m.text)}</div></div>`).join('') : '<div class="small muted" style="margin-top:6px">No email yet.</div>'}</div>`;
  }
  async function loadMail() { const r = await api('GET', `/api/applications/${id}/messages`); if (r.ok) mail = { ...r.data, checked: true }; drawMail(); }

  async function poll() {
    const r = await api('GET', `/api/applications/${id}`);
    if (!r.ok) { $('#trk').innerHTML = `<div class="alert bad">${r.status === 404 ? 'We could not find that application.' : esc((r.data && r.data.message) || 'Could not load the application.')} <a href="#/loans">Back to my loans</a></div>`; stopPolling(); return; }
    const sig = JSON.stringify([r.data.stage, r.data.events.length, r.data.documents.length, r.data.decision && r.data.decision.outcome]);
    if (poll.sig !== sig || !$('#side')) { poll.sig = sig; render(r.data); if (r.data.events.some((e) => e.event === 'NOTIFIED')) loadMail(); }
  }
  await poll(); startPolling(poll, 2500);
}
