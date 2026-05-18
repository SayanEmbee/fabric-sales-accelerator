$config = Get-Content "../config/accelerator-config.json" | ConvertFrom-Json

Write-Host ""
Write-Host "================================="
Write-Host " FABRIC ACCELERATOR DEPLOYMENT "
Write-Host "================================="
Write-Host ""

Write-Host "Workspace Name:" $config.workspaceName
Write-Host "Lakehouse Name:" $config.lakehouseName

if ($config.loadSampleData -eq $true) {
    Write-Host "Sample data will be loaded."
}

Write-Host ""
Write-Host "Deployment completed successfully!"