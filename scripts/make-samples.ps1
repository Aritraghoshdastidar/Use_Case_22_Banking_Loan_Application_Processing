# Generates test documents for every document scenario under samples/documents/<scenario>/.
# Generated files are git-ignored (the oversized one is 3 MB). Re-run any time.
$ErrorActionPreference = 'Stop'
$root = Join-Path (Split-Path $PSScriptRoot -Parent) 'samples\documents'
New-Item -ItemType Directory -Force $root | Out-Null

function New-Pdf([string]$label, [int]$extraBytes = 0) {
    # Minimal but well-formed-looking PDF; unique per label so SHA-256 differs.
    $body = "%PDF-1.4`n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj`n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj`n" +
            "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj`n% sample: $label`n"
    if ($extraBytes -gt 0) { $body += ('% pad ' + ('x' * 70) + "`n") * [math]::Ceiling($extraBytes / 78) }
    $body += "trailer<</Root 1 0 R>>`n%%EOF`n"
    [Text.Encoding]::ASCII.GetBytes($body)
}
function New-Png([string]$label) {
    $sig = [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A)
    $sig + [Text.Encoding]::ASCII.GetBytes("IHDR sample $label") + [byte[]](0..63)
}
function Save($folder, $name, [byte[]]$bytes) {
    $d = Join-Path $root $folder; New-Item -ItemType Directory -Force $d | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $d $name), $bytes)
}
function Add-Complete($f) {
    Save $f 'id_proof.pdf'      (New-Pdf "$f id")
    Save $f 'address_proof.pdf' (New-Pdf "$f address")
    Save $f 'payslip_1.pdf'     (New-Pdf "$f payslip1")
    Save $f 'payslip_2.pdf'     (New-Pdf "$f payslip2")
}

Get-ChildItem $root -Directory | Remove-Item -Recurse -Force

# AC 2: complete set (use for APPROVED / DECLINED / REFERRED demos too)
Add-Complete 'complete-ok'
# Scenario 8 / AC 3: one payslip where two required
Save 'missing-payslip' 'id_proof.pdf'      (New-Pdf 'mp id')
Save 'missing-payslip' 'address_proof.pdf' (New-Pdf 'mp address')
Save 'missing-payslip' 'payslip_1.pdf'     (New-Pdf 'mp payslip1')
# Scenario 9 / AC 4: payslip over the 2 MB limit (3 MB)
Add-Complete 'oversized'; Save 'oversized' 'payslip_2.pdf' (New-Pdf 'big' 3145728)
# Scenario 10 / AC 5: Windows executable renamed to .pdf
Add-Complete 'renamed'; Save 'renamed' 'payslip_2.pdf' ([byte[]](0x4D,0x5A,0x90,0x00) + [Text.Encoding]::ASCII.GetBytes('This is not a PDF') + [byte[]](0..31))
# Scenario 11: zero length, and truncated (header only, no EOF)
Add-Complete 'zero-length'; Save 'zero-length' 'payslip_2.pdf' ([byte[]]@())
Add-Complete 'truncated';   Save 'truncated'   'payslip_2.pdf' ([Text.Encoding]::ASCII.GetBytes('%PDF-1.4'))
# Scenario 16: same file under two names
Add-Complete 'duplicate-content'; Save 'duplicate-content' 'payslip_2.pdf' (New-Pdf 'duplicate-content payslip1')
Save 'duplicate-content' 'payslip_1.pdf' (New-Pdf 'duplicate-content payslip1')
# Scenario 13: unexpected extra files
Add-Complete 'extra-files'; Save 'extra-files' 'notes.txt' ([Text.Encoding]::ASCII.GetBytes('random notes')); Save 'extra-files' 'holiday.png' (New-Png 'holiday')
# Scenario 12 uses 'complete-ok' with a wrong declared count/checksum in the request.
# Scenario 6 (folder absent) needs no files; scenario 7 (empty folder) is created at upload time.

# Checksums file (outside the folders) to help build manifests
$sums = @{}
Get-ChildItem $root -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($root.Length + 1).Replace('\','/')
    $sums[$rel] = @{ sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(); bytes = $_.Length }
}
$sums | ConvertTo-Json -Depth 3 | Set-Content (Join-Path (Split-Path $root -Parent) 'checksums.json') -Encoding utf8
"Generated $($sums.Count) files in $root"
