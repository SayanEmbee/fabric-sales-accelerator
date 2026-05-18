$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$configPath = Join-Path $repoRoot "config/accelerator-config.json"

if (!(Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found."
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json
$resourceGroup = $config.resourceGroup
$capacityName = $config.capacityName
$location = $config.location
$capacitySku = $config.capacitySku

if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
    Write-Host "ERROR: resourceGroup is missing in accelerator-config.json"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($capacityName)) {
    Write-Host "ERROR: capacityName is missing in accelerator-config.json"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($location)) {
    Write-Host "ERROR: location is missing in accelerator-config.json"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($capacitySku)) {
    Write-Host "ERROR: capacitySku is missing in accelerator-config.json"
    exit 1
}

function Invoke-AzCommand {
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,

        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage
    )

    & $Command

    if ($LASTEXITCODE -ne 0) {
        Write-Host $ErrorMessage
        exit 1
    }
}

Write-Host ""
Write-Host "Checking Azure Login..."

az account show

if ($LASTEXITCODE -ne 0) {
    Write-Host "Please login to Azure first."
    az login
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Azure login failed."
    exit 1
}

Write-Host ""
Write-Host "Checking Microsoft Fabric Azure CLI extension..."

az extension show --name microsoft-fabric *> $null

if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing Microsoft Fabric Azure CLI extension..."

    Invoke-AzCommand `
      -Command { az extension add --name microsoft-fabric --allow-preview true } `
      -ErrorMessage "ERROR: Failed to install Microsoft Fabric Azure CLI extension."
}

Write-Host ""
Write-Host "Creating Resource Group..."

Invoke-AzCommand `
  -Command { az group create `
      --name $resourceGroup `
      --location $location } `
  -ErrorMessage "ERROR: Failed to create or update resource group."

Write-Host ""
Write-Host "Creating Fabric Capacity..."

$capacityExists = $false
az fabric capacity show --resource-group $resourceGroup --name $capacityName *> $null

if ($LASTEXITCODE -eq 0) {
    $capacityExists = $true
    Write-Host "Fabric capacity already exists:" $capacityName
}
else {
    Invoke-AzCommand `
      -Command { az fabric capacity create `
          --resource-group $resourceGroup `
          --name $capacityName `
          --sku $capacitySku `
          --location $location } `
      -ErrorMessage "ERROR: Failed to create Fabric capacity."
}

$capacity = az fabric capacity show --resource-group $resourceGroup --name $capacityName -o json | ConvertFrom-Json

if ($LASTEXITCODE -eq 0 -and $capacity) {
    $capacityId = $capacity.properties.capacityId

    if ([string]::IsNullOrWhiteSpace($capacityId)) {
        $capacityId = $capacity.capacityId
    }

    if (-not [string]::IsNullOrWhiteSpace($capacityId)) {
        if ($config.PSObject.Properties.Name -contains "capacityId") {
            $config.capacityId = $capacityId
        }
        else {
            $config | Add-Member -NotePropertyName "capacityId" -NotePropertyValue $capacityId
        }

        $config | ConvertTo-Json -Depth 20 | Set-Content $configPath
        Write-Host "Capacity ID saved to accelerator-config.json:" $capacityId
    }
}

Write-Host ""
Write-Host "Fabric Capacity Created Successfully!"
