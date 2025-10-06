#!/bin/bash

# Validation and Testing Script for Cost Optimization
# This script validates the deployment and tests the complete cost optimization pipeline

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

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# Function to run test and track results
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    print_info "Testing: $test_name"
    
    if eval "$test_command" >/dev/null 2>&1; then
        print_status "PASS: $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        print_error "FAIL: $test_name"
        FAILED_TESTS+=("$test_name")
        ((TESTS_FAILED++))
        return 1
    fi
}

# Function to validate Azure login
validate_azure_login() {
    print_info "Validating Azure CLI login..."
    
    if az account show >/dev/null 2>&1; then
        local account_name=$(az account show --query name --output tsv)
        local subscription_id=$(az account show --query id --output tsv)
        print_status "Logged in to Azure account: $account_name ($subscription_id)"
        return 0
    else
        print_error "Not logged into Azure CLI. Please run 'az login' first."
        return 1
    fi
}

# Function to validate resource group
validate_resource_group() {
    print_info "Validating resource group: $RESOURCE_GROUP"
    
    if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
        local location=$(az group show --name "$RESOURCE_GROUP" --query location --output tsv)
        print_status "Resource group exists in location: $location"
        return 0
    else
        print_error "Resource group $RESOURCE_GROUP does not exist"
        return 1
    fi
}

# Function to validate core infrastructure
validate_infrastructure() {
    print_info "Validating core infrastructure components..."
    
    # Test Log Analytics Workspace
    run_test "Log Analytics Workspace" \
        "az monitor log-analytics workspace show --resource-group '$RESOURCE_GROUP' --workspace-name '$WORKSPACE_NAME'"
    
    # Test Automation Account
    run_test "Automation Account" \
        "az automation account show --automation-account-name '$AUTOMATION_ACCOUNT' --resource-group '$RESOURCE_GROUP'"
    
    # Test Storage Account
    run_test "Storage Account" \
        "az storage account show --name '$STORAGE_ACCOUNT' --resource-group '$RESOURCE_GROUP'"
    
    # Test Key Vault
    run_test "Key Vault" \
        "az keyvault show --name '$KEY_VAULT' --resource-group '$RESOURCE_GROUP'"
    
    # Test Application Insights
    if [ ! -z "$APPINSIGHTS_NAME" ]; then
        run_test "Application Insights" \
            "az monitor app-insights component show --app '$APPINSIGHTS_NAME' --resource-group '$RESOURCE_GROUP'"
    fi
}

# Function to validate automation runbooks
validate_runbooks() {
    print_info "Validating automation runbooks..."
    
    # List of expected runbooks
    local runbooks=("Optimize-VMSize" "Optimize-Storage" "Optimize-Database")
    
    for runbook in "${runbooks[@]}"; do
        run_test "Runbook: $runbook" \
            "az automation runbook show --automation-account-name '$AUTOMATION_ACCOUNT' --resource-group '$RESOURCE_GROUP' --name '$runbook'"
        
        # Check if runbook is published
        local state=$(az automation runbook show \
            --automation-account-name "$AUTOMATION_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --name "$runbook" \
            --query state --output tsv 2>/dev/null || echo "Unknown")
        
        if [ "$state" = "Published" ]; then
            print_status "Runbook $runbook is published"
        else
            print_warning "Runbook $runbook state: $state"
        fi
    done
}

# Function to validate PowerShell modules
validate_powershell_modules() {
    print_info "Validating PowerShell modules in Automation Account..."
    
    # List of required modules
    local required_modules=("Az.Accounts" "Az.Compute" "Az.Storage" "Az.Sql" "Az.Monitor")
    
    for module in "${required_modules[@]}"; do
        local module_status=$(az automation module show \
            --automation-account-name "$AUTOMATION_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --name "$module" \
            --query provisioningState --output tsv 2>/dev/null || echo "NotFound")
        
        if [ "$module_status" = "Succeeded" ]; then
            print_status "Module $module is installed and ready"
        elif [ "$module_status" = "Running" ] || [ "$module_status" = "Importing" ]; then
            print_warning "Module $module is still installing: $module_status"
        else
            print_error "Module $module status: $module_status"
        fi
    done
}

# Function to validate monitoring and alerts
validate_monitoring() {
    print_info "Validating monitoring and alerting configuration..."
    
    # Test Action Group
    if [ ! -z "$ACTION_GROUP_ID" ]; then
        run_test "Action Group" \
            "az monitor action-group show --resource-group '$RESOURCE_GROUP' --name 'CostOptimizationActions'"
    fi
    
    # Test Activity Log Alerts
    run_test "High Cost Resource Alert" \
        "az monitor activity-log alert show --resource-group '$RESOURCE_GROUP' --name 'HighCostResourceAlert'"
    
    run_test "Cost Anomaly Detection Alert" \
        "az monitor activity-log alert show --resource-group '$RESOURCE_GROUP' --name 'CostAnomalyDetection'"
    
    # Test Budget
    local budget_exists=$(az consumption budget list --query "[?name=='MonthlyOptimizationBudget']" --output tsv 2>/dev/null | wc -l)
    if [ "$budget_exists" -gt 0 ]; then
        print_status "Budget 'MonthlyOptimizationBudget' exists"
    else
        print_error "Budget 'MonthlyOptimizationBudget' not found"
    fi
}

# Function to validate role assignments
validate_role_assignments() {
    print_info "Validating role assignments for Automation Account..."
    
    if [ ! -z "$PRINCIPAL_ID" ]; then
        local required_roles=("Virtual Machine Contributor" "Storage Account Contributor" "SQL DB Contributor" "Cost Management Reader" "Monitoring Reader")
        
        for role in "${required_roles[@]}"; do
            local assignment_exists=$(az role assignment list \
                --assignee "$PRINCIPAL_ID" \
                --role "$role" \
                --scope "/subscriptions/$SUBSCRIPTION_ID" \
                --query "[0].id" --output tsv 2>/dev/null)
            
            if [ ! -z "$assignment_exists" ] && [ "$assignment_exists" != "null" ]; then
                print_status "Role assignment: $role"
            else
                print_error "Missing role assignment: $role"
            fi
        done
    else
        print_warning "PRINCIPAL_ID not found, skipping role assignment validation"
    fi
}

# Function to test runbook execution
test_runbook_execution() {
    local runbook_name="$1"
    
    print_info "Testing runbook execution: $runbook_name"
    
    # Start a test job with DryRun=true
    local job_id=$(az automation runbook start \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$runbook_name" \
        --parameters "DryRun=true" \
        --query id --output tsv 2>/dev/null)
    
    if [ -z "$job_id" ]; then
        print_error "Failed to start test job for $runbook_name"
        return 1
    fi
    
    print_info "Test job started for $runbook_name (ID: $job_id)"
    
    # Wait for job completion (with timeout)
    local timeout=180  # 3 minutes
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        local job_status=$(az automation job show \
            --automation-account-name "$AUTOMATION_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --id "$job_id" \
            --query status --output tsv 2>/dev/null || echo "Unknown")
        
        case $job_status in
            "Completed")
                print_status "Test job completed successfully for $runbook_name"
                return 0
                ;;
            "Failed"|"Stopped"|"Suspended")
                print_error "Test job failed for $runbook_name with status: $job_status"
                
                # Get job output for debugging
                local job_output=$(az automation job output show \
                    --automation-account-name "$AUTOMATION_ACCOUNT" \
                    --resource-group "$RESOURCE_GROUP" \
                    --id "$job_id" \
                    --query value --output tsv 2>/dev/null | head -10)
                
                if [ ! -z "$job_output" ]; then
                    print_info "Job output (first 10 lines):"
                    echo "$job_output"
                fi
                
                return 1
                ;;
            *)
                if [ $((elapsed % 30)) -eq 0 ]; then
                    print_info "Test job status for $runbook_name: $job_status (waiting...)"
                fi
                sleep 10
                elapsed=$((elapsed + 10))
                ;;
        esac
    done
    
    print_warning "Test job timeout for $runbook_name"
    return 1
}

# Function to test all runbooks
test_all_runbooks() {
    print_info "Testing runbook execution (dry run mode)..."
    
    local runbooks=("Optimize-VMSize" "Optimize-Storage" "Optimize-Database")
    
    for runbook in "${runbooks[@]}"; do
        if test_runbook_execution "$runbook"; then
            ((TESTS_PASSED++))
        else
            ((TESTS_FAILED++))
            FAILED_TESTS+=("Runbook execution: $runbook")
        fi
    done
}

# Function to validate Log Analytics data
validate_log_analytics_data() {
    print_info "Validating Log Analytics data collection..."
    
    # Test basic connectivity
    local query_result=$(az monitor log-analytics query \
        --workspace "$WORKSPACE_ID" \
        --analytics-query "Heartbeat | take 1" \
        --query "tables[0].rows" --output tsv 2>/dev/null | wc -l)
    
    if [ "$query_result" -gt 0 ]; then
        print_status "Log Analytics workspace is receiving data"
    else
        print_warning "No heartbeat data found in Log Analytics (may be normal for new deployment)"
    fi
    
    # Test activity logs
    local activity_logs=$(az monitor log-analytics query \
        --workspace "$WORKSPACE_ID" \
        --analytics-query "AzureActivity | where TimeGenerated > ago(1h) | take 1" \
        --query "tables[0].rows" --output tsv 2>/dev/null | wc -l)
    
    if [ "$activity_logs" -gt 0 ]; then
        print_status "Activity logs are being collected"
    else
        print_warning "No recent activity logs found"
    fi
}

# Function to create test resources
create_test_resources() {
    print_info "Creating test resources for validation..."
    
    # Create a small test VM
    print_info "Creating test VM for optimization validation..."
    
    local test_vm_name="test-vm-costopt-${RANDOM_SUFFIX}"
    
    az vm create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$test_vm_name" \
        --image "Ubuntu2204" \
        --size "Standard_B1s" \
        --admin-username "azureuser" \
        --generate-ssh-keys \
        --tags purpose=testing component=cost-optimization \
        --output none 2>/dev/null
    
    if [ $? -eq 0 ]; then
        print_status "Test VM created: $test_vm_name"
        
        # Store test VM name for cleanup
        echo "TEST_VM_NAME=\"$test_vm_name\"" >> .env
        
        # Wait a bit for metrics to be available
        print_info "Waiting for VM metrics to initialize..."
        sleep 30
        
        return 0
    else
        print_error "Failed to create test VM"
        return 1
    fi
}

# Function to cleanup test resources
cleanup_test_resources() {
    if [ ! -z "$TEST_VM_NAME" ]; then
        print_info "Cleaning up test resources..."
        
        az vm delete \
            --resource-group "$RESOURCE_GROUP" \
            --name "$TEST_VM_NAME" \
            --yes \
            --output none 2>/dev/null
        
        if [ $? -eq 0 ]; then
            print_status "Test VM deleted: $TEST_VM_NAME"
        else
            print_warning "Failed to delete test VM: $TEST_VM_NAME"
        fi
        
        # Remove from environment file
        sed -i.bak '/TEST_VM_NAME=/d' .env && rm .env.bak 2>/dev/null || true
    fi
}

# Function to validate Azure Copilot integration
validate_copilot_integration() {
    print_info "Validating Azure Copilot integration readiness..."
    
    # Check if the required components are in place
    local copilot_ready=true
    
    # Check Log Analytics workspace
    if [ -z "$WORKSPACE_ID" ]; then
        print_error "Log Analytics workspace ID not found"
        copilot_ready=false
    fi
    
    # Check Automation Account
    if [ -z "$AUTOMATION_ACCOUNT" ]; then
        print_error "Automation Account name not found"
        copilot_ready=false
    fi
    
    # Check if runbooks are published
    local published_runbooks=$(az automation runbook list \
        --automation-account-name "$AUTOMATION_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --query "[?state=='Published']" --output tsv | wc -l)
    
    if [ "$published_runbooks" -lt 3 ]; then
        print_warning "Not all runbooks are published ($published_runbooks/3)"
        copilot_ready=false
    fi
    
    if [ "$copilot_ready" = true ]; then
        print_status "Azure Copilot integration components are ready"
        print_info "You can now configure Azure Copilot in the Azure Portal"
    else
        print_error "Azure Copilot integration is not ready"
    fi
}

# Function to generate test report
generate_test_report() {
    local total_tests=$((TESTS_PASSED + TESTS_FAILED))
    local success_rate=0
    
    if [ $total_tests -gt 0 ]; then
        success_rate=$(echo "scale=1; $TESTS_PASSED * 100 / $total_tests" | bc -l 2>/dev/null || echo "0")
    fi
    
    echo
    echo "=============================================="
    echo "VALIDATION TEST REPORT"
    echo "=============================================="
    echo "Total Tests: $total_tests"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo "Success Rate: ${success_rate}%"
    echo
    
    if [ $TESTS_FAILED -gt 0 ]; then
        echo "Failed Tests:"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  ❌ $test"
        done
        echo
    fi
    
    if [ $TESTS_FAILED -eq 0 ]; then
        print_status "All validation tests passed! ✨"
        echo
        print_info "Your cost optimization system is ready to use!"
        echo
        print_info "Next steps:"
        echo "  1. Configure Azure Copilot integration in Azure Portal"
        echo "  2. Start interacting with Azure Copilot using cost optimization queries"
        echo "  3. Monitor the runbook executions and their results"
        echo "  4. Review and adjust optimization thresholds as needed"
    else
        print_error "Some validation tests failed. Please review and fix the issues."
        echo
        print_info "Common solutions:"
        echo "  1. Ensure all PowerShell modules are fully installed (may take 15-20 minutes)"
        echo "  2. Verify Azure CLI login and permissions"
        echo "  3. Check resource group and subscription access"
        echo "  4. Re-run specific deployment scripts if needed"
    fi
    
    echo
}

# Main execution
main() {
    echo "=============================================="
    echo "Infrastructure Cost Optimization"
    echo "Validation and Testing"
    echo "=============================================="
    echo
    
    # Validate prerequisites
    if ! validate_azure_login; then
        exit 1
    fi
    
    if ! validate_resource_group; then
        exit 1
    fi
    
    # Run validation tests
    validate_infrastructure
    validate_runbooks
    validate_powershell_modules
    validate_monitoring
    validate_role_assignments
    validate_log_analytics_data
    validate_copilot_integration
    
    # Ask user if they want to run runbook tests
    echo
    read -p "Do you want to test runbook execution (this may take a few minutes)? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        test_all_runbooks
    fi
    
    # Ask user if they want to create test resources
    echo
    read -p "Do you want to create test resources for optimization validation? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if create_test_resources; then
            print_info "Test resources created. You can now test the optimization workflows."
            print_warning "Remember to clean up test resources when done to avoid charges."
            
            # Ask if user wants to cleanup now
            echo
            read -p "Do you want to clean up test resources now? (y/N): " -n 1 -r
            echo
            
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cleanup_test_resources
            fi
        fi
    fi
    
    # Generate final report
    generate_test_report
    
    # Exit with appropriate code
    if [ $TESTS_FAILED -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"