# Loan Application Processing (MuleSoft)

Cognizant NPN Hackathon, Use Case 22: Banking Loan Application Processing.
Accept loan applications, verify the uploaded documents, score credit asynchronously, store an explainable decision, and email the applicant.

Five Mule 4 apps in three API-led layers, three queues, PostgreSQL, an S3-compatible document store and SMTP. This branch holds the complete working solution: you can run all of it on your own laptop, and deploy all of it to your own CloudHub 2.0 account.

Design: [docs/HLD.md](docs/HLD.md). Versions: [docs/versions.md](docs/versions.md). Decisions: [docs/decisions.md](docs/decisions.md). Config pattern: [docs/config-pattern.md](docs/config-pattern.md).

| App | Layer | Port | Folder | Job |
|---|---|---|---|---|
| loan-system-api | System | 8701 | `loan-system-api/` | The only app that touches PostgreSQL: applications, outbox, audit, dedupe, bureau mock |
| loan-intake-exp-api | Experience | 8702 | `loan-intake-exp-api/` | Public API. Validates, records the application, answers 202 with a status URL |
| loan-document-proc | Process | 8703 | `loan-document-proc/` | Reads the applicant's documents from the object store, validates every file, takes custody. Also offers an upload endpoint that checks files before storing them |
| loan-scoring-proc | Process | 8704 | `loan-scoring-proc/` | Scorecard SC-1.0, affordability, decision bands, hard policy rules |
| loan-notification-proc | Process | 8705 | `loan-notification-proc/` | Outbox sweeper (batch job), applicant emails, digest |

Messages travel on RabbitMQ: `loan.exchange` (direct) with `loan.verify.q`, `loan.score.q`, `loan.decision.q` and a dead-letter queue for each. Only the system API reads or writes the database.

## 1. What you need

| Need | Notes |
|---|---|
| Windows with PowerShell | The scripts are PowerShell (`.ps1`) plus two Python files |
| Docker Desktop | PostgreSQL, RabbitMQ, MailHog and MinIO run as containers |
| JDK 17 | Temurin 17. Mule 4.12 rejects 21 and 25. `scripts\mvn.ps1` looks in `JDK17_HOME`, the JDK bundled with Anypoint Studio, the one Anypoint Code Builder installs, then a Temurin 17 under Program Files |
| Maven 3.9 | In `MAVEN_HOME`, in `%USERPROFILE%\tools\apache-maven-3.9.9`, or on the PATH |
| Mule 4.12 Enterprise runtime | Installed once by running any app from Anypoint Code Builder (free Anypoint account). Set `MULE_RUNTIME_SOURCE` if it is somewhere else. `run-chain.ps1` copies it to `%USERPROFILE%\tools\mule-local-runtime` (about 450 MB) |
| Python 3 | Only for the CloudHub scripts |

Nothing secret is needed to run locally. The demo key `LocalDemoKey1234` decrypts the `secure-local.yaml` files and is passed to the runtime at start.

## 2. Run everything on your laptop

Run every command from the repository root.

```powershell
docker compose up -d                          # PostgreSQL, RabbitMQ, MailHog, MinIO
powershell -File scripts\verify-phase1.ps1    # checks the stack, schema, seed data, queues, mail, object store
powershell -File scripts\make-samples.ps1     # generate the test documents
powershell -File scripts\upload-samples.ps1   # copy them into MinIO staging/

powershell -File scripts\run-chain.ps1        # build, deploy and start all five apps in one local Mule runtime
curl.exe http://localhost:8701/api/health     # {"status":"UP","database":"UP"}
```

Stop the runtime with `powershell -File scripts\run-chain.ps1 -Stop`. `-NoBuild` starts with the jars already built. `-Only loan-system-api,loan-intake-exp-api` starts just those apps. Do not start an app from the IDE at the same time: they share the ports. Do not pipe `run-chain.ps1` into another command: the runtime keeps the pipe open and the command never returns.

### Submit an application

```powershell
$body = @'
{"requestId":"DEMO-1","productCode":"PL","amount":200000,"tenureMonths":24,
 "applicant":{"fullName":"Demo Applicant","dateOfBirth":"1990-05-15","identityRef":"ABCDE1234F","email":"demo@example.com",
 "monthlyIncome":90000,"monthlyObligations":10000,"employmentMonths":48},
 "documents":{"folder":"complete-ok","documentCount":4,"documents":[
  {"fileName":"id_proof.pdf","type":"ID_PROOF"},{"fileName":"address_proof.pdf","type":"ADDRESS_PROOF"},
  {"fileName":"payslip_1.pdf","type":"PAYSLIP"},{"fileName":"payslip_2.pdf","type":"PAYSLIP"}]}}
'@
$body | Out-File demo.json -Encoding ascii
curl.exe -s -X POST http://localhost:8702/api/applications -H "Content-Type: application/json" --data-binary "@demo.json"
curl.exe -s http://localhost:8702/api/applications/<applicationId>/status
```

Open MailHog to read the applicant's email. The sample folders (`complete-ok`, `missing-payslip` and others) come from `make-samples.ps1`. Custody moves accepted files out of staging, so run `upload-samples.ps1` again before reusing a folder.

### Optional: upload the documents through the checking endpoint

Instead of copying files into the bucket, an applicant can upload them to the document app, which checks every file **before** storing it:

```powershell
curl.exe -s -X POST "http://localhost:8703/api/staging/my-folder/documents?product=PL" `
  -F "a=@samples\documents\complete-ok\id_proof.pdf" -F "b=@samples\documents\complete-ok\address_proof.pdf" `
  -F "c=@samples\documents\complete-ok\payslip_1.pdf" -F "d=@samples\documents\complete-ok\payslip_2.pdf"
```

- All files pass: `201`, and the files are stored under `staging/my-folder/` with their own names. Submit the application with `"folder":"my-folder"`; verification runs as usual.
- Any file fails: `422` with a reason per file, and **nothing is stored**. Upload the whole set again.
- Checks, in order: safe file name, name starts with a document type of the product (`id_proof`, `address_proof`, `payslip`), not empty, size limit of that type, allowed extension, first bytes are really PDF/JPEG/PNG, extension agrees with the content, declared content type agrees, file is complete (not cut short), no duplicate content in the same upload.
- Bad requests are `400`: folder name not 3 to 64 letters, digits, `_` or `-` (`INVALID_FOLDER`); missing or malformed `product` (`INVALID_PRODUCT`); no checklist for the product (`UNKNOWN_PRODUCT`); no files (`NO_FILES`). More than `verify.maxFiles` (20) files in a folder is `422 TOO_MANY_FILES`.
- To fix a rejected set, upload again. A name that is already in the folder is replaced.
- Copying files straight into the bucket still works; the verification step after the queue runs its own checks either way.

`powershell -File scripts\smoke-upload.ps1` proves all of this live (good set approved, each bad sample refused with the right reason, nothing stored, resubmission, bad requests).

The idea of checking files before storing them comes from Member 3's Google Drive version of the document app, which proved that the storage layer can be swapped behind the same contract.

| UI | URL | Login |
|---|---|---|
| RabbitMQ | http://localhost:15672 | loan / loan |
| MailHog | http://localhost:8625 | none |
| MinIO console | http://localhost:9001 | loan / loan-secret-123 |

Windows reserves TCP ports 7779 to 8378 on some machines, so the apps use 8701 to 8705 and the MailHog UI uses 8625.

## 3. Prove it works

```powershell
powershell -File scripts\run-all-munit.ps1    # MUnit for all five apps with coverage; needs no running services
```

Expected: 386 tests, 100% application coverage on every app.

The live checks come in two groups, because the first two assume nothing downstream consumes their test data.

**Group A: only the system API and intake running.**

```powershell
powershell -File scripts\run-chain.ps1 -Stop
powershell -File scripts\run-chain.ps1 -Only loan-system-api,loan-intake-exp-api
powershell -File scripts\smoke-system-api.ps1     # every system API operation
powershell -File scripts\smoke-intake.ps1         # validation, idempotency, 202, status (-WithOutage also proves a 503 when the database is down)
powershell -File scripts\run-chain.ps1 -Stop
```

**Group B: all five apps running** (`run-chain.ps1`, then one script at a time):

| Script | What it proves |
|---|---|
| `scripts\smoke-document.ps1` | document reconciliation, per-file checks, quarantine and custody |
| `scripts\smoke-upload.ps1` | the upload endpoint: files checked before storage, 422 with nothing stored, resubmission, bad requests |
| `scripts\smoke-scoring.ps1` | scoring bands, affordability, hard rules, no sensitive data in logs |
| `scripts\smoke-notification.ps1` | the batch outbox sweep and the decision consumer |
| `scripts\smoke-email.ps1` | all four applicant emails through MailHog, retries, mail-server outage. Stops the mail server on purpose, run it alone |
| `scripts\smoke-resilience.ps1` | resume after a missing document, live checklist change, broker outage. Stops RabbitMQ on purpose, run it alone; runs less than two minutes apart interfere through the checklist caches |

## 4. Deploy it to your own CloudHub 2.0 account

Everything runs in your own accounts, with your own credentials. Nothing in this repository belongs to anyone else's account, and nobody needs to share a password: create the free accounts below and fill in one settings file.

**Accounts (all free tiers are enough)**

| Service | Used for |
|---|---|
| Anypoint Platform trial (anypoint.mulesoft.com) | CloudHub 2.0, Exchange, API Manager |
| Neon (neon.tech) | hosted PostgreSQL. Create a project, then a database called `loan` |
| CloudAMQP (cloudamqp.com), plan "Little Lemur" | hosted RabbitMQ |
| Mailtrap (mailtrap.io) Email Sandbox | catches the applicant emails |
| Backblaze B2 (backblaze.com) | S3-compatible bucket for the applicants' documents. Create a bucket and an application key limited to it |

**One-time Anypoint setup**
1. Find your organization id: Access Management > Business Groups > your organization.
2. Create a Connected App (Access Management > Connected Apps > Create app > "App acts on its own behalf"). Scopes for the Sandbox environment: Deploy Applications, Create Applications, Delete Applications, Read Applications, Download Application, Manage APIs Configuration, Manage Policies, Create Applications in Exchange, Exchange Contributor.
3. Find the environment's own client id and secret: Access Management > Environments > Sandbox. API autodiscovery uses these; the Connected App credentials are not accepted for it.
4. Download `secure-properties-tool.jar` (docs.mulesoft.com, "Secure Configuration Properties") and note its path.

**Settings file.** Copy [cloud/anypoint-cloud.env.example](cloud/anypoint-cloud.env.example) to `%USERPROFILE%\.anypoint-cloud.env` (outside the repository) and fill in every value. Choose any 16 characters for `SECURE_KEY_CLOUD`. Git ignores every `*.env` file and every generated cloud config, so the secrets cannot be committed by accident.

**Steps** (repository root)

```powershell
docker compose up -d                                  # only needed for the sample documents and the local stack
powershell -File scripts\make-samples.ps1
python scripts\setup-cloud.py db                      # schema and seed data into your hosted PostgreSQL
python scripts\setup-cloud.py broker                  # exchange, queues and bindings on your hosted RabbitMQ
python scripts\setup-cloud.py samples                 # sample documents into your bucket under staging/
python scripts\setup-cloud.py api-manager             # publish the API specs, register both APIs, apply the policies, create a demo client
powershell -File scripts\deploy-cloud.ps1 -App all    # system API first, then the other four; each deploy takes a few minutes
python scripts\cloud-e2e.py complete-ok               # APPROVED, one email, three consumer claims
python scripts\setup-cloud.py samples                 # the accepted files leave staging, so upload again
python scripts\cloud-e2e.py missing-payslip           # DOCUMENTS_INCOMPLETE, one email, two claims
```

What the scripts do:
- `setup-cloud.py config` (run for you by the deploy script) generates `config-cloudhub.yaml` from each app's `config-local.yaml` with your hosts, and `secure-cloudhub.yaml` with your passwords encrypted under your own key. The key reaches the apps as the secure property `secure.key`.
- The poms carry the placeholder `ANYPOINT-ORG-ID` as group id. The deploy script builds from a temporary copy with your organization id, publishes the application to your Exchange, then deploys that asset to the shared space.
- The runtime is 4.13.2 EDGE with Java 17 (the trial rejects 4.12). Each app uses 0.1 vCore, so all five fit in the 1 vCore of a trial Sandbox. If your shared space has another name or region, set `CLOUD_TARGET` in the settings file or pass `-Target`.
- API Manager: both APIs are tracked through autodiscovery. Policies: the intake API has client-id enforcement and spike control; the system API has spike control. A call to the public intake API needs the `client_id` and `client_secret` headers of an application with a contract; `api-manager` creates one (`loan-portal-demo`) and stores its credentials in your settings file.
- Alerts: in Runtime Manager > Alerts, create a "Deployment failed" alert for the five apps (the trial offers no other conditions).

Check a deployment by hand:

```powershell
curl.exe https://<system-api-url>/api/health                                       # {"status":"UP","database":"UP"}
curl.exe -i https://<intake-url>/api/applications/APP-1/status                     # 401 without credentials
curl.exe -i -H "client_id: <id>" -H "client_secret: <secret>" https://<intake-url>/api/applications/APP-1/status    # 404 for an unknown application
```

## 5. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Port 870x is busy` | An app runs from the IDE or from an earlier runtime. Stop it, or `run-chain.ps1 -Stop` |
| `JDK 17 not found` / `Maven 3.9 not found` / `Mule runtime not found` | Install it or set `JDK17_HOME` / `MAVEN_HOME` / `MULE_RUNTIME_SOURCE` |
| A smoke script reports `FOLDER_NOT_FOUND` or an unexpected `DOCUMENTS_INCOMPLETE` | The earlier run consumed the staging files. Run `upload-samples.ps1` again |
| Every call to a local app answers an empty 503 | The API gateway blocks an app that has an `api.id` property but no API Manager. Keep `api.id` only in `config-cloudhub.yaml` |
| A CloudHub app stays in APPLYING | Runtime Manager > the app > Logs. Autodiscovery needs the environment client id and secret and an API instance (`setup-cloud.py api-manager` before the first deploy); a policy needs an implementation for the runtime version |
| "Runtime version not supported for this target" | The trial accepts only 4.13.x EDGE and 4.9.x. Pass `-MuleVersion` |

## 6. Working in this repo
- One folder per Mule app. Work on short branches named `feature/<app>-<topic>` and merge by pull request.
- Contracts between apps (system API RAML, queue names and message envelope, stages, reason codes, error body) change only after agreement, in a pull request labelled `contract`.
- Never commit `target/`, `.mule/`, `.studio/`, a real encryption key, a settings file or any credential.
