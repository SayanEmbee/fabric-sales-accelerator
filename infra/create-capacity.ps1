$ErrorActionPreference = "Stop"

$resourceGroup = "rg-fabric-dev"
$capacityName = "fabricf2dev"
$location = "CentralIndia"

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

Invoke-AzCommand `
  -Command { az fabric capacity create `
      --resource-group $resourceGroup `
      --name $capacityName `
      --sku F2 `
      --location $location } `
  -ErrorMessage "ERROR: Failed to create Fabric capacity."

Write-Host ""
Write-Host "Fabric Capacity Created Successfully!"
