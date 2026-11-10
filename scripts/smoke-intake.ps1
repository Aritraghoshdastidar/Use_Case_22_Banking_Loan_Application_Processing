# Live smoke test for loan-intake-exp-api (port 8702). Needs the Docker stack, the system API (8701) and the intake API running.
#   powershell -File scripts\smoke-intake.ps1               normal run
#   powershell -File scripts\smoke-intake.ps1 -WithOutage   also stops PostgreSQL for a moment to prove a 503 (never a false 202)
param([switch]$WithOutage)
$ErrorActionPreference = 'Continue'
$u = 'http://localhost:8702/api'
$sys = 'http://localhost:8701/api'
$tmp = Join-Path $env:TEMP 'loan-smoke-intake'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
$run = Get-Date -Format 'HHmmss'

function Check($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "[PASS] $name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $name (got $actual, expected $expected)" -ForegroundColor Red; $script:fail++ }
}
function Sql($q) { (docker exec loan-postgres psql -U loan -d loan -tA -c $q) -join '' }
function Post($body) {
    $f = Join-Path $tmp 'req.json'; [IO.File]::WriteAllText($f, $body)
    $r = curl.exe -s -i -X POST "$u/applications" -H "Content-Type: application/json" --data-binary "@$f"
    $text = $r -join "`n"
    $code = [int](($text -split "`n")[0] -replace '^HTTP/\S+\s+(\d+).*$', '$1')
    $json = $null; $i = $text.IndexOf("`n`n"); if ($i -lt 0) { $i = $text.IndexOf("`r`n`r`n") }
    $bodyText = ($text -split "(\r?\n){2}", 2)[-1]
    try { $json = $bodyText | ConvertFrom-Json } catch { }
    [pscustomobject]@{ Code = $code; Json = $json; Raw = $text }
}
function Request($overrides) {
    $r = @{
        requestId = "SMOKEI-$run-1"; productCode = 'PL'; amount = 200000; tenureMonths = 24
        applicant = @{ fullName = 'Smoke Intake'; dateOfBirth = '1990-05-15'; identityRef = 'ABCDE1234F'; email = 'smoke@example.com'; monthlyIncome = 90000; monthlyObligations = 10000; employmentMonths = 48 }
        documents = @{ folder = 'complete-ok'; documentCount = 4; documents = @(@{ fileName = 'id_proof.pdf'; type = 'ID_PROOF' }) }
    }
    foreach ($k in $overrides.Keys) { $r[$k] = $overrides[$k] }
    $r
}
function J($o) { $o | ConvertTo-Json -Depth 8 -Compress }

# ---- wait for both apps
for ($i = 0; $i -lt 30; $i++) { if ((curl.exe -s -o NUL -w "%{http_code}" "$sys/health") -eq '200') { break }; Start-Sleep 2 }
Check 'system API is up' (curl.exe -s -o NUL -w "%{http_code}" "$sys/health") 200

# ---- scenario 1: validation (400, field-level)
$r = Post '{}'
Check 'empty request is a 400' $r.Code 400
Check 'errors name productCode' (@($r.Json.details.errors | Where-Object { $_.field -eq 'productCode' }).Count) 1
Check 'errors name applicant.monthlyIncome' (@($r.Json.details.errors | Where-Object { $_.field -eq 'applicant.monthlyIncome' }).Count) 1
Check 'response carries a correlation id' ([bool]$r.Json.correlationId) $true
$nobody = Post (J (Request @{ amount = $null }))
Check 'missing amount is a 400' $nobody.Code 400
Check 'body that is not JSON is a 400' (Post 'this is not json').Code 400
$bad = Post (J (Request @{ applicant = @{ fullName = 'X'; dateOfBirth = '1990-05-15'; identityRef = 'abc123'; email = 'smoke@example.com'; monthlyIncome = 90000 } }))
Check 'malformed identity reference is a 400' $bad.Code 400
Check 'error points at applicant.identityRef' (@($bad.Json.details.errors | Where-Object { $_.field -eq 'applicant.identityRef' }).Count) 1
$trav = Post (J (Request @{ documents = @{ folder = '../../secret'; documentCount = 1 } }))
Check 'manifest folder escaping the staging root is a 400' $trav.Code 400
Check 'error points at documents.folder' (@($trav.Json.details.errors | Where-Object { $_.field -eq 'documents.folder' }).Count) 1

# ---- scenarios 2 and 3: product and limits (422, limits stated)
Check 'unknown product is a 422' (Post (J (Request @{ productCode = 'XX' }))).Code 422
$low = Post (J (Request @{ amount = 10000 }))
Check 'amount below the minimum is a 422' $low.Code 422
Check 'limits are stated in the message' ($low.Json.details.errors[0].message) 'Amount must be between 50000 and 1000000 for product PL'
Check 'amount above the maximum is a 422' (Post (J (Request @{ amount = 5000000 }))).Code 422
Check 'tenure outside the limits is a 422' (Post (J (Request @{ tenureMonths = 100 }))).Code 422
$young = Request @{}; $young.applicant.dateOfBirth = '2020-01-01'
Check 'applicant under 21 is a 422' (Post (J $young)).Code 422
$old = Request @{}; $old.applicant.dateOfBirth = '1950-01-01'
Check 'applicant over 60 is a 422' (Post (J $old)).Code 422
Check 'rejected requests created nothing' (Sql "select count(*) from applications where request_id like 'SMOKEI-$run%'") 0

# ---- fast acknowledgement and idempotency (scenarios 5, AC 1)
$ok = Post (J (Request @{}))
Check 'valid application is accepted with 202' $ok.Code 202
$id = $ok.Json.applicationId
Check 'response has an application id' ($id -match '^APP-\d{4}-\d{6}$') $true
Check 'response has a status URL' ($ok.Json.statusUrl -eq "http://localhost:8702/api/applications/$id/status") $true
Check 'Location header equals the status URL' ($ok.Raw -match "(?im)^location:\s*http://localhost:8702/api/applications/$id/status") $true
Check 'application row recorded in RECEIVED' (Sql "select stage from applications where application_id='$id'") 'RECEIVED'
Check 'verify message waits in the outbox' (Sql "select count(*) from outbox where payload->>'applicationId'='$id' and payload->>'type'='VERIFY_REQUESTED' and status='PENDING'") 1
Check 'RECEIVED audit row written' (Sql "select count(*) from decision_audit where application_id='$id' and event='RECEIVED'") 1
$again = Post (J (Request @{}))
Check 'duplicate submission is 202 again' $again.Code 202
Check 'duplicate returns the original application id' $again.Json.applicationId $id
Check 'still exactly one application' (Sql "select count(*) from applications where request_id='SMOKEI-$run-1'") 1
Check 'still exactly one outbox message' (Sql "select count(*) from outbox where payload->>'applicationId'='$id'") 1
$diff = Post (J (Request @{ amount = 250000 }))
Check 'same request id with a different payload is a 409' $diff.Code 409

# ---- status endpoint
$st = curl.exe -s "$u/applications/$id/status" | ConvertFrom-Json
Check 'status shows the stage' $st.stage 'RECEIVED'
Check 'status has no identity number' ($null -eq $st.identityRef) $true
Check 'status of unknown application is a 404' (curl.exe -s -o NUL -w "%{http_code}" "$u/applications/APP-NOPE/status") 404

# ---- resubmit
Check 'resubmit while RECEIVED is a 409' (curl.exe -s -o NUL -w "%{http_code}" -X POST "$u/applications/$id/resubmit") 409
Check 'resubmit of unknown application is a 404' (curl.exe -s -o NUL -w "%{http_code}" -X POST "$u/applications/APP-NOPE/resubmit") 404
$corr = '22222222-2222-4222-8222-222222222222'
$inc = Join-Path $tmp 'inc.json'; [IO.File]::WriteAllText($inc, '{"toStage":"DOCUMENTS_INCOMPLETE","reason":"MISSING_TYPE","sourceApp":"smoke","correlationId":"' + $corr + '"}')
curl.exe -s -o NUL -X PUT "$sys/applications/$id/stage" -H "Content-Type: application/json" --data-binary "@$inc"
Check 'status now shows DOCUMENTS_INCOMPLETE' ((curl.exe -s "$u/applications/$id/status" | ConvertFrom-Json).stage) 'DOCUMENTS_INCOMPLETE'
$rs = curl.exe -s -i -X POST "$u/applications/$id/resubmit"
Check 'resubmit after missing documents is 202' (($rs -join "`n") -match 'HTTP/\S+ 202') $true
Check 'status shows VERIFYING after resubmit' ((curl.exe -s "$u/applications/$id/status" | ConvertFrom-Json).stage) 'VERIFYING'
Check 'still one application after resubmit' (Sql "select count(*) from applications where request_id='SMOKEI-$run-1'") 1

# ---- decision visible through status, without scores
$sc = Join-Path $tmp 'sc.json'; [IO.File]::WriteAllText($sc, '{"toStage":"SCORING","sourceApp":"smoke","correlationId":"' + $corr + '"}')
curl.exe -s -o NUL -X PUT "$sys/applications/$id/stage" -H "Content-Type: application/json" --data-binary "@$sc"
$dec = Join-Path $tmp 'dec.json'; [IO.File]::WriteAllText($dec, '{"decision":"DECLINED","score":41.5,"scorecardVersion":"SC-1.0","decidingRule":"HP-02","reasonCodes":["HP-02"],"requestedAmount":200000,"correlationId":"' + $corr + '","sourceApp":"smoke","ruleHits":[{"ruleCode":"HP-02","ruleType":"HARD_RULE","triggered":true}]}')
curl.exe -s -o NUL -X POST "$sys/applications/$id/decision" -H "Content-Type: application/json" --data-binary "@$dec"
$final = curl.exe -s "$u/applications/$id/status" | ConvertFrom-Json
Check 'status shows the decision' $final.decision.decision 'DECLINED'
Check 'status gives the reason codes' $final.decision.reasonCodes[0] 'HP-02'
Check 'status hides the internal score' ($null -eq $final.decision.score) $true
Check 'status hides rule hits' ($null -eq $final.decision.ruleHits) $true

# ---- privacy: no identity number in the intake log
$logPath = Join-Path $env:USERPROFILE 'tools\mule-local-runtime\logs\loan-intake-exp-api.log'
if (Test-Path $logPath) { Check 'identity number is not in the intake log' (Select-String -Path $logPath -Pattern 'ABCDE1234F' -Quiet) $false }

# ---- optional: outage must give 503 and record nothing
if ($WithOutage) {
    docker stop loan-postgres *> $null
    Start-Sleep 3
    $down = Post (J (Request @{ requestId = "SMOKEI-$run-down" }))
    Check 'database outage gives a 503, not a false 202' $down.Code 503
    docker start loan-postgres *> $null
    for ($i = 0; $i -lt 40; $i++) { if ((curl.exe -s -o NUL -w "%{http_code}" "$sys/health") -eq '200') { break }; Start-Sleep 3 }
    Check 'nothing was recorded during the outage' (Sql "select count(*) from applications where request_id='SMOKEI-$run-down'") 0
    Check 'the system recovers and accepts again' (Post (J (Request @{ requestId = "SMOKEI-$run-after" }))).Code 202
}

# ---- cleanup of this run's data (the audit table is append-only, so lift its trigger for the test rows only)
$ids = (Sql "select string_agg(quote_literal(application_id), ',') from applications where request_id like 'SMOKEI-$run%'")
if ($ids) {
    docker exec loan-postgres psql -U loan -d loan -c "alter table decision_audit disable trigger trg_decision_audit_immutable" -c "delete from decision_audit where application_id in ($ids)" -c "alter table decision_audit enable trigger trg_decision_audit_immutable" -c "delete from decision_rule_hits where application_id in ($ids)" -c "delete from credit_decisions where application_id in ($ids)" -c "delete from outbox where payload->>'applicationId' in ($ids)" -c "delete from applications where application_id in ($ids)" *> $null
}
if ($fail -eq 0) { Write-Host "`nIntake smoke test: ALL PASSED" -ForegroundColor Green } else { Write-Host "`nIntake smoke test: $fail FAILED" -ForegroundColor Red }
exit $fail
