# Marigold Finance: customer portal and staff console

A real website on top of the loan system. A customer creates an account, applies, uploads documents, and watches the application move through verification, scoring and decision. Staff sign in to a console that reads the running system and acts on it. Nothing on the pages is canned: every number comes from the Mule apps, the database and the message broker.

## Run it

Needs Node 22.13 or later (no packages to install).

```powershell
cd web
npm start                     # http://localhost:3000, backend chosen automatically
$env:WEB_ENV = 'local';  npm start    # force the local stack
$env:WEB_ENV = 'cloud';  npm start    # force the CloudHub deployment
```

or, from the repository root, `powershell -File scripts\run-web.ps1 -Env cloud` (from inside `web`: `..\scripts\run-web.ps1 -Env cloud`).

- **Local** talks to the Docker stack and the five apps started by `scripts\run-chain.ps1` (ports 8701 to 8705, RabbitMQ 15672, MailHog 8625).
- **CloudHub** reads the addresses and the API client credentials from your settings file (`~/.anypoint-cloud.env`, the same one the cloud scripts use). Run `python scripts\setup-cloud.py urls` once so it knows all five addresses. The credentials stay on the server and are never sent to the browser.
- Staff can switch the environment from the bar under the header; customers always see the one the server is using.

### Accounts

- **Customers** create their own account on the site (email and password, 8 or more characters).
- **Staff** accounts are created on the first start, with random passwords, and written to `web/data/initial-credentials.txt` (git-ignored). Set `WEB_STAFF_PASSWORD` before the first start to choose one password for both. Delete `web/data/web.db` to start over.
- The loan system itself has no user accounts, so the site keeps its own small database (`web/data/web.db`, SQLite) of accounts, sessions and which application belongs to which customer.

## Put it online (Render)

The site is a small Node server, so it needs a host that runs one (Vercel and GitHub Pages serve static files only). [render.yaml](../render.yaml) describes the service for Render.

1. Run `powershell -File scripts\make-render-env.ps1`. It writes `render-web.env` in your home folder with only the settings the site needs (CloudHub addresses, API client id and secret, broker login, a staff password).
2. On render.com: New > Blueprint > pick this repository and the `frontend-web` branch. Render reads `render.yaml`.
3. When asked for the values, open Environment and use Add from .env to paste the file, then delete the file.
4. Open the address Render gives you. Staff sign in with `priya.raman@marigold.example` or `ops@marigold.example` and the staff password from the file.

The free plan has no disk and sleeps when idle: the first visit takes about half a minute, and customer accounts are lost when the service restarts (the staff accounts are created again). Use a paid plan with a disk (see the end of `render.yaml`) to keep customers. Only the CloudHub backend is available online.

## What a customer can do

1. **Apply**: details (checked on the page, then again by the intake API), documents, review, submit. The answer is a real reference with a status page.
2. **Upload documents** through the upload gate: every file is checked before it is stored, and if one fails none is kept and each file shows its plain-language reason.
3. **Watch it live**: the progress list is built from the decision audit and updates by itself; the offer letter, the reasons for a decline, or the exact list of missing documents appear as soon as they exist.
4. **Fix missing documents** on the same application: choose the file, upload and resubmit.
5. **Read the email** the system sent (Local only; on CloudHub the email goes to the test inbox of that deployment).

The apply form has a **Demo applicant** list. The test credit bureau knows those identity references, so each choice gives a different real outcome: approved, reduced offer, referred, declined, declined by a hard rule, referred because there is no credit record. The documents step has **Demo helpers** that add sample documents, a text file named like a PDF, or an empty file, so the upload checks can be shown live.

## What staff can do

- **Overview**: health of the five apps, queue depths and dead letters, outbox, decisions not yet notified, bureau switch, applications by stage, a log of what staff did.
- **Applications**: filter by stage; open one for the overview, the scorecard (factors adding up to the score, hard rules), the documents with digests, the audit trail, and the actions.
- **Act**: for an application waiting for documents, supply the file for the applicant and resubmit; for a referred one, send the underwriting digest.
- **Underwriting**: referred applications oldest first, and applications waiting for documents.
- **Pipeline**: queues, look into a dead-letter queue and replay it, see the decisions whose email has not gone out and **retry a failed email** (after five failed attempts the notification app gives up; the button sets it back to pending and the app sends it again, the decision is never touched), turn the credit bureau off and on, and (Local only) stop and start the mail server and the broker to prove that decisions are kept and accepted applications wait in the outbox.
- **Proof mode** (switch in the header): gold chips next to the parts of the screen link to the requirement they prove. Each opens the requirement, the tests that guarantee it, and the real calls this page made (status, the loan system's own status and timing, and the start of its correlation id).

Not built: a manual underwriting decision. The loan system keeps one decision per application and has no review operation to call, so the console shows referred applications and sends the digest but does not record a decision.

## Security notes

- Passwords are hashed with scrypt; sessions are random tokens in an `HttpOnly`, `SameSite=Lax` cookie (add `WEB_SECURE_COOKIE=1` behind HTTPS), stored only as hashes.
- Every state-changing call needs the site's own header and a matching `Origin`, so another site cannot post on a signed-in user's behalf.
- Customers can only open their own applications; staff routes need a staff role. Identity numbers are masked in the console, and the customer view never shows scores or rule ids.
- Login attempts are limited (8 wrong passwords in 10 minutes per address and email).
- API client credentials, broker passwords and the settings file are read on the server only.
- The server sets a strict content security policy.

## Checks

```powershell
cd web
npm run check                                   # syntax of every file
npm run smoke                                   # real accounts, uploads, applications and staff actions against the running backend
$env:CHAOS = '1'; npm run smoke                 # Local only: also stops the mail server and the broker from the console and checks recovery (about 8 minutes)
npm run ui                                      # drives headless Chrome through the whole journey and takes screenshots
```

Both tests create real customers and applications in the backend the server is using. `smoke.mjs` reads the staff passwords from `data/initial-credentials.txt` (or `STAFF_FILE`); set `BASE` to test a server on another port. `ui.mjs` needs Chrome or Edge installed and writes screenshots to `SHOTS` (default: a temp folder).

## Layout

```
server/  config.js (environments), upstream.js (Mule, broker, mail), store.js (SQLite), auth.js, domain.js, index.js (routes, static files)
client/  index.html, app.css, app.js (shell, routing, proof mode), customer.js, staff.js, util.js
test/    smoke.mjs, ui.mjs
data/    web.db and initial-credentials.txt (created on first start, git-ignored)
```
