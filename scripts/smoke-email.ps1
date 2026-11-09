# Live end-to-end test of the applicant emails: every outcome through the whole chain into MailHog (FR19, FR20, AC3, AC8, AC10,
# AC13 to AC15, N21, N23, N24). The last part stops the mail server on purpose, so run it on its own.
# Needs the Docker stack and all five apps running (scripts\run-chain.ps1).
#   powershell -File scripts\smoke-email.ps1
$ErrorActionPreference = 'Continue'
$intake = 'http://localhost:8702/api'
$mq = 'http://localhost:15672/api'
$mh = 'http://localhost:8625'
$notify = 'http://localhost:8705/api'
$tmp = Join-Path $env:TEMP 'loan-smoke-email'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
$run = Get-Date -Format 'HHmmss'
$logs = Join-Path $env:USERPROFILE 'tools\mule-local-runtime\logs'
$root = Split-Path $PSScriptRoot -Parent
$samples = Join-Path $root 'samples'
$awsBase = @('run', '--rm', '-e', 'AWS_ACCESS_KEY_ID=loan', '-e', 'AWS_SECRET_ACCESS_KEY=loan-secret-123', '-e', 'AWS_DEFAULT_REGION=us-east-1')

function Check($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "[PASS] $name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $name (got $actual, expected $expected)" -ForegroundColor Red; $script:fail++ }
}
function Contains($name, $text, $needle) { Check $name ($text.Contains($needle)) $true }
function Lacks($name, $text, $needle) { Check $name ($text.ToLower().Contains($needle.ToLower())) $false }
function Sql($q) { (docker exec loan-postgres psql -U loan -d loan -tA -c $q) -join '' }
function Json($o) { $o | ConvertTo-Json -Depth 8 -Compress }
function Aws { docker @awsBase -v "${samples}:/data:ro" amazon/aws-cli --endpoint-url http://host.docker.internal:9000 @args 2>&1 }
function WaitFor($scriptBlock, $seconds) {
    for ($i = 0; $i -lt $seconds; $i++) { if (& $scriptBlock) { return $true }; Start-Sleep 1 }
    return $false
}
# all mails to one address, with the body decoded (the mail library sends it as Base64)
function Mails($to) {
    $r = curl.exe -s "$mh/api/v2/search?kind=to&query=$to&limit=50" | ConvertFrom-Json
    $items = @($r.items | ForEach-Object {
        $enc = ($_.Content.Headers.'Content-Transfer-Encoding' -join '')
        $body = if ($enc -match 'base64') { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($_.Content.Body -replace '\s', ''))) } else { $_.Content.Body }
        [pscustomobject]@{ Subject = ($_.Content.Headers.Subject -join ''); Body = $body }
    })
    return , $items      # the comma keeps a single mail an array, so .Count always works
}
function Decided($id) { WaitFor { (Sql "SELECT count(*) FROM credit_decisions WHERE application_id = '$id'") -eq '1' } 240 }
function NotifStatus($id) { Sql "SELECT status FROM notifications WHERE application_id = '$id'" }

function NewApplication($tag, $identity, $amount, $tenure, $income, $obligations, $employment, $sourceFolder = 'complete-ok') {
    $folder = "email-$run-$tag"
    $email = "smoke-$run-$tag@example.com"
    Aws s3 cp "s3://loan-docs/staging/$sourceFolder/" "s3://loan-docs/staging/$folder/" --recursive | Out-Null
    $body = Json @{
        requestId = "SMOKEE-$run-$tag"; productCode = 'PL'; amount = $amount; tenureMonths = $tenure
        applicant = @{ fullName = 'Smoke Email'; dateOfBirth = '1990-05-15'; identityRef = $identity; email = $email; monthlyIncome = $income; monthlyObligations = $obligations; employmentMonths = $employment }
        documents = @{ folder = $folder; documentCount = 4; documents = @(
            @{ fileName = 'id_proof.pdf'; type = 'ID_PROOF' }, @{ fileName = 'address_proof.pdf'; type = 'ADDRESS_PROOF' },
            @{ fileName = 'payslip_1.pdf'; type = 'PAYSLIP' }, @{ fileName = 'payslip_2.pdf'; type = 'PAYSLIP' }) }
    }
    $f = Join-Path $tmp 'req.json'; [IO.File]::WriteAllText($f, $body)
    $id = (curl.exe -s -X POST "$intake/applications" -H 'Content-Type: application/json' --data-binary "@$f" | ConvertFrom-Json).applicationId
    [pscustomobject]@{ Id = $id; Email = $email }
}

Check 'notification app is up' (curl.exe -s -o NUL -w "%{http_code}" "$notify/health") 200
Check 'mail server is up' (curl.exe -s -o NUL -w "%{http_code}" "$mh/api/v2/messages?limit=1") 200
curl.exe -s -X DELETE "$mh/api/v1/messages" -o NUL
Aws s3 sync /data/documents s3://loan-docs/staging/ --delete | Out-Null

# one application per outcome, all started together so the chain works on them side by side
$a = NewApplication 'a' 'ABCDE1234F' 200000 24 90000 10000 48
$b = NewApplication 'b' 'ABCDE1234F' 500000 36 50000 20000 48
$c = NewApplication 'c' 'LMNOP9012Q' 200000 24 90000 10000 12
$d = NewApplication 'd' 'RSTUV3456W' 200000 24 90000 10000 48
$e = NewApplication 'e' 'FGHIJ5678K' 300000 36 70000 15000 20
$f = NewApplication 'f' 'ABCDE1234F' 200000 24 90000 10000 48 'missing-payslip'

# ---- APPROVED
Check 'approved: an email arrives' (WaitFor { (Mails $a.Email).Count -ge 1 } 240) $true
$m = (Mails $a.Email)[0]
Check 'approved: exactly one email' (Mails $a.Email).Count 1
Contains 'approved: subject says approved' $m.Subject 'is approved'
Contains 'approved: subject carries the reference' $m.Subject $a.Id
Contains 'approved: addressed to the applicant' $m.Body 'Dear Smoke Email,'
Contains 'approved: states the approved amount' $m.Body 'Approved amount: 200,000.00'
Contains 'approved: states the term' $m.Body 'Term: 24 months'
Contains 'approved: states the rate' $m.Body 'Interest rate: 12.00% a year'
Contains 'approved: states the instalment' $m.Body 'Monthly instalment: 9,414.69'
Contains 'approved: states how long the offer is open' $m.Body 'This offer is valid until'
Contains 'approved: gives next steps' $m.Body 'What happens next'
Lacks 'approved: no reduction wording when nothing was reduced' $m.Body 'You requested'
Check 'approved: the notification is recorded as sent' (NotifStatus $a.Id) 'SENT'
Check 'approved: the audit now ends with NOTIFIED' (Sql "SELECT string_agg(to_stage, '>' ORDER BY id) FROM decision_audit WHERE application_id = '$($a.Id)'") 'RECEIVED>VERIFYING>VERIFIED>SCORING>APPROVED>NOTIFIED'

# ---- APPROVED at a reduced amount
Check 'reduced: an email arrives' (WaitFor { (Mails $b.Email).Count -ge 1 } 240) $true
$m = (Mails $b.Email)[0]
Contains 'reduced: states the reduced amount' $m.Body 'Approved amount: 451,000.00'
Contains 'reduced: states what was requested' $m.Body 'You requested 500,000.00'
Contains 'reduced: explains the reduction' $m.Body 'less than you asked for'

# ---- DECLINED
Check 'declined: an email arrives' (WaitFor { (Mails $c.Email).Count -ge 1 } 240) $true
$m = (Mails $c.Email)[0]
Contains 'declined: subject is an update' $m.Subject 'An update on your loan application'
Contains 'declined: gives a reason in plain words' $m.Body 'lower standing than we require'
Contains 'declined: gives another reason' $m.Body 'Payments on other credit were missed'
Contains 'declined: states the right to a review' $m.Body 'right to ask for the decision to be reviewed'
Contains 'declined: says where to ask' $m.Body 'loan.review@loan-platform.local'
Lacks 'declined: no score' $m.Body 'score'
Lacks 'declined: no rule id' $m.Body 'HP-'
Lacks 'declined: no internal factor name' $m.Body 'BUREAU'
Lacks 'declined: no internal reason code' $m.Body 'SCORE_BELOW'
Lacks 'declined: no numeric score' $m.Body '38.00'

# ---- DECLINED by a hard rule: explained without naming it
Check 'default: an email arrives' (WaitFor { (Mails $d.Email).Count -ge 1 } 240) $true
$m = (Mails $d.Email)[0]
Contains 'default: the reason is explained' $m.Body 'default is recorded'
Lacks 'default: the rule id stays internal' $m.Body 'HP-02'

# ---- REFERRED
Check 'referred: an email arrives' (WaitFor { (Mails $e.Email).Count -ge 1 } 240) $true
$m = (Mails $e.Email)[0]
Contains 'referred: subject says under review' $m.Subject 'under review'
Contains 'referred: gives the expected timescale' $m.Body 'within 3 working days'

# ---- DOCUMENTS MISSING
Check 'documents missing: an email arrives' (WaitFor { (Mails $f.Email).Count -ge 1 } 240) $true
$m = (Mails $f.Email)[0]
Contains 'documents missing: subject asks for documents' $m.Subject 'Documents needed'
Contains 'documents missing: names the type, the required count and the found count' $m.Body 'Recent payslip (PAYSLIP): 2 required, 1 found'
Contains 'documents missing: names the file that was listed but absent' $m.Body 'payslip_2.pdf was listed in your application'
Contains 'documents missing: says how to resubmit' $m.Body "/applications/$($f.Id)/resubmit"
Contains 'documents missing: says what need not be sent again' $m.Body 'already accepted do not need to be sent again'
Check 'documents missing: the application is waiting for documents' (Sql "SELECT stage FROM applications WHERE application_id = '$($f.Id)'") 'DOCUMENTS_INCOMPLETE'
Check 'documents missing: the notification is recorded as sent' (NotifStatus $f.Id) 'SENT'

# ---- each outcome has its own template (AC8)
$subjects = @($a, $c, $e, $f) | ForEach-Object { (Mails $_.Email)[0].Subject -replace 'APP-\d+-\d+', 'ID' }
Check 'four outcomes use four different templates' (@($subjects | Sort-Object -Unique).Count) 4

# ---- N21 / AC13: the decision message delivered many times still gives one email
$decisionMsgId = Sql "SELECT id FROM outbox WHERE queue_name = 'loan.decision.q' AND payload->>'applicationId' = '$($a.Id)'"
function PublishDecision($messageId) {
    $msg = Json @{ messageId = $messageId; correlationId = [guid]::NewGuid().ToString(); applicationId = $a.Id; type = 'DECISION_READY'; attempt = 1; createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $file = Join-Path $tmp 'mq.json'
    [IO.File]::WriteAllText($file, (Json @{ properties = @{ delivery_mode = 2; content_type = 'application/json' }; routing_key = 'loan.decision.q'; payload = $msg; payload_encoding = 'string' }))
    curl.exe -s -u loan:loan -X POST "$mq/exchanges/%2F/loan.exchange/publish" -H 'Content-Type: application/json' --data-binary "@$file" -o NUL
}
1..10 | ForEach-Object { PublishDecision $decisionMsgId }
1..10 | ForEach-Object { PublishDecision ([guid]::NewGuid().ToString()) }
Start-Sleep 25
Check 'replay: still exactly one email' (Mails $a.Email).Count 1
Check 'replay: still one notification' (Sql "SELECT count(*) FROM notifications WHERE application_id = '$($a.Id)'") 1
Check 'replay: still one NOTIFIED step in the audit' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$($a.Id)' AND event = 'NOTIFIED'") 1
Check 'replay: the stored decision is unchanged' (Sql "SELECT decision || '|' || score FROM credit_decisions WHERE application_id = '$($a.Id)'") 'APPROVED|100.00'
Check 'replay: nothing went to the dead-letter queue' ((curl.exe -s -u loan:loan "$mq/queues/%2F/loan.decision.q.dlq" | ConvertFrom-Json).messages) 0

# ---- FR20: the underwriting digest
$digest = curl.exe -s -X POST "$notify/digest" | ConvertFrom-Json
Check 'digest: sent' $digest.sent $true
Check 'digest: an email reaches underwriting' (WaitFor { (Mails 'underwriting@loan-platform.local').Count -ge 1 } 30) $true
$dm = (Mails 'underwriting@loan-platform.local')[0]
Contains 'digest: subject counts the waiting applications' $dm.Subject 'referred application'
Contains 'digest: lists the referred application' $dm.Body $e.Id
Contains 'digest: gives its amount' $dm.Body 'requested 300,000.00'
Contains 'digest: gives how long it has waited' $dm.Body 'waiting'
Lacks 'digest: no applicant details' $dm.Body 'Smoke Email'

# ---- AC16 / N24: no applicant detail in any log
foreach ($logName in 'loan-notification-proc.log', 'loan-scoring-proc.log', 'loan-document-proc.log', 'loan-intake-exp-api.log', 'loan-system-api.log') {
    $path = Join-Path $logs $logName
    $hits = @(Select-String -Path $path -Pattern "smoke-$run-", 'Smoke Email', 'ABCDE1234F', 'LMNOP9012Q', 'RSTUV3456W', 'FGHIJ5678K').Count
    Check "privacy: no email address, name or identity number in $logName" $hits 0
}

# ---- N23 / AC14: the mail server goes down. The decision is kept, only the email is retried, and the delay is visible and alerted.
Write-Host ''
Write-Host 'Stopping the mail server...' -ForegroundColor Yellow
docker stop loan-mailhog | Out-Null
$alertsBefore = @(Select-String -Path (Join-Path $logs 'loan-notification-proc.log') -Pattern 'ALERT applicants not notified' -SimpleMatch).Count
$z = NewApplication 'z' 'ABCDE1234F' 200000 24 90000 10000 48
Check 'mail down: the decision is still recorded' (Decided $z.Id) $true
Check 'mail down: the application is APPROVED' (Sql "SELECT stage FROM applications WHERE application_id = '$($z.Id)'") 'APPROVED'
Check 'mail down: the notification waits for a retry' (WaitFor { (NotifStatus $z.Id) -eq 'RETRYING' } 120) $true
Check 'mail down: the failure is recorded by type, without the address' (Sql "SELECT last_error FROM notifications WHERE application_id = '$($z.Id)'") 'EMAIL:CONNECTIVITY'
$list = curl.exe -s "$notify/unnotified" | ConvertFrom-Json
Check 'mail down: the unnotified list shows the application' (@($list.notifications | Where-Object { $_.applicationId -eq $z.Id }).Count) 1
Check 'mail down: the list carries no personal data' (($list.notifications[0] | Get-Member -MemberType NoteProperty | ForEach-Object Name) -contains 'email') $false
Check 'mail down: an alert is raised' (WaitFor { @(Select-String -Path (Join-Path $logs 'loan-notification-proc.log') -Pattern 'ALERT applicants not notified' -SimpleMatch).Count -gt $alertsBefore } 150) $true
Check 'mail down: nothing is marked as notified' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$($z.Id)' AND event = 'NOTIFIED'") 0
Write-Host 'Starting the mail server again...' -ForegroundColor Yellow
docker start loan-mailhog | Out-Null
Check 'mail server is back' (WaitFor { (curl.exe -s -o NUL -w "%{http_code}" "$mh/api/v2/messages?limit=1") -eq '200' } 60) $true
Check 'mail back: the email is finally delivered' (WaitFor { (Mails $z.Email).Count -ge 1 } 300) $true
Check 'mail back: exactly one email' (Mails $z.Email).Count 1
Check 'mail back: the notification is recorded as sent' (WaitFor { (NotifStatus $z.Id) -eq 'SENT' } 30) $true
Check 'mail back: more than one attempt was needed' (Sql "SELECT attempts >= 1 FROM notifications WHERE application_id = '$($z.Id)'") 't'
Check 'mail back: the audit now ends with NOTIFIED' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$($z.Id)' AND event = 'NOTIFIED'") 1
Check 'mail back: the application is off the unnotified list' (@((curl.exe -s "$notify/unnotified" | ConvertFrom-Json).notifications | Where-Object { $_.applicationId -eq $z.Id }).Count) 0
Check 'never scored again: one decision' (Sql "SELECT count(*) FROM credit_decisions WHERE application_id = '$($z.Id)'") 1
Check 'never scored again: one scoring message' (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.score.q' AND payload->>'applicationId' = '$($z.Id)'") 1
Check 'never scored again: one decision message' (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.decision.q' AND payload->>'applicationId' = '$($z.Id)'") 1

Write-Host ''
if ($fail -eq 0) { Write-Host 'All email checks passed.' -ForegroundColor Green } else { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
