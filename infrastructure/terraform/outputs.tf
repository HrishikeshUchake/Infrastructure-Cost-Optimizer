# Outputs for AI-Driven Infrastructure Cost Optimization

# Core Infrastructure Outputs
output "resource_group_name" {
  description = "Name of the resource group"
  value       = var.resource_group_name
}

output "location" {
  description = "Azure region where resources are deployed"
  value       = var.location
}

output "unique_suffix" {
  description = "Unique suffix used for resource names"
  value       = local.resource_suffix
}

# Log Analytics Workspace
output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.cost_optimization.id
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.cost_optimization.name
}

output "log_analytics_workspace_workspace_id" {
  description = "Workspace ID (GUID) of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.cost_optimization.workspace_id
}

output "log_analytics_workspace_primary_shared_key" {
  description = "Primary shared key for the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.cost_optimization.primary_shared_key
  sensitive   = true
}

# Automation Account
output "automation_account_id" {
  description = "Resource ID of the Automation Account"
  value       = azurerm_automation_account.cost_optimization.id
}

output "automation_account_name" {
  description = "Name of the Automation Account"
  value       = azurerm_automation_account.cost_optimization.name
}

output "automation_account_principal_id" {
  description = "Principal ID of the Automation Account managed identity"
  value       = azurerm_automation_account.cost_optimization.identity[0].principal_id
}

output "automation_account_tenant_id" {
  description = "Tenant ID of the Automation Account managed identity"
  value       = azurerm_automation_account.cost_optimization.identity[0].tenant_id
}

# Storage Account
output "storage_account_id" {
  description = "Resource ID of the Storage Account"
  value       = azurerm_storage_account.cost_optimization.id
}

output "storage_account_name" {
  description = "Name of the Storage Account"
  value       = azurerm_storage_account.cost_optimization.name
}

output "storage_account_primary_blob_endpoint" {
  description = "Primary blob endpoint of the Storage Account"
  value       = azurerm_storage_account.cost_optimization.primary_blob_endpoint
}

output "storage_account_primary_access_key" {
  description = "Primary access key for the Storage Account"
  value       = azurerm_storage_account.cost_optimization.primary_access_key
  sensitive   = true
}

# Key Vault
output "key_vault_id" {
  description = "Resource ID of the Key Vault"
  value       = azurerm_key_vault.cost_optimization.id
}

output "key_vault_name" {
  description = "Name of the Key Vault"
  value       = azurerm_key_vault.cost_optimization.name
}

output "key_vault_uri" {
  description = "URI of the Key Vault"
  value       = azurerm_key_vault.cost_optimization.vault_uri
}

# Application Insights
output "application_insights_id" {
  description = "Resource ID of Application Insights"
  value       = azurerm_application_insights.cost_optimization.id
}

output "application_insights_name" {
  description = "Name of Application Insights"
  value       = azurerm_application_insights.cost_optimization.name
}

output "application_insights_instrumentation_key" {
  description = "Instrumentation key for Application Insights"
  value       = azurerm_application_insights.cost_optimization.instrumentation_key
  sensitive   = true
}

output "application_insights_connection_string" {
  description = "Connection string for Application Insights"
  value       = azurerm_application_insights.cost_optimization.connection_string
  sensitive   = true
}

# Action Group
output "action_group_id" {
  description = "Resource ID of the Action Group"
  value       = azurerm_monitor_action_group.cost_optimization.id
}

output "action_group_name" {
  description = "Name of the Action Group"
  value       = azurerm_monitor_action_group.cost_optimization.name
}

# Logic App
output "logic_app_id" {
  description = "Resource ID of the Logic App"
  value       = azurerm_logic_app_workflow.cost_optimization.id
}

output "logic_app_name" {
  description = "Name of the Logic App"
  value       = azurerm_logic_app_workflow.cost_optimization.name
}

output "logic_app_callback_url" {
  description = "Callback URL for the Logic App HTTP trigger"
  value       = azurerm_logic_app_trigger_http_request.cost_alert.callback_url
  sensitive   = true
}

# Budget
output "budget_id" {
  description = "Resource ID of the Budget"
  value       = azurerm_consumption_budget_resource_group.cost_optimization.id
}

output "budget_name" {
  description = "Name of the Budget"
  value       = azurerm_consumption_budget_resource_group.cost_optimization.name
}

# Runbooks
output "runbook_names" {
  description = "Names of the deployed runbooks"
  value = {
    vm_optimization       = azurerm_automation_runbook.vm_optimization.name
    storage_optimization  = azurerm_automation_runbook.storage_optimization.name
    database_optimization = azurerm_automation_runbook.database_optimization.name
  }
}

output "runbook_ids" {
  description = "Resource IDs of the deployed runbooks"
  value = {
    vm_optimization       = azurerm_automation_runbook.vm_optimization.id
    storage_optimization  = azurerm_automation_runbook.storage_optimization.id
    database_optimization = azurerm_automation_runbook.database_optimization.id
  }
}

# Schedules
output "schedule_names" {
  description = "Names of the automation schedules"
  value = {
    vm_optimization_daily       = azurerm_automation_schedule.vm_optimization_daily.name
    storage_optimization_weekly = azurerm_automation_schedule.storage_optimization_weekly.name
    database_optimization_weekly = azurerm_automation_schedule.database_optimization_weekly.name
  }
}

output "schedule_ids" {
  description = "Resource IDs of the automation schedules"
  value = {
    vm_optimization_daily       = azurerm_automation_schedule.vm_optimization_daily.id
    storage_optimization_weekly = azurerm_automation_schedule.storage_optimization_weekly.id
    database_optimization_weekly = azurerm_automation_schedule.database_optimization_weekly.id
  }
}

# Alerts
output "activity_log_alert_ids" {
  description = "Resource IDs of the activity log alerts"
  value = {
    high_cost_resource = azurerm_monitor_activity_log_alert.high_cost_resource.id
    cost_anomaly      = azurerm_monitor_activity_log_alert.cost_anomaly.id
  }
}

output "metric_alert_ids" {
  description = "Resource IDs of the metric alerts"
  value = {
    vm_low_cpu = azurerm_monitor_metric_alert.vm_low_cpu.id
  }
}

# Configuration Summary
output "deployment_summary" {
  description = "Summary of the deployed infrastructure"
  value = {
    deployment_date     = timestamp()
    environment        = var.environment
    location           = var.location
    resource_count     = 15
    monthly_budget     = var.monthly_budget_amount
    notification_email = var.notification_email
    tags              = local.common_tags
  }
}

# Connection Information
output "connection_info" {
  description = "Connection information for external integrations"
  value = {
    subscription_id           = data.azurerm_subscription.current.subscription_id
    tenant_id                = data.azurerm_client_config.current.tenant_id
    resource_group_name       = var.resource_group_name
    automation_account_name   = azurerm_automation_account.cost_optimization.name
    log_analytics_workspace_name = azurerm_log_analytics_workspace.cost_optimization.name
    storage_account_name      = azurerm_storage_account.cost_optimization.name
    key_vault_name           = azurerm_key_vault.cost_optimization.name
  }
}

# Environment Variables for Scripts
output "environment_variables" {
  description = "Environment variables for use in deployment scripts"
  value = {
    RESOURCE_GROUP      = var.resource_group_name
    LOCATION           = var.location
    SUBSCRIPTION_ID    = data.azurerm_subscription.current.subscription_id
    WORKSPACE_NAME     = azurerm_log_analytics_workspace.cost_optimization.name
    WORKSPACE_ID       = azurerm_log_analytics_workspace.cost_optimization.id
    AUTOMATION_ACCOUNT = azurerm_automation_account.cost_optimization.name
    STORAGE_ACCOUNT    = azurerm_storage_account.cost_optimization.name
    KEY_VAULT         = azurerm_key_vault.cost_optimization.name
    ACTION_GROUP_ID   = azurerm_monitor_action_group.cost_optimization.id
    PRINCIPAL_ID      = azurerm_automation_account.cost_optimization.identity[0].principal_id
    RANDOM_SUFFIX     = local.resource_suffix
  }
  sensitive = false
}

# Cost Optimization Configuration
output "cost_optimization_config" {
  description = "Configuration parameters for cost optimization"
  value = {
    monthly_budget_amount    = var.monthly_budget_amount
    cost_alert_thresholds   = var.cost_alert_thresholds
    runbook_parameters      = var.automation_runbook_parameters
    schedules_enabled       = var.enable_runbook_schedules
    vm_schedule            = var.vm_optimization_schedule
    storage_schedule       = var.storage_optimization_schedule
    database_schedule      = var.database_optimization_schedule
  }
}

# Next Steps Information
output "next_steps" {
  description = "Next steps to complete the deployment"
  value = [
    "1. Configure Azure Copilot integration in the Azure Portal",
    "2. Test the runbooks manually in Azure Portal > Automation Account",
    "3. Verify that all PowerShell modules are installed",
    "4. Create test resources to validate the optimization workflows",
    "5. Review and customize the optimization thresholds based on your requirements",
    "6. Set up additional monitoring and alerting as needed",
    "7. Configure webhook integrations for external systems if required"
  ]
}