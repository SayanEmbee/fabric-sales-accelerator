$configPath = "../config/accelerator-config.json"
$pipelinePath = "../pipelines/salesdatapipeline.json"

Write-Host ""
Write-Host "======================================="
Write-Host " FABRIC SALES ACCELERATOR DEPLOYMENT "
Write-Host "======================================="
Write-Host ""

# Validate config file
if (!(Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found."
    exit
}

# Load config
$config = Get-Content $configPath | ConvertFrom-Json

# Validate required fields
if ([string]::IsNullOrEmpty($config.workspaceId)) {
    Write-Host "ERROR: workspaceId is missing in accelerator-config.json"
    exit
}

if ([string]::IsNullOrEmpty($config.sourceFile)) {
    Write-Host "ERROR: sourceFile is missing in accelerator-config.json"
    exit
}

if ([string]::IsNullOrEmpty($config.destinationTable)) {
    Write-Host "ERROR: destinationTable is missing in accelerator-config.json"
    exit
}

# Show configuration
Write-Host "Workspace Name :" $config.workspaceName
Write-Host "Workspace ID   :" $config.workspaceId
Write-Host "Lakehouse Name :" $config.lakehouseName
Write-Host "Pipeline Name  :" $config.pipelineName
Write-Host "Capacity Name  :" $config.capacityName

Write-Host ""
Write-Host "Source File      :" $config.sourceFile
Write-Host "Destination Table:" $config.destinationTable

# Validate pipeline file
if (!(Test-Path $pipelinePath)) {
    Write-Host ""
    Write-Host "ERROR: Pipeline file not found."
    exit
}

Write-Host ""
Write-Host "Updating pipeline configuration..."

# Read pipeline JSON
$pipelineJson = Get-Content $pipelinePath -Raw

# Replace placeholders
$pipelineJson = $pipelineJson.Replace("#{workspaceId}#", $config.workspaceId)
$pipelineJson = $pipelineJson.Replace("#{sourceFile}#", $config.sourceFile)
$pipelineJson = $pipelineJson.Replace("#{destinationTable}#", $config.destinationTable)

# Save updated pipeline
$pipelineJson | Set-Content $pipelinePath

Write-Host ""
Write-Host "Pipeline updated successfully."

Write-Host ""
Write-Host "Deployment completed successfully!"
Write-Host ""