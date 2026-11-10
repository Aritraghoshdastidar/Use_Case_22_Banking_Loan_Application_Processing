# Live smoke test for loan-document-proc: reconciliation, file validation, manifest agreement and custody (requirements FR6 to FR11, N6 to N16, AC2, AC4 to AC7).
# Quarantine moves files out of the staging folders, so the sample folders are uploaded again at the start of every run.
# Needs the Docker stack and the system, intake, notification and document apps running (scripts\run-chain.ps1).
#   powershell -File scripts\smoke-document.ps1
$ErrorActionPreference = 'Continue'
$intake = 'http://localhost:8702/api'
$sys = 'http://localhost:8701/api'
$tmp = Join-Path $env:TEMP 'loan-smoke-document'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
$run = Get-Date -Format 'HHmmss'

function Check($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "[PASS] $name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $name (got $actual, expected $expected)" -ForegroundColor Red; $script:fail++ }
}
function Sql($q) { (docker exec loan-postgres psql -U loan -d loan -tA -c $q) -join '' }
function Json($o) { $o | ConvertTo-Json -Depth 8 -Compress }
function WaitFor($scriptBlock, $seconds) {
    for ($i = 0; $i -lt $seconds; $i++) { if (& $scriptBlock) { return $true }; Start-Sleep 1 }
    return $false
}
function Docs($names) {
    @($names | ForEach-Object {
        $type = if ($_ -like 'id_proof*') { 'ID_PROOF' } elseif ($_ -like 'address_proof*') { 'ADDRESS_PROOF' } else { 'PAYSLIP' }
        @{ fileName = $_; type = $type }
    })
}
function NewApplication($tag, $folder, $names, $count = $null, $sums = $null) {
    $docs = Docs $names
    if ($sums) { $docs = @($docs | ForEach-Object { if ($sums.ContainsKey($_.fileName)) { $_['sha256'] = $sums[$_.fileName] }; $_ }) }
    $declared = if ($null -ne $count) { $count } else { @($names).Count }
    $body = Json @{
        requestId = "SMOKED-$run-$tag"; productCode = 'PL'; amount = 200000; tenureMonths = 24
        applicant = @{ fullName = 'Smoke Document'; dateOfBirth = '1990-05-15'; identityRef = 'ABCDE1234F'; email = 'smoke@example.com'; monthlyIncome = 90000; monthlyObligations = 10000; employmentMonths = 48 }
        documents = @{ folder = $folder; documentCount = $declared; documents = $docs }
    }
    $f = Join-Path $tmp 'req.json'; [IO.File]::WriteAllText($f, $body)
    (curl.exe -s -X POST "$intake/applications" -H 'Content-Type: application/json' --data-binary "@$f" | ConvertFrom-Json).applicationId
}
function StageOf($id) { Sql "SELECT stage FROM applications WHERE application_id = '$id'" }
function Handled($id) {
    $m = Sql "SELECT id FROM outbox WHERE queue_name = 'loan.verify.q' AND payload->>'applicationId' = '$id' ORDER BY created_at DESC LIMIT 1"
    (Sql "SELECT count(*) FROM processed_messages WHERE consumer = 'document-proc' AND message_id = '$m'") -eq '1'
}
$root = Split-Path $PSScriptRoot -Parent
$samples = Join-Path $root 'samples'
$awsBase = @('run', '--rm', '-e', 'AWS_ACCESS_KEY_ID=loan', '-e', 'AWS_SECRET_ACCESS_KEY=loan-secret-123', '-e', 'AWS_DEFAULT_REGION=us-east-1')
function Aws { docker @awsBase -v "${samples}:/data:ro" amazon/aws-cli --endpoint-url http://host.docker.internal:9000 @args 2>&1 }
function Exists($key) { $out = (Aws s3 ls "s3://loan-docs/$key" | Out-String).Trim(); return ($out.Length -gt 0 -and $out -notmatch 'error|NoSuch') }
$checksums = [IO.File]::ReadAllText((Join-Path $samples 'checksums.json')) | ConvertFrom-Json
function Checksum($path) { $checksums.PSObject.Properties[$path].Value.sha256 }
function IncompleteDetail($id, $path) { Sql "SELECT $path FROM decision_audit WHERE application_id = '$id' AND to_stage = 'DOCUMENTS_INCOMPLETE' ORDER BY id DESC LIMIT 1" }

Check 'document app is up' (curl.exe -s -o NUL -w "%{http_code}" http://localhost:8703/api/health) 200

# fresh start: samples back in staging, quarantine empty, and an empty folder (a zero-byte object whose key ends with a slash)
Aws s3 rm s3://loan-docs/quarantine/ --recursive | Out-Null
Aws s3 sync /data/documents s3://loan-docs/staging/ --delete | Out-Null
Aws s3api put-object --bucket loan-docs --key staging/empty-folder/ | Out-Null
foreach ($copy in 'count-mismatch', 'checksum-mismatch', 'checksum-ok') { Aws s3 cp s3://loan-docs/staging/complete-ok/ "s3://loan-docs/staging/$copy/" --recursive | Out-Null }
curl.exe -s -u loan:loan -X DELETE "http://localhost:15672/api/queues/%2F/loan.score.q/contents" -o NUL

$all4 = @('id_proof.pdf', 'address_proof.pdf', 'payslip_1.pdf', 'payslip_2.pdf')

# ---- complete folder: everything present, nothing is reported missing
$a = NewApplication 'A' 'complete-ok' $all4
Check 'complete: application created' ([bool]$a) $true
Check 'complete: the application reaches VERIFIED' (WaitFor { (StageOf $a) -eq 'VERIFIED' } 120) $true
Check 'complete: four documents accepted' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$a' AND status = 'ACCEPTED'") 4
Check 'complete: digest recorded for id_proof.pdf' (Sql "SELECT sha256 FROM application_documents WHERE application_id = '$a' AND file_name = 'id_proof.pdf'") (Checksum 'complete-ok/id_proof.pdf')
Check 'complete: digest recorded for payslip_2.pdf' (Sql "SELECT sha256 FROM application_documents WHERE application_id = '$a' AND file_name = 'payslip_2.pdf'") (Checksum 'complete-ok/payslip_2.pdf')
Check 'complete: nothing quarantined' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$a' AND status = 'QUARANTINED'") 0
Check 'complete: stored path of every document is in the verified folder' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$a' AND stored_path = 'verified/$a/' || file_name") 4
Check 'complete: source path is still recorded' (Sql "SELECT source_path FROM application_documents WHERE application_id = '$a' AND file_name = 'id_proof.pdf'") 'staging/complete-ok/id_proof.pdf'
Check 'complete: the verified copy exists' (Exists "verified/$a/id_proof.pdf") $true
Check 'complete: the staging copy is gone after the inventory is saved' (Exists "staging/complete-ok/id_proof.pdf") $false
Check 'complete: a scoring message is queued' (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.score.q' AND payload->>'applicationId' = '$a' AND payload->>'type' = 'SCORE_REQUESTED'") 1
Check 'complete: the audit shows VERIFYING to VERIFIED' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$a' AND from_stage = 'VERIFYING' AND to_stage = 'VERIFIED'") 1
Check 'complete: not marked incomplete' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$a' AND to_stage = 'DOCUMENTS_INCOMPLETE'") 0

# ---- N8: one payslip where two are required
$b = NewApplication 'B' 'missing-payslip' $all4
Check 'missing payslip: stage becomes DOCUMENTS_INCOMPLETE' (WaitFor { (StageOf $b) -eq 'DOCUMENTS_INCOMPLETE' } 60) $true
Check 'missing payslip: reason is MISSING_DOCUMENTS' (Sql "SELECT stage_reason FROM applications WHERE application_id = '$b'") 'MISSING_DOCUMENTS'
Check 'missing payslip: names the type' (IncompleteDetail $b "detail->'missing'->0->>'docType'") 'PAYSLIP'
Check 'missing payslip: states required count' (IncompleteDetail $b "detail->'missing'->0->>'required'") 2
Check 'missing payslip: states found count' (IncompleteDetail $b "detail->'missing'->0->>'found'") 1
Check 'missing payslip: names the missing file' (IncompleteDetail $b "detail->'missingFiles'->0->>'fileName'") 'payslip_2.pdf'
Check 'missing payslip: only one type is missing' (IncompleteDetail $b "jsonb_array_length(detail->'missing')") 1
Check 'missing payslip: a decision message went to the notification queue' (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.decision.q' AND payload->>'applicationId' = '$b'") 1
Check 'missing payslip: the notification app picked it up' (WaitFor { (Sql "SELECT count(*) FROM processed_messages WHERE consumer = 'notification-proc' AND message_id = (SELECT id FROM outbox WHERE queue_name = 'loan.decision.q' AND payload->>'applicationId' = '$b')") -eq '1' } 40) $true

# ---- N6: folder absent
$c = NewApplication 'C' 'no-such-folder' $all4
Check 'absent folder: stage becomes DOCUMENTS_INCOMPLETE' (WaitFor { (StageOf $c) -eq 'DOCUMENTS_INCOMPLETE' } 60) $true
Check 'absent folder: reason is FOLDER_NOT_FOUND' (Sql "SELECT stage_reason FROM applications WHERE application_id = '$c'") 'FOLDER_NOT_FOUND'
Check 'absent folder: every required type is listed as missing' (IncompleteDetail $c "jsonb_array_length(detail->'missing')") 3

# ---- N7: folder exists but is empty
$d = NewApplication 'D' 'empty-folder' $all4
Check 'empty folder: stage becomes DOCUMENTS_INCOMPLETE' (WaitFor { (StageOf $d) -eq 'DOCUMENTS_INCOMPLETE' } 60) $true
Check 'empty folder: reason is MISSING_DOCUMENTS, not FOLDER_NOT_FOUND' (Sql "SELECT stage_reason FROM applications WHERE application_id = '$d'") 'MISSING_DOCUMENTS'
Check 'empty folder: the full list is reported' (IncompleteDetail $d "jsonb_array_length(detail->'missing')") 3
Check 'empty folder: payslips show required 2 found 0' (IncompleteDetail $d "detail->'missing'->2->>'found'") 0

# ---- N13: extra files do not block
$e = NewApplication 'E' 'extra-files' $all4
Check 'extra files: all four expected documents validated' (WaitFor { (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$e' AND status = 'ACCEPTED'") -eq '4' } 90) $true
Check 'extra files: not blocked (reaches VERIFIED)' (WaitFor { (StageOf $e) -eq 'VERIFIED' } 90) $true
Check 'extra files: the unexpected files stay in staging, untouched' (Exists "staging/extra-files/notes.txt") $true
Check 'extra files: two unexpected files recorded' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$e' AND status = 'UNEXPECTED'") 2

# ---- bad files: quarantined with a reason, never scored (N9 to N11, AC4, AC5)
$bad = @(
    @{ tag = 'G'; folder = 'oversized'; reason = 'FILE_TOO_LARGE' },
    @{ tag = 'H'; folder = 'renamed'; reason = 'UNSUPPORTED_TYPE' },
    @{ tag = 'I'; folder = 'truncated'; reason = 'EMPTY_OR_UNREADABLE' },
    @{ tag = 'J'; folder = 'zero-length'; reason = 'EMPTY_OR_UNREADABLE' }
)
$badIds = @{}
foreach ($b in $bad) {
    $id = NewApplication $b.tag $b.folder $all4
    $badIds[$b.folder] = $id
    $n = $b.folder
    Check "${n}: stage becomes DOCUMENTS_INCOMPLETE" (WaitFor { (StageOf $id) -eq 'DOCUMENTS_INCOMPLETE' } 60) $true
    Check "${n}: exactly one file quarantined" (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$id' AND status = 'QUARANTINED'") 1
    Check "${n}: reason is $($b.reason)" (Sql "SELECT reason FROM application_documents WHERE application_id = '$id' AND status = 'QUARANTINED'") $b.reason
    $file = Sql "SELECT file_name FROM application_documents WHERE application_id = '$id' AND status = 'QUARANTINED'"
    Check "${n}: stored path is in the quarantine folder" (Sql "SELECT stored_path FROM application_documents WHERE application_id = '$id' AND status = 'QUARANTINED'") "quarantine/$id/$file"
    Check "${n}: file exists in quarantine" (Exists "quarantine/$id/$file") $true
    Check "${n}: file is gone from staging" (Exists "staging/$n/$file") $false
    Check "${n}: the other three documents are accepted" (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$id' AND status = 'ACCEPTED'") 3
    Check "${n}: a document type is counted as missing" (IncompleteDetail $id "jsonb_array_length(detail->'missing')") 1
    Check "${n}: the audit names the quarantined file reason" (IncompleteDetail $id "detail->'quarantined'->0->>'reason'") $b.reason
    Check "${n}: nothing was passed on to scoring" (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.score.q' AND payload->>'applicationId' = '$id'") 0
}
Check 'oversized: the large file was never hashed (never read in full)' (Sql "SELECT sha256 IS NULL FROM application_documents WHERE application_id = '$($badIds['oversized'])' AND status = 'QUARANTINED'") 't'

# ---- N16: the same content under two names counts once
$k = NewApplication 'K' 'duplicate-content' $all4
Check 'duplicate: stage becomes DOCUMENTS_INCOMPLETE' (WaitFor { (StageOf $k) -eq 'DOCUMENTS_INCOMPLETE' } 60) $true
Check 'duplicate: one file recorded as DUPLICATE_CONTENT' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$k' AND status = 'DUPLICATE' AND reason = 'DUPLICATE_CONTENT'") 1
Check 'duplicate: payslip counted once (found 1 of 2)' (IncompleteDetail $k "detail->'missing'->0->>'found'") 1
Check 'duplicate: the duplicate is not quarantined' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$k' AND status = 'QUARANTINED'") 0

# ---- N15 / AC7 / N14: supply the missing document against the same application (the new file is fresh, so it must also wait until stable)
$g = $badIds['oversized']
Aws s3 cp /data/documents/complete-ok/payslip_2.pdf s3://loan-docs/staging/oversized/payslip_2.pdf | Out-Null
$resubmit = curl.exe -s -o NUL -w "%{http_code}" -X POST "$intake/applications/$g/resubmit"
Check 'resubmission is accepted (202)' $resubmit 202
Check 'resubmission: the second verification finishes with four accepted documents' (WaitFor { (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$g' AND status = 'ACCEPTED'") -eq '4' } 120) $true
Check 'resubmission: the application reaches VERIFIED, not a new application' (WaitFor { (StageOf $g) -eq 'VERIFIED' } 60) $true
Check 'resubmission: all four documents are in the verified folder' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$g' AND stored_path = 'verified/$g/' || file_name") 4
Check 'resubmission: all four documents are accepted now' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$g' AND status = 'ACCEPTED'") 4
Check 'resubmission: the earlier quarantine record is replaced, not repeated' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$g' AND status = 'QUARANTINED'") 0
Check 'resubmission: the new payslip has its digest' (Sql "SELECT sha256 FROM application_documents WHERE application_id = '$g' AND file_name = 'payslip_2.pdf'") (Checksum 'complete-ok/payslip_2.pdf')
Check 'resubmission: still one application for the request' (Sql "SELECT count(*) FROM applications WHERE request_id = 'SMOKED-$run-G'") 1
Check 'resubmission: the quarantined copy is kept as evidence' (Exists "quarantine/$g/payslip_2.pdf") $true

# ---- N12 / AC6 / FR8: the manifest must agree with what was found
$m1 = NewApplication 'M1' 'count-mismatch' $all4 5
Check 'count mismatch: stage becomes DOCUMENTS_INCOMPLETE' (WaitFor { (StageOf $m1) -eq 'DOCUMENTS_INCOMPLETE' } 120) $true
Check 'count mismatch: reason is MANIFEST_MISMATCH' (Sql "SELECT stage_reason FROM applications WHERE application_id = '$m1'") 'MANIFEST_MISMATCH'
Check 'count mismatch: the audit states declared 5' (IncompleteDetail $m1 "detail->'mismatch'->>'declaredCount'") 5
Check 'count mismatch: the audit states found 4' (IncompleteDetail $m1 "detail->'mismatch'->>'foundCount'") 4
Check 'count mismatch: nothing is moved to the verified folder' (Exists "verified/$m1/") $false
Check 'count mismatch: staging is untouched' (Exists "staging/count-mismatch/id_proof.pdf") $true
Check 'count mismatch: no scoring message' (Sql "SELECT count(*) FROM outbox WHERE queue_name = 'loan.score.q' AND payload->>'applicationId' = '$m1'") 0

$wrong = @{ 'id_proof.pdf' = ('0' * 64) }
$m2 = NewApplication 'M2' 'checksum-mismatch' $all4 $null $wrong
Check 'checksum mismatch: stage becomes DOCUMENTS_INCOMPLETE' (WaitFor { (StageOf $m2) -eq 'DOCUMENTS_INCOMPLETE' } 120) $true
Check 'checksum mismatch: reason is MANIFEST_MISMATCH' (Sql "SELECT stage_reason FROM applications WHERE application_id = '$m2'") 'MANIFEST_MISMATCH'
Check 'checksum mismatch: the file is named' (IncompleteDetail $m2 "detail->'mismatch'->'checksumMismatches'->0->>'fileName'") 'id_proof.pdf'
Check 'checksum mismatch: declared and found digests are both recorded' (IncompleteDetail $m2 "detail->'mismatch'->'checksumMismatches'->0->>'found'") (Checksum 'complete-ok/id_proof.pdf')
Check 'checksum mismatch: nothing is moved to the verified folder' (Exists "verified/$m2/") $false

$right = @{}
foreach ($n in $all4) { $right[$n] = Checksum "complete-ok/$n" }
$m3 = NewApplication 'M3' 'checksum-ok' $all4 $null $right
Check 'matching checksums: the application reaches VERIFIED' (WaitFor { (StageOf $m3) -eq 'VERIFIED' } 120) $true
Check 'matching checksums: four documents are in the verified folder' (Sql "SELECT count(*) FROM application_documents WHERE application_id = '$m3' AND stored_path = 'verified/$m3/' || file_name") 4

# ---- redelivery: the same verify message again changes nothing
$mid = Sql "SELECT id FROM outbox WHERE queue_name = 'loan.verify.q' AND payload->>'applicationId' = '$b' LIMIT 1"
$auditBefore = Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$b'"
$msg = Json @{ messageId = $mid; correlationId = [guid]::NewGuid().ToString(); applicationId = $b; type = 'VERIFY_REQUESTED'; attempt = 1; createdAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
$f = Join-Path $tmp 'mq.json'
[IO.File]::WriteAllText($f, (Json @{ properties = @{ delivery_mode = 2; content_type = 'application/json' }; routing_key = 'loan.verify.q'; payload = $msg; payload_encoding = 'string' }))
curl.exe -s -u loan:loan -X POST "http://localhost:15672/api/exchanges/%2F/loan.exchange/publish" -H 'Content-Type: application/json' --data-binary "@$f" | Out-Null
Start-Sleep 6
Check 'redelivery: no second audit row' (Sql "SELECT count(*) FROM decision_audit WHERE application_id = '$b'") $auditBefore

Write-Host ''
if ($fail -eq 0) { Write-Host 'All document checks passed.' -ForegroundColor Green } else { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
