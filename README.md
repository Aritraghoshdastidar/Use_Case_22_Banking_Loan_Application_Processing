# Loan Application Processing (MuleSoft)

Cognizant NPN Hackathon, Use Case 22: Banking Loan Application Processing.
Accept loan applications, verify the uploaded documents, score credit asynchronously, store an explainable decision, and email the applicant.

Five Mule 4 apps in three API-led layers, three queues, PostgreSQL. Design: [docs/HLD.md](docs/HLD.md). Versions: [docs/versions.md](docs/versions.md). Decisions: [docs/decisions.md](docs/decisions.md). Config pattern: [docs/config-pattern.md](docs/config-pattern.md).

| App | Layer | Port | Folder |
|---|---|---|---|
| loan-system-api | System (owns PostgreSQL, bureau mock) | 8701 | `loan-system-api/` (present) |
| loan-intake-exp-api | Experience | 8702 | `loan-intake-exp-api/` |
| loan-document-proc | Process | 8703 | `loan-document-proc/` |
| loan-scoring-proc | Process | 8704 | `loan-scoring-proc/` |
| loan-notification-proc | Process | 8705 | `loan-notification-proc/` |

## Quickstart (local, Windows)
Prerequisites: Docker Desktop, Temurin JDK 17, Maven 3.9.9, Anypoint Code Builder or Studio 7.28.

```powershell
docker compose up -d                        # PostgreSQL, RabbitMQ, MailHog, MinIO
powershell -File scripts\verify-phase1.ps1  # checks the stack, schema and seed data
powershell -File scripts\make-samples.ps1   # generate test documents
powershell -File scripts\upload-samples.ps1 # copy them into MinIO staging/

cd loan-system-api
..\scripts\mvn.ps1 clean test               # MUnit tests
# Run the app from the IDE (project folder opened as its own workspace root), then:
curl.exe http://localhost:8701/api/health   # {"status":"UP","database":"UP"}
```

| UI | URL | Login |
|---|---|---|
| RabbitMQ | http://localhost:15672 | loan / loan |
| MailHog | http://localhost:8625 | none |
| MinIO console | http://localhost:9001 | loan / loan-secret-123 |

Windows reserves TCP ports 7779 to 8378 on some machines, so the apps use 8701 to 8705 and the MailHog UI uses 8625.

## Working in this repo
- One folder per Mule app; the owner of a folder is the only one who edits it. Others send a pull request.
- `main` is the integration line. Work on short branches named `feature/<app>-<topic>` and merge by pull request.
- Contracts between apps (system API RAML, queue names and message envelope, stages, reason codes, error body) change only after agreement in the group chat, in a pull request labelled `contract`.
- Never commit `target/`, `.mule/`, `.studio/`, a real encryption key or any credential.
