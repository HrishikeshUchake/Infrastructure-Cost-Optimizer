# Variables for AI-Driven Infrastructure Cost Optimization

variable "location" {
  description = "Azure region where resources will be deployed"
  type        = string
  default     = "East US"
  
  validation {
    condition = contains([
      "East US", "East US 2", "West US", "West US 2", "West US 3",
      "Central US", "North Central US", "South Central US", "West Central US",
      "Canada Central", "Canada East",
      "Brazil South",
      "North Europe", "West Europe",
      "UK South", "UK West",
      "France Central", "France South",
      "Germany West Central", "Germany North",
      "Switzerland North", "Switzerland West",
      "Norway East", "Norway West",
      "Sweden Central",
      "Australia East", "Australia Southeast", "Australia Central", "Australia Central 2",
      "East Asia", "Southeast Asia",
      "Japan East", "Japan West",
      "Korea Central", "Korea South",
      "India Central", "India South", "India West",
      "UAE North", "UAE Central",
      "South Africa North", "South Africa West"
    ], var.location)
    error_message = "The location must be a valid Azure region."
  }
}

variable "resource_group_name" {
  description = "Name of the resource group where resources will be deployed"
  type        = string
  
  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.resource_group_name))
    error_message = "Resource group name must contain only alphanumeric characters, periods, underscores, hyphens, and parentheses."
  }
}

variable "unique_suffix" {
  description = "Unique suffix for resource names (leave empty to auto-generate)"
  type        = string
  default     = ""
  
  validation {
    condition     = var.unique_suffix == "" || can(regex("^[a-z0-9]{1,6}$", var.unique_suffix))
    error_message = "Unique suffix must be empty or 1-6 characters of lowercase letters and numbers only."
  }
}

variable "environment" {
  description = "Environment name (e.g., prod, dev, test)"
  type        = string
  default     = "prod"
  
  validation {
    condition     = contains(["prod", "dev", "test", "staging", "uat"], var.environment)
    error_message = "Environment must be one of: prod, dev, test, staging, uat."
  }
}

variable "monthly_budget_amount" {
  description = "Monthly budget amount in USD"
  type        = number
  default     = 5000
  
  validation {
    condition     = var.monthly_budget_amount > 0 && var.monthly_budget_amount <= 1000000
    error_message = "Monthly budget amount must be between 1 and 1,000,000 USD."
  }
}

variable "notification_email" {
  description = "Email address for cost and alert notifications"
  type        = string
  
  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.notification_email))
    error_message = "Notification email must be a valid email address."
  }
}

variable "resource_tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    purpose     = "cost-optimization"
    project     = "ai-cost-optimizer"
    team        = "platform"
    costCenter  = "IT"
  }
}

variable "log_retention_days" {
  description = "Number of days to retain logs in Log Analytics workspace"
  type        = number
  default     = 30
  
  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "Log retention days must be between 30 and 730."
  }
}

variable "daily_log_quota_gb" {
  description = "Daily log ingestion quota in GB for Log Analytics workspace"
  type        = number
  default     = 10
  
  validation {
    condition     = var.daily_log_quota_gb >= 1 && var.daily_log_quota_gb <= 1000
    error_message = "Daily log quota must be between 1 and 1000 GB."
  }
}

variable "enable_runbook_schedules" {
  description = "Whether to enable automated runbook schedules"
  type        = bool
  default     = true
}

variable "vm_optimization_schedule" {
  description = "Schedule configuration for VM optimization runbook"
  type = object({
    enabled   = bool
    frequency = string  # "Day" or "Week"
    interval  = number
    time      = string  # "HH:MM" format in UTC
    weekdays  = list(string)  # Only used for weekly frequency
  })
  default = {
    enabled   = true
    frequency = "Day"
    interval  = 1
    time      = "02:00"
    weekdays  = []
  }
  
  validation {
    condition = contains(["Day", "Week"], var.vm_optimization_schedule.frequency)
    error_message = "VM optimization schedule frequency must be 'Day' or 'Week'."
  }
}

variable "storage_optimization_schedule" {
  description = "Schedule configuration for storage optimization runbook"
  type = object({
    enabled   = bool
    frequency = string
    interval  = number
    time      = string
    weekdays  = list(string)
  })
  default = {
    enabled   = true
    frequency = "Week"
    interval  = 1
    time      = "03:00"
    weekdays  = ["Sunday"]
  }
}

variable "database_optimization_schedule" {
  description = "Schedule configuration for database optimization runbook"
  type = object({
    enabled   = bool
    frequency = string
    interval  = number
    time      = string
    weekdays  = list(string)
  })
  default = {
    enabled   = true
    frequency = "Week"
    interval  = 1
    time      = "01:00"
    weekdays  = ["Saturday"]
  }
}

variable "cost_alert_thresholds" {
  description = "Budget alert threshold configuration"
  type = object({
    warning_threshold    = number  # Percentage (e.g., 80)
    critical_threshold   = number  # Percentage (e.g., 100)
    forecast_threshold   = number  # Percentage (e.g., 100)
  })
  default = {
    warning_threshold  = 80
    critical_threshold = 100
    forecast_threshold = 100
  }
  
  validation {
    condition = (
      var.cost_alert_thresholds.warning_threshold > 0 &&
      var.cost_alert_thresholds.warning_threshold <= 100 &&
      var.cost_alert_thresholds.critical_threshold > 0 &&
      var.cost_alert_thresholds.critical_threshold <= 200 &&
      var.cost_alert_thresholds.forecast_threshold > 0 &&
      var.cost_alert_thresholds.forecast_threshold <= 200
    )
    error_message = "Cost alert thresholds must be valid percentages (warning: 1-100, critical/forecast: 1-200)."
  }
}

variable "automation_runbook_parameters" {
  description = "Default parameters for automation runbooks"
  type = object({
    vm_cpu_threshold      = number  # CPU utilization threshold for VM optimization
    vm_memory_threshold   = number  # Memory utilization threshold
    storage_access_days   = number  # Days since last access for storage optimization
    auto_approval_limit   = number  # Auto-approval cost threshold in USD
    require_approval_limit = number # Manual approval cost threshold in USD
  })
  default = {
    vm_cpu_threshold      = 10
    vm_memory_threshold   = 20
    storage_access_days   = 30
    auto_approval_limit   = 100
    require_approval_limit = 500
  }
}

variable "enable_diagnostic_settings" {
  description = "Whether to enable diagnostic settings for Azure resources"
  type        = bool
  default     = true
}

variable "key_vault_soft_delete_retention_days" {
  description = "Number of days to retain soft-deleted Key Vault items"
  type        = number
  default     = 7
  
  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "Key Vault soft delete retention must be between 7 and 90 days."
  }
}

variable "storage_account_tier" {
  description = "Storage account performance tier"
  type        = string
  default     = "Standard"
  
  validation {
    condition     = contains(["Standard", "Premium"], var.storage_account_tier)
    error_message = "Storage account tier must be 'Standard' or 'Premium'."
  }
}

variable "storage_account_replication" {
  description = "Storage account replication type"
  type        = string
  default     = "LRS"
  
  validation {
    condition     = contains(["LRS", "GRS", "RAGRS", "ZRS", "GZRS", "RAGZRS"], var.storage_account_replication)
    error_message = "Storage account replication must be one of: LRS, GRS, RAGRS, ZRS, GZRS, RAGZRS."
  }
}

variable "application_insights_retention_days" {
  description = "Number of days to retain Application Insights data"
  type        = number
  default     = 30
  
  validation {
    condition     = contains([30, 60, 90, 120, 180, 270, 365, 550, 730], var.application_insights_retention_days)
    error_message = "Application Insights retention must be one of: 30, 60, 90, 120, 180, 270, 365, 550, 730 days."
  }
}