#!/bin/bash

# Infrastructure Cost Optimization Setup Script
# This script sets up the environment variables and prerequisites for the cost optimization solution

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check Azure CLI login status
check_azure_login() {
    if ! az account show >/dev/null 2>&1; then
        print_error "Not logged into Azure CLI. Please run 'az login' first."
        exit 1
    fi
}

# Function to validate Azure subscription
validate_subscription() {
    local subscription_id=$(az account show --query id --output tsv)
    print_info "Using Azure subscription: $subscription_id"
    
    # Check if user has sufficient permissions
    local role_assignments=$(az role assignment list --assignee $(az account show --query user.name --output tsv) --scope "/subscriptions/$subscription_id" --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor']" --output tsv)
    
    if [ -z "$role_assignments" ]; then
        print_warning "You may not have sufficient permissions (Owner/Contributor) on this subscription."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Main setup function
main() {
    echo "=============================================="
    echo "Infrastructure Cost Optimization"
    echo "Environment Setup Script"
    echo "=============================================="
    echo

    # Check prerequisites
    print_info "Checking prerequisites..."
    
    # Check Azure CLI
    if ! command_exists az; then
        print_error "Azure CLI is not installed. Please install it from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi
    print_status "Azure CLI is installed"

    # Check PowerShell (for runbook development)
    if ! command_exists pwsh; then
        print_warning "PowerShell 7+ is not installed. You may need it for runbook development."
        print_info "Install from: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell"
    else
        print_status "PowerShell is installed"
    fi

    # Check jq for JSON parsing
    if ! command_exists jq; then
        print_warning "jq is not installed. Installing via package manager..."
        if command_exists brew; then
            brew install jq
        elif command_exists apt-get; then
            sudo apt-get update && sudo apt-get install -y jq
        else
            print_warning "Please install jq manually for better JSON parsing"
        fi
    fi

    # Check Azure login
    check_azure_login
    print_status "Azure CLI is logged in"

    # Validate subscription
    validate_subscription

    # Generate unique suffix for resource names
    RANDOM_SUFFIX=$(openssl rand -hex 3)
    
    # Set environment variables
    export RESOURCE_GROUP="rg-costopt-${RANDOM_SUFFIX}"
    export LOCATION="${AZURE_LOCATION:-eastus}"
    export SUBSCRIPTION_ID=$(az account show --query id --output tsv)
    export WORKSPACE_NAME="law-costopt-${RANDOM_SUFFIX}"
    export AUTOMATION_ACCOUNT="aa-costopt-${RANDOM_SUFFIX}"
    export STORAGE_ACCOUNT="sacostopt${RANDOM_SUFFIX}"
    export KEY_VAULT="kv-costopt-${RANDOM_SUFFIX}"

    # Create .env file for future use
    cat > .env << EOF
# Infrastructure Cost Optimization Environment Variables
# Generated on $(date)

RESOURCE_GROUP="${RESOURCE_GROUP}"
LOCATION="${LOCATION}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
WORKSPACE_NAME="${WORKSPACE_NAME}"
AUTOMATION_ACCOUNT="${AUTOMATION_ACCOUNT}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT}"
KEY_VAULT="${KEY_VAULT}"
RANDOM_SUFFIX="${RANDOM_SUFFIX}"

# Cost Management Settings
MONTHLY_BUDGET_AMOUNT=\${MONTHLY_BUDGET_AMOUNT:-5000}
COST_ALERT_THRESHOLD=\${COST_ALERT_THRESHOLD:-80}

# Optimization Settings
VM_CPU_THRESHOLD=\${VM_CPU_THRESHOLD:-10}
VM_MEMORY_THRESHOLD=\${VM_MEMORY_THRESHOLD:-20}
STORAGE_ACCESS_THRESHOLD=\${STORAGE_ACCESS_THRESHOLD:-30}

# Automation Settings
AUTO_APPROVE_THRESHOLD=\${AUTO_APPROVE_THRESHOLD:-100}
REQUIRE_APPROVAL_THRESHOLD=\${REQUIRE_APPROVAL_THRESHOLD:-500}
EOF

    print_status "Environment file created: .env"

    # Display configuration
    echo
    print_info "Configuration Summary:"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Location: $LOCATION"
    echo "  Subscription: $SUBSCRIPTION_ID"
    echo "  Log Analytics: $WORKSPACE_NAME"
    echo "  Automation Account: $AUTOMATION_ACCOUNT"
    echo "  Storage Account: $STORAGE_ACCOUNT"
    echo "  Key Vault: $KEY_VAULT"
    echo

    # Source the environment file
    source .env

    # Check resource group existence
    if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
        print_warning "Resource group $RESOURCE_GROUP already exists"
        read -p "Continue with existing resource group? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Please update RESOURCE_GROUP in .env file with a unique name"
            exit 1
        fi
    fi

    # Create resource group
    print_info "Creating resource group..."
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --tags purpose=cost-optimization environment=production project=cost-optimizer created=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
        --output none

    print_status "Resource group created: $RESOURCE_GROUP"

    # Enable required resource providers
    print_info "Enabling required Azure resource providers..."
    
    providers=(
        "Microsoft.Automation"
        "Microsoft.OperationalInsights"
        "Microsoft.Logic"
        "Microsoft.Insights"
        "Microsoft.CostManagement"
        "Microsoft.Advisor"
        "Microsoft.Storage"
        "Microsoft.KeyVault"
    )

    for provider in "${providers[@]}"; do
        print_info "Registering $provider..."
        az provider register --namespace "$provider" --output none
    done

    print_status "Resource providers registered"

    # Create Log Analytics workspace
    print_info "Creating Log Analytics workspace..."
    az monitor log-analytics workspace create \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$WORKSPACE_NAME" \
        --location "$LOCATION" \
        --retention-in-days 30 \
        --sku pergb2018 \
        --tags purpose=cost-optimization \
        --output none

    # Store workspace ID
    export WORKSPACE_ID=$(az monitor log-analytics workspace show \
        --resource-group "$RESOURCE_GROUP" \
        --workspace-name "$WORKSPACE_NAME" \
        --query id --output tsv)

    echo "WORKSPACE_ID=\"$WORKSPACE_ID\"" >> .env

    print_status "Log Analytics workspace created: $WORKSPACE_NAME"

    # Create storage account for runbook artifacts
    print_info "Creating storage account..."
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --tags purpose=cost-optimization \
        --output none

    print_status "Storage account created: $STORAGE_ACCOUNT"

    # Create Key Vault for secrets
    print_info "Creating Key Vault..."
    az keyvault create \
        --name "$KEY_VAULT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku standard \
        --tags purpose=cost-optimization \
        --output none

    print_status "Key Vault created: $KEY_VAULT"

    # Set up monitoring for the resource group itself
    print_info "Configuring activity log monitoring..."
    az monitor diagnostic-settings create \
        --name "CostOptimizationLogs" \
        --resource "/subscriptions/$SUBSCRIPTION_ID" \
        --logs '[{
            "category": "Administrative",
            "enabled": true,
            "retentionPolicy": {"enabled": true, "days": 30}
        }, {
            "category": "ServiceHealth", 
            "enabled": true,
            "retentionPolicy": {"enabled": true, "days": 30}
        }, {
            "category": "ResourceHealth",
            "enabled": true,
            "retentionPolicy": {"enabled": true, "days": 30}
        }]' \
        --workspace "$WORKSPACE_ID" \
        --output none

    print_status "Activity log monitoring configured"

    echo
    print_status "Environment setup completed successfully!"
    echo
    print_info "Next steps:"
    echo "  1. Run './scripts/deploy-infrastructure.sh' to deploy the complete infrastructure"
    echo "  2. Run './scripts/configure-monitoring.sh' to set up detailed monitoring"
    echo "  3. Run './scripts/deploy-runbooks.sh' to deploy automation runbooks"
    echo
    print_info "Environment variables have been saved to .env file"
    print_info "Source the file in your current session: source .env"
    echo
}

# Run main function
main "$@"