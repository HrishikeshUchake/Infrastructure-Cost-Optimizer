# Infrastructure Cost Optimizer

An Azure automation project for identifying and acting on infrastructure cost-optimization opportunities. It combines Azure Monitor and Log Analytics with Azure Automation runbooks for virtual machines, storage, and databases.

## What it includes

- VM right-sizing based on utilization metrics
- Blob storage tier recommendations and lifecycle optimization
- SQL Database and Cosmos DB utilization analysis
- Azure Monitor alerts, Log Analytics, Key Vault, and Automation Account provisioning
- Bicep and Terraform infrastructure templates

## Architecture

```text
Azure Monitor → Log Analytics → Azure Automation → VM / Storage / Database actions
```

The Azure Automation account uses a managed identity. Give that identity only the roles needed for the resources it will assess or modify.

## Prerequisites

- An Azure subscription and Azure CLI login (`az login`)
- Contributor access to the target resource group or subscription
- Permission to create role assignments when using the deployment scripts
- PowerShell 7+ for runbook development or local testing
- Bicep CLI or Terraform, if using the corresponding infrastructure template

## Quick start

The shell-script workflow creates an `.env` file, a resource group, and the foundational Azure resources. Review the generated names and costs before continuing.

```bash
git clone <repository-url>
cd Infrastructure-Cost-Optimizer
chmod +x scripts/*.sh

./scripts/setup-environment.sh
./scripts/deploy-infrastructure.sh
./scripts/configure-monitoring.sh
./scripts/deploy-runbooks.sh
./scripts/validate-deployment.sh
```

`setup-environment.sh` checks your Azure login, generates resource names, creates `.env`, and provisions the initial resource group, Log Analytics workspace, storage account, and Key Vault. The later scripts use the values in `.env`.

## Infrastructure as code

Use one infrastructure approach for a deployment; do not run it alongside the shell-script provisioning workflow against the same resources without reviewing the overlap.

### Bicep

```bash
cd infrastructure/bicep
az deployment group create \
  --resource-group <resource-group> \
  --template-file main.bicep \
  --parameters @main.parameters.json notificationEmail=<email-address>
```

### Terraform

```bash
cd infrastructure/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your deployment values.
terraform init
terraform plan
terraform apply
```

## Runbooks

| Runbook | Azure Automation name | Purpose |
| --- | --- | --- |
| `runbooks/vm-optimization.ps1` | `Optimize-VMSize` | Recommends or applies VM size changes. |
| `runbooks/storage-optimization.ps1` | `Optimize-Storage` | Evaluates storage access patterns and tier changes. |
| `runbooks/database-optimization.ps1` | `Optimize-Database` | Evaluates SQL Database and Cosmos DB utilization. |

Runbooks can change Azure resources. Start with `DryRun=$true` and use `Force=$false` while validating recommendations.

```powershell
Start-AzAutomationRunbook `
  -AutomationAccountName $env:AUTOMATION_ACCOUNT `
  -ResourceGroupName $env:RESOURCE_GROUP `
  -Name 'Optimize-VMSize' `
  -Parameters @{ ResourceGroupName = '<target-resource-group>'; DryRun = $true }
```

## Configuration and monitoring

- The deployment scripts read `.env`; it is created by `scripts/setup-environment.sh`.
- `.env.example` is a reference template for Azure configuration values. Keep credentials out of source control.
- Optimization thresholds are defined in the PowerShell runbooks.
- `scripts/configure-monitoring.sh` creates Azure Monitor alerts for low and high utilization patterns.
- Review Azure Automation job history and Log Analytics when assessing recommendations or failures.

## Troubleshooting

```bash
# Confirm the active Azure account and subscription
az account show

# Validate provisioned resources and automation configuration
./scripts/validate-deployment.sh
```

For failed runbooks, inspect the Azure Automation job output and confirm that the Automation Account managed identity has the required RBAC roles on the target scope.

## Project layout

```text
infrastructure/  Bicep and Terraform templates
runbooks/        PowerShell optimization runbooks
scripts/         Setup, deployment, monitoring, and validation scripts
docs/            Supporting project documentation
```

Work in progress...
