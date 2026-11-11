# Starts the Marigold Finance website (customer portal and staff console) on http://localhost:3000.
#   powershell -File scripts\run-web.ps1                 backend chosen automatically (CloudHub if configured, else Local)
#   powershell -File scripts\run-web.ps1 -Env local      the Docker stack and the apps from run-chain.ps1
#   powershell -File scripts\run-web.ps1 -Env cloud      the CloudHub deployment (needs ~/.anypoint-cloud.env)
#   powershell -File scripts\run-web.ps1 -Port 3100
# Needs Node 22.13 or later. First start writes the staff passwords to web\data\initial-credentials.txt.
param([ValidateSet('', 'local', 'cloud')][string]$Env = '', [int]$Port = 3000)
$ErrorActionPreference = 'Stop'
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw 'Node.js 22.13 or later is required. Install it from https://nodejs.org and run this again.' }
$major = [int]((& $node -v).TrimStart('v').Split('.')[0])
if ($major -lt 22) { throw "Node $major found; 22.13 or later is required." }
$web = Join-Path (Split-Path $PSScriptRoot -Parent) 'web'
if ($Env) { $env:WEB_ENV = $Env }
$env:PORT = "$Port"
Set-Location $web
& $node server/index.js
