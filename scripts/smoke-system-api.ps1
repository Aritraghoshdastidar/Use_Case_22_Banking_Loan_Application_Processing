# Live smoke test for loan-system-api. Start the stack and the app first, then run:
#   powershell -File scripts\smoke-system-api.ps1
# It creates its own test data and removes it at the end.
$ErrorActionPreference = 'Continue'
$u = 'http://localhost:8701/api'
$tmp = Join-Path $env:TEMP 'loan-smoke'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0

function Body($name, $json) { $p = Join-Path $tmp "$name.json"; [IO.File]::WriteAllText($p, $json); $p }
function Code($method, $path, $file) {
    if ($file) { curl.exe -s -o NUL -w "%{http_code}" -X $method "$u$path" -H "Content-Type: application/json" --data-binary "@$file" }
    else { curl.exe -s -o NUL -w "%{http_code}" -X $method "$u$path" }
}
function Check($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "[PASS] $name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $name (got $actual, expected $expected)" -ForegroundColor Red; $script:fail++ }
}
function Sql($q) { (docker exec loan-postgres psql -U loan -d loan -tA -c $q) -join '' }

$corr = '22222222-2222-4222-8222-222222222222'
$run = Get-Date -Format 'HHmmss'
$app = Body 'app' ('{"requestId":"SMOKE-' + $run + '","payloadHash":"hash-1","correlationId":"' + $corr + '","productCode":"PL","requestedAmount":200000,"requestedTenure":24,"applicantName":"Smoke Test","dateOfBirth":"1990-05-15","identityRef":"ABCDE1234F","email":"smoke@example.com","monthlyIncome":90000,"monthlyObligations":10000,"employmentMonths":48,"manifest":{"folder":"complete-ok","documentCount":4,"documents":[]}}')
$app2 = Body 'app2' ((Get-Content $app -Raw) -replace 'hash-1', 'hash-2')

Check 'health' (Code GET '/health') 200

$created = curl.exe -s -X POST "$u/applications" -H "Content-Type: application/json" --data-binary "@$app" | ConvertFrom-Json
$id = $created.applicationId
Check 'create application' $created.created $true
Check 'duplicate, same payload' (Code POST '/applications' $app) 200
Check 'duplicate, different payload' (Code POST '/applications' $app2) 409
$got = curl.exe -s "$u/applications/$id" | ConvertFrom-Json
Check 'get application: stage' $got.stage 'RECEIVED'
Check 'get application: UTC timestamp' ($got.createdAt -match 'Z$') $true
Check 'get unknown application' (Code GET '/applications/APP-NOPE') 404

$s1 = Body 's1' ('{"toStage":"DOCUMENTS_INCOMPLETE","reason":"MISSING_TYPE","sourceApp":"smoke","correlationId":"' + $corr + '","expectedFromStage":"RECEIVED","detail":{"missing":["PAYSLIP"]}}')
Check 'stage change' (Code PUT "/applications/$id/stage" $s1) 200
Check 'stage change, stale expected stage' (Code PUT "/applications/$id/stage" $s1) 409
Check 'stage change, unknown application' (Code PUT '/applications/APP-NOPE/stage' $s1) 404

$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock { param($url, $i) curl.exe -s -o NUL -w "%{http_code}" -X POST "$url/applications/$i/resubmit" } -ArgumentList $u, $id }
$codes = ($jobs | Wait-Job | Receive-Job | Sort-Object) -join ','; $jobs | Remove-Job
Check 'two simultaneous resubmits (one wins)' $codes '202,409'
Check 'resubmit audit rows' (Sql "select count(*) from decision_audit where application_id='$id' and event='RESUBMITTED'") 1
Check 'resubmit while VERIFYING' (Code POST "/applications/$id/resubmit") 409
Check 'resubmit unknown application' (Code POST '/applications/APP-NOPE/resubmit') 404

$pending = curl.exe -s "$u/outbox/pending?limit=50" | ConvertFrom-Json
$mine = @($pending | Where-Object { $_.payload.applicationId -eq $id })
Check 'outbox has create + resubmit messages' $mine.Count 2
$mid = $mine[0].messageId
Check 'mark failed' (Code POST "/outbox/$mid/failed" (Body 'fail' '{"error":"broker unavailable"}')) 204
Check 'mark sent' (Code POST "/outbox/$mid/sent") 204
Check 'mark sent again' (Code POST "/outbox/$mid/sent") 204
Check 'mark sent, unknown id' (Code POST '/outbox/99999999-9999-4999-8999-999999999999/sent') 404
Check 'mark sent, malformed id' (Code POST '/outbox/not-a-uuid/sent') 400

$claim = Body 'claim' '{"consumer":"smoke","messageId":"11111111-1111-4111-8111-111111111111"}'
Check 'claim message' (Code POST '/processed-messages' $claim) 201
Check 'claim again (redelivery)' (Code POST '/processed-messages' $claim) 409
Check 'release claim' (Code DELETE '/processed-messages/smoke/11111111-1111-4111-8111-111111111111') 204
Check 'claim after release' (Code POST '/processed-messages' $claim) 201
Check 'release again' (Code DELETE '/processed-messages/smoke/11111111-1111-4111-8111-111111111111') 204
Check 'claim, malformed id' (Code POST '/processed-messages' (Body 'claimbad' '{"consumer":"smoke","messageId":"nope"}')) 400

$aud = Body 'aud' ('{"applicationId":"' + $id + '","correlationId":"' + $corr + '","event":"NOTIFIED","sourceApp":"smoke","detail":{"template":"DOCUMENTS_MISSING"}}')
Check 'append audit event' (Code POST '/audit/events' $aud) 201
Check 'append audit event, unknown application' (Code POST '/audit/events' (Body 'aud2' ('{"applicationId":"APP-NOPE","correlationId":"' + $corr + '","event":"X","sourceApp":"smoke"}'))) 404
$trail = curl.exe -s "$u/applications/$id/audit" | ConvertFrom-Json
Check 'audit trail order' (($trail.events | ForEach-Object { $_.event }) -join '>') 'RECEIVED>DOCUMENTS_INCOMPLETE>RESUBMITTED>NOTIFIED'
Check 'audit trail, unknown application' (Code GET '/applications/APP-NOPE/audit') 404

# cleanup: the audit table is append-only, so lift the trigger for the test rows only
docker exec loan-postgres psql -U loan -d loan -c "alter table decision_audit disable trigger trg_decision_audit_immutable" -c "delete from decision_audit where application_id='$id'" -c "alter table decision_audit enable trigger trg_decision_audit_immutable" -c "delete from outbox where payload->>'applicationId'='$id'" -c "delete from processed_messages where consumer='smoke'" -c "delete from applications where application_id='$id'" *> $null

if ($fail -eq 0) { Write-Host "`nSmoke test: ALL PASSED" -ForegroundColor Green } else { Write-Host "`nSmoke test: $fail FAILED" -ForegroundColor Red }
exit $fail
