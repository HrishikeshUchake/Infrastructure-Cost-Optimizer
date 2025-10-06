#!/bin/bash

# Runbook Deployment Script for Cost Optimization
# This script deploys PowerShell runbooks to Azure Automation Account

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
required_vars=("RESOURCE_GROUP" "AUTOMATION_ACCOUNT" "WORKSPACE_ID")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Required variable $var is not set"
        exit 1
    fi
done

# List of runbooks to deploy
declare -A RUNBOOKS=(
    ["Optimize-VMSize"]="runbooks/vm-optimization.ps1"
    ["Optimize-Storage"]="runbooks/storage-optimization.ps1"
    ["Optimize-Database"]="runbooks/database-optimization.ps1"
)

deploy_runbook() {
    local runbook_name=$1
    local runbook_file=$2
    
    print_info "Deploying runbook: $runbook_name"
    
    # Check if runbook file exists
    if [ ! -f "$runbook_file" ]; then
        print_error "Runbook file not found: $runbook_file"
        return 1
    fi
    
    # Import the runbook
    print_info "Importing runbook from: $runbook_file"
    az automation runbook create \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$runbook_name" \
        --type "PowerShell" \
        --description "Infrastructure Cost Optimization Runbook" \
        --tags purpose=cost-optimization component=runbook \
        --output none
    
    # Set runbook content
    print_info "Setting runbook content..."
    az automation runbook replace-content \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$runbook_name" \
        --content @"$runbook_file" \
        --output none
    
    # Publish the runbook
    print_info "Publishing runbook..."
    az automation runbook publish \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$runbook_name" \
        --output none
    
    print_status "Runbook $runbook_name deployed successfully"
}

create_runbook_schedules() {
    print_info "Creating schedules for automated runbook execution..."
    
    # VM Optimization Schedule (Daily at 2 AM)
    az automation schedule create \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --name "VMOptimizationDaily" \
        --frequency "Day" \
        --start-time "$(date -d 'tomorrow 02:00' '+%Y-%m-%dT%H:%M:%S')" \
        --description "Daily VM optimization schedule" \
        --time-zone "UTC" \
        --output none
    
    # Storage Optimization Schedule (Weekly on Sunday at 3 AM)
    az automation schedule create \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --name "StorageOptimizationWeekly" \
        --frequency "Week" \
        --start-time "$(date -d 'next sunday 03:00' '+%Y-%m-%dT%H:%M:%S')" \
        --description "Weekly storage optimization schedule" \
        --time-zone "UTC" \
        --output none
    
    # Database Optimization Schedule (Weekly on Saturday at 1 AM)
    az automation schedule create \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --name "DatabaseOptimizationWeekly" \
        --frequency "Week" \
        --start-time "$(date -d 'next saturday 01:00' '+%Y-%m-%dT%H:%M:%S')" \
        --description "Weekly database optimization schedule" \
        --time-zone "UTC" \
        --output none
    
    print_status "Schedules created successfully"
}

link_runbooks_to_schedules() {
    print_info "Linking runbooks to schedules..."
    
    # Link VM optimization runbook to daily schedule
    az automation runbook schedule link \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --runbook-name "Optimize-VMSize" \
        --schedule-name "VMOptimizationDaily" \
        --parameters "DryRun=false" \
        --output none
    
    # Link Storage optimization runbook to weekly schedule
    az automation runbook schedule link \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --runbook-name "Optimize-Storage" \
        --schedule-name "StorageOptimizationWeekly" \
        --parameters "DryRun=false" \
        --output none
    
    # Link Database optimization runbook to weekly schedule
    az automation runbook schedule link \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --runbook-name "Optimize-Database" \
        --schedule-name "DatabaseOptimizationWeekly" \
        --parameters "DatabaseType=All,DryRun=false" \
        --output none
    
    print_status "Runbooks linked to schedules successfully"
}

create_webhooks() {
    print_info "Creating webhooks for external integration..."
    
    # Create webhooks for each runbook
    for runbook_name in "${!RUNBOOKS[@]}"; do
        print_info "Creating webhook for: $runbook_name"
        
        # Generate expiry date (1 year from now)
        expiry_date=$(date -d "+1 year" "+%Y-%m-%dT%H:%M:%S")
        
        # Create webhook
        webhook_uri=$(az automation webhook create \
            --automation-account-name "$AUTOMATION_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --name "${runbook_name}Webhook" \
            --runbook-name "$runbook_name" \
            --expiry-time "$expiry_date" \
            --is-enabled true \
            --query uri --output tsv)
        
        # Store webhook URI in environment file
        webhook_var_name="${runbook_name^^}_WEBHOOK_URI"
        webhook_var_name=${webhook_var_name//-/_}
        echo "${webhook_var_name}=\"$webhook_uri\"" >> .env
        
        print_status "Webhook created for $runbook_name"
    done
    
    print_status "All webhooks created successfully"
}

create_test_job() {
    local runbook_name=$1
    
    print_info "Creating test job for runbook: $runbook_name"
    
    # Start a test job with DryRun=true
    job_id=$(az automation runbook start \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$runbook_name" \
        --parameters "DryRun=true" \
        --query id --output tsv)
    
    print_info "Test job started with ID: $job_id"
    
    # Wait for job completion (with timeout)
    timeout=300 # 5 minutes
    elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        job_status=$(az automation job show \
            --automation-account-name "$AUTOMATION_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --id "$job_id" \
            --query status --output tsv)
        
        case $job_status in
            "Completed")
                print_status "Test job completed successfully for $runbook_name"
                return 0
                ;;
            "Failed"|"Stopped"|"Suspended")
                print_error "Test job failed for $runbook_name with status: $job_status"
                return 1
                ;;
            *)
                print_info "Test job status: $job_status (waiting...)"
                sleep 10
                elapsed=$((elapsed + 10))
                ;;
        esac
    done
    
    print_warning "Test job timeout for $runbook_name"
    return 1
}

install_required_modules() {
    print_info "Installing required PowerShell modules in Automation Account..."
    
    # List of required modules
    modules=(
        "Az.Accounts"
        "Az.Compute"
        "Az.Storage"
        "Az.Sql" 
        "Az.CosmosDB"
        "Az.Monitor"
        "Az.Profile"
        "Az.Resources"
    )
    
    for module in "${modules[@]}"; do
        print_info "Installing module: $module"
        
        # Import module
        az automation module create \
            --automation-account-name "$AUTOMATION_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --name "$module" \
            --module-uri "https://www.powershellgallery.com/packages/$module" \
            --output none || print_warning "Failed to install $module (may already exist)"
    done
    
    print_status "PowerShell modules installation initiated"
    print_warning "Note: Module installation may take 10-15 minutes to complete"
}

main() {
    echo "=============================================="
    echo "Infrastructure Cost Optimization"
    echo "Runbook Deployment"
    echo "=============================================="
    echo
    
    print_info "Deploying automation runbooks..."
    echo
    
    # Install required PowerShell modules
    install_required_modules
    
    # Deploy each runbook
    for runbook_name in "${!RUNBOOKS[@]}"; do
        runbook_file="${RUNBOOKS[$runbook_name]}"
        deploy_runbook "$runbook_name" "$runbook_file"
    done
    
    # Create schedules
    create_runbook_schedules
    
    # Link runbooks to schedules
    link_runbooks_to_schedules
    
    # Create webhooks
    create_webhooks
    
    echo
    print_info "Waiting for modules to install before running tests..."
    print_info "This may take 10-15 minutes. You can check module status in Azure Portal."
    echo
    
    read -p "Press Enter when modules are installed, or 's' to skip tests: " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        # Test runbooks
        print_info "Testing runbooks..."
        
        for runbook_name in "${!RUNBOOKS[@]}"; do
            create_test_job "$runbook_name" || print_warning "Test failed for $runbook_name"
        done
    fi
    
    echo
    print_status "Runbook deployment completed successfully!"
    echo
    print_info "Deployed runbooks:"
    for runbook_name in "${!RUNBOOKS[@]}"; do
        echo "  • $runbook_name"
    done
    echo
    print_info "Created schedules:"
    echo "  • VMOptimizationDaily (Daily at 2 AM UTC)"
    echo "  • StorageOptimizationWeekly (Weekly on Sunday at 3 AM UTC)"
    echo "  • DatabaseOptimizationWeekly (Weekly on Saturday at 1 AM UTC)"
    echo
    print_info "Webhook URIs have been added to .env file"
    echo
    print_info "Next steps:"
    echo "  1. Check Azure Portal to verify module installation status"
    echo "  2. Test runbooks manually in Azure Portal"
    echo "  3. Configure Azure Copilot integration"
    echo "  4. Run './scripts/validate-deployment.sh' to test the complete system"
    echo
}

main "$@"