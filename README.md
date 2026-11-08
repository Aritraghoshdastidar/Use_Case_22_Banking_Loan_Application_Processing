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

`scripts\mvn.ps1` finds the tools itself: JDK 17 from `JDK17_HOME`, then the JDK bundled with Anypoint Studio, then the one Anypoint Code Builder installs, then a Temurin 17 under Program Files; Maven from `MAVEN_HOME`, `%USERPROFILE%\tools\apache-maven-3.9.9` or the PATH. Set the variable if your tools are somewhere else.

```powershell
docker compose up -d                        # PostgreSQL, RabbitMQ, MailHog, MinIO
powershell -File scripts\verify-phase1.ps1  # checks the stack, schema and seed data
powershell -File scripts\make-samples.ps1   # generate test documents
powershell -File scripts\upload-samples.ps1 # copy them into MinIO staging/

cd loan-system-api
..\scripts\mvn.ps1 clean test               # MUnit tests
# Run the app from the IDE (project folder opened as its own workspace root), then:
curl.exe http://localhost:8701/api/health   # {"status":"UP","database":"UP"}
cd ..
powershell -File scripts\smoke-system-api.ps1  # live check of every system API operation
```

| UI | URL | Login |
|---|---|---|
| RabbitMQ | http://localhost:15672 | loan / loan |
| MailHog | http://localhost:8625 | none |
| MinIO console | http://localhost:9001 | loan / loan-secret-123 |

Windows reserves TCP ports 7779 to 8378 on some machines, so the apps use 8701 to 8705 and the MailHog UI uses 8625.

## Run the system API on CloudHub 2.0
The system API deploys to a CloudHub 2.0 shared space with a hosted PostgreSQL (Neon needs `sslmode=require`, set through the `db.urlParams` property).

- `mule.env` selects the configuration: `local` (default) reads `config-local.yaml` and `secure-local.yaml`; `cloudhub` reads `config-cloudhub.yaml` and `secure-cloudhub.yaml`. The two cloud files are not in git. Copy `config-local.yaml`, change the database host and port and `db.urlParams`, set the listener port to `8081`, and encrypt the database password into `secure-cloudhub.yaml` with the Secure Properties tool and a key of your own.
- The `cloud` Maven profile in `pom.xml` deploys with the Mule Maven plugin. The pom's group id is the organization id, so the application is first published to Anypoint Exchange (`mvn clean deploy`), then deployed (`mvn mule:deploy -Pcloud -DmuleDeploy`) with the connected-app credentials, target, runtime (4.13.2 EDGE, Java 17) and `secure.key` passed as `-D` properties. Nothing secret is stored in the pom.
- API Manager: the RAML is published to Exchange as an API asset and registered as an API instance. `autodiscovery-cloudhub.xml` binds the app to its instance (the file is imported through `autodiscovery-${mule.env}.xml`, so local runs load an empty file). It needs the Sandbox environment client id and secret as the properties `anypoint.platform.client_id` and `anypoint.platform.client_secret`. Policy applied: spike control.
- Check it: `GET /api/health` on the public URL answers `{"status":"UP","database":"UP"}`.

## Working in this repo
- One folder per Mule app; the owner of a folder is the only one who edits it. Others send a pull request.
- `main` is the integration line. Work on short branches named `feature/<app>-<topic>` and merge by pull request.
- Contracts between apps (system API RAML, queue names and message envelope, stages, reason codes, error body) change only after agreement in the group chat, in a pull request labelled `contract`.
- Never commit `target/`, `.mule/`, `.studio/`, a real encryption key or any credential.
