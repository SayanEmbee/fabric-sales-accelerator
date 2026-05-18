$resourceGroup = "rg-fabric-dev"
$capacityName = "fabricf2dev"
$location = "CentralIndia"

Write-Host ""
Write-Host "Checking Azure Login..."

az account show

if ($LASTEXITCODE -ne 0) {
    Write-Host "Please login to Azure first."
    az login
}

Write-Host ""
Write-Host "Creating Resource Group..."

az group create `
  --name $resourceGroup `
  --location $location

Write-Host ""
Write-Host "Creating Fabric Capacity..."

az fabric capacity create `
  --resource-group $resourceGroup `
  --name $capacityName `
  --sku F2 `
  --location $location

Write-Host ""
Write-Host "Fabric Capacity Created Successfully!"