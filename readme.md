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
