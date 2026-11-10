# Live tests of three behaviours that only show over time (requirements AC7, N15, FR5, S14, N22):
#   1. a missing document is supplied later, the same application resumes and ends with a decision and an email
#   2. the product checklist is changed in the database and the next application follows it with no redeployment
#   3. the message broker is stopped while an application is being submitted and nothing is lost
# Part 3 stops RabbitMQ on purpose, so run this on its own. Needs the Docker stack and all five apps running.
#   powershell -File scripts\smoke-resilience.ps1            all three parts
#   powershell -File scripts\smoke-resilience.ps1 -Part 3    one part only (1, 2 or 3)
param([string]$Part = 'all')
$ErrorActionPreference = 'Continue'
$intake = 'http://localhost:8702/api'
$mq = 'http://localhost:15672/api'
$mh = 'http://localhost:8625'
$tmp = Join-Path $env:TEMP 'loan-smoke-resilience'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
$run = Get-Date -Format 'HHmmss'
$root = Split-Path $PSScriptRoot -Parent
$samples = Join-Path $root 'samples'
$awsBase = @('run', '--rm', '-e', 'AWS_ACCESS_KEY_ID=loan', '-e', 'AWS_SECRET_ACCESS_KEY=loan-secret-123', '-e', 'AWS_DEFAULT_REGION=us-east-1')

function Check($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "[PASS] $name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $name (got $actual, expected $expected)" -ForegroundColor Red; $script:fail++ }
}
function Sql($q) { (docker exec loan-postgres psql -U loan -d loan -tA -c $q) -join '' }
function Json($o) { $o | ConvertTo-Json -Depth 8 -Compress }
function Aws { docker @awsBase -v "${samples}:/data:ro" amazon/aws-cli --endpoint-url http://host.docker.internal:9000 @args 2>&1 }
function WaitFor($scriptBlock, $seconds) {
    for ($i = 0; $i -lt $seconds; $i++) { if (& $scriptBlock) { return $true }; Start-Sleep 1 }
    return $false
}
function Mails($to) {
    $r = curl.exe -s "$mh/api/v2/search?kind=to&query=$to&limit=50" | ConvertFrom-Json
    $items = @($r.items | ForEach-Object {
        $enc = ($_.Content.Headers.'Content-Transfer-Encoding' -join '')
        $body = if ($enc -match 'base64') { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($_.Content.Body -replace '\s', ''))) } else { $_.Content.Body }
        [pscustomobject]@{ Subject = ($_.Content.Headers.Subject -join ''); Body = $body }
    })
    return , $items
}
function Stage($id) { Sql "SELECT stage FROM applications WHERE application_id = '$id'" }
function DecisionRows($id) { Sql "SELECT count(*) FROM credit_decisions WHERE application_id = '$id'" }

# $names are the files in the folder that the manifest declares; $sourceFolder is the sample folder copied for this application
function NewApplication($tag, $sourceFolder, $names, $identity = 'ABCDE1234F') {
    $folder = "res-$run-$tag"
    $email = "smoke-$run-$tag@example.com"
    Aws s3 cp "s3://loan-docs/staging/$sourceFolder/" "s3://loan-docs/staging/$folder/" --recursive | Out-Null
    $docs = @($names | ForEach-Object {
        $type = if ($_ -like 'id_proof*') { 'ID_PROOF' } elseif ($_ -like 'address_proof*') { 'ADDRESS_PROOF' } else { 'PAYSLIP' }
        @{ fileName = $_; type = $type }
    })
    $body = Json @{
        requestId = "SMOKER-$run-$tag"; productCode = 'PL'; amount = 200000; tenureMonths = 24
        applicant = @{ fullName = 'Smoke Resilience'; dateOfBirth = '1990-05-15'; identityRef = $identity; email = $email; monthlyIncome = 90000; monthlyObligations = 10000; employmentMonths = 48 }
        documents = @{ folder = $folder; documentCount = $docs.Count; documents = $docs }
    }
    $f = Join-Path $tmp 'req.json'; [IO.File]::WriteAllText($f, $body)
    $id = (curl.exe -s -X POST "$intake/applications" -H 'Content-Type: application/json' --data-binary "@$f" | ConvertFrom-Json).applicationId
    [pscustomobject]@{ Id = $id; Email = $email; Folder = $folder }
}

Aws s3 sync /data/documents s3://loan-docs/staging/ --delete | Out-Null
curl.exe -s -X DELETE "$mh/api/v1/messages" -o NUL
foreach ($dlq in 'loan.verify.q.dlq', 'loan.score.q.dlq', 'loan.decision.q.dlq') { curl.exe -s -u loan:loan -X DELETE "$mq/queues/%2F/$dlq/contents" -o NUL }   # start with empty dead-letter queues
$all4 = 'id_proof.pdf', 'address_proof.pdf', 'payslip_1.pdf', 'payslip_2.pdf'
$three = 'id_proof.pdf', 'address_proof.pdf', 'payslip_1.pdf'

# ============================================================ 1. AC7 / N15: the missing document is supplied later
if ($Part -in 'all', '1') {
Write-Host '--- 1. a missing document is supplied later' -ForegroundColor Cyan
$r = NewApplication 'r' 'missing-payslip' $all4
Check 'resubmission: the application waits for documents' (WaitFor { (Stage $r.Id) -eq 'DOCUMENTS_INCOMPLETE' } 180) $true
Check 'resubmission: the first email asks for documents' (WaitFor { (Mails $r.Email).Count -ge 1 } 120) $true
Check 'resubmission: that email is the documents-needed one' ((Mails $r.Email)[0].Subject.Contains('Documents needed')) $true
Check 'resubmission: three documents are accepted so far' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$($r.Id)' AND status = 'ACCEPTED'") 3
Aws s3 cp /data/documents/complete-ok/payslip_2.pdf "s3://loan-docs/staging/$($r.Folder)/payslip_2.pdf" | Out-Null
Check 'resubmission: the request is accepted (202)' (curl.exe -s -o NUL -w "%{http_code}" -X POST "$intake/applications/$($r.Id)/resubmit") 202
Check 'resubmission: the same application reaches a decision' (WaitFor { (DecisionRows $r.Id) -eq '1' } 300) $true
Check 'resubmission: it is approved' (Stage $r.Id) 'APPROVED'
Check 'resubmission: the second email announces the approval' (WaitFor { (Mails $r.Email).Count -ge 2 } 120) $true
Check 'resubmission: the applicant got exactly two emails' (Mails $r.Email).Count 2
Check 'resubmission: still one application for the request' (Sql "SELECT count(*) FROM applications WHERE request_id = 'SMOKER-$run-r'") 1
Check 'resubmission: it is the second verification round' (Sql "SELECT verification_round FROM applications WHERE application_id = '$($r.Id)'") 2
Check 'resubmission: the accepted files were not quarantined' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$($r.Id)' AND status = 'QUARANTINED'") 0
Check 'resubmission: all four documents are in the verified folder' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$($r.Id)' AND stored_path LIKE 'verified/%'") 4
Check 'resubmission: one email per outcome and round' (Sql "SELECT string_agg(template || ':' || round || ':' || status, ',' ORDER BY id) FROM notifications WHERE application_id = '$($r.Id)'") 'DOCUMENTS_MISSING:1:SENT,APPROVED:2:SENT'
Check 'resubmission: one decision' (DecisionRows $r.Id) 1

}
# ============================================================ 2. FR5 / S14b: the checklist is data, and it is cached for 60 seconds
if ($Part -in 'all', '2') {
Write-Host '--- 2. the checklist is changed with no redeployment' -ForegroundColor Cyan
try {
    $w = NewApplication 'w' 'missing-payslip' $three
    Check 'checklist: with two payslips required, one payslip is not enough' (WaitFor { (Stage $w.Id) -eq 'DOCUMENTS_INCOMPLETE' } 180) $true
    Sql "UPDATE product_document_rules SET required_count = 1 WHERE product_code = 'PL' AND doc_type = 'PAYSLIP'" | Out-Null
    $changedAt = Get-Date
    Check 'checklist: the table now asks for one payslip' (Sql "SELECT required_count FROM product_document_rules WHERE product_code = 'PL' AND doc_type = 'PAYSLIP'") 1
    $x = NewApplication 'x' 'missing-payslip' $three
    Check 'checklist cache: inside the 60 seconds the earlier answer is still used' (WaitFor { (Stage $x.Id) -ne 'RECEIVED' -and (Stage $x.Id) -ne 'VERIFYING' } 180) $true
    Check 'checklist cache: so the change is not seen yet' (Stage $x.Id) 'DOCUMENTS_INCOMPLETE'
    # two 60 s caches are stacked (system API, then document app), so the change can take up to about 120 s to show
    $wait = 125 - [int]((Get-Date) - $changedAt).TotalSeconds
    if ($wait -gt 0) { Write-Host "Waiting $wait s for the cache to expire..."; Start-Sleep $wait }
    $y = NewApplication 'y' 'missing-payslip' $three
    Check 'checklist: after the cache expires one payslip is enough, with no redeployment' (WaitFor { (DecisionRows $y.Id) -eq '1' } 300) $true
    Check 'checklist: the application went on to be verified and scored' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$($y.Id)' AND to_stage = 'VERIFIED'") 1
    Check 'checklist: and was not asked for documents' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$($y.Id)' AND to_stage = 'DOCUMENTS_INCOMPLETE'") 0
}
finally {
    Sql "UPDATE product_document_rules SET required_count = 2 WHERE product_code = 'PL' AND doc_type = 'PAYSLIP'" | Out-Null
}
Check 'checklist: restored to two payslips' (Sql "SELECT required_count FROM product_document_rules WHERE product_code = 'PL' AND doc_type = 'PAYSLIP'") 2
# both caches still hold the one-payslip answer for up to about 120 s; wait so the next check or the next run starts from the restored table
Write-Host 'Waiting 125 s so both caches pick up the restored checklist...'; Start-Sleep 125

}
# ============================================================ 3. N22: the broker is down while an application arrives
if ($Part -in 'all', '3') {
Write-Host '--- 3. the message broker goes down' -ForegroundColor Cyan
try {
    Write-Host 'Stopping RabbitMQ...' -ForegroundColor Yellow
    docker stop loan-rabbitmq | Out-Null
    Start-Sleep 3
    $q = NewApplication 'q' 'complete-ok' $all4
    Check 'broker down: the application is still accepted' ([bool]$q.Id) $true
    Check 'broker down: its verification message is held in the outbox' (Sql "SELECT status FROM outbox WHERE queue_name = 'loan.verify.q' AND payload->>'applicationId' = '$($q.Id)'") 'PENDING'
    Check 'broker down: the sweeper keeps trying and records why' (WaitFor { [int](Sql "SELECT attempts FROM outbox WHERE queue_name = 'loan.verify.q' AND payload->>'applicationId' = '$($q.Id)'") -ge 2 } 90) $true
    Check 'broker down: the reason is stored' ((Sql "SELECT length(coalesce(last_error, '')) > 0 FROM outbox WHERE queue_name = 'loan.verify.q' AND payload->>'applicationId' = '$($q.Id)'")) 't'
    Check 'broker down: the application is waiting, not lost' (Stage $q.Id) 'RECEIVED'
}
finally {
    Write-Host 'Starting RabbitMQ again...' -ForegroundColor Yellow
    docker start loan-rabbitmq | Out-Null
}
Check 'broker is back' (WaitFor { (docker exec loan-rabbitmq rabbitmq-diagnostics -q ping 2>$null) -match 'Ping succeeded' } 120) $true
Check 'broker back: the held message is published' (WaitFor { (Sql "SELECT status FROM outbox WHERE queue_name = 'loan.verify.q' AND payload->>'applicationId' = '$($q.Id)'") -eq 'SENT' } 180) $true
Check 'broker back: the apps reconnected and consume again' (WaitFor { $ok = $true; foreach ($qn in 'loan.verify.q', 'loan.score.q', 'loan.decision.q') { if ([int]((curl.exe -s -u loan:loan "$mq/queues/%2F/$qn" | ConvertFrom-Json).consumers) -lt 1) { $ok = $false } }; $ok } 180) $true
Check 'broker back: the application goes on to a decision' (WaitFor { (DecisionRows $q.Id) -eq '1' } 300) $true
Check 'broker back: it is approved' (Stage $q.Id) 'APPROVED'
Check 'broker back: the applicant is told' (WaitFor { (Mails $q.Email).Count -ge 1 } 120) $true
Check 'broker back: exactly one verification message was ever published' (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.verify.q' AND payload->>'applicationId' = '$($q.Id)'") 1
Check 'broker back: exactly one decision' (DecisionRows $q.Id) 1
Check 'broker back: nothing in any dead-letter queue' (@('loan.verify.q.dlq', 'loan.score.q.dlq', 'loan.decision.q.dlq') | ForEach-Object { [int]((curl.exe -s -u loan:loan "$mq/queues/%2F/$_" | ConvertFrom-Json).messages) } | Measure-Object -Sum).Sum 0

}
Write-Host ''
if ($fail -eq 0) { Write-Host 'All resilience checks passed.' -ForegroundColor Green } else { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
