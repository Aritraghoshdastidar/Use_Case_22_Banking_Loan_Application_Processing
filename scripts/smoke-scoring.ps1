# Live end-to-end test: an application goes from intake through document verification to a scored decision.
# Covers requirements FR12 to FR18, N4, N17 to N20, AC9 to AC13 and the identity-number part of AC16.
# Needs the Docker stack and the system, intake, notification, document and scoring apps running (scripts\run-chain.ps1).
#   powershell -File scripts\smoke-scoring.ps1
$ErrorActionPreference = 'Continue'
$intake = 'http://localhost:8702/api'
$sys = 'http://localhost:8701/api'
$mq = 'http://localhost:15672/api'
$tmp = Join-Path $env:TEMP 'loan-smoke-scoring'
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
function Sql($q) { (docker exec loan-postgres psql -U loan -d loan -tA -c $q) -join '' }
function Json($o) { $o | ConvertTo-Json -Depth 8 -Compress }
function Aws { docker @awsBase -v "${samples}:/data:ro" -v "${tmp}:/scratch:ro" amazon/aws-cli --endpoint-url http://host.docker.internal:9000 @args 2>&1 }
function WaitFor($scriptBlock, $seconds) {
    for ($i = 0; $i -lt $seconds; $i++) { if (& $scriptBlock) { return $true }; Start-Sleep 1 }
    return $false
}
function Decision($id, $col) { Sql "SELECT $col FROM credit_decisions WHERE application_id = '$id'" }
function Hits($id, $where) { Sql "SELECT count(*) FROM decision_rule_hits WHERE application_id = '$id' AND $where" }

# every application gets its own copy of a complete document set, because custody moves the files out of staging
function NewApplication($tag, $identity, $amount, $tenure, $income, $obligations, $employment, $product = 'PL', $dob = '1990-05-15') {
    $folder = "score-$run-$tag"
    Aws s3 cp s3://loan-docs/staging/complete-ok/ "s3://loan-docs/staging/$folder/" --recursive | Out-Null
    $docs = @(
        @{ fileName = 'id_proof.pdf'; type = 'ID_PROOF' }, @{ fileName = 'address_proof.pdf'; type = 'ADDRESS_PROOF' },
        @{ fileName = 'payslip_1.pdf'; type = 'PAYSLIP' }, @{ fileName = 'payslip_2.pdf'; type = 'PAYSLIP' })
    if ($product -eq 'HL') {
        # a home loan also needs a property document, with content of its own (identical content would count once)
        [IO.File]::WriteAllText((Join-Path $tmp 'property_document.pdf'), "%PDF-1.4`n% property deed $([guid]::NewGuid())`ntrailer<</Root 1 0 R>>`n%%EOF`n")
        Aws s3 cp /scratch/property_document.pdf "s3://loan-docs/staging/$folder/property_document.pdf" | Out-Null
        $docs += @{ fileName = 'property_document.pdf'; type = 'PROPERTY_DOCUMENT' }
    }
    $body = Json @{
        requestId = "SMOKES-$run-$tag"; productCode = $product; amount = $amount; tenureMonths = $tenure
        applicant = @{ fullName = 'Smoke Scoring'; dateOfBirth = $dob; identityRef = $identity; email = 'smoke@example.com'; monthlyIncome = $income; monthlyObligations = $obligations; employmentMonths = $employment }
        documents = @{ folder = $folder; documentCount = $docs.Count; documents = $docs }
    }
    $f = Join-Path $tmp 'req.json'; [IO.File]::WriteAllText($f, $body)
    (curl.exe -s -X POST "$intake/applications" -H 'Content-Type: application/json' --data-binary "@$f" | ConvertFrom-Json).applicationId
}
function Decided($id) { WaitFor { (Sql "SELECT count(*) FROM credit_decisions WHERE application_id = '$id'") -eq '1' } 240 }

Check 'scoring app is up' (curl.exe -s -o NUL -w "%{http_code}" http://localhost:8704/api/health) 200
Aws s3 sync /data/documents s3://loan-docs/staging/ --delete | Out-Null
curl.exe -s -u loan:loan -X DELETE "$mq/queues/%2F/loan.score.q/contents" -o NUL
Check 'bureau is switched on at the start' ((curl.exe -s "$sys/bureau/switch" | ConvertFrom-Json).enabled) $true

# ---- the standard applicant: strong score, affordable instalment
$a = NewApplication 'A' 'ABCDE1234F' 200000 24 90000 10000 48
Check 'approved: application created' ([bool]$a) $true
Check 'approved: a decision is recorded' (Decided $a) $true
Check 'approved: decision is APPROVED' (Decision $a 'decision') 'APPROVED'
Check 'approved: score is 100' (Decision $a 'score') '100.00'
Check 'approved: scorecard version is recorded' (Decision $a 'scorecard_version') 'SC-1.0'
Check 'approved: deciding rule is the score band' (Decision $a 'deciding_rule') 'BAND'
Check 'approved: approved amount is the requested amount' (Decision $a 'approved_amount') '200000.00'
Check 'approved: instalment is 9414.69' (Decision $a 'instalment') 9414.69
Check 'approved: approved rate is the product rate' (Decision $a 'approved_rate_pct') '12.00'
Check 'approved: no reduction is recorded' (Decision $a 'reduction_reason') ''
Check 'approved: affordability ratio is recorded' (Decision $a 'affordability_ratio') 0.1177
Check 'approved: the offer is valid for 30 days' (Sql "SELECT (offer_expires_at::date - decided_at::date) FROM credit_decisions WHERE application_id = '$a'") 30
Check 'approved: five factor rows and three rule rows' (Sql "SELECT count(*) FILTER (WHERE rule_type = 'FACTOR') || '/' || count(*) FILTER (WHERE rule_type = 'HARD_RULE') FROM decision_rule_hits WHERE application_id = '$a'") '5/3'
Check 'approved: the factor contributions add up to the score' (Sql "SELECT (SELECT sum(contribution) FROM decision_rule_hits WHERE application_id = '$a' AND rule_type = 'FACTOR') = (SELECT score FROM credit_decisions WHERE application_id = '$a')") 't'
Check 'approved: the bureau factor stores value, weight, points and contribution' (Sql "SELECT input_value || '|' || weight || '|' || points || '|' || contribution FROM decision_rule_hits WHERE application_id = '$a' AND rule_code = 'BUREAU_SCORE'") '780.0000|35.00|100.00|35.00'
Check 'approved: no hard rule fired' (Hits $a "rule_type = 'HARD_RULE' AND triggered") 0
Check 'approved: the application stage is APPROVED' (Sql "SELECT stage FROM applications WHERE application_id = '$a'") 'APPROVED'
Check 'approved: the audit reconstructs the whole path' (Sql "SELECT string_agg(to_stage, '>' ORDER BY id) FROM decision_audit WHERE application_id = '$a'") 'RECEIVED>VERIFYING>VERIFIED>SCORING>APPROVED'
Check 'approved: one decision message is queued for the applicant' (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.decision.q' AND payload->>'applicationId' = '$a' AND payload->>'type' = 'DECISION_READY'") 1
Check 'approved: the notification app picked it up' (WaitFor { (Sql "SELECT count(*) FROM processed_messages WHERE consumer = 'notification-proc' AND message_id = (SELECT id FROM outbox WHERE queue_name = 'loan.decision.q' AND payload->>'applicationId' = '$a')") -eq '1' } 60) $true

# ---- score between 50 and 70 is referred
$b = NewApplication 'B' 'FGHIJ5678K' 300000 36 70000 15000 20
Check 'referred: a decision is recorded' (Decided $b) $true
Check 'referred: decision is REFERRED' (Decision $b 'decision') 'REFERRED'
Check 'referred: score is 63.40' (Decision $b 'score') '63.40'
Check 'referred: deciding rule is the score band' (Decision $b 'deciding_rule') 'BAND'
Check 'referred: no approved terms' (Decision $b 'approved_amount') ''

# ---- score under 50 is declined, with the weak factors as reasons
$c = NewApplication 'C' 'LMNOP9012Q' 200000 24 90000 10000 12
Check 'declined: a decision is recorded' (Decided $c) $true
Check 'declined: decision is DECLINED' (Decision $c 'decision') 'DECLINED'
Check 'declined: score is 38.00' (Decision $c 'score') '38.00'
Check 'declined: the weak bureau score is a reason' (Sql "SELECT 'LOW_BUREAU_SCORE' = ANY(reason_codes) FROM credit_decisions WHERE application_id = '$c'") 't'
Check 'declined: no approved terms' (Decision $c 'approved_amount') ''

# ---- N19 / AC12: a strong score does not outvote an active default
$d = NewApplication 'D' 'RSTUV3456W' 200000 24 90000 10000 48
Check 'default: a decision is recorded' (Decided $d) $true
Check 'default: decision is DECLINED' (Decision $d 'decision') 'DECLINED'
Check 'default: the score itself is high' (Decision $d 'score') '100.00'
Check 'default: HP-02 is the deciding rule' (Decision $d 'deciding_rule') 'HP-02'
Check 'default: HP-02 is recorded as triggered' (Sql "SELECT triggered FROM decision_rule_hits WHERE application_id = '$d' AND rule_code = 'HP-02'") 't'
Check 'default: HP-02 is the only rule that fired' (Hits $d "rule_type = 'HARD_RULE' AND triggered") 1

# ---- N18 / AC10: the instalment is above the ceiling, so the offer is reduced
$e = NewApplication 'E' 'ABCDE1234F' 500000 36 50000 20000 48
Check 'reduced: a decision is recorded' (Decided $e) $true
Check 'reduced: decision is APPROVED' (Decision $e 'decision') 'APPROVED'
Check 'reduced: the requested amount is kept on record' (Decision $e 'requested_amount') '500000.00'
Check 'reduced: the approved amount is lower' (Decision $e 'approved_amount') '451000.00'
Check 'reduced: the reduction reason is stated' (Decision $e 'reduction_reason') 'AFFORDABILITY_REDUCED'
Check 'reduced: the reason is also in the reason codes' (Sql "SELECT 'AFFORDABILITY_REDUCED' = ANY(reason_codes) FROM credit_decisions WHERE application_id = '$e'") 't'
Check 'reduced: the instalment is for the approved amount' (Decision $e 'instalment') 14979.65
Check 'reduced: the ratio is for the requested amount' (Decision $e 'affordability_ratio') 0.5536

# ---- HP-03: even the smallest loan would not fit
$f2 = NewApplication 'F' 'ABCDE1234F' 200000 24 30000 27000 48
Check 'unaffordable: a decision is recorded' (Decided $f2) $true
Check 'unaffordable: decision is DECLINED by HP-03' (Decision $f2 'deciding_rule') 'HP-03'
Check 'unaffordable: never approved at the requested amount' (Decision $f2 'approved_amount') ''

# ---- N4 / HP-01: the home loan would end at 76, over the limit of 70
$g = NewApplication 'G' 'ABCDE1234F' 1000000 240 200000 10000 48 'HL' '1970-01-01'
Check 'age: a decision is recorded' (Decided $g) $true
Check 'age: decision is DECLINED by HP-01' (Decision $g 'deciding_rule') 'HP-01'
Check 'age: the age at maturity is recorded' (Sql "SELECT input_value FROM decision_rule_hits WHERE application_id = '$g' AND rule_code = 'HP-01'") '76.0000'

# ---- N17 / AC11: no bureau record, and then the bureau switched off
$h = NewApplication 'H' 'ZZZZZ9999Z' 200000 24 90000 10000 48
Check 'no bureau record: a decision is recorded' (Decided $h) $true
Check 'no bureau record: REFERRED' (Decision $h 'decision') 'REFERRED'
Check 'no bureau record: DATA_UNAVAILABLE is the deciding rule' (Decision $h 'deciding_rule') 'DATA_UNAVAILABLE'
Check 'no bureau record: no score is invented' (Decision $h 'score') ''
Check 'no bureau record: nothing is approved' (Decision $h 'approved_amount') ''
Check 'no bureau record: the unreadable data is recorded as a rule hit' (Hits $h "rule_code = 'DATA_UNAVAILABLE' AND triggered") 1

$switchBody = Join-Path $tmp 'switch.json'
[IO.File]::WriteAllText($switchBody, '{"enabled":false}')
curl.exe -s -X PUT "$sys/bureau/switch" -H 'Content-Type: application/json' --data-binary "@$switchBody" -o NUL
$i = NewApplication 'I' 'ABCDE1234F' 200000 24 90000 10000 48
$decidedWhileOff = Decided $i
[IO.File]::WriteAllText($switchBody, '{"enabled":true}')
curl.exe -s -X PUT "$sys/bureau/switch" -H 'Content-Type: application/json' --data-binary "@$switchBody" -o NUL
Check 'bureau off: a decision is recorded' $decidedWhileOff $true
Check 'bureau off: a strong applicant is still only REFERRED' (Decision $i 'decision') 'REFERRED'
Check 'bureau off: DATA_UNAVAILABLE is the deciding rule' (Decision $i 'deciding_rule') 'DATA_UNAVAILABLE'
Check 'bureau is switched back on' ((curl.exe -s "$sys/bureau/switch" | ConvertFrom-Json).enabled) $true

# ---- N20 / AC13: the scoring message delivered many times leaves one decision, one set of hits and one decision message
$scoreMsgId = Sql "SELECT id FROM outbox WHERE queue_name = 'loan.score.q' AND payload->>'applicationId' = '$a'"
$auditBefore = Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$a'"
function PublishScore($messageId) {
    $msg = Json @{ messageId = $messageId; correlationId = [guid]::NewGuid().ToString(); applicationId = $a; type = 'SCORE_REQUESTED'; attempt = 1; createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $f = Join-Path $tmp 'mq.json'
    [IO.File]::WriteAllText($f, (Json @{ properties = @{ delivery_mode = 2; content_type = 'application/json' }; routing_key = 'loan.score.q'; payload = $msg; payload_encoding = 'string' }))
    curl.exe -s -u loan:loan -X POST "$mq/exchanges/%2F/loan.exchange/publish" -H 'Content-Type: application/json' --data-binary "@$f" -o NUL
}
1..10 | ForEach-Object { PublishScore $scoreMsgId }
1..10 | ForEach-Object { PublishScore ([guid]::NewGuid().ToString()) }
Start-Sleep 20
Check 'replay: still one decision' (Sql "SELECT count(*) FROM credit_decisions WHERE application_id = '$a'") 1
Check 'replay: still one set of rule hits (8)' (Sql "SELECT count(*) FROM decision_rule_hits WHERE application_id = '$a'") 8
Check 'replay: still one decision message for the applicant' (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.decision.q' AND payload->>'applicationId' = '$a'") 1
Check 'replay: no extra audit rows' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$a'") $auditBefore
Check 'replay: the decision itself is unchanged' (Decision $a 'decision') 'APPROVED'
Check 'replay: nothing went to the dead-letter queue' ((curl.exe -s -u loan:loan "$mq/queues/%2F/loan.score.q.dlq" | ConvertFrom-Json).messages) 0

# ---- AC16 / N24: no identity number in any log
$identities = 'ABCDE1234F', 'FGHIJ5678K', 'LMNOP9012Q', 'RSTUV3456W', 'ZZZZZ9999Z'
foreach ($logName in 'loan-scoring-proc.log', 'loan-document-proc.log', 'loan-intake-exp-api.log', 'loan-system-api.log') {
    $path = Join-Path $logs $logName
    $hits = 0
    foreach ($id in $identities) { $hits += @(Select-String -Path $path -Pattern $id -SimpleMatch).Count }
    Check "privacy: no identity number in $logName" $hits 0
}
Check 'privacy: no income figure in the scoring log' (@(Select-String -Path (Join-Path $logs 'loan-scoring-proc.log') -Pattern 'monthlyIncome' -SimpleMatch).Count) 0

Write-Host ''
if ($fail -eq 0) { Write-Host 'All scoring checks passed.' -ForegroundColor Green } else { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
