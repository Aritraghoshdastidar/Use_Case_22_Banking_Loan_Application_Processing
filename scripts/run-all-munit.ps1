# Runs the MUnit tests of every app in one go and prints tests and coverage per app and per file (acceptance criterion 17).
#   powershell -File scripts\run-all-munit.ps1                 all apps
#   powershell -File scripts\run-all-munit.ps1 -Only loan-scoring-proc
# Needs no running services: the tests mock every connector. Takes several minutes.
param([string]$Only = '')
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent                                  # repository root
$hack = $root                                                             # one repository: every app folder sits at the root
$mvn = Join-Path $hack 'scripts\mvn.ps1'
$apps = @(
    @{ Name = 'loan-system-api'; Dir = Join-Path $hack 'loan-system-api' },
    @{ Name = 'loan-intake-exp-api'; Dir = Join-Path $root 'loan-intake-exp-api' },
    @{ Name = 'loan-document-proc'; Dir = Join-Path $root 'loan-document-proc' },
    @{ Name = 'loan-scoring-proc'; Dir = Join-Path $root 'loan-scoring-proc' },
    @{ Name = 'loan-notification-proc'; Dir = Join-Path $root 'loan-notification-proc' }
) | Where-Object { (Test-Path $_.Dir) -and ($Only -eq '' -or $_.Name -eq $Only) }

$rows = @(); $files = @(); $failed = 0
foreach ($a in $apps) {
    Write-Host "Testing $($a.Name)..." -ForegroundColor Cyan
    Push-Location $a.Dir
    $out = & $mvn clean test 2>&1 | Out-String
    Pop-Location
    $tests = 0; $bad = 0
    foreach ($m in [regex]::Matches($out, 'Tests run:\s*(\d+)\s*-\s*Failed:\s*(\d+)\s*-\s*Errors:\s*(\d+)')) {
        $tests += [int]$m.Groups[1].Value; $bad += [int]$m.Groups[2].Value + [int]$m.Groups[3].Value
    }
    $cov = [regex]::Match($out, 'Application Coverage:\s*([\d.]+)%').Groups[1].Value
    $built = $out -match 'BUILD SUCCESS'
    if (-not $built -or $bad -gt 0) { $failed++ }
    $rows += [pscustomobject]@{ App = $a.Name; Tests = $tests; Failing = $bad; Coverage = "$cov%"; Build = $(if ($built) { 'success' } else { 'FAILED' }) }
    $summary = Join-Path $a.Dir 'target\site\munit\coverage\summary.html'
    if (Test-Path $summary) {
        $html = Get-Content $summary -Raw
        foreach ($r in [regex]::Matches($html, '<a href=[^>]+>([^<]+\.xml)</a></td>\s*<td>(\d+)</td>\s*<td>[\d.]+</td>\s*<td>\s*<div class="progress">\s*<span>([\d.]+)%')) {
            $files += [pscustomobject]@{ App = $a.Name; File = $r.Groups[1].Value; Components = [int]$r.Groups[2].Value; Coverage = "$($r.Groups[3].Value)%" }
        }
    }
}
Write-Host ''
$rows | Format-Table -AutoSize
Write-Host ('Total tests: ' + ($rows | Measure-Object Tests -Sum).Sum)
Write-Host ''
Write-Host 'Coverage per file (anything below 100% needs a reason, see requirements checklist S5):'
$files | Where-Object { $_.Coverage -ne '100%' } | Format-Table -AutoSize
if ($failed -eq 0) { Write-Host 'All MUnit suites passed.' -ForegroundColor Green } else { Write-Host "$failed app(s) failed." -ForegroundColor Red; exit 1 }
