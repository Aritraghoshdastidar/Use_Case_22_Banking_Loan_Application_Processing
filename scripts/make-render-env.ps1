# Builds one settings file for the Render dashboard (Environment > Add from .env) with ONLY what the website needs,
# taken from your cloud settings file. Nothing is sent anywhere; the file is written to your home folder.
#   powershell -File scripts\make-render-env.ps1
# Delete the output after pasting it into Render.
$ErrorActionPreference = 'Stop'
$src = if ($env:ANYPOINT_CLOUD_ENV) { $env:ANYPOINT_CLOUD_ENV } else { Join-Path $env:USERPROFILE '.anypoint-cloud.env' }
if (-not (Test-Path $src)) { throw "Settings file not found: $src" }
$want = 'CLOUD_SYSTEM_API_URL', 'CLOUD_INTAKE_API_URL', 'CLOUD_DOCUMENT_URL', 'CLOUD_SCORING_URL', 'CLOUD_NOTIFICATION_URL',
        'INTAKE_CLIENT_ID', 'INTAKE_CLIENT_SECRET', 'AMQP_HOST', 'AMQP_VHOST', 'AMQP_USER', 'AMQP_PASSWORD'
$have = @{}
foreach ($l in Get-Content $src) {
    $t = $l.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('='); if ($i -gt 0) { $have[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
}
$missing = $want | Where-Object { -not $have[$_] }
if ($missing) { throw "Missing in ${src}: $($missing -join ', '). Run: python scripts\setup-cloud.py urls   (and api-manager for the client id and secret)." }
$staffPw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
$out = Join-Path $env:USERPROFILE 'render-web.env'
$lines = @('WEB_ENV=cloud', 'WEB_SECURE_COOKIE=1', 'WEB_TRUST_PROXY=1', 'WEB_HIDE_LOCAL=1', "WEB_STAFF_PASSWORD=$staffPw") + ($want | ForEach-Object { "$_=$($have[$_])" })
Set-Content -Path $out -Value $lines -Encoding ascii
Write-Host "Written: $out  ($($lines.Count) settings, none printed here)"
Write-Host "Staff password for both staff accounts is the WEB_STAFF_PASSWORD line in that file."
Write-Host "Paste the file into Render (Environment > Add from .env), then delete it."
