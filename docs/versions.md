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

## Not pinned yet (do not add these dependencies until a version is recorded here)
| Item | Status |
|---|---|
| AMQP (RabbitMQ) connector | to be tested and pinned |
| S3 or SFTP connector | to be tested; S3 against a MinIO custom endpoint is untested, SFTP is the fallback |
| Email (SMTP) connector | to be tested and pinned |

## Local demo values (not secrets)
- The Docker stack uses throwaway passwords that appear in `docker-compose.yml`.
- `loan-system-api` runs locally with the demo key `LocalDemoKey1234` (MUnit config in `pom.xml` and `.vscode/settings.json`). It only protects those throwaway passwords. A cloud key is never committed; it is set as an application property in Runtime Manager.

## Maven
Run Maven with JDK 17: `scripts\mvn.ps1 clean test` from an app folder (Windows).
