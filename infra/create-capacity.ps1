param (
    [switch]$UseConfig,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$CapacityName
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$configPath = Join-Path $repoRoot "config/accelerator-config.json"

if (!(Test-Path $configPath)) {
    Write-Host "ERROR: Config file not found."
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json
$location = $config.location
$capacitySku = $config.capacitySku

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

function Set-ConfigValue {
    param (
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ($Config.PSObject.Properties.Name -contains $Name) {
        $Config.$Name = $Value
    }
    else {
        $Config | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Save-Config {
    param ([Parameter(Mandatory = $true)]$Config)

    $Config | ConvertTo-Json -Depth 20 | Set-Content $configPath
}

function Read-Value {
    param (
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$DefaultValue = ""
    )

    if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
        return Read-Host $Prompt
    }

    $value = Read-Host "$Prompt [$DefaultValue]"

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value
}

function Select-AzureSubscription {
    param (
        [string]$RequestedSubscriptionId,
        [switch]$UseExistingConfig
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSubscriptionId)) {
        az account set --subscription $RequestedSubscriptionId
        Assert-LastExitCode "Failed to select Azure subscription $RequestedSubscriptionId."
        return $RequestedSubscriptionId
    }

    if ($UseExistingConfig -and -not [string]::IsNullOrWhiteSpace($config.subscriptionId)) {
        az account set --subscription $config.subscriptionId
        Assert-LastExitCode "Failed to select Azure subscription $($config.subscriptionId)."
        return $config.subscriptionId
    }

    if ($UseExistingConfig) {
        $currentId = az account show --query id -o tsv
        Assert-LastExitCode "Failed to read current Azure subscription."
        return $currentId
    }

    $subscriptions = az account list -o json | ConvertFrom-Json
    Assert-LastExitCode "Failed to list Azure subscriptions."

    if ($null -eq $subscriptions -or @($subscriptions).Count -eq 0) {
        Write-Host "ERROR: No Azure subscriptions found for this login."
        exit 1
    }

    Write-Host ""
    Write-Host "Choose Azure subscription:"

    for ($i = 0; $i -lt @($subscriptions).Count; $i++) {
        $subscription = @($subscriptions)[$i]
        $marker = if ($subscription.isDefault) { "*" } else { " " }
        Write-Host ("[{0}] {1} {2} ({3})" -f ($i + 1), $marker, $subscription.name, $subscription.id)
    }

    $choice = Read-Host "Enter subscription number"
    $choiceNumber = 0

    if (-not [int]::TryParse($choice, [ref]$choiceNumber) -or $choiceNumber -lt 1 -or $choiceNumber -gt @($subscriptions).Count) {
        Write-Host "ERROR: Invalid subscription choice."
        exit 1
    }

    $selected = @($subscriptions)[$choiceNumber - 1]
    az account set --subscription $selected.id
    Assert-LastExitCode "Failed to select Azure subscription $($selected.id)."

    return $selected.id
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
Write-Host "Selecting Azure Subscription..."

$selectedSubscriptionId = Select-AzureSubscription -RequestedSubscriptionId $SubscriptionId -UseExistingConfig:$UseConfig
Set-ConfigValue -Config $config -Name "subscriptionId" -Value $selectedSubscriptionId
Save-Config -Config $config

$resourceGroup = $ResourceGroup

if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
    if ($UseConfig) {
        $resourceGroup = $config.resourceGroup
    }
    else {
        $resourceGroup = Read-Value -Prompt "Enter resource group name" -DefaultValue $config.resourceGroup
    }
}

$capacityName = $CapacityName

if ([string]::IsNullOrWhiteSpace($capacityName)) {
    if ($UseConfig) {
        $capacityName = $config.capacityName
    }
    else {
        $capacityName = Read-Value -Prompt "Enter Fabric capacity name" -DefaultValue $config.capacityName
    }
}

if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
    Write-Host "ERROR: Resource group name is required."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($capacityName)) {
    Write-Host "ERROR: Fabric capacity name is required."
    exit 1
}

Set-ConfigValue -Config $config -Name "resourceGroup" -Value $resourceGroup
Set-ConfigValue -Config $config -Name "capacityName" -Value $capacityName
Save-Config -Config $config

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
        Set-ConfigValue -Config $config -Name "capacityId" -Value $capacityId
        Save-Config -Config $config
        Write-Host "Capacity ID saved to accelerator-config.json:" $capacityId
    }
}

Write-Host ""
Write-Host "Fabric Capacity Created Successfully!"
