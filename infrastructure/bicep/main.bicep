// AI-Driven Infrastructure Cost Optimization - Main Bicep Template
// This template deploys the complete infrastructure for the cost optimization solution

@description('Location for all resources')
param location string = resourceGroup().location

@description('Unique suffix for resource names')
param uniqueSuffix string = substring(uniqueString(resourceGroup().id), 0, 6)

@description('Environment name (e.g., prod, dev, test)')
param environment string = 'prod'

@description('Monthly budget amount in USD')
param monthlyBudgetAmount int = 5000

@description('Email address for notifications')
param notificationEmail string

@description('Tags to apply to all resources')
param resourceTags object = {
  purpose: 'cost-optimization'
  environment: environment
  project: 'ai-cost-optimizer'
  deployedBy: 'bicep'
  createdDate: utcNow('yyyy-MM-dd')
}

// Variables
var resourceGroupName = resourceGroup().name
var subscriptionId = subscription().subscriptionId
var workspaceName = 'law-costopt-${uniqueSuffix}'
var automationAccountName = 'aa-costopt-${uniqueSuffix}'
var storageAccountName = 'sacostopt${uniqueSuffix}'
var keyVaultName = 'kv-costopt-${uniqueSuffix}'
var appInsightsName = 'ai-costopt-${uniqueSuffix}'
var actionGroupName = 'ag-costopt-${uniqueSuffix}'
var logicAppName = 'la-costopt-${uniqueSuffix}'
var budgetName = 'budget-costopt-${uniqueSuffix}'

// Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: resourceTags
  properties: {
    sku: {
      name: 'pergb2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: 10
    }
  }
}

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: resourceTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: resourceTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    accessPolicies: []
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enableRbacAuthorization: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Application Insights
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: resourceTags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'
    RetentionInDays: 30
  }
}

// Automation Account
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: resourceTags
  properties: {
    sku: {
      name: 'Basic'
    }
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// Action Group for notifications
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: resourceTags
  properties: {
    groupShortName: 'CostOpt'
    enabled: true
    emailReceivers: [
      {
        name: 'Admin'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
    logicAppReceivers: [
      {
        name: 'CostWorkflow'
        resourceId: logicApp.id
        callbackUrl: listCallbackUrl(logicApp.id, '2019-05-01').value
        useCommonAlertSchema: true
      }
    ]
  }
}

// Logic App for cost optimization workflows
resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: resourceTags
  properties: {
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        automationAccount: {
          defaultValue: automationAccountName
          type: 'String'
        }
        resourceGroup: {
          defaultValue: resourceGroupName
          type: 'String'
        }
        subscriptionId: {
          defaultValue: subscriptionId
          type: 'String'
        }
      }
      triggers: {
        When_a_cost_alert_is_triggered: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                alertType: {
                  type: 'string'
                }
                resourceId: {
                  type: 'string'
                }
                severity: {
                  type: 'string'
                }
                description: {
                  type: 'string'
                }
              }
            }
          }
        }
      }
      actions: {
        Parse_Alert_Data: {
          type: 'ParseJson'
          inputs: {
            content: '@triggerBody()'
            schema: {
              type: 'object'
              properties: {
                alertType: {
                  type: 'string'
                }
                resourceId: {
                  type: 'string'
                }
                severity: {
                  type: 'string'
                }
                description: {
                  type: 'string'
                }
              }
            }
          }
        }
        Determine_Action: {
          type: 'Switch'
          expression: '@body(\'Parse_Alert_Data\')[\'alertType\']'
          cases: {
            VM_Underutilized: {
              case: 'VM_Underutilized'
              actions: {
                Call_VM_Optimization_Runbook: {
                  type: 'Http'
                  inputs: {
                    method: 'POST'
                    uri: 'https://management.azure.com/subscriptions/@{parameters(\'subscriptionId\')}/resourceGroups/@{parameters(\'resourceGroup\')}/providers/Microsoft.Automation/automationAccounts/@{parameters(\'automationAccount\')}/runbooks/Optimize-VMSize/webhooks/OptimizeVMSizeWebhook'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      resourceId: '@body(\'Parse_Alert_Data\')[\'resourceId\']'
                      action: 'rightsize'
                    }
                  }
                }
              }
            }
          }
        }
        Log_Action: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: 'https://@{reference(resourceId(\'Microsoft.OperationalInsights/workspaces\', \'${workspaceName}\')).customerId}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01'
            headers: {
              'Content-Type': 'application/json'
              'Log-Type': 'CostOptimizationLog'
            }
            body: {
              TimeGenerated: '@utcNow()'
              Action: '@body(\'Parse_Alert_Data\')[\'alertType\']'
              Resource: '@body(\'Parse_Alert_Data\')[\'resourceId\']'
              Severity: '@body(\'Parse_Alert_Data\')[\'severity\']'
            }
          }
        }
      }
    }
    parameters: {}
  }
}

// Budget for cost management
resource budget 'Microsoft.Consumption/budgets@2021-10-01' = {
  name: budgetName
  scope: resourceGroup().id
  properties: {
    timePeriod: {
      startDate: '${utcNow('yyyy-MM')}-01'
      endDate: '${dateTimeAdd(utcNow('yyyy-MM-dd'), 'P12M', 'yyyy-MM-dd')}'
    }
    timeGrain: 'Monthly'
    amount: monthlyBudgetAmount
    category: 'Cost'
    notifications: {
      Actual_GreaterThan_80_Percent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        contactEmails: [
          notificationEmail
        ]
        contactGroups: [
          actionGroup.id
        ]
        thresholdType: 'Actual'
      }
      Forecasted_GreaterThan_100_Percent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        contactEmails: [
          notificationEmail
        ]
        contactGroups: [
          actionGroup.id
        ]
        thresholdType: 'Forecasted'
      }
    }
  }
}

// Activity Log Alert for high-cost resource creation
resource highCostAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'HighCostResourceAlert'
  location: 'global'
  tags: resourceTags
  properties: {
    scopes: [
      '/subscriptions/${subscriptionId}'
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Compute/virtualMachines/write'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    enabled: true
    description: 'Alert when new expensive VMs are created'
  }
}

// Cost Anomaly Detection Alert
resource costAnomalyAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'CostAnomalyDetection'
  location: 'global'
  tags: resourceTags
  properties: {
    scopes: [
      '/subscriptions/${subscriptionId}'
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          anyOf: [
            {
              field: 'operationName'
              equals: 'Microsoft.Compute/virtualMachines/write'
            }
            {
              field: 'operationName'
              equals: 'Microsoft.Storage/storageAccounts/write'
            }
            {
              field: 'operationName'
              equals: 'Microsoft.Sql/servers/databases/write'
            }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
    enabled: true
    description: 'Detect unusual resource creation patterns'
  }
}

// VM Performance Monitoring Alert
resource vmLowUtilizationAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'VM-Low-CPU-Utilization'
  location: 'global'
  tags: resourceTags
  properties: {
    description: 'Alert when VM CPU utilization is consistently low (optimization opportunity)'
    severity: 3
    enabled: true
    scopes: [
      '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}'
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'LowCPUUtilization'
          metricName: 'Percentage CPU'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'LessThan'
          threshold: 10
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// Role assignments for Automation Account
resource automationVMContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, 'Virtual Machine Contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c') // Virtual Machine Contributor
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource automationStorageContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, 'Storage Account Contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab') // Storage Account Contributor
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource automationSQLContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, 'SQL DB Contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9b7fa17d-e63e-47b0-bb0a-15c516ac86ec') // SQL DB Contributor
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource automationCostReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, 'Cost Management Reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '72fafb9e-0641-4937-9268-a91bfd8191a3') // Cost Management Reader
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource automationMonitoringReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automationAccount.id, 'Monitoring Reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05') // Monitoring Reader
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Outputs
output workspaceId string = logAnalyticsWorkspace.id
output workspaceName string = logAnalyticsWorkspace.name
output automationAccountName string = automationAccount.name
output automationAccountId string = automationAccount.id
output automationAccountPrincipalId string = automationAccount.identity.principalId
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output appInsightsName string = applicationInsights.name
output appInsightsId string = applicationInsights.id
output actionGroupId string = actionGroup.id
output logicAppId string = logicApp.id
output budgetName string = budget.name
output resourceTags object = resourceTags
output deploymentInfo object = {
  deployedAt: utcNow()
  deployedBy: 'bicep'
  version: '1.0'
  uniqueSuffix: uniqueSuffix
}