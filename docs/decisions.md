# Decisions (Phase 0)

Date: 2026-11-04. Author: Aritra. Source of truth: the problem-statement PDF; the team plan is the design built on it.

## Environment
| Item | Decision |
|---|---|
| Studio | Anypoint Studio 7.28 at `C:\AnypointStudio` |
| Mule runtime | 4.12 EE (bundled with Studio, plugin `org.mule.tooling.server.4.12.ee`). Pin `app.runtime` / `minMuleVersion` to 4.12.x in every app |
| JDK (Studio) | Studio bundles Temurin 17.0.12 and runs apps with it. Compile target 17 |
| JDK (CLI) | **17**, not 21. Tested in Phase 2: the Mule Validation module rejects Java 21 ("supports 1.8, 11, 17, 25"). Always build via `scripts\mvn.ps1`, which uses Studio's bundled Temurin 17 |
| Pinned versions | Mule runtime 4.12.3 (`app.runtime`), mule-maven-plugin 4.10.3, HTTP 1.12.2, APIkit 1.13.4, Database 1.16.3, Validation 2.0.10, Secure Properties 1.3.1, MUnit 3.7.5, PostgreSQL JDBC 42.7.4 |
| IDE | Anypoint Code Builder (VS Code) for the Mule projects |
| Secrets (local) | `secure-local.yaml` holds values encrypted with the Mule Secure Properties tool (AES/CBC, 16-char key passed at run time as `secure.key`). Tool jar is kept outside the repo at `C:\Users\aritr\tools\secure-props\`. Cloud uses a different key set in Runtime Manager |
| Maven | 3.9.9 at `C:\Users\aritr\tools\apache-maven-3.9.9` (not on PATH yet; scripts set `JAVA_HOME` and call it by full path) |
| Docker | 29.9.2, stack in Phase 1 |
| PDF tooling | Poppler (`pdftotext`) via winget |
| Anypoint Code Builder / Design Center | Not used |

## Anypoint trial capacity (from screenshot)
- Sandbox: 1 vCore. Production: 0. Design: 1. VPC / Private Spaces: 0, so **CloudHub 1.0 only**.
- 5 apps fit at 0.1 to 0.2 vCore each (about 0.6 total). System API and document-proc get 0.2, others 0.1.
- Risk: small heap. Keep dependencies lean, deploy one app early (Phase 3) to test.
- 1 Small Managed Omni Gateway is available if in-app policies are blocked.

## Apps (5)
`loan-system-api`, `loan-intake-exp-api`, `loan-document-proc`, `loan-scoring-proc`, `loan-notification-proc`.

## PDF vs team plan: differences to resolve
1. FR 2 requires rejecting a **malformed identity reference**; the plan did not list it. Add in intake validation (regex on the identity reference, Phase 3).
2. FR 11 says "**move**" a verified set into the per-application folder; the plan says copy. Decision: copy to `verified/<id>` then delete from staging only after the DB inventory write succeeds (safe move). Never modify in place.
3. AC 17: all MUnit suites must pass "in one run", so we need `scripts/run-all-munit.ps1`.
4. FR 2 age range check at intake; HP-01 is age at maturity at scoring (as in the plan).
5. Everything else (21 FRs, 24 scenarios, 17 ACs, 16 standards) matches the plan.

## Local ports (Windows reserves TCP 7779-8378 on this laptop, which includes Mule's default 8081)
| Service | Port |
|---|---|
| Postgres | 5432 |
| RabbitMQ AMQP / UI | 5672 / 15672 |
| MailHog SMTP / UI | 1025 / 8625 |
| MinIO S3 / console | 9000 / 9001 |
| Mule apps (HTTP listeners) | system 8701, intake 8702, document 8703, scoring 8704, notification 8705 |

## Docker images
- MinIO: official `minio/minio` images are no longer pullable here. Using `bitnamilegacy/minio` (local dev only, unmaintained mirror). Cloud uses a real S3 bucket anyway.
- SFTP fallback image `atmoz/sftp:alpine` available under compose profile `sftp`.

## Still open (decide in the phase where it first matters)
- Document store: **MinIO/S3 locally + S3-compatible on cloud** (leaning), or SFTP. Decide in Phase 1 by spiking the Mule S3 connector against MinIO with a custom endpoint.
- Appendix numbers (products, SC-1.0 scorecard, retry 2/4/8 s, 30-day offer): accepted as proposed; frozen in `db/seed.sql` in Phase 1.
- Outbox pattern: each app writes to `outbox` via the system API; a scheduler publishes.
