$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$configPath = Join-Path $repoRoot "config/accelerator-config.json"
$pipelineTemplatePath = Join-Path $repoRoot "config/salesdatapipeline.json"
$pipelineOutputPath = Join-Path $repoRoot "pipelines/salesdatapipeline.json"
$dataRoot = Join-Path $repoRoot "data"
$notebooksRoot = Join-Path $repoRoot "notebooks"
$fabricApiRoot = "https://api.fabric.microsoft.com/v1"

function Write-Step {
    param ([Parameter(Mandatory = $true)][string]$Message)

    Write-Host ""
    Write-Host "==> $Message"
}

function Assert-LastExitCode {
    param ([Parameter(Mandatory = $true)][string]$Message)

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: $Message"
        exit 1
    }
}

function Get-AzAccessToken {
    param ([Parameter(Mandatory = $true)][string]$Resource)

    $token = az account get-access-token --resource $Resource --query accessToken -o tsv
    Assert-LastExitCode "Failed to get access token for $Resource."

    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host "ERROR: Empty access token returned for $Resource."
        exit 1
    }

    return $token
}

function Invoke-FabricApi {
    param (
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Body = $null
    )

    $token = Get-AzAccessToken "https://api.fabric.microsoft.com"
    $headers = @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
    }
    $uri = if ($Path.StartsWith("https://")) { $Path } else { "$fabricApiRoot$Path" }
    $jsonBody = $null

    if ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 100
    }

    try {
        $response = Invoke-WebRequest -Method $Method -Uri $uri -Headers $headers -Body $jsonBody -UseBasicParsing
        $parsedBody = $null

        if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
            $parsedBody = $response.Content | ConvertFrom-Json
        }

        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Headers = $response.Headers
            Body = $parsedBody
        }
    }
    catch {
        $errorBody = $_.Exception.Message

        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errorBody = $reader.ReadToEnd()
            }
            catch {}
        }

        Write-Host "ERROR: Fabric API request failed."
        Write-Host "$Method $uri"
        Write-Host $errorBody
        exit 1
    }
}

function Wait-FabricOperation {
    param ([Parameter(Mandatory = $true)]$Response)

    if ($Response.StatusCode -ne 202) {
        return
    }

    $location = $Response.Headers["Location"]

    if ([string]::IsNullOrWhiteSpace($location)) {
        Write-Host "ERROR: Fabric returned 202 Accepted without a Location header."
        exit 1
    }

    do {
        $retryAfter = 10

        if ($Response.Headers["Retry-After"]) {
            $retryAfter = [int]$Response.Headers["Retry-After"]
        }

        Start-Sleep -Seconds $retryAfter

        $operation = Invoke-FabricApi -Method "GET" -Path $location
        $status = $operation.Body.status

        if ([string]::IsNullOrWhiteSpace($status)) {
            $status = $operation.Body.Status
        }

        Write-Host "Operation status:" $status

        if ($status -in @("Succeeded", "Success", "Completed") -or $status -eq 3) {
            return
        }

        if ($status -in @("Failed", "Cancelled", "Canceled") -or $status -eq 4) {
            Write-Host "ERROR: Fabric operation failed."
            $operation.Body | ConvertTo-Json -Depth 20
            exit 1
        }

        $Response = $operation
    } while ($true)
}

function Save-Config {
    param ([Parameter(Mandatory = $true)]$Config)

    $Config | ConvertTo-Json -Depth 20 | Set-Content $configPath
}

function Set-ConfigValue {
    param (
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Config.PSObject.Properties.Name -contains $Name) {
        $Config.$Name = $Value
    }
    else {
        $Config | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-FirstByDisplayName {
    param (
        [Parameter(Mandatory = $true)]$Items,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    return @($Items | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1)[0]
}

function Get-CollectionItems {
    param ([Parameter(Mandatory = $true)]$ResponseBody)

    if ($ResponseBody.PSObject.Properties.Name -contains "value") {
        return $ResponseBody.value
    }

    if ($ResponseBody.PSObject.Properties.Name -contains "data") {
        return $ResponseBody.data
    }

    return @()
}

function Get-CapacityId {
    param ([Parameter(Mandatory = $true)]$Config)

    if (-not [string]::IsNullOrWhiteSpace($Config.capacityId)) {
        return $Config.capacityId
    }

    if ([string]::IsNullOrWhiteSpace($Config.resourceGroup) -or [string]::IsNullOrWhiteSpace($Config.capacityName)) {
        return ""
    }

    az extension show --name microsoft-fabric *> $null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Microsoft Fabric Azure CLI extension is not installed; workspace will be created without capacityId."
        return ""
    }

    $capacity = az fabric capacity show --resource-group $Config.resourceGroup --name $Config.capacityName -o json | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0 -or $null -eq $capacity) {
        Write-Host "Capacity was not found through Azure CLI; workspace will be created without capacityId."
        return ""
    }

    $candidate = $capacity.properties.capacityId

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $capacity.capacityId
    }

    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        Set-ConfigValue -Config $Config -Name "capacityId" -Value $candidate
        Save-Config -Config $Config
    }

    return $candidate
}

function Ensure-Workspace {
    param ([Parameter(Mandatory = $true)]$Config)

    if (-not [string]::IsNullOrWhiteSpace($Config.workspaceId)) {
        Invoke-FabricApi -Method "GET" -Path "/workspaces/$($Config.workspaceId)" | Out-Null
        Write-Host "Using existing workspace:" $Config.workspaceName $Config.workspaceId
        return $Config.workspaceId
    }

    $workspaces = Invoke-FabricApi -Method "GET" -Path "/workspaces"
    $workspaceItems = Get-CollectionItems -ResponseBody $workspaces.Body
    $workspace = Get-FirstByDisplayName -Items $workspaceItems -DisplayName $Config.workspaceName

    if ($null -eq $workspace) {
        $body = @{
            displayName = $Config.workspaceName
            description = "Created by Fabric Sales Analytics Accelerator"
        }
        $capacityId = Get-CapacityId -Config $Config

        if (-not [string]::IsNullOrWhiteSpace($capacityId)) {
            $body.capacityId = $capacityId
        }

        $created = Invoke-FabricApi -Method "POST" -Path "/workspaces" -Body $body
        $workspace = $created.Body
    }

    Set-ConfigValue -Config $Config -Name "workspaceId" -Value $workspace.id
    Save-Config -Config $Config
    Write-Host "Workspace ready:" $workspace.displayName $workspace.id

    return $workspace.id
}

function Ensure-Lakehouse {
    param (
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$WorkspaceId
    )

    if (-not [string]::IsNullOrWhiteSpace($Config.lakehouseId)) {
        Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/lakehouses/$($Config.lakehouseId)" | Out-Null
        Write-Host "Using existing lakehouse:" $Config.lakehouseName $Config.lakehouseId
        return $Config.lakehouseId
    }

    $lakehouses = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/lakehouses"
    $lakehouseItems = Get-CollectionItems -ResponseBody $lakehouses.Body
    $lakehouse = Get-FirstByDisplayName -Items $lakehouseItems -DisplayName $Config.lakehouseName

    if ($null -eq $lakehouse) {
        $body = @{
            displayName = $Config.lakehouseName
            description = "Created by Fabric Sales Analytics Accelerator"
        }
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/lakehouses" -Body $body
        Wait-FabricOperation -Response $response

        if ($response.Body) {
            $lakehouse = $response.Body
        }
        else {
            $lakehouses = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/lakehouses"
            $lakehouseItems = Get-CollectionItems -ResponseBody $lakehouses.Body
            $lakehouse = Get-FirstByDisplayName -Items $lakehouseItems -DisplayName $Config.lakehouseName
        }
    }

    if ($null -eq $lakehouse) {
        Write-Host "ERROR: Lakehouse was not found after creation."
        exit 1
    }

    Set-ConfigValue -Config $Config -Name "lakehouseId" -Value $lakehouse.id
    Save-Config -Config $Config
    Write-Host "Lakehouse ready:" $lakehouse.displayName $lakehouse.id

    return $lakehouse.id
}

function ConvertTo-UrlPath {
    param ([Parameter(Mandatory = $true)][string]$Path)

    $segments = $Path -split "[/\\]" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return ($segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/"
}

function Upload-SampleData {
    param (
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$LakehouseId,
        [Parameter(Mandatory = $true)][string]$SourceFile
    )

    $localSampleDataPath = Join-Path $dataRoot $SourceFile

    if (!(Test-Path $localSampleDataPath)) {
        Write-Host "ERROR: Sample data not found at $localSampleDataPath"
        exit 1
    }

    $token = Get-AzAccessToken "https://storage.azure.com/"
    $headers = @{
        Authorization = "Bearer $token"
        "x-ms-version" = "2021-06-08"
    }
    $encodedFile = ConvertTo-UrlPath $SourceFile
    $baseUri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$LakehouseId/Files/$encodedFile"
    $fileLength = (Get-Item $localSampleDataPath).Length

    try {
        Invoke-WebRequest -Method "DELETE" -Uri $baseUri -Headers $headers -UseBasicParsing | Out-Null
    }
    catch {}

    Invoke-WebRequest -Method "PUT" -Uri "$baseUri?resource=file" -Headers $headers -UseBasicParsing | Out-Null
    Invoke-WebRequest -Method "PATCH" -Uri "$baseUri?action=append&position=0" -Headers $headers -InFile $localSampleDataPath -ContentType "application/octet-stream" -UseBasicParsing | Out-Null
    Invoke-WebRequest -Method "PATCH" -Uri "$baseUri?action=flush&position=$fileLength" -Headers $headers -UseBasicParsing | Out-Null

    Write-Host "Uploaded sample data to Lakehouse Files/$SourceFile"
}

function New-PipelineDefinition {
    param (
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$LakehouseId
    )

    $pipelineJson = Get-Content $pipelineTemplatePath -Raw
    $pipelineJson = $pipelineJson.Replace("#{workspaceId}#", $WorkspaceId)
    $pipelineJson = $pipelineJson.Replace("#{lakehouseId}#", $LakehouseId)
    $pipelineJson = $pipelineJson.Replace("#{sourceFile}#", $Config.sourceFile)
    $pipelineJson = $pipelineJson.Replace("#{destinationTable}#", $Config.destinationTable)
    $pipelineJson | Set-Content $pipelineOutputPath

    $pipelineTemplate = $pipelineJson | ConvertFrom-Json
    $pipelineContent = @{
        properties = $pipelineTemplate.resources[0].properties
    } | ConvertTo-Json -Depth 100
    $pipelinePayload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pipelineContent))

    return @{
        parts = @(
            @{
                path = "pipeline-content.json"
                payload = $pipelinePayload
                payloadType = "InlineBase64"
            }
        )
    }
}

function Ensure-DataPipeline {
    param (
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)]$Definition
    )

    $pipeline = $null

    if (-not [string]::IsNullOrWhiteSpace($Config.pipelineId)) {
        $existing = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/dataPipelines/$($Config.pipelineId)"
        $pipeline = $existing.Body
    }
    else {
        $pipelines = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/dataPipelines"
        $pipelineItems = Get-CollectionItems -ResponseBody $pipelines.Body
        $pipeline = Get-FirstByDisplayName -Items $pipelineItems -DisplayName $Config.pipelineName
    }

    if ($null -eq $pipeline) {
        $body = @{
            displayName = $Config.pipelineName
            description = "Created by Fabric Sales Analytics Accelerator"
            definition = $Definition
        }
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/dataPipelines" -Body $body
        Wait-FabricOperation -Response $response

        if ($response.Body) {
            $pipeline = $response.Body
        }
        else {
            $pipelines = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/dataPipelines"
            $pipelineItems = Get-CollectionItems -ResponseBody $pipelines.Body
            $pipeline = Get-FirstByDisplayName -Items $pipelineItems -DisplayName $Config.pipelineName
        }
    }
    else {
        $body = @{
            definition = $Definition
        }
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/dataPipelines/$($pipeline.id)/updateDefinition?updateMetadata=True" -Body $body
        Wait-FabricOperation -Response $response
    }

    if ($null -eq $pipeline) {
        Write-Host "ERROR: Data pipeline was not found after deployment."
        exit 1
    }

    Set-ConfigValue -Config $Config -Name "pipelineId" -Value $pipeline.id
    Save-Config -Config $Config
    Write-Host "Data pipeline ready:" $pipeline.displayName $pipeline.id

    return $pipeline.id
}

function New-NotebookDefinition {
    param ([Parameter(Mandatory = $true)]$Config)

    $notebookSourcePath = Join-Path $notebooksRoot "$($Config.notebookName).py"

    if (!(Test-Path $notebookSourcePath)) {
        Write-Host "ERROR: Notebook source file not found at $notebookSourcePath"
        exit 1
    }

    $notebookContent = Get-Content $notebookSourcePath -Raw
    $notebookPayload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($notebookContent))
    $platform = @{
        version = "1.0"
        metadata = @{
            type = "Notebook"
            displayName = $Config.notebookName
        }
    } | ConvertTo-Json -Depth 20
    $platformPayload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($platform))

    return @{
        format = "fabricGitSource"
        parts = @(
            @{
                path = "notebook-content.py"
                payload = $notebookPayload
                payloadType = "InlineBase64"
            },
            @{
                path = ".platform"
                payload = $platformPayload
                payloadType = "InlineBase64"
            }
        )
    }
}

function Ensure-Notebook {
    param (
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)]$Definition
    )

    if ([string]::IsNullOrWhiteSpace($Config.notebookName)) {
        Write-Host "Notebook deployment skipped because notebookName is blank."
        return ""
    }

    $notebook = $null

    if (-not [string]::IsNullOrWhiteSpace($Config.notebookId)) {
        $existing = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/notebooks/$($Config.notebookId)"
        $notebook = $existing.Body
    }
    else {
        $notebooks = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/notebooks"
        $notebookItems = Get-CollectionItems -ResponseBody $notebooks.Body
        $notebook = Get-FirstByDisplayName -Items $notebookItems -DisplayName $Config.notebookName
    }

    if ($null -eq $notebook) {
        $body = @{
            displayName = $Config.notebookName
            description = "Created by Fabric Sales Analytics Accelerator"
            definition = $Definition
        }
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/notebooks" -Body $body
        Wait-FabricOperation -Response $response

        if ($response.Body) {
            $notebook = $response.Body
        }
        else {
            $notebooks = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/notebooks"
            $notebookItems = Get-CollectionItems -ResponseBody $notebooks.Body
            $notebook = Get-FirstByDisplayName -Items $notebookItems -DisplayName $Config.notebookName
        }
    }
    else {
        $body = @{
            definition = $Definition
        }
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/notebooks/$($notebook.id)/updateDefinition?updateMetadata=True" -Body $body
        Wait-FabricOperation -Response $response
    }

    if ($null -eq $notebook) {
        Write-Host "ERROR: Notebook was not found after deployment."
        exit 1
    }

    Set-ConfigValue -Config $Config -Name "notebookId" -Value $notebook.id
    Save-Config -Config $Config
    Write-Host "Notebook ready:" $notebook.displayName $notebook.id

    return $notebook.id
}

Write-Host ""
Write-Host "======================================="
Write-Host " FABRIC SALES ACCELERATOR PROVISIONING "
Write-Host "======================================="

if (!(Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found."
    exit 1
}

if (!(Test-Path $pipelineTemplatePath)) {
    Write-Host "ERROR: Pipeline template file not found."
    exit 1
}

az account show | Out-Null
Assert-LastExitCode "Azure CLI is not logged in. Run az login first."

$config = Get-Content $configPath | ConvertFrom-Json

Write-Step "Ensuring Fabric workspace"
$workspaceId = Ensure-Workspace -Config $config

$config = Get-Content $configPath | ConvertFrom-Json
Write-Step "Ensuring Lakehouse"
$lakehouseId = Ensure-Lakehouse -Config $config -WorkspaceId $workspaceId

$config = Get-Content $configPath | ConvertFrom-Json

if ($config.loadSampleData -eq $true) {
    Write-Step "Uploading sample data"
    Upload-SampleData -WorkspaceId $workspaceId -LakehouseId $lakehouseId -SourceFile $config.sourceFile
}

$config = Get-Content $configPath | ConvertFrom-Json

if (-not [string]::IsNullOrWhiteSpace($config.notebookName)) {
    Write-Step "Deploying Fabric notebook"
    $notebookDefinition = New-NotebookDefinition -Config $config
    Ensure-Notebook -Config $config -WorkspaceId $workspaceId -Definition $notebookDefinition | Out-Null
}

$config = Get-Content $configPath | ConvertFrom-Json
Write-Step "Generating and deploying Fabric data pipeline"
$definition = New-PipelineDefinition -Config $config -WorkspaceId $workspaceId -LakehouseId $lakehouseId
Ensure-DataPipeline -Config $config -WorkspaceId $workspaceId -Definition $definition | Out-Null

Write-Host ""
Write-Host "Provisioning completed successfully."
Write-Host "Workspace ID:" $workspaceId
Write-Host "Lakehouse ID:" $lakehouseId
Write-Host "Pipeline JSON:" $pipelineOutputPath
Write-Host ""
