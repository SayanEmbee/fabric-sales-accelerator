# Fabric Sales Analytics Accelerator

A beginner-friendly Microsoft Fabric accelerator for creating a small sales analytics solution with Azure/Fabric capacity, a Lakehouse pipeline template, sample sales data, and a Power BI report.

## Features

- Azure resource group and Microsoft Fabric F2 capacity script
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
+-- pipelines/
+-- powerbi/
|   +-- SalesDashboard.pbix
+-- scripts/
    +-- deploy.ps1
```

## Prerequisites

- Azure CLI installed and logged in
- Microsoft Fabric Azure CLI extension
- PowerShell 5.1 or later
- Microsoft Fabric workspace
- Microsoft Fabric Lakehouse
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
  "workspaceId": "<fabric-workspace-id>",
  "lakehouseName": "SalesLakehouse",
  "lakehouseId": "<fabric-lakehouse-artifact-id>",
  "pipelineName": "salesdatapipeline",
  "capacityName": "fabricf2dev",
  "sourceFile": "sales.csv",
  "destinationTable": "sales",
  "loadSampleData": true
}
```

Important: `lakehouseId` must be the Lakehouse artifact ID, not only the display name.

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

## Generate Pipeline

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
- [ ] Automated Fabric workspace creation
- [ ] Automated Lakehouse creation
- [ ] Automated sample data upload
- [ ] Automated pipeline import/deployment to Fabric
- [ ] Notebook automation
- [ ] CI/CD

## Validation

Basic local checks:

```powershell
Get-Content .\config\accelerator-config.json -Raw | ConvertFrom-Json
Get-Content .\config\salesdatapipeline.json -Raw | ConvertFrom-Json
```

If PowerShell blocks script execution, use the `-ExecutionPolicy Bypass` command shown above. This bypass is process-scoped for that command.

## Future Enhancements

- Fabric REST API deployment
- Automated workspace, Lakehouse, and pipeline creation
- Sample data upload automation
- Medallion architecture
- Incremental data loading
- Notebook-driven transformations
- Automated Power BI publishing
- GitHub Actions CI/CD
