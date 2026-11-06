# Pinned versions

The only source of truth for versions. Change one only through a pull request and a message in the group chat.

| Item | Version | Notes |
|---|---|---|
| Java | Temurin JDK 17 | Not 21 (the Mule Validation module rejects it) and not 25. Set `JAVA_HOME` to 17 for Maven |
| IDE | Anypoint Code Builder (VS Code) or Anypoint Studio 7.28 | Open each Mule project as its own workspace root |
| Mule runtime | 4.12.3 EE | `app.runtime` in `pom.xml`; `minMuleVersion` 4.12.0 in `mule-artifact.json` |
| Maven | 3.9.9 | |
| Mule Maven plugin | 4.10.3 | |
| HTTP connector | 1.12.2 | |
| Sockets connector | 1.2.9 | |
| APIkit | 1.13.4 | |
| Database connector | 1.16.3 | |
| Validation module | 2.0.10 | |
| Secure Properties module | 1.3.1 | |
| MUnit | 3.7.5 | runner, tools and Maven plugin |
| PostgreSQL JDBC driver | 42.7.4 | declare as a `sharedLibrary` in the Mule Maven plugin, otherwise the connector cannot see it |
| Docker images | `postgres:16-alpine`, `rabbitmq:3.13-management-alpine`, `mailhog/mailhog:v1.0.1`, `bitnamilegacy/minio:latest` | MinIO image is for local development only |

## Messaging
| Item | Version | Notes |
|---|---|---|
| AMQP (RabbitMQ) connector | 1.9.0 (`com.mulesoft.connectors:mule-amqp-connector`, classifier `mule-plugin`) | **Tested**: publish (persistent, with broker confirms), consume and manual ack against the local RabbitMQ. Downloads from the public MuleSoft repository, no Exchange login needed |
| Email connector (SMTP) | 1.8.0 (`org.mule.connectors:mule-email-connector`, classifier `mule-plugin`) | **Tested**: `email:send` through `email:smtp-config` to MailHog (localhost:1025), mail arrived with the right sender, recipient and subject. Public repository, no Exchange login needed |

Publish to the exchange `loan.exchange` (direct) with the queue name as the routing key; the connector will not accept an empty exchange name, so the nameless default exchange cannot be used. The exchange and its six bindings (three queues and three dead-letter queues) are in `docker/rabbitmq/definitions.json`. On an already-running broker that was created before this change, create them once in the RabbitMQ UI (Exchanges, then Bindings) or recreate the volume with `docker compose down -v`.

## Found but not yet tested (do not add these dependencies until tested and moved up)
| Item | Latest found | Status |
|---|---|---|
| S3 connector (`com.mulesoft.connectors:mule-amazon-s3-connector`) | 5.7.1 | untested; custom endpoint against MinIO to be checked first |
| SFTP connector (`org.mule.connectors:mule-sftp-connector`) | 2.7.3 | untested; fallback if S3 against MinIO fails |
| File connector (`org.mule.connectors:mule-file-connector`) | 1.5.6 | untested |
| Mule Maven plugin | 4.10.3 in use (4.10.4 exists) | stay on 4.10.3 |

## Local demo values (not secrets)
- The Docker stack uses throwaway passwords that appear in `docker-compose.yml`.
- `loan-system-api` runs locally with the demo key `LocalDemoKey1234` (MUnit config in `pom.xml` and `.vscode/settings.json`). It only protects those throwaway passwords. A cloud key is never committed; it is set as an application property in Runtime Manager.

## Maven
Run Maven with JDK 17: `scripts\mvn.ps1 clean test` from an app folder (Windows).
