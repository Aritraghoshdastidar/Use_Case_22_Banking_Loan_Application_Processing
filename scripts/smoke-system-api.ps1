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

# ---- reference data
$pl = curl.exe -s "$u/products/PL" | ConvertFrom-Json
Check 'get product PL: max amount' $pl.maxAmount 1000000
Check 'get product HL' (Code GET '/products/HL') 200
Check 'get unknown product' (Code GET '/products/XX') 404
$rules = curl.exe -s "$u/products/PL/document-rules" | ConvertFrom-Json
Check 'PL needs 2 payslips' (($rules.rules | Where-Object { $_.docType -eq 'PAYSLIP' }).requiredCount) 2
Check 'document rules, unknown product' (Code GET '/products/XX/document-rules') 404
$sc = curl.exe -s "$u/scorecards/active" | ConvertFrom-Json
Check 'active scorecard version' $sc.version 'SC-1.0'
Check 'active scorecard has 5 factors' @($sc.factors).Count 5
Check 'factor weights add up to 100' (($sc.factors | Measure-Object -Property weight -Sum).Sum) 100

# ---- document inventory
$docs = Body 'docs' '{"documents":[{"docType":"PAYSLIP","fileName":"p1.pdf","status":"ACCEPTED","sizeBytes":224,"sha256":"aaa","sourcePath":"staging/smoke/p1.pdf","storedPath":"verified/smoke/p1.pdf"},{"docType":"PAYSLIP","fileName":"p2.pdf","status":"QUARANTINED","reason":"FILE_TOO_LARGE","sizeBytes":3105617,"sha256":"bbb","sourcePath":"staging/smoke/p2.pdf"},{"fileName":"notes.txt","status":"UNEXPECTED","sourcePath":"staging/smoke/notes.txt"}]}'
Check 'save document inventory' (Code PUT "/applications/$id/documents" $docs) 200
Check 'save document inventory again (upsert)' (Code PUT "/applications/$id/documents" $docs) 200
$withDocs = curl.exe -s "$u/applications/$id" | ConvertFrom-Json
Check 'inventory has 3 files, no duplicates' @($withDocs.documents).Count 3
Check 'quarantined file keeps its reason' (($withDocs.documents | Where-Object { $_.status -eq 'QUARANTINED' }).reason) 'FILE_TOO_LARGE'
Check 'inventory for unknown application' (Code PUT '/applications/APP-NOPE/documents' $docs) 404

# ---- decision (the test application is moved to SCORING first, as the scoring app would)
$toScoring = Body 'toscoring' ('{"toStage":"SCORING","sourceApp":"smoke","correlationId":"' + $corr + '"}')
Check 'move to SCORING' (Code PUT "/applications/$id/stage" $toScoring) 200
$dec = Body 'dec' ('{"decision":"APPROVED","score":81.5,"scorecardVersion":"SC-1.0","reasonCodes":["BAND_APPROVE","AFFORDABILITY_REDUCED"],"requestedAmount":200000,"approvedAmount":180000,"approvedTenure":24,"approvedRatePct":12,"instalment":8472.5,"affordabilityRatio":0.4,"reductionReason":"AFFORDABILITY_REDUCED","offerExpiresAt":"2026-12-05T10:00:00Z","correlationId":"' + $corr + '","sourceApp":"smoke","ruleHits":[{"ruleCode":"BUREAU_SCORE","ruleType":"FACTOR","inputValue":780,"weight":35,"points":100,"contribution":35},{"ruleCode":"HP-02","ruleType":"HARD_RULE","triggered":false}]}')
Check 'save decision' (Code POST "/applications/$id/decision" $dec) 201
Check 'save decision again (redelivery)' (Code POST "/applications/$id/decision" $dec) 200
$decided = curl.exe -s "$u/applications/$id" | ConvertFrom-Json
Check 'application stage follows the decision' $decided.stage 'APPROVED'
Check 'decision keeps scorecard version' $decided.decision.scorecardVersion 'SC-1.0'
Check 'decision has both reason codes' @($decided.decision.reasonCodes).Count 2
Check 'decision has 2 rule hits' @($decided.decision.ruleHits).Count 2
Check 'offer expiry is UTC' ($decided.decision.offerExpiresAt -match 'Z$') $true
Check 'one decision row only' (Sql "select count(*) from credit_decisions where application_id='$id'") 1
Check 'one DECISION_READY message queued' (Sql "select count(*) from outbox where payload->>'applicationId'='$id' and payload->>'type'='DECISION_READY'") 1
Check 'decision for unknown application' (Code POST '/applications/APP-NOPE/decision' $dec) 404
$fresh = curl.exe -s -X POST "$u/applications" -H "Content-Type: application/json" --data-binary "@$(Body 'app3' ((Get-Content $app -Raw) -replace 'SMOKE-', 'SMOKE3-'))" | ConvertFrom-Json
Check 'decision for application not in SCORING' (Code POST "/applications/$($fresh.applicationId)/decision" $dec) 409
Check 'move second application to SCORING' (Code PUT "/applications/$($fresh.applicationId)/stage" $toScoring) 200
$decl = Body 'decl' ('{"decision":"DECLINED","score":41.5,"scorecardVersion":"SC-1.0","decidingRule":"HP-02","reasonCodes":["HP-02"],"requestedAmount":200000,"correlationId":"' + $corr + '","sourceApp":"smoke","ruleHits":[{"ruleCode":"HP-02","ruleType":"HARD_RULE","triggered":true}]}')
Check 'save a decline that has no approved terms' (Code POST "/applications/$($fresh.applicationId)/decision" $decl) 201
$declined = curl.exe -s "$u/applications/$($fresh.applicationId)" | ConvertFrom-Json
Check 'declined application stage' $declined.stage 'DECLINED'
Check 'decline keeps the deciding rule' $declined.decision.decidingRule 'HP-02'
Check 'decline has no approved amount' ($null -eq $declined.decision.approvedAmount) $true
Check 'decline has no offer expiry' ($null -eq $declined.decision.offerExpiresAt) $true

# ---- bureau mock and its switch
$rep = curl.exe -s "$u/bureau/reports/ABCDE1234F" | ConvertFrom-Json
Check 'bureau report score' $rep.bureauScore 780
$def = curl.exe -s "$u/bureau/reports/RSTUV3456W" | ConvertFrom-Json
Check 'bureau report shows active default' $def.activeDefault $true
Check 'bureau report, applicant without history' (Code GET '/bureau/reports/ZZZZZ9999Z') 404
Check 'bureau switch is on' ((curl.exe -s "$u/bureau/switch" | ConvertFrom-Json).enabled) $true
Check 'turn bureau off' (Code PUT '/bureau/switch' (Body 'off' '{"enabled":false}')) 200
Check 'bureau report while off' (Code GET '/bureau/reports/ABCDE1234F') 503
Check 'turn bureau on' (Code PUT '/bureau/switch' (Body 'on' '{"enabled":true}')) 200
Check 'bureau report after switching on' (Code GET '/bureau/reports/ABCDE1234F') 200
Check 'identity number is not in the request log' ((Select-String -Path (Join-Path $env:USERPROFILE 'tools\mule-local-runtime\logs\loan-system-api.log') -Pattern 'ABCDE1234F' -Quiet)) $false

# ---- notifications
$nreq = Body 'nreq' ('{"applicationId":"' + $id + '","template":"APPROVED","round":1}')
Check 'create notification row' (Code POST '/notifications' $nreq) 201
Check 'create it again (one email per round)' (Code POST '/notifications' $nreq) 200
$nid = (Sql "select id from notifications where application_id='$id'")
Check 'one notification row only' (Sql "select count(*) from notifications where application_id='$id'") 1
Check 'notification appears as unnotified' (@(curl.exe -s "$u/notifications" | ConvertFrom-Json | Where-Object { $_.applicationId -eq $id }).Count) 1
Check 'mark retrying' (Code PUT "/notifications/$nid" (Body 'n1' '{"status":"RETRYING","lastError":"smtp down"}')) 200
Check 'mark sent' (Code PUT "/notifications/$nid" (Body 'n2' '{"status":"SENT"}')) 200
Check 'sent notification leaves the unnotified list' (@(curl.exe -s "$u/notifications" | ConvertFrom-Json | Where-Object { $_.applicationId -eq $id }).Count) 0
Check 'attempts counted' (Sql "select attempts from notifications where id=$nid") 2
Check 'notification for unknown application' (Code POST '/notifications' (Body 'n3' '{"applicationId":"APP-NOPE","template":"APPROVED","round":1}')) 404
Check 'update unknown notification' (Code PUT '/notifications/999999' (Body 'n4' '{"status":"SENT"}')) 404
Check 'update notification, malformed id' (Code PUT '/notifications/abc' (Body 'n5' '{"status":"SENT"}')) 400

# ---- application list
# the list is oldest first and capped at 500, so ask for the largest page: a database that has seen many test runs holds more than 50 approved applications
$list = curl.exe -s "$u/applications?stage=APPROVED&limit=500" | ConvertFrom-Json
Check 'list by stage finds the application' @($list | Where-Object { $_.applicationId -eq $id }).Count 1
Check 'list entry has an age' ((@($list | Where-Object { $_.applicationId -eq $id })[0].ageMinutes) -ge 0) $true

# cleanup: the audit table is append-only, so lift the trigger for the test rows only
$ids = "'$id','$($fresh.applicationId)'"
docker exec loan-postgres psql -U loan -d loan -c "alter table decision_audit disable trigger trg_decision_audit_immutable" -c "delete from decision_audit where application_id in ($ids)" -c "alter table decision_audit enable trigger trg_decision_audit_immutable" -c "delete from decision_rule_hits where application_id in ($ids)" -c "delete from credit_decisions where application_id in ($ids)" -c "delete from application_documents where application_id in ($ids)" -c "delete from notifications where application_id in ($ids)" -c "delete from outbox where payload->>'applicationId' in ($ids)" -c "delete from processed_messages where consumer='smoke'" -c "delete from applications where application_id in ($ids)" -c "update system_flags set flag_value='true' where flag_key='bureau_enabled'" *> $null

if ($fail -eq 0) { Write-Host "`nSmoke test: ALL PASSED" -ForegroundColor Green } else { Write-Host "`nSmoke test: $fail FAILED" -ForegroundColor Red }
exit $fail
