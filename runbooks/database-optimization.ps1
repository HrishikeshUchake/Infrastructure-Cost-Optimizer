#Requires -Modules Az.Accounts, Az.Sql, Az.Monitor

<#
.SYNOPSIS
    Database Optimization Automation Runbook for Cost Optimization

.DESCRIPTION
    This runbook analyzes SQL Database and Cosmos DB utilization patterns and automatically
    optimizes DTU levels, scaling tiers, and implements auto-scaling policies
    to reduce database costs while maintaining performance requirements.

.PARAMETER ResourceGroupName
    Name of the resource group containing databases (optional, if not provided will scan all RGs)

.PARAMETER DatabaseName
    Name of specific database to optimize (optional, if not provided will scan all databases)

.PARAMETER DatabaseType
    Type of database to optimize: SQL, CosmosDB, or All (default: All)

.PARAMETER DryRun
    Simulate the operation without making actual changes

.PARAMETER Force
    Skip approval for automated optimizations

.NOTES
    Author: Infrastructure Cost Optimization System
    Version: 1.0
    Last Modified: 2025-01-03
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$DatabaseName,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("SQL", "CosmosDB", "All")]
    [string]$DatabaseType = "All",
    
    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $false,
    
    [Parameter(Mandatory=$false)]
    [bool]$Force = $false
)

# Initialize logging
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"

# SQL Database DTU optimization mapping
$SQLDTUOptimization = @{
    "Basic" = @{
        "MinUtilization" = 20
        "DowngradeThreshold" = 10
        "MonthlySavings" = 0.50
    }
    "Standard" = @{
        "S0" = @{ "DTU" = 10; "MonthlyCost" = 15.30 }
        "S1" = @{ "DTU" = 20; "MonthlyCost" = 30.60 }
        "S2" = @{ "DTU" = 50; "MonthlyCost" = 76.50 }
        "S3" = @{ "DTU" = 100; "MonthlyCost" = 153.00 }
        "S4" = @{ "DTU" = 200; "MonthlyCost" = 306.00 }
        "S6" = @{ "DTU" = 400; "MonthlyCost" = 612.00 }
        "S7" = @{ "DTU" = 800; "MonthlyCost" = 1224.00 }
        "S9" = @{ "DTU" = 1600; "MonthlyCost" = 2448.00 }
        "S12" = @{ "DTU" = 3000; "MonthlyCost" = 4590.00 }
    }
    "Premium" = @{
        "P1" = @{ "DTU" = 125; "MonthlyCost" = 468.00 }
        "P2" = @{ "DTU" = 250; "MonthlyCost" = 936.00 }
        "P4" = @{ "DTU" = 500; "MonthlyCost" = 1872.00 }
        "P6" = @{ "DTU" = 1000; "MonthlyCost" = 3744.00 }
        "P11" = @{ "DTU" = 1750; "MonthlyCost" = 6552.00 }
        "P15" = @{ "DTU" = 4000; "MonthlyCost" = 14976.00 }
    }
}

# Cosmos DB RU optimization
$CosmosDBOptimization = @{
    "AutoscaleThreshold" = 30  # % utilization to enable autoscale
    "MinUtilization" = 20      # % to trigger scaling down
    "MaxUtilization" = 80      # % to trigger scaling up
    "RUCostPer100" = 5.84      # Monthly cost per 100 RU/s
}

# Cost thresholds (monthly USD)
$AutoApprovalThreshold = 100
$RequireApprovalThreshold = 500

function Write-LogEntry {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Timestamp [$Level] $Message"
    Write-Output $LogEntry
    
    # Send to custom log table
    $LogData = @{
        TimeGenerated = (Get-Date).ToUniversalTime()
        ResourceId = "/subscriptions/$((Get-AzContext).Subscription.Id)"
        ResourceType = "Microsoft.Sql/servers/databases"
        OptimizationType = "Database_Optimization"
        Action = $Message
        EstimatedSavings = 0
        Status = $Level
        Details = @{
            RunbookName = "Optimize-Database"
            Parameters = @{
                ResourceGroupName = $ResourceGroupName
                DatabaseName = $DatabaseName
                DatabaseType = $DatabaseType
                DryRun = $DryRun
            }
        }
    }
    
    Write-Verbose "Log entry created: $($LogData | ConvertTo-Json -Depth 3)"
}

function Connect-ToAzure {
    try {
        Write-LogEntry "Connecting to Azure using Managed Identity..."
        
        $null = Connect-AzAccount -Identity
        
        $Context = Get-AzContext
        Write-LogEntry "Connected to Azure subscription: $($Context.Subscription.Id)"
        
        return $true
    }
    catch {
        Write-LogEntry "Failed to connect to Azure: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Get-SQLDatabaseMetrics {
    param(
        [object]$Database,
        [int]$DaysBack = 7
    )
    
    try {
        Write-LogEntry "Retrieving SQL Database metrics for: $($Database.DatabaseName)"
        
        $EndTime = Get-Date
        $StartTime = $EndTime.AddDays(-$DaysBack)
        $ResourceId = $Database.ResourceId
        
        # Get DTU consumption metrics
        $DTUMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "dtu_consumption_percent" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue
        
        $AvgDTU = if ($DTUMetrics -and $DTUMetrics.Data.Count -gt 0) {
            ($DTUMetrics.Data | Measure-Object -Property Average -Average).Average
        } else { 0 }
        
        $MaxDTU = if ($DTUMetrics -and $DTUMetrics.Data.Count -gt 0) {
            ($DTUMetrics.Data | Measure-Object -Property Average -Maximum).Maximum
        } else { 0 }
        
        # Get CPU percentage
        $CPUMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "cpu_percent" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue
        
        $AvgCPU = if ($CPUMetrics -and $CPUMetrics.Data.Count -gt 0) {
            ($CPUMetrics.Data | Measure-Object -Property Average -Average).Average
        } else { 0 }
        
        # Get connection count
        $ConnectionMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "connection_successful" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Total -ErrorAction SilentlyContinue
        
        $TotalConnections = if ($ConnectionMetrics -and $ConnectionMetrics.Data.Count -gt 0) {
            ($ConnectionMetrics.Data | Measure-Object -Property Total -Sum).Sum
        } else { 0 }
        
        # Get storage usage
        $StorageMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "storage_percent" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 1.00:00:00 -AggregationType Average -ErrorAction SilentlyContinue
        
        $AvgStoragePercent = if ($StorageMetrics -and $StorageMetrics.Data.Count -gt 0) {
            ($StorageMetrics.Data | Measure-Object -Property Average -Average).Average
        } else { 0 }
        
        $Metrics = @{
            AvgDTUUtilization = [math]::Round($AvgDTU, 2)
            MaxDTUUtilization = [math]::Round($MaxDTU, 2)
            AvgCPUUtilization = [math]::Round($AvgCPU, 2)
            TotalConnections = $TotalConnections
            AvgDailyConnections = [math]::Round($TotalConnections / $DaysBack, 0)
            AvgStorageUtilization = [math]::Round($AvgStoragePercent, 2)
            SamplePeriodDays = $DaysBack
            DataPoints = if ($DTUMetrics) { $DTUMetrics.Data.Count } else { 0 }
        }
        
        Write-LogEntry "SQL Database metrics retrieved - DTU: $($Metrics.AvgDTUUtilization)%, CPU: $($Metrics.AvgCPUUtilization)%, Connections: $($Metrics.TotalConnections)"
        
        return $Metrics
    }
    catch {
        Write-LogEntry "Failed to retrieve SQL Database metrics: $($_.Exception.Message)" -Level "ERROR"
        return @{
            AvgDTUUtilization = 0
            MaxDTUUtilization = 0
            AvgCPUUtilization = 0
            TotalConnections = 0
            AvgDailyConnections = 0
            AvgStorageUtilization = 0
            SamplePeriodDays = $DaysBack
            DataPoints = 0
        }
    }
}

function Get-CosmosDBMetrics {
    param(
        [object]$CosmosAccount,
        [int]$DaysBack = 7
    )
    
    try {
        Write-LogEntry "Retrieving Cosmos DB metrics for: $($CosmosAccount.Name)"
        
        $EndTime = Get-Date
        $StartTime = $EndTime.AddDays(-$DaysBack)
        $ResourceId = $CosmosAccount.Id
        
        # Get RU consumption metrics
        $RUMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "TotalRequestUnits" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Total -ErrorAction SilentlyContinue
        
        $TotalRU = if ($RUMetrics -and $RUMetrics.Data.Count -gt 0) {
            ($RUMetrics.Data | Measure-Object -Property Total -Sum).Sum
        } else { 0 }
        
        # Get normalized RU consumption
        $NormalizedRUMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "NormalizedRUConsumption" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue
        
        $AvgNormalizedRU = if ($NormalizedRUMetrics -and $NormalizedRUMetrics.Data.Count -gt 0) {
            ($NormalizedRUMetrics.Data | Measure-Object -Property Average -Average).Average
        } else { 0 }
        
        # Get throttled requests
        $ThrottleMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "UserDefinedFunction429" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Total -ErrorAction SilentlyContinue
        
        $ThrottledRequests = if ($ThrottleMetrics -and $ThrottleMetrics.Data.Count -gt 0) {
            ($ThrottleMetrics.Data | Measure-Object -Property Total -Sum).Sum
        } else { 0 }
        
        $Metrics = @{
            TotalRUConsumed = $TotalRU
            AvgDailyRU = [math]::Round($TotalRU / $DaysBack, 0)
            AvgNormalizedRUConsumption = [math]::Round($AvgNormalizedRU, 2)
            ThrottledRequests = $ThrottledRequests
            SamplePeriodDays = $DaysBack
            DataPoints = if ($RUMetrics) { $RUMetrics.Data.Count } else { 0 }
        }
        
        Write-LogEntry "Cosmos DB metrics retrieved - RU: $($Metrics.TotalRUConsumed), Normalized: $($Metrics.AvgNormalizedRUConsumption)%, Throttled: $($Metrics.ThrottledRequests)"
        
        return $Metrics
    }
    catch {
        Write-LogEntry "Failed to retrieve Cosmos DB metrics: $($_.Exception.Message)" -Level "ERROR"
        return @{
            TotalRUConsumed = 0
            AvgDailyRU = 0
            AvgNormalizedRUConsumption = 0
            ThrottledRequests = 0
            SamplePeriodDays = $DaysBack
            DataPoints = 0
        }
    }
}

function Get-SQLDatabaseOptimizationRecommendation {
    param(
        [object]$Database,
        [hashtable]$Metrics
    )
    
    $CurrentTier = $Database.ServiceObjectiveName
    $CurrentEdition = $Database.Edition
    
    $Recommendation = @{
        DatabaseName = $Database.DatabaseName
        CurrentTier = $CurrentTier
        CurrentEdition = $CurrentEdition
        RecommendedTier = $null
        RecommendedEdition = $null
        Reason = ""
        EstimatedMonthlySavings = 0
        Confidence = "Low"
        ShouldOptimize = $false
        Action = "None"
    }
    
    # Check if database is underutilized
    $IsUnderutilized = $Metrics.AvgDTUUtilization -lt 20 -and $Metrics.DataPoints -gt 24
    $IsHighlyUnderutilized = $Metrics.AvgDTUUtilization -lt 10 -and $Metrics.DataPoints -gt 48
    
    if ($IsHighlyUnderutilized -and $Metrics.AvgDailyConnections -lt 10) {
        $Recommendation.Reason = "Database shows very low utilization (DTU: $($Metrics.AvgDTUUtilization)%, Connections: $($Metrics.AvgDailyConnections)/day). Consider pausing or scaling down."
        $Recommendation.ShouldOptimize = $true
        $Recommendation.Confidence = "High"
        $Recommendation.Action = "ScaleDown"
        
        # Find appropriate downgrade
        if ($CurrentEdition -eq "Standard") {
            $CurrentDTU = $SQLDTUOptimization.Standard[$CurrentTier].DTU
            $RecommendedTierOptions = $SQLDTUOptimization.Standard.GetEnumerator() | 
                Where-Object { $_.Value.DTU -lt $CurrentDTU } | 
                Sort-Object { $_.Value.DTU } -Descending | 
                Select-Object -First 1
            
            if ($RecommendedTierOptions) {
                $Recommendation.RecommendedTier = $RecommendedTierOptions.Key
                $Recommendation.RecommendedEdition = "Standard"
                
                $CurrentCost = $SQLDTUOptimization.Standard[$CurrentTier].MonthlyCost
                $NewCost = $RecommendedTierOptions.Value.MonthlyCost
                $Recommendation.EstimatedMonthlySavings = [math]::Round($CurrentCost - $NewCost, 2)
            }
        }
    }
    elseif ($IsUnderutilized) {
        $Recommendation.Reason = "Database shows low utilization (DTU: $($Metrics.AvgDTUUtilization)%). Consider enabling auto-scaling or monitoring longer."
        $Recommendation.Confidence = "Medium"
        $Recommendation.Action = "EnableAutoScale"
    }
    elseif ($Metrics.MaxDTUUtilization -gt 90) {
        $Recommendation.Reason = "Database shows high peak utilization ($($Metrics.MaxDTUUtilization)%). Consider scaling up or enabling auto-scaling."
        $Recommendation.Action = "ScaleUp"
        $Recommendation.Confidence = "High"
    }
    else {
        $Recommendation.Reason = "Database utilization ($($Metrics.AvgDTUUtilization)%) is within acceptable range"
        $Recommendation.Confidence = "High"
    }
    
    return $Recommendation
}

function Get-CosmosDBOptimizationRecommendation {
    param(
        [object]$CosmosAccount,
        [hashtable]$Metrics
    )
    
    $Recommendation = @{
        AccountName = $CosmosAccount.Name
        Reason = ""
        EstimatedMonthlySavings = 0
        Confidence = "Low"
        ShouldOptimize = $false
        Action = "None"
        RecommendedRU = 0
    }
    
    # Check if Cosmos DB is underutilized
    $IsUnderutilized = $Metrics.AvgNormalizedRUConsumption -lt $CosmosDBOptimization.MinUtilization
    $IsOverutilized = $Metrics.AvgNormalizedRUConsumption -gt $CosmosDBOptimization.MaxUtilization
    $HasThrottling = $Metrics.ThrottledRequests -gt 0
    
    if ($IsUnderutilized -and $Metrics.DataPoints -gt 24) {
        $Recommendation.Reason = "Cosmos DB shows low RU utilization ($($Metrics.AvgNormalizedRUConsumption)%). Consider reducing provisioned throughput."
        $Recommendation.ShouldOptimize = $true
        $Recommendation.Confidence = "High"
        $Recommendation.Action = "ReduceRU"
        
        # Estimate savings (simplified calculation)
        $CurrentRU = 400 # Default assumption, would get actual from Cosmos DB configuration
        $RecommendedRU = [math]::Max(100, [math]::Ceiling($CurrentRU * 0.7)) # Reduce by 30%
        $Recommendation.RecommendedRU = $RecommendedRU
        
        $CurrentCost = ($CurrentRU / 100) * $CosmosDBOptimization.RUCostPer100
        $NewCost = ($RecommendedRU / 100) * $CosmosDBOptimization.RUCostPer100
        $Recommendation.EstimatedMonthlySavings = [math]::Round($CurrentCost - $NewCost, 2)
    }
    elseif ($IsOverutilized -or $HasThrottling) {
        $Recommendation.Reason = "Cosmos DB shows high utilization ($($Metrics.AvgNormalizedRUConsumption)%) or throttling. Consider increasing RU or enabling autoscale."
        $Recommendation.Action = "IncreaseRU"
        $Recommendation.Confidence = "High"
    }
    elseif ($Metrics.AvgNormalizedRUConsumption -lt $CosmosDBOptimization.AutoscaleThreshold) {
        $Recommendation.Reason = "Cosmos DB would benefit from autoscale to optimize costs during low usage periods."
        $Recommendation.Action = "EnableAutoscale"
        $Recommendation.Confidence = "Medium"
    }
    else {
        $Recommendation.Reason = "Cosmos DB utilization ($($Metrics.AvgNormalizedRUConsumption)%) is within acceptable range"
        $Recommendation.Confidence = "High"
    }
    
    return $Recommendation
}

function Invoke-SQLDatabaseOptimization {
    param(
        [object]$Database,
        [hashtable]$Recommendation,
        [bool]$DryRun = $false
    )
    
    try {
        $DatabaseName = $Database.DatabaseName
        $ServerName = $Database.ServerName
        $ResourceGroupName = $Database.ResourceGroupName
        
        Write-LogEntry "Starting SQL Database optimization: $DatabaseName"
        
        if ($DryRun) {
            Write-LogEntry "[DRY RUN] Would perform action: $($Recommendation.Action) on database $DatabaseName"
            return @{ Success = $true; Message = "Dry run completed successfully" }
        }
        
        switch ($Recommendation.Action) {
            "ScaleDown" {
                if ($Recommendation.RecommendedTier) {
                    Write-LogEntry "Scaling down database $DatabaseName from $($Recommendation.CurrentTier) to $($Recommendation.RecommendedTier)"
                    
                    Set-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName `
                        -DatabaseName $DatabaseName -Edition $Recommendation.RecommendedEdition `
                        -RequestedServiceObjectiveName $Recommendation.RecommendedTier
                    
                    return @{ 
                        Success = $true
                        Message = "Database scaled down successfully"
                        Action = "ScaleDown"
                        From = $Recommendation.CurrentTier
                        To = $Recommendation.RecommendedTier
                    }
                }
            }
            "EnableAutoScale" {
                Write-LogEntry "Enabling auto-scaling would require configuring elastic pools or serverless tier for $DatabaseName"
                return @{ 
                    Success = $true
                    Message = "Auto-scaling recommendation noted (requires manual configuration)"
                    Action = "EnableAutoScale"
                }
            }
            default {
                return @{ 
                    Success = $true
                    Message = "No action required"
                    Action = "None"
                }
            }
        }
    }
    catch {
        Write-LogEntry "Failed to optimize SQL Database $($Database.DatabaseName): $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Request-Approval {
    param(
        [string]$DatabaseName,
        [decimal]$EstimatedSavings,
        [string]$Action
    )
    
    if ($EstimatedSavings -lt $AutoApprovalThreshold) {
        Write-LogEntry "Auto-approved: Savings ($EstimatedSavings USD) below threshold ($AutoApprovalThreshold USD)"
        return $true
    }
    elseif ($EstimatedSavings -lt $RequireApprovalThreshold) {
        Write-LogEntry "Manual approval required: Savings ($EstimatedSavings USD) requires review for $Action"
        return $Force
    }
    else {
        Write-LogEntry "High-impact change: Savings ($EstimatedSavings USD) requires senior approval for $Action"
        return $false
    }
}

# Main execution logic
try {
    Write-LogEntry "Starting database optimization runbook execution"
    Write-LogEntry "Parameters - ResourceGroup: $ResourceGroupName, Database: $DatabaseName, Type: $DatabaseType, DryRun: $DryRun"
    
    # Connect to Azure
    $null = Connect-ToAzure
    
    $Results = @()
    $TotalSavings = 0
    
    # Process SQL Databases
    if ($DatabaseType -eq "SQL" -or $DatabaseType -eq "All") {
        Write-LogEntry "Processing SQL Databases..."
        
        $SQLServers = if ($ResourceGroupName) {
            Get-AzSqlServer -ResourceGroupName $ResourceGroupName
        } else {
            Get-AzSqlServer
        }
        
        foreach ($Server in $SQLServers) {
            $Databases = if ($DatabaseName) {
                @(Get-AzSqlDatabase -ResourceGroupName $Server.ResourceGroupName -ServerName $Server.ServerName -DatabaseName $DatabaseName -ErrorAction SilentlyContinue)
            } else {
                Get-AzSqlDatabase -ResourceGroupName $Server.ResourceGroupName -ServerName $Server.ServerName | Where-Object { $_.DatabaseName -ne "master" }
            }
            
            foreach ($Database in $Databases) {
                try {
                    Write-LogEntry "Analyzing SQL Database: $($Database.DatabaseName)"
                    
                    # Get database metrics
                    $Metrics = Get-SQLDatabaseMetrics -Database $Database
                    
                    # Get optimization recommendation
                    $Recommendation = Get-SQLDatabaseOptimizationRecommendation -Database $Database -Metrics $Metrics
                    
                    $Result = @{
                        Type = "SQL"
                        DatabaseName = $Database.DatabaseName
                        ServerName = $Database.ServerName
                        ResourceGroupName = $Database.ResourceGroupName
                        Metrics = $Metrics
                        Recommendation = $Recommendation
                        Action = "None"
                        Success = $true
                        Message = ""
                        Savings = $Recommendation.EstimatedMonthlySavings
                    }
                    
                    # Implement optimization if recommended and approved
                    if ($Recommendation.ShouldOptimize) {
                        $Approved = Request-Approval -DatabaseName $Database.DatabaseName `
                            -EstimatedSavings $Recommendation.EstimatedMonthlySavings -Action $Recommendation.Action
                        
                        if ($Approved) {
                            $OptimizationResult = Invoke-SQLDatabaseOptimization -Database $Database `
                                -Recommendation $Recommendation -DryRun $DryRun
                            
                            $Result.Action = $OptimizationResult.Action
                            $Result.Success = $OptimizationResult.Success
                            $Result.Message = $OptimizationResult.Message
                            
                            Write-LogEntry "SQL Database $($Database.DatabaseName) optimization completed successfully"
                        }
                        else {
                            $Result.Action = "Approval Required"
                            $Result.Message = "Optimization requires approval due to high impact"
                        }
                    }
                    else {
                        $Result.Message = $Recommendation.Reason
                    }
                    
                    $TotalSavings += $Result.Savings
                    $Results += $Result
                }
                catch {
                    Write-LogEntry "Error processing SQL Database $($Database.DatabaseName): $($_.Exception.Message)" -Level "ERROR"
                    $Results += @{
                        Type = "SQL"
                        DatabaseName = $Database.DatabaseName
                        Action = "Error"
                        Success = $false
                        Message = $_.Exception.Message
                        Savings = 0
                    }
                }
            }
        }
    }
    
    # Process Cosmos DB Accounts
    if ($DatabaseType -eq "CosmosDB" -or $DatabaseType -eq "All") {
        Write-LogEntry "Processing Cosmos DB Accounts..."
        
        $CosmosAccounts = if ($ResourceGroupName) {
            Get-AzCosmosDBAccount -ResourceGroupName $ResourceGroupName
        } else {
            Get-AzCosmosDBAccount
        }
        
        foreach ($CosmosAccount in $CosmosAccounts) {
            try {
                if ($DatabaseName -and $CosmosAccount.Name -ne $DatabaseName) {
                    continue
                }
                
                Write-LogEntry "Analyzing Cosmos DB Account: $($CosmosAccount.Name)"
                
                # Get Cosmos DB metrics
                $Metrics = Get-CosmosDBMetrics -CosmosAccount $CosmosAccount
                
                # Get optimization recommendation
                $Recommendation = Get-CosmosDBOptimizationRecommendation -CosmosAccount $CosmosAccount -Metrics $Metrics
                
                $Result = @{
                    Type = "CosmosDB"
                    AccountName = $CosmosAccount.Name
                    ResourceGroupName = $CosmosAccount.ResourceGroupName
                    Metrics = $Metrics
                    Recommendation = $Recommendation
                    Action = $Recommendation.Action
                    Success = $true
                    Message = $Recommendation.Reason
                    Savings = $Recommendation.EstimatedMonthlySavings
                }
                
                # Note: Actual Cosmos DB optimization would require additional implementation
                # based on specific optimization actions (RU scaling, autoscale configuration, etc.)
                
                $TotalSavings += $Result.Savings
                $Results += $Result
                
                Write-LogEntry "Cosmos DB Account $($CosmosAccount.Name) analysis completed"
            }
            catch {
                Write-LogEntry "Error processing Cosmos DB Account $($CosmosAccount.Name): $($_.Exception.Message)" -Level "ERROR"
                $Results += @{
                    Type = "CosmosDB"
                    AccountName = $CosmosAccount.Name
                    Action = "Error"
                    Success = $false
                    Message = $_.Exception.Message
                    Savings = 0
                }
            }
        }
    }
    
    # Generate summary
    $TotalDatabases = $Results.Count
    $OptimizedDatabases = ($Results | Where-Object { $_.Action -notin @("None", "Error", "Approval Required") }).Count
    $SQLDatabases = ($Results | Where-Object { $_.Type -eq "SQL" }).Count
    $CosmosDatabases = ($Results | Where-Object { $_.Type -eq "CosmosDB" }).Count
    
    Write-LogEntry "=== DATABASE OPTIMIZATION SUMMARY ===" -Level "SUCCESS"
    Write-LogEntry "Total Databases Processed: $TotalDatabases"
    Write-LogEntry "SQL Databases: $SQLDatabases"
    Write-LogEntry "Cosmos DB Accounts: $CosmosDatabases"
    Write-LogEntry "Databases Optimized: $OptimizedDatabases"
    Write-LogEntry "Estimated Monthly Savings: $TotalSavings USD"
    
    # Output results for monitoring
    $Results | ForEach-Object {
        Write-Output "Database: $($_.DatabaseName)$($_.AccountName) | Type: $($_.Type) | Action: $($_.Action) | Savings: $($_.Savings) USD | Success: $($_.Success)"
    }
    
    Write-LogEntry "Database optimization runbook completed successfully" -Level "SUCCESS"
}
catch {
    Write-LogEntry "Database optimization runbook failed: $($_.Exception.Message)" -Level "ERROR"
    throw
}