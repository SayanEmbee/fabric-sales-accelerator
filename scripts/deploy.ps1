$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$configPath = Join-Path $repoRoot "config/accelerator-config.json"
$pipelineTemplatePath = Join-Path $repoRoot "config/salesdatapipeline.json"
$pipelineOutputPath = Join-Path $repoRoot "pipelines/salesdatapipeline.json"

Write-Host ""
Write-Host "======================================="
Write-Host " FABRIC SALES ACCELERATOR DEPLOYMENT "
Write-Host "======================================="
Write-Host ""

# Validate config file
if (!(Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found."
    exit 1
}

# Load config
$config = Get-Content $configPath | ConvertFrom-Json

# Validate required fields
if ([string]::IsNullOrEmpty($config.workspaceId)) {
    Write-Host "ERROR: workspaceId is missing in accelerator-config.json"
    exit 1
}

if ([string]::IsNullOrEmpty($config.lakehouseId)) {
    Write-Host "ERROR: lakehouseId is missing in accelerator-config.json"
    Write-Host "Use the Lakehouse artifact ID, not the display name."
    exit 1
}

if ([string]::IsNullOrEmpty($config.sourceFile)) {
    Write-Host "ERROR: sourceFile is missing in accelerator-config.json"
    exit 1
}

if ([string]::IsNullOrEmpty($config.destinationTable)) {
    Write-Host "ERROR: destinationTable is missing in accelerator-config.json"
    exit 1
}

# Show configuration
Write-Host "Workspace Name :" $config.workspaceName
Write-Host "Workspace ID   :" $config.workspaceId
Write-Host "Lakehouse Name :" $config.lakehouseName
Write-Host "Lakehouse ID   :" $config.lakehouseId
Write-Host "Pipeline Name  :" $config.pipelineName
Write-Host "Capacity Name  :" $config.capacityName

Write-Host ""
Write-Host "Source File      :" $config.sourceFile
Write-Host "Destination Table:" $config.destinationTable

# Validate pipeline template file
if (!(Test-Path $pipelineTemplatePath)) {
    Write-Host ""
    Write-Host "ERROR: Pipeline template file not found."
    exit 1
}

Write-Host ""
Write-Host "Updating pipeline configuration..."

# Read pipeline template JSON
$pipelineJson = Get-Content $pipelineTemplatePath -Raw

# Replace placeholders
$pipelineJson = $pipelineJson.Replace("#{workspaceId}#", $config.workspaceId)
$pipelineJson = $pipelineJson.Replace("#{lakehouseId}#", $config.lakehouseId)
$pipelineJson = $pipelineJson.Replace("#{sourceFile}#", $config.sourceFile)
$pipelineJson = $pipelineJson.Replace("#{destinationTable}#", $config.destinationTable)

# Save generated pipeline
$pipelineJson | Set-Content $pipelineOutputPath

Write-Host ""
Write-Host "Pipeline generated successfully:" $pipelineOutputPath

Write-Host ""
Write-Host "Deployment completed successfully!"
Write-Host ""
