# Negative scenarios covered

Requirement 25 of the negative scenarios asks for any additional scenario relevant to the implementation to be covered and documented in the submission. This page lists the 24 required scenarios and the additional ones, with the behaviour and where it is checked.

Test names: **unit** means an MUnit test in the app named, **live** means a script in `scripts` that runs the real chain against the Docker stack.

## The 24 required scenarios

| # | Scenario | Behaviour | Checked in |
|---|---|---|---|
| 1 | Missing mandatory field | 400 with a list of the failing fields | unit (intake), live `smoke-intake` |
| 2 | Unknown product | 422, never scored against a default policy | unit (intake), live `smoke-intake` |
| 3 | Amount or tenure outside limits | 422 stating the limits | unit (intake), live `smoke-intake` |
| 4 | Ineligible age | Declined by hard rule HP-01, age at maturity recorded | unit (scoring), live `smoke-scoring` (home loan ending at 76 against 70) |
| 5 | Duplicate submission | Same application id returned, one application | unit (intake), live `smoke-intake` |
| 6 | Staging folder absent | `DOCUMENTS_INCOMPLETE`, reason `FOLDER_NOT_FOUND`, no retry loop | unit (document), live `smoke-document` |
| 7 | Empty staging folder | Every required type reported missing, full list emailed | unit (document, notification), live `smoke-document` |
| 8 | Required type missing | Names the type, the required count and the found count in the record and the email | unit, live `smoke-document`, `smoke-email` |
| 9 | Oversized document | Quarantined as `FILE_TOO_LARGE`, judged from metadata, never read in full | unit, live `smoke-document` (no digest is ever computed for it) |
| 10 | Unsupported type | Quarantined as `UNSUPPORTED_TYPE`, including an executable renamed to `.pdf` | unit, live `smoke-document` |
| 11 | Zero length or unreadable document | Quarantined as `EMPTY_OR_UNREADABLE` (empty, or a PDF with no end marker) | unit, live `smoke-document` |
| 12 | Manifest mismatch | A different declared count or checksum gives `MANIFEST_MISMATCH`, nothing moved, nothing scored | unit, live `smoke-document` |
| 13 | Unexpected extra files | Recorded as `UNEXPECTED`, ignored, never block | unit, live `smoke-document` |
| 14 | Document still being uploaded | Not checked until older than the quiet period and unchanged in size; otherwise a temporary error retried at 2, 4, 8 seconds | unit, live (freshly uploaded files in `smoke-document` and `smoke-resilience`) |
| 15 | Resubmission | Same application resumes, accepted files are reused and not re-quarantined, ends in a decision and an email | unit, live `smoke-resilience` part 1 |
| 16 | Duplicate document content | Detected by SHA-256 and counted once | unit, live `smoke-document` |
| 17 | Bureau unavailable | `REFERRED` with `DATA_UNAVAILABLE`, never an approval; both "no record" and "switched off" | unit, live `smoke-scoring` |
| 18 | Affordability breach | Approved at a reduced amount with the reason stated, or declined by HP-03 | unit, live `smoke-scoring`, `smoke-email` |
| 19 | Hard rule overrides a high score | Score 100 with an active default is declined, HP-02 is the deciding rule | unit, live `smoke-scoring` |
| 20 | Redelivered scoring message | One decision, one set of rule hits, one applicant email, after 20 deliveries | live `smoke-scoring`, `smoke-email` |
| 21 | Redelivered decision message | One email, stored decision unchanged, after 20 deliveries | live `smoke-email` |
| 22 | Broker unavailable | The application is still accepted, its message waits in the outbox with the failure recorded, and it is published once when the broker returns; the queue listeners reconnect on their own | live `smoke-resilience` part 3 |
| 23 | SMTP unavailable | Decision and audit kept, only the notification retried with growing waits, alert raised, never rescored | live `smoke-email` |
| 24 | Sensitive data exposure | No identity number, income figure, email address or document content in any log; the decline email gives reasons without scores or rule ids | live `smoke-scoring`, `smoke-email` (log scans) |

## Additional scenarios

| Scenario | Behaviour | Checked in |
|---|---|---|
| Path traversal in the manifest folder (`../x`, a leading `/`, a backslash) | Rejected at intake with 400; the document app also refuses to list it | unit (intake, document), live `smoke-intake` |
| Same request id with a different payload | 409, the original application is untouched | unit, live `smoke-intake` |
| Database down during submission | 503, nothing recorded, never a false 202; recovers when the database returns | live `smoke-intake` (`-WithOutage`) |
| Two resubmissions at the same moment | One wins, the other gets 409 | live `smoke-system-api` |
| Message that is not valid JSON, or has no application id, or is the wrong type | Dead-lettered at once as poison, never retried | unit (all consumers), live `smoke-notification` |
| Decision or score message for an application that does not exist | Dead-lettered after one attempt, claim released so it can be replayed | unit, live `smoke-notification` |
| Dead-letter publish itself fails | The message is rejected back onto the queue, never lost | unit (all consumers) |
| Claim cannot be released | Logged with the manual step, the dead-letter step still completes | unit (all consumers) |
| Temporary failure of a dependency | Retried after 2, 4 and 8 seconds, then dead-lettered with the reason | unit (all consumers) |
| Application already past the stage a message is for | The late or repeated message is skipped without a call | unit (document, scoring, notification) |
| File in a sub-folder of the applicant folder | Treated as unexpected, never as a document | unit (document) |
| File that vanishes between listing and reading | Quarantined as unreadable | unit (document) |
| Manifest names a file that is not in the folder | Reported as missing | unit, live `smoke-document` |
| Manifest type not on the product checklist | The file counts as unexpected | unit (document) |
| Net income of zero or less | HP-03, and no affordability ratio is invented | unit (scoring) |
| Score exactly on a band threshold | Inclusive at the lower edge of each band (70 approves, 50 refers) | unit (scoring) |
| Product checklist changed in the database | Followed with no redeployment, after the 60 second cache | live `smoke-resilience` part 2 |
| Failure to record that an email was sent | The message is retried; the email may repeat but is never lost | unit (notification) |
| Notification gives up after repeated failures | Becomes `FAILED` and an alert is logged | unit (notification) |
| Message broker restarts while apps are running | All queue listeners reconnect without a restart | live `smoke-resilience` part 3 |
| Sweep still running when the next one is due | The outbox sweep is a batch job; a lock in the object store makes the next tick skip the read, so a row is not published twice. The lock expires by itself if the app dies mid-sweep | unit (notification) |
| A dependency fails inside an app | Answered 503 (system API, broker, object store, mail server) or 500, with the error type and correlation id logged and no dependency message in the response | unit (all five apps) |
| Bureau address in an error message | Identity numbers are masked in failure text and the HTTP request log line is switched off | unit, live log scans |
| Upload with one bad file among good ones | The whole upload is refused with 422 and a reason per file; the good files are not stored either | unit (document, `upload-test-suite`), live `smoke-upload` |
| Upload: renamed program, cut-off file, empty file, oversized file, wrong declared type, duplicate content | Each gets its own reason (`UNSUPPORTED_TYPE`, `EMPTY_OR_UNREADABLE`, `FILE_TOO_LARGE`, `DUPLICATE_CONTENT`) and a plain-language message, before anything is stored | unit (twelve files in one request), live `smoke-upload` |
| Upload with an unsafe file name (spaces, path separators, `..`) | Refused as `UNSUPPORTED_TYPE`; a client-side path is stripped, so a name can never leave the folder | unit (document) |
| Upload with a bad folder name, a missing or lower-case product, an unknown product, or no file part | 400 with `INVALID_FOLDER`, `INVALID_PRODUCT`, `UNKNOWN_PRODUCT` or `NO_FILES`; the store is not touched | unit, live `smoke-upload` |
| Upload that would put more than 20 files in one folder | 422 `TOO_MANY_FILES`; re-uploading an existing name does not count twice | unit (document) |
| Missing document supplied later through the upload endpoint | Stored in the same folder; resubmitting resumes the same application to a decision | live `smoke-upload` part 3 |
| Many simultaneous saves of a document inventory | Twenty at once all succeed: the existence check and the writes share one transaction, so no request holds two database connections | live `smoke-system-api` |
| Call to a public API with no credentials, wrong credentials, or too fast | 401 without or with wrong `client_id`/`client_secret`; spike control above the configured rate; the health check is not governed | live on CloudHub (API Manager policies on the intake and document upload APIs) |

## How to repeat them

```
docker compose up -d
powershell -File scripts\run-chain.ps1       # starts the five apps
powershell -File scripts\run-all-munit.ps1   # every unit test, with coverage
powershell -File scripts\smoke-document.ps1
powershell -File scripts\smoke-scoring.ps1
powershell -File scripts\smoke-email.ps1
powershell -File scripts\smoke-resilience.ps1
powershell -File scripts\smoke-upload.ps1
```
