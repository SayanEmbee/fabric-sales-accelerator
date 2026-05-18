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
    param (
        [Parameter(Mandatory = $true)]$Response,
        [bool]$ExitOnFailure = $true
    )

    if ($Response.StatusCode -ne 202) {
        return $true
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
            return $true
        }

        if ($status -in @("Failed", "Cancelled", "Canceled") -or $status -eq 4) {
            Write-Host "ERROR: Fabric operation failed."
            $operation.Body | ConvertTo-Json -Depth 20

            if ($ExitOnFailure) {
                exit 1
            }

            return $false
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
        $Items,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $matches = @($Items | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1)

    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[0]
}

function Get-CollectionItems {
    param ($ResponseBody)

    if ($null -eq $ResponseBody) {
        return @()
    }

    if ($ResponseBody.PSObject.Properties.Name -contains "value") {
        return @($ResponseBody.value)
    }

    if ($ResponseBody.PSObject.Properties.Name -contains "data") {
        return @($ResponseBody.data)
    }

    return @()
}

function New-WorkspaceFolder {
    param (
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$FolderName,
        [string]$ParentFolderId = ""
    )

    # Check if folder already exists
    $path = "/workspaces/$WorkspaceId/folders"
    $folders = Invoke-FabricApi -Method "GET" -Path $path
    $folderList = Get-CollectionItems -ResponseBody $folders.Body
    
    $existingFolder = $folderList | Where-Object { $_.displayName -eq $FolderName } | Select-Object -First 1

    if ($null -ne $existingFolder) {
        Write-Host "Folder already exists:" $FolderName "(" $existingFolder.id ")"
        return $existingFolder.id
    }

    # Create new folder
    $body = @{
        displayName = $FolderName
        description = "Created by Fabric Sales Analytics Accelerator"
    }
    
    if (-not [string]::IsNullOrWhiteSpace($ParentFolderId)) {
        $body.Add("parentFolderId", $ParentFolderId)
    }

    $response = Invoke-FabricApi -Method "POST" -Path $path -Body $body
    $folder = $response.Body

    Write-Host "Folder created:" $FolderName "(" $folder.id ")"
    return $folder.id
}

function New-WorkspaceFolderStructure {
    param (
        [Parameter(Mandatory = $true)][string]$WorkspaceId
    )

    Write-Host ""
    Write-Host "Creating workspace folder structure..."

    # Create main folders
    $dataIngestionFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Data Ingestion"
    $resourcesFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Resources"
    $reportsFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Reports"

    # Create subfolders in Data Ingestion (for future use)
    # These can be used when deploying additional pipelines
    $auditFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Audit" -ParentFolderId $dataIngestionFolderId
    $notificationFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Notification" -ParentFolderId $dataIngestionFolderId
    $mainDataIngestionFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Main Data Ingestion" -ParentFolderId $dataIngestionFolderId

    # Create subfolders in Resources
    $lakehousesFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Lakehouses" -ParentFolderId $resourcesFolderId
    $warehousesFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Warehouses" -ParentFolderId $resourcesFolderId
    $notebooksFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Notebooks" -ParentFolderId $resourcesFolderId

    # Create subfolders in Reports
    $powerBIReportsFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Power BI Reports" -ParentFolderId $reportsFolderId
    $dashboardsFolderId = New-WorkspaceFolder -WorkspaceId $WorkspaceId -FolderName "Dashboards" -ParentFolderId $reportsFolderId

    Write-Host "Folder structure created successfully"
    Write-Host ""

    return @{
        DataIngestion = $dataIngestionFolderId
        Resources = $resourcesFolderId
        Reports = $reportsFolderId
        Audit = $auditFolderId
        Notification = $notificationFolderId
        MainDataIngestion = $mainDataIngestionFolderId
        Lakehouses = $lakehousesFolderId
        Warehouses = $warehousesFolderId
        Notebooks = $notebooksFolderId
        PowerBIReports = $powerBIReportsFolderId
        Dashboards = $dashboardsFolderId
    }
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

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $fabricCapacities = Invoke-FabricApi -Method "GET" -Path "/capacities"
        $capacityItems = Get-CollectionItems -ResponseBody $fabricCapacities.Body
        $fabricCapacity = Get-FirstByDisplayName -Items $capacityItems -DisplayName $Config.capacityName

        if ($null -ne $fabricCapacity) {
            $candidate = $fabricCapacity.id
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        Set-ConfigValue -Config $Config -Name "capacityId" -Value $candidate
        Save-Config -Config $Config
    }

    return $candidate
}

function Ensure-WorkspaceCapacity {
    param (
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$WorkspaceId
    )

    $capacityId = Get-CapacityId -Config $Config

    if ([string]::IsNullOrWhiteSpace($capacityId)) {
        Write-Host "WARNING: No Fabric capacityId was found. Lakehouse creation may fail if the workspace is not assigned to Fabric capacity."
        return
    }

    $workspaceResponse = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId"
    $assignedCapacityId = $workspaceResponse.Body.capacityId

    if ([string]::IsNullOrWhiteSpace($assignedCapacityId)) {
        $assignedCapacityId = $workspaceResponse.Body.CapacityId
    }

    if ($assignedCapacityId -eq $capacityId) {
        Write-Host "Workspace is already assigned to Fabric capacity:" $capacityId
        return
    }

    $body = @{
        capacityId = $capacityId
    }
    $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/assignToCapacity" -Body $body
    $null = Wait-FabricOperation -Response $response
    Write-Host "Workspace assigned to Fabric capacity:" $capacityId
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
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [string]$FolderId = ""
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
        
        if (-not [string]::IsNullOrWhiteSpace($FolderId)) {
            $body.Add("folderId", $FolderId)
        }
        
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/lakehouses" -Body $body
        $null = Wait-FabricOperation -Response $response

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

    Invoke-WebRequest -Method "PUT" -Uri "${baseUri}?resource=file" -Headers $headers -UseBasicParsing | Out-Null
    Invoke-WebRequest -Method "PATCH" -Uri "${baseUri}?action=append&position=0" -Headers $headers -InFile $localSampleDataPath -ContentType "application/octet-stream" -UseBasicParsing | Out-Null
    Invoke-WebRequest -Method "PATCH" -Uri "${baseUri}?action=flush&position=$fileLength" -Headers $headers -UseBasicParsing | Out-Null

    Write-Host "Uploaded sample data to Lakehouse Files/$SourceFile"
}

function New-PipelineDefinition {
    param (
        [object]$PipelineConfig = $null,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$LakehouseId
    )

    if ($null -ne $PipelineConfig) {
        $templateName = $PipelineConfig.templateName
        if ([string]::IsNullOrEmpty($templateName)) {
            $templateName = "salesdatapipeline.json"
        }
        $thisTemplatePath = Join-Path $repoRoot "config/$templateName"
        $thisOutputPath = Join-Path $repoRoot "pipelines/$($PipelineConfig.pipelineName).json"
        $sourceFile = $PipelineConfig.sourceFile
        $destinationTable = $PipelineConfig.destinationTable
    } else {
        $thisTemplatePath = $pipelineTemplatePath
        $thisOutputPath = $pipelineOutputPath
        $sourceFile = $config.sourceFile
        $destinationTable = $config.destinationTable
    }

    if (!(Test-Path $thisTemplatePath)) {
        Write-Host "ERROR: Pipeline template file not found at $thisTemplatePath"
        exit 1
    }

    $pipelineJson = Get-Content $thisTemplatePath -Raw
    $pipelineJson = $pipelineJson.Replace("#{workspaceId}#", $WorkspaceId)
    $pipelineJson = $pipelineJson.Replace("#{lakehouseId}#", $LakehouseId)
    $pipelineJson = $pipelineJson.Replace("#{sourceFile}#", $sourceFile)
    $pipelineJson = $pipelineJson.Replace("#{destinationTable}#", $destinationTable)
    $pipelineJson | Set-Content $thisOutputPath

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
        [Parameter(Mandatory = $true)]$PipelineConfig,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)]$Definition,
        [string]$FolderId = ""
    )

    $pipeline = $null
    $pipelineId = $PipelineConfig.pipelineId
    $pipelineName = $PipelineConfig.pipelineName

    if (-not [string]::IsNullOrWhiteSpace($pipelineId)) {
        $existing = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/dataPipelines/$pipelineId"
        $pipeline = $existing.Body
    }
    else {
        $pipelines = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/dataPipelines"
        $pipelineItems = Get-CollectionItems -ResponseBody $pipelines.Body
        $pipeline = Get-FirstByDisplayName -Items $pipelineItems -DisplayName $pipelineName
    }

    if ($null -eq $pipeline) {
        $body = @{
            displayName = $pipelineName
            description = "Created by Fabric Sales Analytics Accelerator"
            definition = $Definition
        }
        
        if (-not [string]::IsNullOrWhiteSpace($FolderId)) {
            $body.Add("folderId", $FolderId)
        }
        
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/dataPipelines" -Body $body
        $null = Wait-FabricOperation -Response $response

        if ($response.Body) {
            $pipeline = $response.Body
        }
        else {
            $pipelines = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/dataPipelines"
            $pipelineItems = Get-CollectionItems -ResponseBody $pipelines.Body
            $pipeline = Get-FirstByDisplayName -Items $pipelineItems -DisplayName $pipelineName
        }
    }
    else {
        $body = @{
            definition = $Definition
        }
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/dataPipelines/$($pipeline.id)/updateDefinition?updateMetadata=False" -Body $body
        $null = Wait-FabricOperation -Response $response
    }

    if ($null -eq $pipeline) {
        Write-Host "ERROR: Data pipeline was not found after deployment."
        exit 1
    }

    $PipelineConfig.pipelineId = $pipeline.id
    Save-Config -Config $Config
    Write-Host "Data pipeline ready:" $pipeline.displayName $pipeline.id

    return $pipeline.id
}

function Invoke-DataPipelineRun {
    param (
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$PipelineId,
        [Parameter(Mandatory = $true)][string]$PipelineName
    )

    $body = @{
        executionData = @{
            pipelineName = $PipelineName
        }
    }
    $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/items/$PipelineId/jobs/instances?jobType=Pipeline" -Body $body
    $null = Wait-FabricOperation -Response $response
    Write-Host "Data pipeline execution started:" $PipelineId
}

function New-NotebookDefinition {
    param ([Parameter(Mandatory = $true)]$NotebookConfig)

    $notebookSourcePath = Join-Path $notebooksRoot "$($NotebookConfig.notebookName).py"

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
            displayName = $NotebookConfig.notebookName
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
        [Parameter(Mandatory = $true)]$NotebookConfig,
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)]$Definition,
        [string]$FolderId = ""
    )

    $notebookName = $NotebookConfig.notebookName
    $notebookId = $NotebookConfig.notebookId

    if ([string]::IsNullOrWhiteSpace($notebookName)) {
        Write-Host "Notebook deployment skipped because notebookName is blank."
        return ""
    }

    $notebook = $null

    if (-not [string]::IsNullOrWhiteSpace($notebookId)) {
        $existing = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/notebooks/$notebookId"
        $notebook = $existing.Body
    }
    else {
        $notebooks = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/notebooks"
        $notebookItems = Get-CollectionItems -ResponseBody $notebooks.Body
        $notebook = Get-FirstByDisplayName -Items $notebookItems -DisplayName $notebookName
    }

    if ($null -eq $notebook) {
        $body = @{
            displayName = $notebookName
            description = "Created by Fabric Sales Analytics Accelerator"
            definition = $Definition
        }
        
        if (-not [string]::IsNullOrWhiteSpace($FolderId)) {
            $body.Add("folderId", $FolderId)
        }
        
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/notebooks" -Body $body
        $notebookOperationSucceeded = Wait-FabricOperation -Response $response -ExitOnFailure $false

        if (-not $notebookOperationSucceeded) {
            Write-Host "WARNING: Notebook deployment failed. Continuing with data pipeline deployment."
            return ""
        }

        if ($response.Body) {
            $notebook = $response.Body
        }
        else {
            $notebooks = Invoke-FabricApi -Method "GET" -Path "/workspaces/$WorkspaceId/notebooks"
            $notebookItems = Get-CollectionItems -ResponseBody $notebooks.Body
            $notebook = Get-FirstByDisplayName -Items $notebookItems -DisplayName $notebookName
        }
    }
    else {
        $body = @{
            definition = $Definition
        }
        $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/notebooks/$($notebook.id)/updateDefinition?updateMetadata=True" -Body $body
        $notebookOperationSucceeded = Wait-FabricOperation -Response $response -ExitOnFailure $false

        if (-not $notebookOperationSucceeded) {
            Write-Host "WARNING: Notebook update failed. Continuing with data pipeline deployment."
            return $notebook.id
        }
    }

    if ($null -eq $notebook) {
        Write-Host "ERROR: Notebook was not found after deployment."
        exit 1
    }

    $NotebookConfig.notebookId = $notebook.id
    Save-Config -Config $Config
    Write-Host "Notebook ready:" $notebook.displayName $notebook.id

    return $notebook.id
}

function Get-PowerBIToken {
    Write-Host "Fetching access token for Power BI REST API..."
    $token = Get-AzAccessToken "https://analysis.windows.net/powerbi/api"
    return $token
}

function Import-PowerBIReport {
    param (
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$PbixPath,
        [Parameter(Mandatory = $true)][string]$ReportName
    )

    Write-Host "Preparing Power BI report deployment for: $ReportName"
    $token = Get-PowerBIToken

    # Encode the filename to avoid spaces/special characters breaking in URL
    $escapedReportName = [Uri]::EscapeDataString("$ReportName.pbix")
    $apiUrl = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/imports?datasetDisplayName=$escapedReportName&nameConflict=Overwrite"

    $httpClient = New-Object System.Net.Http.HttpClient
    $httpClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $token)

    $fileStream = [System.IO.File]::OpenRead($PbixPath)
    $fileContent = New-Object System.Net.Http.StreamContent($fileStream)
    $fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream")

    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add($fileContent, "file", [System.IO.Path]::GetFileName($PbixPath))

    Write-Host "Uploading PBIX to Power BI Import service..."
    try {
        $response = $httpClient.PostAsync($apiUrl, $content).Result
        if (!$response.IsSuccessStatusCode) {
            $errorMsg = $response.Content.ReadAsStringAsync().Result
            Write-Host "ERROR: Power BI report import failed. Code: $($response.StatusCode). Details: $errorMsg"
            $fileStream.Close()
            exit 1
        }

        $importJson = $response.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        $fileStream.Close()
        return $importJson.id
    }
    catch {
        Write-Host "ERROR: Failed during HttpClient request: $_"
        if ($null -ne $fileStream) { $fileStream.Close() }
        exit 1
    }
}

function Wait-PowerBIImport {
    param (
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$ImportId
    )

    Write-Host "Polling PBIX import job status (ID: $ImportId)..."
    
    $token = Get-PowerBIToken
    $apiUrl = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/imports/$ImportId"

    $httpClient = New-Object System.Net.Http.HttpClient
    $httpClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $token)

    $startTime = Get-Date
    while ($true) {
        if (((Get-Date) - $startTime).TotalMinutes -gt 5) {
            Write-Host "ERROR: Import operation timed out after 5 minutes."
            exit 1
        }

        try {
            $response = $httpClient.GetAsync($apiUrl).Result
            if ($response.IsSuccessStatusCode) {
                $statusJson = $response.Content.ReadAsStringAsync().Result | ConvertFrom-Json
                $status = $statusJson.importState
                Write-Host "Current Import Status: $status"

                if ($status -eq "Succeeded") {
                    return $statusJson
                }
                elseif ($status -eq "Failed") {
                    Write-Host "ERROR: Power BI Import failed. Details:" ($statusJson | ConvertTo-Json)
                    exit 1
                }
            } else {
                Write-Host "WARNING: Polling request failed with status: $($response.StatusCode)"
            }
        }
        catch {
            Write-Host "WARNING: Failed to request polling: $_"
        }

        Start-Sleep -Seconds 5
    }
}

function Move-FabricItem {
    param (
        [Parameter(Mandatory = $true)][string]$WorkspaceId,
        [Parameter(Mandatory = $true)][string]$ItemId,
        [Parameter(Mandatory = $true)][string]$DestinationFolderId
    )

    Write-Host "Moving item (ID: $ItemId) to folder (ID: $DestinationFolderId)..."
    $body = @{
        destinationFolderId = $DestinationFolderId
    }

    $response = Invoke-FabricApi -Method "POST" -Path "/workspaces/$WorkspaceId/items/$ItemId/move" -Body $body
    return $response
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
Write-Step "Ensuring workspace capacity assignment"
Ensure-WorkspaceCapacity -Config $config -WorkspaceId $workspaceId

$config = Get-Content $configPath | ConvertFrom-Json
Write-Step "Creating workspace folder structure"
$folderStructure = New-WorkspaceFolderStructure -WorkspaceId $workspaceId

$config = Get-Content $configPath | ConvertFrom-Json
Write-Step "Ensuring Lakehouse in Resources > Lakehouses folder"
$lakehouseId = Ensure-Lakehouse -Config $config -WorkspaceId $workspaceId -FolderId $folderStructure.Lakehouses

$config = Get-Content $configPath | ConvertFrom-Json

if ($config.loadSampleData -eq $true) {
    Write-Step "Uploading sample data"
    $sourceFile = if ($null -ne $config.sourceFile) { $config.sourceFile } else { $config.pipelines[0].sourceFile }
    Upload-SampleData -WorkspaceId $workspaceId -LakehouseId $lakehouseId -SourceFile $sourceFile
}

# 1. Deploy Fabric Notebooks
$config = Get-Content $configPath | ConvertFrom-Json
$hasNotebooksArray = ($null -ne $config.notebooks -and $config.notebooks.GetType().IsArray -and $config.notebooks.Count -gt 0)

if ($hasNotebooksArray) {
    Write-Step "Deploying Fabric notebooks"
    foreach ($nb in $config.notebooks) {
        $notebookDefinition = New-NotebookDefinition -NotebookConfig $nb
        
        # Map folder destination
        $folderId = ""
        if (-not [string]::IsNullOrWhiteSpace($nb.destinationFolder) -and $folderStructure.PSObject.Properties.Name -contains $nb.destinationFolder) {
            $folderId = $folderStructure.$($nb.destinationFolder)
        } else {
            $folderId = $folderStructure.Notebooks
        }

        $notebookId = Ensure-Notebook -Config $config -NotebookConfig $nb -WorkspaceId $workspaceId -Definition $notebookDefinition -FolderId $folderId
    }
} elseif (-not [string]::IsNullOrWhiteSpace($config.notebookName)) {
    Write-Step "Deploying Fabric notebook (singular fallback)"
    $nbObj = [pscustomobject]@{
        notebookName = $config.notebookName
        notebookId = $config.notebookId
    }
    $notebookDefinition = New-NotebookDefinition -NotebookConfig $nbObj
    $notebookId = Ensure-Notebook -Config $config -NotebookConfig $nbObj -WorkspaceId $workspaceId -Definition $notebookDefinition -FolderId $folderStructure.Notebooks
    
    # Save back to singular
    Set-ConfigValue -Config $config -Name "notebookId" -Value $nbObj.notebookId
    Save-Config -Config $config
}

# 2. Deploy Fabric Pipelines
$config = Get-Content $configPath | ConvertFrom-Json
$hasPipelinesArray = ($null -ne $config.pipelines -and $config.pipelines.GetType().IsArray -and $config.pipelines.Count -gt 0)

$pipelineSummary = @()

if ($hasPipelinesArray) {
    Write-Step "Generating and deploying Fabric data pipelines"
    foreach ($p in $config.pipelines) {
        $pipelineDefinition = New-PipelineDefinition -PipelineConfig $p -WorkspaceId $workspaceId -LakehouseId $lakehouseId
        
        # Map folder destination
        $folderId = ""
        if (-not [string]::IsNullOrWhiteSpace($p.destinationFolder) -and $folderStructure.PSObject.Properties.Name -contains $p.destinationFolder) {
            $folderId = $folderStructure.$($p.destinationFolder)
        } else {
            $folderId = $folderStructure.MainDataIngestion
        }

        $pipelineId = Ensure-DataPipeline -Config $config -PipelineConfig $p -WorkspaceId $workspaceId -Definition $pipelineDefinition -FolderId $folderId
        $pipelineSummary += "[Array] $($p.pipelineName) (ID: $pipelineId)"

        if ($p.runAfterProvisioning -eq $true) {
            Write-Host "Triggering pipeline run for $($p.pipelineName)..."
            Invoke-DataPipelineRun -WorkspaceId $workspaceId -PipelineId $pipelineId -PipelineName $p.pipelineName
        }
    }
} else {
    Write-Step "Generating and deploying Fabric data pipeline (singular fallback)"
    $pObj = [pscustomobject]@{
        pipelineName = $config.pipelineName
        pipelineId = $config.pipelineId
        sourceFile = $config.sourceFile
        destinationTable = $config.destinationTable
    }
    $pipelineDefinition = New-PipelineDefinition -PipelineConfig $pObj -WorkspaceId $workspaceId -LakehouseId $lakehouseId
    $pipelineId = Ensure-DataPipeline -Config $config -PipelineConfig $pObj -WorkspaceId $workspaceId -Definition $pipelineDefinition -FolderId $folderStructure.MainDataIngestion
    $pipelineSummary += "[Singular] $($config.pipelineName) (ID: $pipelineId)"

    # Save back to singular
    Set-ConfigValue -Config $config -Name "pipelineId" -Value $pObj.pipelineId
    Save-Config -Config $config

    Write-Step "Executing Fabric data pipeline"
    Invoke-DataPipelineRun -WorkspaceId $workspaceId -PipelineId $pipelineId -PipelineName $config.pipelineName
}

# 3. Deploy Power BI Report (.pbix)
$config = Get-Content $configPath | ConvertFrom-Json
if (-not [string]::IsNullOrWhiteSpace($config.pbixFile)) {
    Write-Step "Deploying Power BI Report (.pbix)"
    
    $pbixPath = Join-Path $repoRoot "powerbi/$($config.pbixFile)"
    if (!(Test-Path $pbixPath)) {
        Write-Host "ERROR: Power BI report file not found at: $pbixPath"
        exit 1
    }

    $reportName = [System.IO.Path]::GetFileNameWithoutExtension($config.pbixFile)
    
    # Import the report
    $importId = Import-PowerBIReport -WorkspaceId $workspaceId -PbixPath $pbixPath -ReportName $reportName
    
    # Wait for the import to complete successfully
    $importResult = Wait-PowerBIImport -WorkspaceId $workspaceId -ImportId $importId

    # Map destination folder
    $destFolderId = ""
    if (-not [string]::IsNullOrWhiteSpace($config.pbixFolder) -and $folderStructure.PSObject.Properties.Name -contains $config.pbixFolder) {
        $destFolderId = $folderStructure.$($config.pbixFolder)
    } else {
        $destFolderId = $folderStructure.PowerBIReports
    }

    # Move the newly imported report item to the Reports > Power BI Reports folder
    if ($null -ne $importResult.reports -and $importResult.reports.Count -gt 0) {
        foreach ($rep in $importResult.reports) {
            Write-Host "Relocating report '$($rep.name)' (ID: $($rep.id)) to folder..."
            $null = Move-FabricItem -WorkspaceId $workspaceId -ItemId $($rep.id) -DestinationFolderId $destFolderId
        }
    }
    Write-Host "Power BI report deployed successfully!"
}

Write-Host ""
Write-Host "Provisioning completed successfully."
Write-Host "Workspace ID:" $workspaceId
Write-Host "Lakehouse ID:" $lakehouseId
Write-Host "Pipelines deployed:"
foreach ($sum in $pipelineSummary) {
    Write-Host "  -$sum"
}
Write-Host "Folder Structure:"
Write-Host "  - Data Ingestion (ID: $($folderStructure.DataIngestion))"
Write-Host "    - Main Data Ingestion (ID: $($folderStructure.MainDataIngestion))"
Write-Host "    - Audit (ID: $($folderStructure.Audit))"
Write-Host "    - Notification (ID: $($folderStructure.Notification))"
Write-Host "  - Resources (ID: $($folderStructure.Resources))"
Write-Host "    - Lakehouses (ID: $($folderStructure.Lakehouses))"
Write-Host "    - Warehouses (ID: $($folderStructure.Warehouses))"
Write-Host "    - Notebooks (ID: $($folderStructure.Notebooks))"
Write-Host "  - Reports (ID: $($folderStructure.Reports))"
Write-Host "    - Power BI Reports (ID: $($folderStructure.PowerBIReports))"
Write-Host "    - Dashboards (ID: $($folderStructure.Dashboards))"
Write-Host ""
