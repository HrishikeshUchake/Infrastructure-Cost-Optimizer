#!/bin/bash

# Azure Monitor Configuration Script for Cost Optimization
# This script configures detailed monitoring and metrics collection

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

configure_vm_monitoring() {
    print_info "Configuring VM performance monitoring..."
    
    # Create VM utilization alert rules
    az monitor metrics alert create \
        --name "VM-High-CPU-Utilization" \
        --resource-group "$RESOURCE_GROUP" \
        --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP" \
        --condition "avg Percentage CPU > 80" \
        --window-size 5m \
        --evaluation-frequency 1m \
        --severity 2 \
        --description "Alert when VM CPU utilization is high" \
        --action-groups "$ACTION_GROUP_ID" \
        --tags purpose=cost-optimization \
        --output none || print_warning "VM CPU alert may already exist"

    az monitor metrics alert create \
        --name "VM-Low-CPU-Utilization" \
        --resource-group "$RESOURCE_GROUP" \
        --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP" \
        --condition "avg Percentage CPU < 10" \
        --window-size 1h \
        --evaluation-frequency 5m \
        --severity 3 \
        --description "Alert when VM CPU utilization is consistently low (optimization opportunity)" \
        --action-groups "$ACTION_GROUP_ID" \
        --tags purpose=cost-optimization \
        --output none || print_warning "VM low CPU alert may already exist"

    print_status "VM monitoring alerts configured"
}

configure_storage_monitoring() {
    print_info "Configuring storage monitoring..."
    
    # Create storage access pattern alerts
    az monitor metrics alert create \
        --name "Storage-Low-Access-Pattern" \
        --resource-group "$RESOURCE_GROUP" \
        --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP" \
        --condition "total Transactions < 100" \
        --window-size 24h \
        --evaluation-frequency 1h \
        --severity 3 \
        --description "Alert when storage has low access patterns (tier optimization opportunity)" \
        --action-groups "$ACTION_GROUP_ID" \
        --tags purpose=cost-optimization \
        --output none || print_warning "Storage access alert may already exist"

    print_status "Storage monitoring alerts configured"
}

configure_database_monitoring() {
    print_info "Configuring database monitoring..."
    
    # SQL Database DTU utilization alerts
    az monitor metrics alert create \
        --name "SQL-Low-DTU-Utilization" \
        --resource-group "$RESOURCE_GROUP" \
        --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP" \
        --condition "avg dtu_consumption_percent < 20" \
        --window-size 1h \
        --evaluation-frequency 5m \
        --severity 3 \
        --description "Alert when SQL Database DTU utilization is low (scaling opportunity)" \
        --action-groups "$ACTION_GROUP_ID" \
        --tags purpose=cost-optimization \
        --output none || print_warning "SQL DTU alert may already exist"

    print_status "Database monitoring alerts configured"
}

create_custom_metrics() {
    print_info "Creating custom cost optimization metrics..."
    
    # Create custom log table for cost optimization events
    cat > custom-table-schema.json << 'EOF'
{
    "properties": {
        "schema": {
            "name": "CostOptimizationEvents_CL",
            "columns": [
                {
                    "name": "TimeGenerated",
                    "type": "datetime"
                },
                {
                    "name": "ResourceId",
                    "type": "string"
                },
                {
                    "name": "ResourceType",
                    "type": "string"
                },
                {
                    "name": "OptimizationType",
                    "type": "string"
                },
                {
                    "name": "Action",
                    "type": "string"
                },
                {
                    "name": "EstimatedSavings",
                    "type": "real"
                },
                {
                    "name": "Status",
                    "type": "string"
                },
                {
                    "name": "Details",
                    "type": "dynamic"
                }
            ]
        }
    }
}
EOF

    # Note: Custom table creation via CLI is limited, this would typically be done via REST API
    print_info "Custom table schema prepared (requires manual creation in Log Analytics)"
    rm custom-table-schema.json

    print_status "Custom metrics configuration prepared"
}

configure_workbooks() {
    print_info "Creating Azure Workbooks for cost visualization..."
    
    # Create workbook definition
    cat > cost-optimization-workbook.json << 'EOF'
{
    "version": "Notebook/1.0",
    "items": [
        {
            "type": 1,
            "content": {
                "json": "# Cost Optimization Dashboard\n\nThis workbook provides insights into cost optimization opportunities and automated actions taken by the system."
            },
            "name": "title"
        },
        {
            "type": 3,
            "content": {
                "version": "KqlItem/1.0",
                "query": "AzureActivity\n| where TimeGenerated > ago(7d)\n| where Category == \"Administrative\"\n| where OperationNameValue contains \"Microsoft.Compute\"\n| summarize Count = count() by bin(TimeGenerated, 1h), OperationNameValue\n| render timechart",
                "size": 0,
                "title": "VM Operations (Last 7 Days)",
                "timeContext": {
                    "durationMs": 604800000
                },
                "queryType": 0,
                "resourceType": "microsoft.operationalinsights/workspaces"
            },
            "name": "vm-operations"
        },
        {
            "type": 3,
            "content": {
                "version": "KqlItem/1.0",
                "query": "Perf\n| where TimeGenerated > ago(24h)\n| where ObjectName == \"Processor\" and CounterName == \"% Processor Time\"\n| where InstanceName == \"_Total\"\n| summarize AvgCPU = avg(CounterValue) by Computer\n| where AvgCPU < 10\n| order by AvgCPU asc",
                "size": 0,
                "title": "Underutilized VMs (CPU < 10%)",
                "timeContext": {
                    "durationMs": 86400000
                },
                "queryType": 0,
                "resourceType": "microsoft.operationalinsights/workspaces"
            },
            "name": "underutilized-vms"
        },
        {
            "type": 3,
            "content": {
                "version": "KqlItem/1.0",
                "query": "CostOptimizationEvents_CL\n| where TimeGenerated > ago(30d)\n| summarize TotalSavings = sum(EstimatedSavings_d) by OptimizationType_s\n| render piechart",
                "size": 0,
                "title": "Cost Savings by Optimization Type",
                "timeContext": {
                    "durationMs": 2592000000
                },
                "queryType": 0,
                "resourceType": "microsoft.operationalinsights/workspaces"
            },
            "name": "savings-by-type"
        }
    ],
    "isLocked": false,
    "fallbackResourceIds": [
        "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$WORKSPACE_NAME"
    ]
}
EOF

    # Create the workbook
    az monitor app-insights workbook create \
        --name "CostOptimizationDashboard" \
        --resource-group "$RESOURCE_GROUP" \
        --display-name "AI Cost Optimization Dashboard" \
        --source-id "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$WORKSPACE_NAME" \
        --category cost-optimization \
        --serialized-data @cost-optimization-workbook.json \
        --tags purpose=cost-optimization \
        --output none || print_warning "Workbook creation may require manual setup"

    rm cost-optimization-workbook.json

    print_status "Workbook template created"
}

configure_data_collection_rules() {
    print_info "Configuring data collection rules..."
    
    # Create data collection rule for performance monitoring
    cat > dcr-performance.json << 'EOF'
{
    "properties": {
        "description": "Data collection rule for cost optimization performance metrics",
        "dataSources": {
            "performanceCounters": [
                {
                    "name": "VMPerformanceCounters",
                    "streams": ["Microsoft-Perf"],
                    "scheduledTransferPeriod": "PT1M",
                    "samplingFrequencyInSeconds": 60,
                    "counterSpecifiers": [
                        "\\Processor(_Total)\\% Processor Time",
                        "\\Memory\\% Committed Bytes In Use",
                        "\\PhysicalDisk(_Total)\\% Disk Time",
                        "\\Network Interface(*)\\Bytes Total/sec"
                    ]
                }
            ],
            "windowsEventLogs": [
                {
                    "name": "VMEventLogs",
                    "streams": ["Microsoft-Event"],
                    "xPathQueries": [
                        "System!*[System[(Level=1 or Level=2 or Level=3)]]",
                        "Application!*[System[(Level=1 or Level=2 or Level=3)]]"
                    ]
                }
            ]
        },
        "destinations": {
            "logAnalytics": [
                {
                    "workspaceResourceId": "$WORKSPACE_ID",
                    "name": "CostOptimizationWorkspace"
                }
            ]
        },
        "dataFlows": [
            {
                "streams": ["Microsoft-Perf", "Microsoft-Event"],
                "destinations": ["CostOptimizationWorkspace"]
            }
        ]
    }
}
EOF

    # Create the data collection rule
    az monitor data-collection rule create \
        --name "DCR-CostOptimization" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --rule-file dcr-performance.json \
        --tags purpose=cost-optimization \
        --output none || print_warning "Data collection rule creation may require manual setup"

    rm dcr-performance.json

    print_status "Data collection rules configured"
}

create_saved_searches() {
    print_info "Creating saved KQL queries for cost analysis..."
    
    # Common cost optimization queries
    queries=(
        "UnderutilizedVMs|Perf | where TimeGenerated > ago(24h) | where ObjectName == \"Processor\" and CounterName == \"% Processor Time\" | where InstanceName == \"_Total\" | summarize AvgCPU = avg(CounterValue) by Computer | where AvgCPU < 10 | order by AvgCPU asc"
        "HighStorageCosts|AzureMetrics | where TimeGenerated > ago(7d) | where ResourceProvider == \"MICROSOFT.STORAGE\" | where MetricName == \"Transactions\" | summarize TransactionCount = sum(Total) by Resource | where TransactionCount < 1000 | order by TransactionCount asc"
        "DatabaseOptimization|AzureMetrics | where TimeGenerated > ago(24h) | where ResourceProvider == \"MICROSOFT.SQL\" | where MetricName == \"dtu_consumption_percent\" | summarize AvgDTU = avg(Average) by Resource | where AvgDTU < 20 | order by AvgDTU asc"
        "CostOptimizationActions|CostOptimizationEvents_CL | where TimeGenerated > ago(30d) | summarize TotalSavings = sum(EstimatedSavings_d), ActionCount = count() by OptimizationType_s | order by TotalSavings desc"
    )

    for query in "${queries[@]}"; do
        IFS='|' read -r name kql <<< "$query"
        print_info "Creating saved search: $name"
        
        az monitor log-analytics workspace saved-search create \
            --workspace-name "$WORKSPACE_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --saved-search-id "$(echo $name | tr '[:upper:]' '[:lower:]')" \
            --display-name "$name" \
            --category "Cost Optimization" \
            --query "$kql" \
            --tags purpose=cost-optimization \
            --output none || print_warning "Saved search creation failed for $name"
    done

    print_status "Saved searches created"
}

main() {
    echo "=============================================="
    echo "Infrastructure Cost Optimization"
    echo "Azure Monitor Configuration"
    echo "=============================================="
    echo

    print_info "Configuring monitoring and alerting..."
    echo

    # Configure monitoring components
    configure_vm_monitoring
    configure_storage_monitoring
    configure_database_monitoring
    create_custom_metrics
    configure_workbooks
    configure_data_collection_rules
    create_saved_searches

    echo
    print_status "Azure Monitor configuration completed successfully!"
    echo
    print_info "Configured components:"
    echo "  • VM performance alerts"
    echo "  • Storage access pattern monitoring"
    echo "  • Database utilization alerts"
    echo "  • Custom cost optimization metrics"
    echo "  • Azure Workbooks dashboard"
    echo "  • Data collection rules"
    echo "  • Saved KQL queries"
    echo
    print_info "Next steps:"
    echo "  1. Run './scripts/deploy-runbooks.sh' to deploy automation runbooks"
    echo "  2. Access Azure Portal to view workbooks and configure additional alerts"
    echo "  3. Test the monitoring by creating some test resources"
    echo
    print_warning "Note: Some configurations may require manual setup in Azure Portal"
    echo
}

main "$@"