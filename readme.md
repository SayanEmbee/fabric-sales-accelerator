# Fabric Sales Analytics Accelerator

A beginner-friendly Microsoft Fabric accelerator for creating a small sales analytics solution with Azure/Fabric capacity, a Lakehouse pipeline template, sample sales data, and a Power BI report.

## Features

- Azure resource group and Microsoft Fabric F2 capacity script
- Automated Fabric workspace creation
- Automated Lakehouse creation
- Automated sample data upload to OneLake
- Automated Fabric data pipeline import/deployment
- Automated Fabric notebook import/deployment
- GitHub Actions validation and optional provisioning workflow
- Lakehouse copy pipeline template for CSV to Lakehouse table loading
- Sample sales dataset
- PowerShell deployment helper
- Power BI dashboard file
- Repo structure ready for notebooks, pipeline exports, and future CI/CD

## Start Here for Beginners

Follow these steps in order if you are new to Azure, Fabric, or PowerShell.

### 1. Clone This Repository

Open PowerShell and run:

```powershell
git clone https://github.com/SayanEmbee/fabric-sales-accelerator.git
```

This downloads the accelerator code to your machine.

### 2. Open PowerShell in the Project Folder

Go to the project folder:

```powershell
cd fabric-sales-accelerator
```

If you cloned it somewhere specific, go to that folder instead. Example:

```powershell
cd C:\Users\015237\Desktop\fabric-sales-accelerator
```

### 3. Check Azure CLI

Run:

```powershell
az --version
```

If this command is not found, install Azure CLI first:

```text
https://learn.microsoft.com/cli/azure/install-azure-cli
```

### 4. Login to Azure

Run:

```powershell
az login
```

Then confirm the active subscription:

```powershell
az account show
```

If the wrong subscription is active, set the correct one:

```powershell
az account set --subscription "<your-subscription-id>"
```

### 5. Install the Fabric CLI Extension

Run:

```powershell
az extension add --name microsoft-fabric --allow-preview true
```

### 6. Review the Config File

Open:

```text
config/accelerator-config.json
```

For a first run, you can leave these values blank:

- `workspaceId`
- `lakehouseId`
- `pipelineId`
- `notebookId`
- `capacityId`

The scripts fill them in after resources are created or found.

You can change these names if needed:

- `workspaceName`
- `lakehouseName`
- `pipelineName`
- `notebookName`
- `resourceGroup`
- `capacityName`
- `location`

### 7. Create Fabric Capacity

This step can create Azure cost. Run it only when you are ready:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\infra\create-capacity.ps1
```

### 8. Provision the Fabric Accelerator

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-fabric.ps1
```

This creates or updates:

- Fabric workspace
- Lakehouse
- Sample data upload
- Notebook
- Data pipeline

### 9. Check the Results

After the script completes, check:

- `config/accelerator-config.json` now has generated IDs
- `pipelines/salesdatapipeline.json` exists
- The Fabric workspace exists in the Fabric portal
- The Lakehouse contains `sales.csv` under `Files`
- The notebook and pipeline exist in the workspace

### 10. Common Beginner Fixes

If PowerShell says scripts are disabled, use the commands exactly as shown with:

```powershell
-ExecutionPolicy Bypass
```

If Azure says you do not have permission, ask your Azure/Fabric admin for:

- Permission to create resource groups or Fabric capacity
- Permission to create Fabric workspaces
- Contributor access to the target Fabric workspace or capacity

If the Fabric extension install fails, run:

```powershell
az config set extension.dynamic_install_allow_preview=true
az extension add --name microsoft-fabric --allow-preview true
```

## Project Structure

```text
fabric-sales-accelerator/
|
+-- config/
|   +-- accelerator-config.json
|   +-- salesdatapipeline.json
+-- data/
|   +-- sales.csv
+-- infra/
|   +-- create-capacity.ps1
+-- notebooks/
|   +-- sales_transform.py
+-- pipelines/
+-- powerbi/
|   +-- SalesDashboard.pbix
+-- scripts/
    +-- deploy.ps1
    +-- provision-fabric.ps1
+-- .github/
    +-- workflows/
        +-- ci.yml
```

## Prerequisites

- Azure CLI installed and logged in
- Microsoft Fabric Azure CLI extension
- PowerShell 5.1 or later
- Permission to create Microsoft Fabric workspaces
- Contributor access to the target Fabric capacity/workspace
- Permission to create or manage Fabric capacity in the Azure subscription

Install the Fabric CLI extension if needed:

```powershell
az extension add --name microsoft-fabric --allow-preview true
```

Check Azure login:

```powershell
az account show
```

## Configuration

Update `config/accelerator-config.json` before deployment:

```json
{
  "workspaceName": "SalesAnalyticsWorkspace",
  "workspaceId": "",
  "lakehouseName": "SalesLakehouse",
  "lakehouseId": "",
  "pipelineName": "salesdatapipeline",
  "pipelineId": "",
  "notebookName": "sales_transform",
  "notebookId": "",
  "resourceGroup": "rg-fabric-dev",
  "capacityName": "fabricf2dev",
  "capacityId": "",
  "location": "CentralIndia",
  "capacitySku": "F2",
  "sourceFile": "sales.csv",
  "destinationTable": "sales",
  "loadSampleData": true
}
```

Leave `workspaceId`, `lakehouseId`, `pipelineId`, `notebookId`, and `capacityId` blank for a first run. The automation script fills them in after it finds or creates the resources.

## Create Fabric Capacity

Run this only when you want to create or update Azure resources. Fabric capacity can create Azure cost.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\infra\create-capacity.ps1
```

The script creates or updates:

- Resource group: `rg-fabric-dev`
- Capacity: `fabricf2dev`
- SKU: `F2`
- Location: `CentralIndia`

It also saves `capacityId` back into `config/accelerator-config.json` when the Azure CLI returns it.

## Provision Fabric Accelerator

Run the full Fabric automation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-fabric.ps1
```

This script:

- Finds or creates the Fabric workspace
- Finds or creates the Lakehouse
- Uploads `data/sales.csv` into the Lakehouse `Files` area
- Creates or updates the Fabric notebook item from `notebooks/sales_transform.py`
- Generates `pipelines/salesdatapipeline.json`
- Creates or updates the Fabric data pipeline item
- Saves discovered IDs back into `config/accelerator-config.json`

## Notebook Automation

Notebook source:

```text
notebooks/sales_transform.py
```

The provisioning script deploys it as a Fabric notebook using the Notebook REST API in `fabricGitSource` format. The notebook reads the `sales` table and writes a Delta summary table named `sales_summary_by_region`.

## CI/CD

GitHub Actions workflow:

```text
.github/workflows/ci.yml
```

The `validate` job runs on push and pull request. It checks:

- JSON syntax
- PowerShell syntax
- Required accelerator assets

The `provision` job is manual-only through `workflow_dispatch`. Set `provision_fabric` to `true` when starting the workflow. It requires these GitHub secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

The Azure identity must have permission to create/manage the Azure capacity and Fabric resources.

## Generate Pipeline Only

After `workspaceId` and `lakehouseId` are set, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
```

This reads the template from:

```text
config/salesdatapipeline.json
```

And generates the deployable pipeline JSON at:

```text
pipelines/salesdatapipeline.json
```

## Data

Sample file:

```text
data/sales.csv
```

The pipeline expects this file to be available in the Lakehouse `Files` area using the configured `sourceFile` value.

## Current Status

- [x] Repository structure
- [x] Configuration file
- [x] Sample dataset
- [x] Capacity creation script
- [x] Pipeline template
- [x] Pipeline generation script
- [x] Power BI dashboard file
- [x] Automated Fabric workspace creation
- [x] Automated Lakehouse creation
- [x] Automated sample data upload
- [x] Automated pipeline import/deployment to Fabric
- [x] Notebook automation
- [x] CI/CD

## Validation

Basic local checks:

```powershell
Get-Content .\config\accelerator-config.json -Raw | ConvertFrom-Json
Get-Content .\config\salesdatapipeline.json -Raw | ConvertFrom-Json
```

PowerShell parser checks:

```powershell
$files = @('.\infra\create-capacity.ps1', '.\scripts\deploy.ps1', '.\scripts\provision-fabric.ps1')
foreach ($file in $files) {
  $errors = $null
  $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $file -Raw), [ref]$errors)
  if ($errors) { $errors; exit 1 }
}
```

If PowerShell blocks script execution, use the `-ExecutionPolicy Bypass` command shown above. This bypass is process-scoped for that command.

## Future Enhancements

- Medallion architecture
- Incremental data loading
- Automated Power BI publishing
