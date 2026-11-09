# Live smoke test for the upload gate of loan-document-proc: POST /api/staging/{folder}/documents.
# Every file is checked BEFORE it is stored. If any file fails, the answer is 422 and nothing is stored.
# Needs the Docker stack and all five apps running (scripts\run-chain.ps1). The sample documents are read from samples\documents.
#   powershell -File scripts\smoke-upload.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$samples = Join-Path $root 'samples\documents'
$intake = 'http://localhost:8702/api'
$docApp = 'http://localhost:8703/api/staging'
$tmp = Join-Path $env:TEMP 'loan-smoke-upload'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
$run = Get-Date -Format 'HHmmss'

function Check($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "[PASS] $name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $name (got $actual, expected $expected)" -ForegroundColor Red; $script:fail++ }
}
# Upload files (full paths) to a folder. Returns @{ Status; Body }
function Upload($folder, $files, $product = 'PL') {
    $curlArgs = @('-s', '-o', (Join-Path $tmp 'up.json'), '-w', '%{http_code}', '-X', 'POST', "$docApp/$folder/documents?product=$product")
    $i = 0
    foreach ($f in $files) { $curlArgs += @('-F', "f$i=@$f"); $i++ }
    $code = & curl.exe @curlArgs
    @{ Status = [int]$code; Body = (Get-Content (Join-Path $tmp 'up.json') -Raw | ConvertFrom-Json) }
}
function Reasons($r) { (@($r.Body.details.files) | ForEach-Object { if ($_.reasonCode) { $_.reasonCode } else { 'OK' } }) -join ',' }
function Docs($names) {
    @($names | ForEach-Object {
        $type = if ($_ -like 'id_proof*') { 'ID_PROOF' } elseif ($_ -like 'address_proof*') { 'ADDRESS_PROOF' } else { 'PAYSLIP' }
        @{ fileName = $_; type = $type }
    })
}
function Submit($tag, $folder, $names) {
    $docs = Docs $names
    $body = @{
        requestId = "SMOKEU-$run-$tag"; productCode = 'PL'; amount = 200000; tenureMonths = 24
        applicant = @{ fullName = 'Smoke Upload'; dateOfBirth = '1990-05-15'; identityRef = 'ABCDE1234F'; email = 'smoke@example.com'; monthlyIncome = 90000; monthlyObligations = 10000; employmentMonths = 48 }
        documents = @{ folder = $folder; documentCount = $docs.Count; documents = $docs }
    } | ConvertTo-Json -Depth 8 -Compress
    $f = Join-Path $tmp 'req.json'; [IO.File]::WriteAllText($f, $body)
    (curl.exe -s -X POST "$intake/applications" -H 'Content-Type: application/json' --data-binary "@$f" | ConvertFrom-Json).applicationId
}
function WaitStage($id, $stages, $seconds = 90) {
    for ($i = 0; $i -lt $seconds; $i += 3) {
        $s = curl.exe -s "$intake/applications/$id/status" | ConvertFrom-Json
        if ($stages -contains $s.stage) { return $s }
        Start-Sleep 3
    }
    return $s
}
$ok = Join-Path $samples 'complete-ok'
$four = 'id_proof.pdf', 'address_proof.pdf', 'payslip_1.pdf', 'payslip_2.pdf'

Write-Host "`n--- 1. A good set is stored, and the application is then verified and decided ---"
$r = Upload "up-$run" (Get-ChildItem $ok -File | ForEach-Object FullName)
Check '201 when every file passes' $r.Status 201
Check 'answer says FILES_STAGED' $r.Body.code 'FILES_STAGED'
Check 'four files reported STAGED' (@($r.Body.details.files | Where-Object status -eq 'STAGED').Count) 4
$id = Submit 'good' "up-$run" $four
$s = WaitStage $id @('APPROVED', 'REFERRED', 'DECLINED', 'DOCUMENTS_INCOMPLETE')
Check 'application uploaded through the gate is approved' $s.stage 'APPROVED'
Check 'all four documents accepted' (@($s.documents | Where-Object status -eq 'ACCEPTED').Count) 4

Write-Host "`n--- 2. One bad file rejects the whole set and nothing is stored ---"
$expect = @{
    'renamed'           = 'OK,OK,OK,UNSUPPORTED_TYPE'
    'truncated'         = 'OK,OK,OK,EMPTY_OR_UNREADABLE'
    'zero-length'       = 'OK,OK,OK,EMPTY_OR_UNREADABLE'
    'oversized'         = 'OK,OK,OK,FILE_TOO_LARGE'
    'duplicate-content' = 'OK,OK,OK,DUPLICATE_CONTENT'
    'extra-files'       = 'OK,UNSUPPORTED_TYPE,OK,UNSUPPORTED_TYPE,OK,OK'
}
foreach ($d in $expect.Keys | Sort-Object) {
    $folder = "upx-$run-$($d -replace '[^a-z]', '')"
    $r = Upload $folder (Get-ChildItem (Join-Path $samples $d) -File | ForEach-Object FullName)
    Check "$d : 422" $r.Status 422
    Check "$d : reasons per file" (Reasons $r) $expect[$d]
}
# nothing was stored: an application pointing at a rejected folder finds no folder at all
$id = Submit 'nothing-stored' "upx-$run-oversized" $four
$s = WaitStage $id @('APPROVED', 'REFERRED', 'DECLINED', 'DOCUMENTS_INCOMPLETE')
Check 'rejected upload left no folder behind' $s.stage 'DOCUMENTS_INCOMPLETE'
Check 'reason is FOLDER_NOT_FOUND' $s.reason 'FOLDER_NOT_FOUND'

Write-Host "`n--- 3. Resubmission: upload the missing document and resubmit the same application ---"
$three = 'id_proof.pdf', 'address_proof.pdf', 'payslip_1.pdf' | ForEach-Object { Join-Path $ok $_ }
$r = Upload "upr-$run" $three
Check '3 files stored' $r.Status 201
$id = Submit 'resubmit' "upr-$run" $four
$s = WaitStage $id @('APPROVED', 'REFERRED', 'DECLINED', 'DOCUMENTS_INCOMPLETE')
Check 'incomplete while payslip_2 is missing' $s.stage 'DOCUMENTS_INCOMPLETE'
$r = Upload "upr-$run" @((Join-Path $ok 'payslip_2.pdf'))
Check 'the missing file is stored in the same folder' $r.Status 201
curl.exe -s -o NUL -X POST "$intake/applications/$id/resubmit" | Out-Null
$s = WaitStage $id @('APPROVED', 'REFERRED', 'DECLINED')
Check 'the same application is now approved' $s.stage 'APPROVED'

Write-Host "`n--- 4. Bad requests are refused before any check ---"
$one = @((Join-Path $ok 'id_proof.pdf'))
$r = Upload 'ab' $one;                       Check 'folder name too short: 400' $r.Status 400; Check '  code' $r.Body.code 'INVALID_FOLDER'
$r = Upload "up-$run-p" $one 'pl';           Check 'product in lower case: 400' $r.Status 400; Check '  code' $r.Body.code 'INVALID_PRODUCT'
$r = Upload "up-$run-q" $one 'XX';           Check 'unknown product: 400' $r.Status 400; Check '  code' $r.Body.code 'UNKNOWN_PRODUCT'
$code = curl.exe -s -o (Join-Path $tmp 'up.json') -w '%{http_code}' -X POST "$docApp/up-$run-n/documents?product=PL" -H 'Content-Type: text/plain' --data 'no files here'
Check 'no files in the request: 400' $code 400
Check '  code' ((Get-Content (Join-Path $tmp 'up.json') -Raw | ConvertFrom-Json).code) 'NO_FILES'

Write-Host ''
if ($fail -eq 0) { Write-Host 'All upload checks passed.' -ForegroundColor Green } else { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
