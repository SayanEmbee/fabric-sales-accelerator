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

$hasPipelinesArray = ($null -ne $config.pipelines -and $config.pipelines.GetType().IsArray -and $config.pipelines.Count -gt 0)

if (-not $hasPipelinesArray) {
    if ([string]::IsNullOrEmpty($config.sourceFile)) {
        Write-Host "ERROR: sourceFile is missing in accelerator-config.json"
        exit 1
    }

    if ([string]::IsNullOrEmpty($config.destinationTable)) {
        Write-Host "ERROR: destinationTable is missing in accelerator-config.json"
        exit 1
    }
}

# Show configuration
Write-Host "Workspace Name :" $config.workspaceName
Write-Host "Workspace ID   :" $config.workspaceId
Write-Host "Lakehouse Name :" $config.lakehouseName
Write-Host "Lakehouse ID   :" $config.lakehouseId
Write-Host "Capacity Name  :" $config.capacityName

if ($hasPipelinesArray) {
    Write-Host "Pipelines      :" (($config.pipelines | ForEach-Object { $_.pipelineName }) -join ", ")
} else {
    Write-Host "Pipeline Name  :" $config.pipelineName
    Write-Host "Source File      :" $config.sourceFile
    Write-Host "Destination Table:" $config.destinationTable
}

Write-Host ""
Write-Host "Updating pipeline configuration..."

if ($hasPipelinesArray) {
    foreach ($p in $config.pipelines) {
        if ([string]::IsNullOrEmpty($p.pipelineName)) {
            Write-Host "ERROR: pipelineName is missing in pipeline configuration item."
            exit 1
        }
        if ([string]::IsNullOrEmpty($p.sourceFile)) {
            Write-Host "ERROR: sourceFile is missing in pipeline configuration item for $($p.pipelineName)."
            exit 1
        }
        if ([string]::IsNullOrEmpty($p.destinationTable)) {
            Write-Host "ERROR: destinationTable is missing in pipeline configuration item for $($p.pipelineName)."
            exit 1
        }

        $templateName = $p.templateName
        if ([string]::IsNullOrEmpty($templateName)) {
            $templateName = "salesdatapipeline.json"
        }

        $thisTemplatePath = Join-Path $repoRoot "config/$templateName"
        if (!(Test-Path $thisTemplatePath)) {
            Write-Host "ERROR: Pipeline template file not found at $thisTemplatePath"
            exit 1
        }

        $pipelineJson = Get-Content $thisTemplatePath -Raw
        $pipelineJson = $pipelineJson.Replace("#{workspaceId}#", $config.workspaceId)
        $pipelineJson = $pipelineJson.Replace("#{lakehouseId}#", $config.lakehouseId)
        $pipelineJson = $pipelineJson.Replace("#{sourceFile}#", $p.sourceFile)
        $pipelineJson = $pipelineJson.Replace("#{destinationTable}#", $p.destinationTable)

        $thisOutputPath = Join-Path $repoRoot "pipelines/$($p.pipelineName).json"
        $pipelineJson | Set-Content $thisOutputPath

        Write-Host "Pipeline generated successfully: $thisOutputPath"
    }
} else {
    # Validate pipeline template file
    if (!(Test-Path $pipelineTemplatePath)) {
        Write-Host ""
        Write-Host "ERROR: Pipeline template file not found."
        exit 1
    }

    # Read pipeline template JSON
    $pipelineJson = Get-Content $pipelineTemplatePath -Raw

    # Replace placeholders
    $pipelineJson = $pipelineJson.Replace("#{workspaceId}#", $config.workspaceId)
    $pipelineJson = $pipelineJson.Replace("#{lakehouseId}#", $config.lakehouseId)
    $pipelineJson = $pipelineJson.Replace("#{sourceFile}#", $config.sourceFile)
    $pipelineJson = $pipelineJson.Replace("#{destinationTable}#", $config.destinationTable)

    # Save generated pipeline
    $pipelineJson | Set-Content $pipelineOutputPath

    Write-Host "Pipeline generated successfully: $pipelineOutputPath"
}

Write-Host ""
Write-Host "Deployment completed successfully!"
Write-Host ""

