$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$configPath = Join-Path $repoRoot "config/accelerator-config.json"

Write-Host ""
Write-Host "==================================================="
Write-Host "   FABRIC SALES ACCELERATOR - AZURE DEVELOPER CLI  "
Write-Host "==================================================="
Write-Host ""

if (!(Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found at $configPath"
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json

# Helper to save changes back to json
function Save-Config {
    param ($Cfg)
    $Cfg | ConvertTo-Json -Depth 20 | Set-Content $configPath
}

# 1. Ask for Resource Group Name
$currentRg = $config.resourceGroup
if ([string]::IsNullOrWhiteSpace($currentRg)) { $currentRg = "rg-fabric-sales" }
$inputRg = Read-Host "Enter Azure Resource Group Name [default: $currentRg]"
if ([string]::IsNullOrWhiteSpace($inputRg)) { $inputRg = $currentRg }
$config.resourceGroup = $inputRg

# 2. Ask for Fabric Capacity Name
$currentCap = $config.capacityName
if ([string]::IsNullOrWhiteSpace($currentCap)) { $currentCap = "fabricf2sales" }
$inputCap = Read-Host "Enter Fabric Capacity Name [default: $currentCap]"
if ([string]::IsNullOrWhiteSpace($inputCap)) { $inputCap = $currentCap }
$config.capacityName = $inputCap

# 3. Ask for Workspace Name
$currentWs = $config.workspaceName
if ([string]::IsNullOrWhiteSpace($currentWs)) { $currentWs = "SalesAnalyticsWorkspace" }
$inputWs = Read-Host "Enter Ideal Workspace Name [default: $currentWs]"
if ([string]::IsNullOrWhiteSpace($inputWs)) { $inputWs = $currentWs }
$config.workspaceName = $inputWs

# Save config changes
Save-Config -Cfg $config

Write-Host ""
Write-Host "Config saved with your custom values:"
Write-Host " - Resource Group : $inputRg"
Write-Host " - Capacity Name  : $inputCap"
Write-Host " - Workspace Name : $inputWs"
Write-Host ""

# 4. Trigger Capacity Provisioning
Write-Host "==> Phase 1: Deploying Azure Capacity..."
$createCapScript = Join-Path $repoRoot "infra/create-capacity.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $createCapScript -UseConfig
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Capacity deployment failed."
    exit 1
}

# 5. Trigger Fabric Items Provisioning
Write-Host "==> Phase 2: Provisioning Fabric Items..."
$provisionScript = Join-Path $repoRoot "scripts/provision-fabric.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $provisionScript
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Fabric provisioning failed."
    exit 1
}

Write-Host ""
Write-Host "==================================================="
Write-Host "   AZD UP DEPLOYMENT COMPLETED SUCCESSFULLY!       "
Write-Host "==================================================="
Write-Host ""
