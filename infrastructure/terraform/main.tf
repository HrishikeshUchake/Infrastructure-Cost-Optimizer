# AI-Driven Infrastructure Cost Optimization - Main Terraform Configuration
# This configuration deploys the complete infrastructure for the cost optimization solution

terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

# Data sources
data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

# Random suffix for unique resource names
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Local variables
locals {
  resource_suffix = var.unique_suffix != "" ? var.unique_suffix : random_string.suffix.result
  common_tags = merge(var.resource_tags, {
    deployedBy   = "terraform"
    createdDate  = formatdate("YYYY-MM-DD", timestamp())
    uniqueSuffix = local.resource_suffix
  })
  
  # Resource names
  workspace_name          = "law-costopt-${local.resource_suffix}"
  automation_account_name = "aa-costopt-${local.resource_suffix}"
  storage_account_name    = "sacostopt${local.resource_suffix}"
  key_vault_name         = "kv-costopt-${local.resource_suffix}"
  app_insights_name      = "ai-costopt-${local.resource_suffix}"
  action_group_name      = "ag-costopt-${local.resource_suffix}"
  logic_app_name         = "la-costopt-${local.resource_suffix}"
  budget_name           = "budget-costopt-${local.resource_suffix}"
}

# Log Analytics Workspace
resource "azurerm_log_analytics_workspace" "cost_optimization" {
  name                = local.workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 10

  tags = local.common_tags
}

# Storage Account
resource "azurerm_storage_account" "cost_optimization" {
  name                     = local.storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

# Key Vault
resource "azurerm_key_vault" "cost_optimization" {
  name                       = local.key_vault_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  enable_rbac_authorization = true

  tags = local.common_tags
}

# Application Insights
resource "azurerm_application_insights" "cost_optimization" {
  name                = local.app_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.cost_optimization.id
  application_type    = "web"
  retention_in_days   = 30

  tags = local.common_tags
}

# Automation Account
resource "azurerm_automation_account" "cost_optimization" {
  name                = local.automation_account_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# Action Group
resource "azurerm_monitor_action_group" "cost_optimization" {
  name                = local.action_group_name
  resource_group_name = var.resource_group_name
  short_name          = "CostOpt"

  email_receiver {
    name          = "Admin"
    email_address = var.notification_email
  }

  logic_app_receiver {
    name                    = "CostWorkflow"
    resource_id             = azurerm_logic_app_workflow.cost_optimization.id
    callback_url            = azurerm_logic_app_trigger_http_request.cost_alert.callback_url
    use_common_alert_schema = true
  }

  tags = local.common_tags
}

# Logic App Workflow
resource "azurerm_logic_app_workflow" "cost_optimization" {
  name                = local.logic_app_name
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = local.common_tags
}

# Logic App HTTP Request Trigger
resource "azurerm_logic_app_trigger_http_request" "cost_alert" {
  name         = "When_a_cost_alert_is_triggered"
  logic_app_id = azurerm_logic_app_workflow.cost_optimization.id

  schema = jsonencode({
    type = "object"
    properties = {
      alertType = {
        type = "string"
      }
      resourceId = {
        type = "string"
      }
      severity = {
        type = "string"
      }
      description = {
        type = "string"
      }
    }
  })
}

# Logic App Action - Parse JSON
resource "azurerm_logic_app_action_custom" "parse_alert_data" {
  name         = "Parse_Alert_Data"
  logic_app_id = azurerm_logic_app_workflow.cost_optimization.id

  body = jsonencode({
    type = "ParseJson"
    inputs = {
      content = "@triggerBody()"
      schema = {
        type = "object"
        properties = {
          alertType = {
            type = "string"
          }
          resourceId = {
            type = "string"
          }
          severity = {
            type = "string"
          }
          description = {
            type = "string"
          }
        }
      }
    }
  })

  depends_on = [azurerm_logic_app_trigger_http_request.cost_alert]
}

# Budget
resource "azurerm_consumption_budget_resource_group" "cost_optimization" {
  name              = local.budget_name
  resource_group_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"

  amount     = var.monthly_budget_amount
  time_grain = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01", timestamp())
    end_date   = formatdate("YYYY-MM-01", timeadd(timestamp(), "8760h"))
  }

  notification {
    enabled         = true
    threshold       = 80
    operator        = "GreaterThan"
    threshold_type  = "Actual"
    contact_emails  = [var.notification_email]
    contact_groups  = [azurerm_monitor_action_group.cost_optimization.id]
  }

  notification {
    enabled         = true
    threshold       = 100
    operator        = "GreaterThan"
    threshold_type  = "Forecasted"
    contact_emails  = [var.notification_email]
    contact_groups  = [azurerm_monitor_action_group.cost_optimization.id]
  }
}

# Activity Log Alert - High Cost Resource Creation
resource "azurerm_monitor_activity_log_alert" "high_cost_resource" {
  name                = "HighCostResourceAlert"
  resource_group_name = var.resource_group_name
  scopes              = [data.azurerm_subscription.current.id]
  description         = "Alert when new expensive VMs are created"

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.Compute/virtualMachines/write"
  }

  action {
    action_group_id = azurerm_monitor_action_group.cost_optimization.id
  }

  tags = local.common_tags
}

# Activity Log Alert - Cost Anomaly Detection
resource "azurerm_monitor_activity_log_alert" "cost_anomaly" {
  name                = "CostAnomalyDetection"
  resource_group_name = var.resource_group_name
  scopes              = [data.azurerm_subscription.current.id]
  description         = "Detect unusual resource creation patterns"

  criteria {
    category = "Administrative"
    operation_name_value = [
      "Microsoft.Compute/virtualMachines/write",
      "Microsoft.Storage/storageAccounts/write",
      "Microsoft.Sql/servers/databases/write"
    ]
  }

  action {
    action_group_id = azurerm_monitor_action_group.cost_optimization.id
  }

  tags = local.common_tags
}

# Metric Alert - VM Low CPU Utilization
resource "azurerm_monitor_metric_alert" "vm_low_cpu" {
  name                = "VM-Low-CPU-Utilization"
  resource_group_name = var.resource_group_name
  scopes              = ["/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"]
  description         = "Alert when VM CPU utilization is consistently low (optimization opportunity)"
  severity            = 3
  frequency           = "PT5M"
  window_size         = "PT1H"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 10
  }

  action {
    action_group_id = azurerm_monitor_action_group.cost_optimization.id
  }

  tags = local.common_tags
}

# Role Assignments for Automation Account
resource "azurerm_role_assignment" "automation_vm_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_automation_account.cost_optimization.identity[0].principal_id
}

resource "azurerm_role_assignment" "automation_storage_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = azurerm_automation_account.cost_optimization.identity[0].principal_id
}

resource "azurerm_role_assignment" "automation_sql_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "SQL DB Contributor"
  principal_id         = azurerm_automation_account.cost_optimization.identity[0].principal_id
}

resource "azurerm_role_assignment" "automation_cost_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Cost Management Reader"
  principal_id         = azurerm_automation_account.cost_optimization.identity[0].principal_id
}

resource "azurerm_role_assignment" "automation_monitoring_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_automation_account.cost_optimization.identity[0].principal_id
}

# Automation Runbooks (placeholder - actual runbooks deployed via scripts)
resource "azurerm_automation_runbook" "vm_optimization" {
  name                    = "Optimize-VMSize"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  log_verbose             = true
  log_progress            = true
  description             = "VM Right-sizing Automation Runbook for Cost Optimization"
  runbook_type            = "PowerShell"

  content = file("${path.module}/../../runbooks/vm-optimization.ps1")

  tags = local.common_tags
}

resource "azurerm_automation_runbook" "storage_optimization" {
  name                    = "Optimize-Storage"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  log_verbose             = true
  log_progress            = true
  description             = "Storage Optimization Automation Runbook for Cost Optimization"
  runbook_type            = "PowerShell"

  content = file("${path.module}/../../runbooks/storage-optimization.ps1")

  tags = local.common_tags
}

resource "azurerm_automation_runbook" "database_optimization" {
  name                    = "Optimize-Database"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  log_verbose             = true
  log_progress            = true
  description             = "Database Optimization Automation Runbook for Cost Optimization"
  runbook_type            = "PowerShell"

  content = file("${path.module}/../../runbooks/database-optimization.ps1")

  tags = local.common_tags
}

# Automation Schedules
resource "azurerm_automation_schedule" "vm_optimization_daily" {
  name                    = "VMOptimizationDaily"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  frequency               = "Day"
  interval                = 1
  timezone                = "UTC"
  start_time              = formatdate("YYYY-MM-DD'T'02:00:00Z", timeadd(timestamp(), "24h"))
  description             = "Daily VM optimization schedule"
}

resource "azurerm_automation_schedule" "storage_optimization_weekly" {
  name                    = "StorageOptimizationWeekly"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  frequency               = "Week"
  interval                = 1
  timezone                = "UTC"
  start_time              = formatdate("YYYY-MM-DD'T'03:00:00Z", timeadd(timestamp(), "168h"))
  description             = "Weekly storage optimization schedule"
  week_days               = ["Sunday"]
}

resource "azurerm_automation_schedule" "database_optimization_weekly" {
  name                    = "DatabaseOptimizationWeekly"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  frequency               = "Week"
  interval                = 1
  timezone                = "UTC"
  start_time              = formatdate("YYYY-MM-DD'T'01:00:00Z", timeadd(timestamp(), "144h"))
  description             = "Weekly database optimization schedule"
  week_days               = ["Saturday"]
}

# Link Runbooks to Schedules
resource "azurerm_automation_job_schedule" "vm_optimization_schedule" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  schedule_name           = azurerm_automation_schedule.vm_optimization_daily.name
  runbook_name           = azurerm_automation_runbook.vm_optimization.name

  parameters = {
    DryRun = "false"
  }
}

resource "azurerm_automation_job_schedule" "storage_optimization_schedule" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  schedule_name           = azurerm_automation_schedule.storage_optimization_weekly.name
  runbook_name           = azurerm_automation_runbook.storage_optimization.name

  parameters = {
    DryRun = "false"
  }
}

resource "azurerm_automation_job_schedule" "database_optimization_schedule" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.cost_optimization.name
  schedule_name           = azurerm_automation_schedule.database_optimization_weekly.name
  runbook_name           = azurerm_automation_runbook.database_optimization.name

  parameters = {
    DatabaseType = "All"
    DryRun       = "false"
  }
}