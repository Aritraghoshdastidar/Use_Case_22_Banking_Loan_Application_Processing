# Runs several Mule apps together in ONE local Mule runtime (ACB can only run one app at a time).
#   powershell -File scripts\run-chain.ps1             build, deploy and start the apps (system API + every reference app that exists)
#   powershell -File scripts\run-chain.ps1 -NoBuild    start with the jars already deployed
#   powershell -File scripts\run-chain.ps1 -Stop       stop the runtime
# Stop any app you started from ACB first: they would fight over the same ports.
param([switch]$Stop, [switch]$NoBuild, [string[]]$Only = @())
$ErrorActionPreference = 'Stop'
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # -File passes a comma list as one string
$root = Split-Path $PSScriptRoot -Parent                                  # repository root
$hack = $root                                                             # one repository: every app folder sits at the root
$mvn = Join-Path $hack 'scripts\mvn.ps1'
# Mule 4.12 Enterprise runtime that Anypoint Code Builder installs on first use. Override with $env:MULE_RUNTIME_SOURCE.
$source = if ($env:MULE_RUNTIME_SOURCE) { $env:MULE_RUNTIME_SOURCE } else { Join-Path $env:USERPROFILE 'AnypointCodeBuilder\runtime\mule-enterprise-standalone-4.12.3' }
$rt = Join-Path $env:USERPROFILE 'tools\mule-local-runtime'                                 # our own copy, outside every repo
# JDK 17 for the runtime. Override with $env:JDK17_HOME.
$jdk = @($env:JDK17_HOME, (Get-ChildItem (Join-Path $env:USERPROFILE 'AnypointCodeBuilder\java\jdk-17*') -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName), 'C:\AnypointStudio\plugins\org.mule.tooling.jdk.win32.x86_64_1.4.1') | Where-Object { $_ -and (Test-Path (Join-Path $_ 'bin\java.exe')) } | Select-Object -First 1
if (-not $jdk) { throw 'JDK 17 not found. Install Temurin 17 or set JDK17_HOME.' }
$key = 'LocalDemoKey1234'                                                                   # local demo key only
$apps = @(
    @{ Name = 'loan-system-api'; Dir = Join-Path $hack 'loan-system-api'; Port = 8701; Health = 'http://localhost:8701/api/health' },
    @{ Name = 'loan-intake-exp-api'; Dir = Join-Path $root 'loan-intake-exp-api'; Port = 8702; Health = $null },
    @{ Name = 'loan-document-proc'; Dir = Join-Path $root 'loan-document-proc'; Port = 8703; Health = $null },
    @{ Name = 'loan-scoring-proc'; Dir = Join-Path $root 'loan-scoring-proc'; Port = 8704; Health = $null },
    @{ Name = 'loan-notification-proc'; Dir = Join-Path $root 'loan-notification-proc'; Port = 8705; Health = $null }
) | Where-Object { (Test-Path $_.Dir) -and ($Only.Count -eq 0 -or $Only -contains $_.Name) }

function Get-RuntimeProcesses {
    Get-CimInstance Win32_Process | Where-Object { $_.Name -in 'java.exe', 'cmd.exe', 'wrapper-windows-x86-64.exe' -and $_.CommandLine -like "*mule-local-runtime*" }
}

if ($Stop) {
    $p = Get-RuntimeProcesses
    if (-not $p) { 'Local Mule runtime is not running.'; exit 0 }
    # the service wrapper restarts the JVM when it is killed, so it has to go first
    $p | Where-Object { $_.Name -eq 'wrapper-windows-x86-64.exe' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
    Get-RuntimeProcesses | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
    if (Get-RuntimeProcesses) { 'Some runtime processes are still alive.'; exit 1 }
    'Local Mule runtime stopped.'; exit 0
}

# one-time copy of the runtime (about 450 MB)
if (-not (Test-Path "$rt\bin\mule.bat")) {
    if (-not (Test-Path "$source\bin\mule.bat")) { throw "Mule runtime not found at $source. Run any app once from ACB so it is installed." }
    'Copying the Mule runtime once (about 450 MB)...'
    New-Item -ItemType Directory -Force $rt | Out-Null
    robocopy $source $rt /E /XD "$source\apps" "$source\.mule" "$source\logs" /NFL /NDL /NJH /NJS /NP | Out-Null
    foreach ($d in 'apps', '.mule', 'logs') { New-Item -ItemType Directory -Force (Join-Path $rt $d) | Out-Null }
}

if (Get-RuntimeProcesses) { 'The local Mule runtime is already running. Use -Stop first to redeploy.'; exit 1 }
foreach ($a in $apps) {
    if (Get-NetTCPConnection -State Listen -LocalPort $a.Port -ErrorAction SilentlyContinue) { throw "Port $($a.Port) is busy (an app started from ACB?). Stop it first, then run this script again." }
}

Remove-Item (Join-Path $rt 'apps\*') -Recurse -Force -ErrorAction SilentlyContinue
foreach ($a in $apps) {
    if (-not $NoBuild) {
        Write-Host "Building $($a.Name)..." -ForegroundColor Cyan
        Push-Location $a.Dir
        & $mvn clean package -DskipTests -DskipMunitTests | Out-Null
        if ($LASTEXITCODE -ne 0) { Pop-Location; throw "Build of $($a.Name) failed. Run scripts\mvn.ps1 clean package inside $($a.Dir) to see why." }
        Pop-Location
    }
    $jar = Get-ChildItem (Join-Path $a.Dir 'target') -Filter '*-mule-application.jar' | Select-Object -First 1
    if (-not $jar) { throw "No packaged jar for $($a.Name). Run without -NoBuild." }
    Copy-Item $jar.FullName (Join-Path $rt "apps\$($a.Name).jar") -Force
}

Write-Host 'Starting the local Mule runtime...' -ForegroundColor Cyan
$env:JAVA_HOME = $jdk
$env:PATH = "$jdk\bin;$env:PATH"
$log = Join-Path $rt 'logs\runtime-console.txt'
Start-Process -FilePath "$rt\bin\mule.bat" -ArgumentList "-M-Dmule.env=local", "-M-Dsecure.key=$key" -WorkingDirectory $rt -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err" | Out-Null

$deadline = (Get-Date).AddMinutes(4)
foreach ($a in $apps) {
    while ((Get-Date) -lt $deadline -and -not (Get-NetTCPConnection -State Listen -LocalPort $a.Port -ErrorAction SilentlyContinue)) { Start-Sleep 3 }
    if (Get-NetTCPConnection -State Listen -LocalPort $a.Port -ErrorAction SilentlyContinue) { Write-Host "[UP]   $($a.Name) on port $($a.Port)" -ForegroundColor Green }
    else { Write-Host "[DOWN] $($a.Name) did not open port $($a.Port). See $rt\logs" -ForegroundColor Red }
}
Write-Host "Logs: $rt\logs   Stop with: powershell -File scripts\run-chain.ps1 -Stop"
