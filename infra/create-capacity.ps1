$resourceGroup = "rg-fabric-dev"
$capacityName = "fabric-f2-dev"
$location = "Central India"

Write-Host "Creating Microsoft Fabric Capacity..."

az fabric capacity create `
  --resource-group $resourceGroup `
  --name $capacityName `
  --sku F2 `
  --location $location

Write-Host "Fabric Capacity Created!"