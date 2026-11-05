# Configuration pattern (all apps)

Same code runs locally and on CloudHub; only the property files differ. Selected by `mule.env` (`local` or `cloudhub`).

```
src/main/resources/
  config-local.yaml        # plain, non-secret values for laptops (committed)
  config-cloudhub.yaml     # plain, non-secret values for CloudHub (committed)
  secure-local.yaml        # ENCRYPTED values: ![...] (committed)
  secure-cloudhub.yaml     # ENCRYPTED values: ![...] (committed)
  dwl/                     # DataWeave modules and transforms
```

Load order in each app's `global-config.xml`:
1. `<global-property name="mule.env" value="local"/>`
2. `<configuration-properties file="config-${mule.env}.yaml"/>`
3. `<secure-properties:config name="Secure_Props" file="secure-${mule.env}.yaml" key="${secure.key}"/>`

The encryption key `secure.key` is passed at run time (`-M-Dsecure.key=...` locally, an application property in Runtime Manager on cloud) and never committed.

## What goes where
| Plain (`config-*.yaml`) | Encrypted (`secure-*.yaml`) |
|---|---|
| hosts, ports, queue names, bucket/folder names, retry counts, thresholds, cache TTLs | db password, AMQP password, SMTP password, S3 secret key, client secrets |

## Local values (from docker-compose)
| Setting | Local value |
|---|---|
| Postgres | `localhost:5432`, db `loan`, user `loan` |
| RabbitMQ | `localhost:5672`, vhost `/`, user `loan` |
| SMTP | `localhost:1025`, no auth |
| S3 (MinIO) | `http://localhost:9000`, bucket `loan-docs`, user `loan` |

Local demo passwords are in `docker-compose.yml`; they are throwaway and exist only for the Docker stack. Mule apps still read them from `secure-local.yaml`, so the code path is identical to cloud.

## Key folders in the bucket
`staging/<applicantFolder>/`, `verified/<applicationId>/`, `quarantine/<applicationId>/`. Paths always come from properties.

## Local HTTP ports (avoid Windows-reserved 7779-8378)
system 8701, intake 8702, document 8703, scoring 8704, notification 8705. On CloudHub the port is `${https.port}`.
