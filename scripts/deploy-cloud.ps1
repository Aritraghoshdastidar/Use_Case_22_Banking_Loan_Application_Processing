# Deploys one app, or all five, to CloudHub 2.0 (shared space) with Maven, using YOUR settings file.
#   powershell -File scripts\deploy-cloud.ps1 -App loan-system-api
#   powershell -File scripts\deploy-cloud.ps1 -App all                 system API first, then the other four
# Reads %USERPROFILE%\.anypoint-cloud.env (see cloud\anypoint-cloud.env.example). Secrets are masked in the output and never written into the repository.
# Before each deploy it regenerates that app's config-cloudhub.yaml / secure-cloudhub.yaml (scripts\setup-cloud.py config).
# Options: -VCores 0.1   -MuleVersion 4.13.2 (the Anypoint trial accepts only 4.13.x EDGE and 4.9.x)   -Target (default: CLOUD_TARGET in the settings file, else Cloudhub-US-East-2)   -SkipTests
param([Parameter(Mandatory = $true)][string]$App, [string]$VCores = '0.1', [string]$MuleVersion = '4.13.2', [string]$Target = '', [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent                      # repository root: the five app folders sit here
$settingsFile = if ($env:ANYPOINT_CLOUD_ENV) { $env:ANYPOINT_CLOUD_ENV } else { Join-Path $env:USERPROFILE '.anypoint-cloud.env' }
if (-not (Test-Path $settingsFile)) { throw "Settings file $settingsFile not found. Copy cloud\anypoint-cloud.env.example there and fill it in." }
$py = @('python', 'py') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $py) { throw 'Python 3 is needed (scripts\setup-cloud.py).' }
$order = @('loan-system-api', 'loan-intake-exp-api', 'loan-document-proc', 'loan-scoring-proc', 'loan-notification-proc')

function Read-Settings { $c = @{}; Get-Content $settingsFile | ForEach-Object { if ($_ -match '^([A-Za-z0-9_]+)=(.*)$') { $c[$Matches[1]] = $Matches[2].Trim() } }; $c }

function Deploy-One([string]$name) {
    $cfg = Read-Settings
    foreach ($k in 'ANYPOINT_ORG_ID', 'ANYPOINT_CLIENT_ID', 'ANYPOINT_CLIENT_SECRET', 'ANYPOINT_ENV', 'SECURE_KEY_CLOUD', 'ENV_CLIENT_ID', 'ENV_CLIENT_SECRET') {
        if (-not $cfg[$k]) { throw "$k is empty in $settingsFile" }
    }
    $dir = Join-Path $root $name
    if (-not (Test-Path $dir)) { throw "App folder $dir not found" }
    $target = if ($Target) { $Target } elseif ($cfg['CLOUD_TARGET']) { $cfg['CLOUD_TARGET'] } else { 'Cloudhub-US-East-2' }
    $mvn = Join-Path $PSScriptRoot 'mvn.ps1'
    Write-Host "=== $name -> $target" -ForegroundColor Cyan
    & $py (Join-Path $PSScriptRoot 'setup-cloud.py') config --app $name --env $settingsFile
    if ($LASTEXITCODE -ne 0) { throw 'Could not generate the cloud configuration.' }
    # Maven settings with the Exchange credentials (Connected App), written outside the repository
    $settings = Join-Path $env:USERPROFILE '.anypoint-m2-settings.xml'
    $cred = "<username>~~~Client~~~</username><password>$($cfg['ANYPOINT_CLIENT_ID'])~?~$($cfg['ANYPOINT_CLIENT_SECRET'])</password>"
    [IO.File]::WriteAllText($settings, "<settings><servers><server><id>anypoint-exchange</id>$cred</server><server><id>anypoint-exchange-v3</id>$cred</server></servers></settings>")
    # The committed pom carries the placeholder ANYPOINT-ORG-ID as group id; the cloud build uses a temporary copy with your organization id.
    $pom = Join-Path $dir 'pom.xml'
    $cloudPom = Join-Path $dir 'pom.cloud.xml'
    [IO.File]::WriteAllText($cloudPom, ([IO.File]::ReadAllText($pom)).Replace('ANYPOINT-ORG-ID', $cfg['ANYPOINT_ORG_ID']))
    $mask = { $s = $_; foreach ($k in 'ANYPOINT_CLIENT_SECRET', 'SECURE_KEY_CLOUD', 'ENV_CLIENT_SECRET') { if ($cfg[$k]) { $s = $s.Replace($cfg[$k], '***') } }; $s }
    Push-Location $dir
    try {
        $skip = @(); if ($SkipTests) { $skip = @('-DskipTests') }
        # step 1: build and publish the application to Anypoint Exchange (CloudHub 2.0 deploys from there)
        & $mvn -f pom.cloud.xml -s $settings clean deploy @skip 2>&1 | ForEach-Object $mask | Select-String -Pattern 'BUILD|ERROR' | ForEach-Object { $_.Line }
        # step 2: deploy that asset to the shared space
        $dep = @('-f', 'pom.cloud.xml', '-s', $settings, 'mule:deploy', '-Pcloud', '-DmuleDeploy',
            "-Dcloud.environment=$($cfg['ANYPOINT_ENV'])", "-Dcloud.target=$target", "-Dcloud.appName=$name", "-Dcloud.vCores=$VCores", "-Dcloud.muleVersion=$MuleVersion",
            "-Danypoint.clientId=$($cfg['ANYPOINT_CLIENT_ID'])", "-Danypoint.clientSecret=$($cfg['ANYPOINT_CLIENT_SECRET'])", "-Dcloud.secureKey=$($cfg['SECURE_KEY_CLOUD'])",
            "-Danypoint.platformClientId=$($cfg['ENV_CLIENT_ID'])", "-Danypoint.platformClientSecret=$($cfg['ENV_CLIENT_SECRET'])")
        & $mvn @dep 2>&1 | ForEach-Object $mask
    }
    finally { Pop-Location; Remove-Item $cloudPom -Force -ErrorAction SilentlyContinue }
}

if ($App -eq 'all') {
    foreach ($n in $order) {
        Deploy-One $n
        # the apps deployed next need the public address of the system API, and the notification emails need the intake address
        if ($n -in 'loan-system-api', 'loan-intake-exp-api') { & $py (Join-Path $PSScriptRoot 'setup-cloud.py') urls --env $settingsFile }
    }
    & $py (Join-Path $PSScriptRoot 'setup-cloud.py') urls --env $settingsFile
}
else {
    if ($order -notcontains $App) { throw "Unknown app $App. Use one of: $($order -join ', '), or all." }
    Deploy-One $App
}
