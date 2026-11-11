# Sample requests for loan-intake-exp-api

One request body per scenario, with the curl command and the expected answer, so anyone can try the intake API by hand
or show it in a demo. `scripts/smoke-intake.ps1` runs the same checks automatically.

Before you start: the Docker stack, `loan-system-api` (8701) and `loan-intake-exp-api` (8702) are running, for example with
`powershell -File scripts\run-chain.ps1 -Only loan-system-api,loan-intake-exp-api`. Run the commands from the repository root.
On Windows PowerShell type `curl.exe`, not `curl`.

## Scenarios

Run them in this order: 2 and 3 reuse the request id of 1.

| # | Scenario | Body | Expected |
|---|---|---|---|
| 1 | Valid application (AC 1) | `application-valid.json` | `202`, an `applicationId` such as `APP-2026-000001`, a `statusUrl` and a `Location` header |
| 2 | Same request again (scenario 5) | `application-valid.json` | `202` with the **same** `applicationId`; still one row in `applications` |
| 3 | Same request id, different amount | `application-conflict.json` | `409`, code `CONFLICT` |
| 4 | Missing mandatory field (scenario 1) | `application-missing-amount.json` | `400`, code `BAD_REQUEST` |
| 5 | Malformed identity reference (FR 2) | `application-bad-identity.json` | `400`, `details.errors` names `applicant.identityRef` |
| 6 | Folder that escapes the upload area | `application-bad-folder.json` | `400`, `details.errors` names `documents.folder` |
| 7 | Unknown product (scenario 2) | `application-unknown-product.json` | `422`, code `UNPROCESSABLE` |
| 8 | Amount above the product limit (scenario 3) | `application-over-limit.json` | `422`, message `Amount must be between 50000 and 1000000 for product PL` |
| 9 | Applicant under 21 (FR 2) | `application-too-young.json` | `422`, `details.errors` names `applicant.dateOfBirth` |

Rejected requests (4 to 9) create nothing in the database.

Send a body (change the file name for each scenario):

```powershell
curl.exe -i -X POST http://localhost:8702/api/applications -H "Content-Type: application/json" --data-binary "@samples/intake/application-valid.json"
```

Then follow the application, using the `applicationId` from scenario 1:

```powershell
curl.exe -i http://localhost:8702/api/applications/APP-2026-000001/status
```

Expected: `200` with `stage` (`RECEIVED` at first, later `VERIFYING`, `SCORING` and the decision when the other apps run),
the document list and, once decided, the decision with its reason codes. Identity reference, income and score never appear.

Other status checks:

| Request | Expected |
|---|---|
| `GET /api/applications/APP-404/status` | `404`, code `NOT_FOUND` |
| `POST /api/applications/<id>/resubmit` for an application that is not `DOCUMENTS_INCOMPLETE` | `409`, code `CONFLICT` |

## The applicant and documents in these samples

- `ABCDE1234F` is a seeded applicant in `db/seed.sql` with a strong bureau record, so the full chain normally ends in `APPROVED`.
- `complete-ok` is the complete document set created by `scripts\make-samples.ps1` and `scripts\upload-samples.ps1`.
- Every run of scenario 1 with the same `requestId` returns the same application. To create a new one, change `requestId`.

## On CloudHub

The deployed intake API has client-id enforcement, so add the credentials of an application with a contract
(see the cloud section of the main README):

```powershell
curl.exe -i -X POST https://<intake-url>/api/applications -H "Content-Type: application/json" -H "client_id: <id>" -H "client_secret: <secret>" --data-binary "@samples/intake/application-valid.json"
```

Without the headers the answer is `401`.
