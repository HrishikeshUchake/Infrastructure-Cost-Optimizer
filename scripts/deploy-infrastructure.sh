#!/bin/bash

# Infrastructure Deployment Script for Cost Optimization
# This script deploys the core Azure infrastructure components

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
print_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# Load environment variables
if [ -f ".env" ]; then
    source .env
    print_status "Environment variables loaded from .env"
else
    print_error ".env file not found. Please run setup-environment.sh first."
    exit 1
fi

# Validate required variables
required_vars=("RESOURCE_GROUP" "LOCATION" "SUBSCRIPTION_ID" "WORKSPACE_NAME" "AUTOMATION_ACCOUNT" "STORAGE_ACCOUNT" "KEY_VAULT")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Required variable $var is not set"
        exit 1
    fi
done

deploy_automation_account() {
    print_info "Creating Azure Automation Account..."
    
    az automation account create \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku "Basic" \
        --tags purpose=cost-optimization \
        --output none

    print_status "Automation account created: $AUTOMATION_ACCOUNT"

    # Enable system-assigned managed identity
    print_info "Enabling managed identity for automation account..."
    az automation account identity assign \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --output none

    # Get the principal ID for role assignments
    export PRINCIPAL_ID=$(az automation account show \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --query identity.principalId --output tsv)

    echo "PRINCIPAL_ID=\"$PRINCIPAL_ID\"" >> .env

    print_status "Managed identity configured for automation account"
}

configure_role_assignments() {
    print_info "Configuring role assignments for automation account..."
    
    # Wait for the managed identity to propagate
    sleep 30
    
    # Assign necessary roles
    roles=(
        "Virtual Machine Contributor"
        "Storage Account Contributor" 
        "SQL DB Contributor"
        "Cost Management Reader"
        "Monitoring Reader"
        "Log Analytics Reader"
    )

    for role in "${roles[@]}"; do
        print_info "Assigning role: $role"
        az role assignment create \
            --assignee "$PRINCIPAL_ID" \
            --role "$role" \
            --scope "/subscriptions/$SUBSCRIPTION_ID" \
            --output none || print_warning "Failed to assign role: $role (may already exist)"
    done

    print_status "Role assignments configured"
}

create_logic_app() {
    print_info "Creating Logic App for automated workflows..."
    
    # Create Logic App with basic workflow definition
    cat > logic-app-definition.json << 'EOF'
{
    "definition": {
        "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {},
        "triggers": {
            "When_a_cost_alert_is_triggered": {
                "type": "Request",
                "kind": "Http",
                "inputs": {
                    "schema": {
                        "type": "object",
                        "properties": {
                            "alertType": {"type": "string"},
                            "resourceId": {"type": "string"},
                            "severity": {"type": "string"},
                            "description": {"type": "string"}
                        }
                    }
                }
            }
        },
        "actions": {
            "Parse_Alert_Data": {
                "type": "ParseJson",
                "inputs": {
                    "content": "@triggerBody()",
                    "schema": {
                        "type": "object",
                        "properties": {
                            "alertType": {"type": "string"},
                            "resourceId": {"type": "string"},
                            "severity": {"type": "string"},
                            "description": {"type": "string"}
                        }
                    }
                }
            },
            "Determine_Action": {
                "type": "Switch",
                "expression": "@body('Parse_Alert_Data')['alertType']",
                "cases": {
                    "VM_Underutilized": {
                        "case": "VM_Underutilized",
                        "actions": {
                            "Call_VM_Optimization_Runbook": {
                                "type": "Http",
                                "inputs": {
                                    "method": "POST",
                                    "uri": "https://management.azure.com/subscriptions/@{variables('subscriptionId')}/resourceGroups/@{variables('resourceGroup')}/providers/Microsoft.Automation/automationAccounts/@{variables('automationAccount')}/runbooks/Optimize-VMSize/webhooks/@{variables('webhookName')}",
                                    "headers": {
                                        "Content-Type": "application/json"
                                    },
                                    "body": {
                                        "resourceId": "@body('Parse_Alert_Data')['resourceId']",
                                        "action": "rightsize"
                                    }
                                }
                            }
                        }
                    }
                }
            },
            "Log_Action": {
                "type": "Http",
                "inputs": {
                    "method": "POST",
                    "uri": "https://api.loganalytics.io/v1/workspaces/@{variables('workspaceId')}/query",
                    "headers": {
                        "Content-Type": "application/json"
                    },
                    "body": {
                        "query": "CostOptimizationLog_CL | project TimeGenerated, Action=@{body('Parse_Alert_Data')['alertType']}, Resource=@{body('Parse_Alert_Data')['resourceId']}"
                    }
                }
            }
        }
    }
}
EOF

    az logic workflow create \
        --resource-group "$RESOURCE_GROUP" \
        --name "CostOptimizationWorkflow" \
        --definition @logic-app-definition.json \
        --location "$LOCATION" \
        --tags purpose=cost-optimization \
        --output none

    rm logic-app-definition.json

    print_status "Logic App created: CostOptimizationWorkflow"
}

create_application_insights() {
    print_info "Creating Application Insights for monitoring..."
    
    az monitor app-insights component create \
        --app "costopt-${RANDOM_SUFFIX}" \
        --location "$LOCATION" \
        --resource-group "$RESOURCE_GROUP" \
        --workspace "$WORKSPACE_ID" \
        --kind web \
        --tags purpose=cost-optimization \
        --output none

    export APPINSIGHTS_NAME="costopt-${RANDOM_SUFFIX}"
    echo "APPINSIGHTS_NAME=\"$APPINSIGHTS_NAME\"" >> .env

    print_status "Application Insights created: $APPINSIGHTS_NAME"
}

create_action_group() {
    print_info "Creating Action Group for notifications..."
    
    # Get user email for notifications
    USER_EMAIL=$(az account show --query user.name --output tsv)
    
    az monitor action-group create \
        --name "CostOptimizationActions" \
        --resource-group "$RESOURCE_GROUP" \
        --short-name "CostOpt" \
        --email-receivers name="Admin" email="$USER_EMAIL" \
        --logic-app-receivers name="CostWorkflow" resource-id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Logic/workflows/CostOptimizationWorkflow" \
        --tags purpose=cost-optimization \
        --output none

    export ACTION_GROUP_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/microsoft.insights/actionGroups/CostOptimizationActions"
    echo "ACTION_GROUP_ID=\"$ACTION_GROUP_ID\"" >> .env

    print_status "Action Group created: CostOptimizationActions"
}

create_budget() {
    print_info "Creating budget with cost alerts..."
    
    # Create budget
    budget_amount=${MONTHLY_BUDGET_AMOUNT:-5000}
    
    az consumption budget create \
        --budget-name "MonthlyOptimizationBudget" \
        --amount "$budget_amount" \
        --time-grain Monthly \
        --start-date $(date +%Y-%m-01) \
        --end-date $(date -d "+1 year" +%Y-%m-%d) \
        --category cost \
        --notifications "Actual_GreaterThan_80_Percent={\"enabled\":true,\"operator\":\"GreaterThan\",\"threshold\":80,\"contactEmails\":[\"$(az account show --query user.name --output tsv)\"],\"contactRoles\":[\"Owner\"],\"contactGroups\":[\"$ACTION_GROUP_ID\"]}" \
        --notifications "Forecasted_GreaterThan_100_Percent={\"enabled\":true,\"operator\":\"GreaterThan\",\"threshold\":100,\"contactEmails\":[\"$(az account show --query user.name --output tsv)\"],\"contactRoles\":[\"Owner\"],\"contactGroups\":[\"$ACTION_GROUP_ID\"]}" \
        --output none

    print_status "Budget created: MonthlyOptimizationBudget ($budget_amount USD)"
}

create_cost_alerts() {
    print_info "Creating cost anomaly detection alerts..."
    
    # Create activity log alert for expensive resource creation
    az monitor activity-log alert create \
        --name "HighCostResourceAlert" \
        --resource-group "$RESOURCE_GROUP" \
        --scopes "/subscriptions/$SUBSCRIPTION_ID" \
        --condition category=Administrative operationName="Microsoft.Compute/virtualMachines/write" \
        --action-groups "$ACTION_GROUP_ID" \
        --description "Alert when new expensive VMs are created" \
        --tags purpose=cost-optimization \
        --output none

    # Create alert for unusual spending patterns
    az monitor activity-log alert create \
        --name "CostAnomalyDetection" \
        --resource-group "$RESOURCE_GROUP" \
        --scopes "/subscriptions/$SUBSCRIPTION_ID" \
        --condition category=Administrative operationName="Microsoft.Compute/virtualMachines/write" \
        --action-groups "$ACTION_GROUP_ID" \
        --description "Detect unusual resource creation patterns" \
        --tags purpose=cost-optimization \
        --output none

    print_status "Cost alerts configured"
}

main() {
    echo "=============================================="
    echo "Infrastructure Cost Optimization"
    echo "Infrastructure Deployment"
    echo "=============================================="
    echo

    print_info "Deploying infrastructure components..."
    echo

    # Deploy core components
    deploy_automation_account
    configure_role_assignments
    create_application_insights
    create_action_group
    create_logic_app
    create_budget
    create_cost_alerts

    echo
    print_status "Infrastructure deployment completed successfully!"
    echo
    print_info "Deployed components:"
    echo "  • Automation Account: $AUTOMATION_ACCOUNT"
    echo "  • Application Insights: $APPINSIGHTS_NAME"
    echo "  • Logic App: CostOptimizationWorkflow"
    echo "  • Action Group: CostOptimizationActions"
    echo "  • Budget: MonthlyOptimizationBudget"
    echo "  • Cost Alerts: Configured"
    echo
    print_info "Next steps:"
    echo "  1. Run './scripts/configure-monitoring.sh' to set up detailed monitoring"
    echo "  2. Run './scripts/deploy-runbooks.sh' to deploy automation runbooks"
    echo "  3. Configure Azure Copilot integration in the Azure Portal"
    echo
}

main "$@"