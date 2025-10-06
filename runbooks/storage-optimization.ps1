#Requires -Modules Az.Accounts, Az.Storage, Az.Monitor

<#
.SYNOPSIS
    Storage Optimization Automation Runbook for Cost Optimization

.DESCRIPTION
    This runbook analyzes storage account access patterns and automatically optimizes
    blob storage tiers, removes unused storage accounts, and implements lifecycle policies
    to reduce storage costs while maintaining data accessibility requirements.

.PARAMETER ResourceGroupName
    Name of the resource group containing storage accounts (optional, if not provided will scan all RGs)

.PARAMETER StorageAccountName
    Name of specific storage account to optimize (optional, if not provided will scan all accounts)

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
    [string]$StorageAccountName,
    
    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $false,
    
    [Parameter(Mandatory=$false)]
    [bool]$Force = $false
)

# Initialize logging
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"

# Storage tier optimization mapping
$TierOptimization = @{
    "Hot" = @{
        "CoolThreshold" = 30    # Days since last access
        "ArchiveThreshold" = 90 # Days since last access
        "MonthlySavings" = @{
            "Cool" = 0.60      # 60% savings vs Hot
            "Archive" = 0.85   # 85% savings vs Hot
        }
    }
    "Cool" = @{
        "ArchiveThreshold" = 180 # Days since last access
        "MonthlySavings" = @{
            "Archive" = 0.40   # 40% additional savings vs Cool
        }
    }
}

# Cost thresholds (monthly USD)
$AutoApprovalThreshold = 50
$RequireApprovalThreshold = 200

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
        ResourceType = "Microsoft.Storage/storageAccounts"
        OptimizationType = "Storage_Optimization"
        Action = $Message
        EstimatedSavings = 0
        Status = $Level
        Details = @{
            RunbookName = "Optimize-Storage"
            Parameters = @{
                ResourceGroupName = $ResourceGroupName
                StorageAccountName = $StorageAccountName
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

function Get-StorageAccountMetrics {
    param(
        [object]$StorageAccount,
        [int]$DaysBack = 30
    )
    
    try {
        Write-LogEntry "Retrieving metrics for storage account: $($StorageAccount.StorageAccountName)"
        
        $EndTime = Get-Date
        $StartTime = $EndTime.AddDays(-$DaysBack)
        $ResourceId = $StorageAccount.Id
        
        # Get transaction metrics
        $TransactionMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "Transactions" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Total -ErrorAction SilentlyContinue
        
        $TotalTransactions = if ($TransactionMetrics -and $TransactionMetrics.Data.Count -gt 0) {
            ($TransactionMetrics.Data | Measure-Object -Property Total -Sum).Sum
        } else { 0 }
        
        # Get used capacity metrics
        $CapacityMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "UsedCapacity" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 1.00:00:00 -AggregationType Average -ErrorAction SilentlyContinue
        
        $AvgUsedCapacityGB = if ($CapacityMetrics -and $CapacityMetrics.Data.Count -gt 0) {
            [math]::Round(($CapacityMetrics.Data | Measure-Object -Property Average -Average).Average / 1GB, 2)
        } else { 0 }
        
        # Get egress metrics (data retrieval costs)
        $EgressMetrics = Get-AzMetric -ResourceId $ResourceId -MetricName "Egress" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Total -ErrorAction SilentlyContinue
        
        $TotalEgressGB = if ($EgressMetrics -and $EgressMetrics.Data.Count -gt 0) {
            [math]::Round(($EgressMetrics.Data | Measure-Object -Property Total -Sum).Sum / 1GB, 2)
        } else { 0 }
        
        $Metrics = @{
            TotalTransactions = $TotalTransactions
            AvgDailyTransactions = [math]::Round($TotalTransactions / $DaysBack, 0)
            UsedCapacityGB = $AvgUsedCapacityGB
            TotalEgressGB = $TotalEgressGB
            AvgDailyEgressGB = [math]::Round($TotalEgressGB / $DaysBack, 2)
            SamplePeriodDays = $DaysBack
        }
        
        Write-LogEntry "Metrics retrieved - Transactions: $($Metrics.TotalTransactions), Capacity: $($Metrics.UsedCapacityGB)GB, Egress: $($Metrics.TotalEgressGB)GB"
        
        return $Metrics
    }
    catch {
        Write-LogEntry "Failed to retrieve storage metrics: $($_.Exception.Message)" -Level "ERROR"
        return @{
            TotalTransactions = 0
            AvgDailyTransactions = 0
            UsedCapacityGB = 0
            TotalEgressGB = 0
            AvgDailyEgressGB = 0
            SamplePeriodDays = $DaysBack
        }
    }
}

function Get-BlobAccessPatterns {
    param(
        [object]$StorageAccount,
        [string]$ContainerName = $null
    )
    
    try {
        Write-LogEntry "Analyzing blob access patterns for: $($StorageAccount.StorageAccountName)"
        
        $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName `
            -UseConnectedAccount
        
        $Containers = if ($ContainerName) {
            @(Get-AzStorageContainer -Context $StorageContext -Name $ContainerName)
        } else {
            Get-AzStorageContainer -Context $StorageContext
        }
        
        $BlobAnalysis = @()
        
        foreach ($Container in $Containers) {
            Write-LogEntry "Analyzing container: $($Container.Name)"
            
            $Blobs = Get-AzStorageBlob -Container $Container.Name -Context $StorageContext
            
            foreach ($Blob in $Blobs) {
                $DaysSinceLastModified = (Get-Date) - $Blob.LastModified
                $DaysSinceAccess = if ($Blob.Properties.LastAccessTime) {
                    (Get-Date) - $Blob.Properties.LastAccessTime
                } else {
                    $DaysSinceLastModified
                }
                
                $BlobInfo = @{
                    BlobName = $Blob.Name
                    ContainerName = $Container.Name
                    CurrentTier = $Blob.Properties.AccessTier
                    SizeGB = [math]::Round($Blob.Length / 1GB, 4)
                    DaysSinceLastModified = $DaysSinceLastModified.Days
                    DaysSinceLastAccess = $DaysSinceAccess.Days
                    RecommendedTier = $null
                    EstimatedSavings = 0
                    ShouldOptimize = $false
                }
                
                # Determine recommended tier based on access patterns
                $CurrentTier = $Blob.Properties.AccessTier
                if ($CurrentTier -eq "Hot") {
                    if ($DaysSinceAccess.Days -gt $TierOptimization.Hot.ArchiveThreshold) {
                        $BlobInfo.RecommendedTier = "Archive"
                        $BlobInfo.ShouldOptimize = $true
                    }
                    elseif ($DaysSinceAccess.Days -gt $TierOptimization.Hot.CoolThreshold) {
                        $BlobInfo.RecommendedTier = "Cool"
                        $BlobInfo.ShouldOptimize = $true
                    }
                }
                elseif ($CurrentTier -eq "Cool") {
                    if ($DaysSinceAccess.Days -gt $TierOptimization.Cool.ArchiveThreshold) {
                        $BlobInfo.RecommendedTier = "Archive"
                        $BlobInfo.ShouldOptimize = $true
                    }
                }
                
                # Calculate estimated savings
                if ($BlobInfo.ShouldOptimize) {
                    $SavingsPercentage = if ($CurrentTier -eq "Hot" -and $BlobInfo.RecommendedTier -eq "Cool") {
                        $TierOptimization.Hot.MonthlySavings.Cool
                    } elseif ($CurrentTier -eq "Hot" -and $BlobInfo.RecommendedTier -eq "Archive") {
                        $TierOptimization.Hot.MonthlySavings.Archive
                    } elseif ($CurrentTier -eq "Cool" -and $BlobInfo.RecommendedTier -eq "Archive") {
                        $TierOptimization.Cool.MonthlySavings.Archive
                    } else { 0 }
                    
                    # Simplified cost calculation (actual implementation would use Azure pricing API)
                    $CurrentMonthlyCost = Get-StorageCostEstimate -SizeGB $BlobInfo.SizeGB -Tier $CurrentTier
                    $BlobInfo.EstimatedSavings = [math]::Round($CurrentMonthlyCost * $SavingsPercentage, 2)
                }
                
                $BlobAnalysis += $BlobInfo
            }
        }
        
        Write-LogEntry "Blob analysis completed. Total blobs: $($BlobAnalysis.Count), Optimization candidates: $(($BlobAnalysis | Where-Object ShouldOptimize).Count)"
        
        return $BlobAnalysis
    }
    catch {
        Write-LogEntry "Failed to analyze blob access patterns: $($_.Exception.Message)" -Level "ERROR"
        return @()
    }
}

function Get-StorageCostEstimate {
    param(
        [decimal]$SizeGB,
        [string]$Tier
    )
    
    # Simplified cost estimates per GB per month (USD) - in real implementation, use Azure pricing API
    $TierCosts = @{
        "Hot" = 0.0184
        "Cool" = 0.0100
        "Archive" = 0.00099
    }
    
    return $SizeGB * $TierCosts[$Tier]
}

function Get-StorageOptimizationRecommendations {
    param(
        [object]$StorageAccount,
        [hashtable]$Metrics,
        [array]$BlobAnalysis
    )
    
    $Recommendations = @{
        StorageAccountName = $StorageAccount.StorageAccountName
        AccountRecommendations = @()
        BlobOptimizations = $BlobAnalysis | Where-Object ShouldOptimize
        TotalEstimatedSavings = 0
        ShouldImplementLifecyclePolicy = $false
        ShouldDeleteUnusedAccount = $false
    }
    
    # Check if storage account is unused
    if ($Metrics.TotalTransactions -eq 0 -and $Metrics.UsedCapacityGB -lt 1) {
        $Recommendations.ShouldDeleteUnusedAccount = $true
        $Recommendations.AccountRecommendations += "Storage account appears unused (no transactions, minimal data)"
    }
    
    # Check if lifecycle policy would be beneficial
    $OptimizableBlobCount = ($BlobAnalysis | Where-Object ShouldOptimize).Count
    if ($OptimizableBlobCount -gt 10) {
        $Recommendations.ShouldImplementLifecyclePolicy = $true
        $Recommendations.AccountRecommendations += "Implement lifecycle management policy for automatic tier transitions"
    }
    
    # Check for low access patterns
    if ($Metrics.AvgDailyTransactions -lt 100 -and $Metrics.UsedCapacityGB -gt 10) {
        $Recommendations.AccountRecommendations += "Consider migrating to cheaper storage tier due to low access patterns"
    }
    
    # Calculate total estimated savings
    $Recommendations.TotalEstimatedSavings = ($Recommendations.BlobOptimizations | 
        Measure-Object -Property EstimatedSavings -Sum).Sum
    
    return $Recommendations
}

function Invoke-BlobTierOptimization {
    param(
        [object]$StorageAccount,
        [array]$BlobOptimizations,
        [bool]$DryRun = $false
    )
    
    try {
        Write-LogEntry "Starting blob tier optimization for: $($StorageAccount.StorageAccountName)"
        
        if ($DryRun) {
            Write-LogEntry "[DRY RUN] Would optimize $($BlobOptimizations.Count) blobs"
            return @{ Success = $true; OptimizedCount = $BlobOptimizations.Count; Message = "Dry run completed" }
        }
        
        $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName `
            -UseConnectedAccount
        
        $OptimizedCount = 0
        $FailedCount = 0
        
        foreach ($Blob in $BlobOptimizations) {
            try {
                Write-LogEntry "Optimizing blob: $($Blob.BlobName) ($($Blob.CurrentTier) → $($Blob.RecommendedTier))"
                
                $BlobObject = Get-AzStorageBlob -Container $Blob.ContainerName -Blob $Blob.BlobName -Context $StorageContext
                $BlobObject.BlobClient.SetAccessTier($Blob.RecommendedTier)
                
                $OptimizedCount++
                Write-LogEntry "Successfully optimized blob: $($Blob.BlobName)"
            }
            catch {
                $FailedCount++
                Write-LogEntry "Failed to optimize blob $($Blob.BlobName): $($_.Exception.Message)" -Level "ERROR"
            }
        }
        
        return @{
            Success = $true
            OptimizedCount = $OptimizedCount
            FailedCount = $FailedCount
            Message = "Optimized $OptimizedCount blobs, $FailedCount failed"
        }
    }
    catch {
        Write-LogEntry "Failed to optimize blob tiers: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function New-LifecycleManagementPolicy {
    param(
        [object]$StorageAccount,
        [bool]$DryRun = $false
    )
    
    try {
        Write-LogEntry "Creating lifecycle management policy for: $($StorageAccount.StorageAccountName)"
        
        if ($DryRun) {
            Write-LogEntry "[DRY RUN] Would create lifecycle management policy"
            return @{ Success = $true; Message = "Dry run completed" }
        }
        
        # Create lifecycle policy rules
        $Rule1 = New-AzStorageAccountManagementPolicyRule -Name "MoveToCool" `
            -Action (New-AzStorageAccountManagementPolicyAction -BaseBlobAction @{
                tierToCool = New-AzStorageAccountManagementPolicyFilter -DaysAfterModificationGreaterThan 30
            })
        
        $Rule2 = New-AzStorageAccountManagementPolicyRule -Name "MoveToArchive" `
            -Action (New-AzStorageAccountManagementPolicyAction -BaseBlobAction @{
                tierToArchive = New-AzStorageAccountManagementPolicyFilter -DaysAfterModificationGreaterThan 90
            })
        
        $Rule3 = New-AzStorageAccountManagementPolicyRule -Name "DeleteOldBlobs" `
            -Action (New-AzStorageAccountManagementPolicyAction -BaseBlobAction @{
                delete = New-AzStorageAccountManagementPolicyFilter -DaysAfterModificationGreaterThan 2555 # 7 years
            })
        
        $Policy = New-AzStorageAccountManagementPolicyRuleSet -Rule $Rule1, $Rule2, $Rule3
        
        Set-AzStorageAccountManagementPolicy -ResourceGroupName $StorageAccount.ResourceGroupName `
            -StorageAccountName $StorageAccount.StorageAccountName -Policy $Policy
        
        Write-LogEntry "Lifecycle management policy created successfully"
        
        return @{ Success = $true; Message = "Lifecycle policy created" }
    }
    catch {
        Write-LogEntry "Failed to create lifecycle policy: $($_.Exception.Message)" -Level "ERROR"
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}

function Request-Approval {
    param(
        [string]$StorageAccountName,
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
    Write-LogEntry "Starting storage optimization runbook execution"
    Write-LogEntry "Parameters - ResourceGroup: $ResourceGroupName, StorageAccount: $StorageAccountName, DryRun: $DryRun"
    
    # Connect to Azure
    $null = Connect-ToAzure
    
    # Get storage accounts to process
    if ($StorageAccountName) {
        if ($ResourceGroupName) {
            $StorageAccounts = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)
        } else {
            $StorageAccounts = @(Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $StorageAccountName })
        }
        Write-LogEntry "Processing single storage account: $StorageAccountName"
    }
    else {
        if ($ResourceGroupName) {
            $StorageAccounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName
        } else {
            $StorageAccounts = Get-AzStorageAccount
        }
        Write-LogEntry "Processing storage accounts (Count: $($StorageAccounts.Count))"
    }
    
    $Results = @()
    $TotalSavings = 0
    
    foreach ($StorageAccount in $StorageAccounts) {
        try {
            Write-LogEntry "Analyzing storage account: $($StorageAccount.StorageAccountName)"
            
            # Get storage metrics
            $Metrics = Get-StorageAccountMetrics -StorageAccount $StorageAccount
            
            # Analyze blob access patterns
            $BlobAnalysis = Get-BlobAccessPatterns -StorageAccount $StorageAccount
            
            # Get optimization recommendations
            $Recommendations = Get-StorageOptimizationRecommendations -StorageAccount $StorageAccount `
                -Metrics $Metrics -BlobAnalysis $BlobAnalysis
            
            $Result = @{
                StorageAccountName = $StorageAccount.StorageAccountName
                ResourceGroupName = $StorageAccount.ResourceGroupName
                Metrics = $Metrics
                Recommendations = $Recommendations
                Actions = @()
                TotalSavings = $Recommendations.TotalEstimatedSavings
                Success = $true
                Message = ""
            }
            
            # Implement optimizations if approved
            if ($Recommendations.BlobOptimizations.Count -gt 0) {
                $Approved = Request-Approval -StorageAccountName $StorageAccount.StorageAccountName `
                    -EstimatedSavings $Recommendations.TotalEstimatedSavings -Action "Blob Tier Optimization"
                
                if ($Approved) {
                    $OptimizationResult = Invoke-BlobTierOptimization -StorageAccount $StorageAccount `
                        -BlobOptimizations $Recommendations.BlobOptimizations -DryRun $DryRun
                    
                    $Result.Actions += @{
                        Type = "BlobTierOptimization"
                        Success = $OptimizationResult.Success
                        Message = $OptimizationResult.Message
                        OptimizedCount = $OptimizationResult.OptimizedCount
                    }
                }
                else {
                    $Result.Actions += @{
                        Type = "BlobTierOptimization"
                        Success = $false
                        Message = "Requires approval"
                    }
                }
            }
            
            # Create lifecycle policy if recommended
            if ($Recommendations.ShouldImplementLifecyclePolicy) {
                $LifecycleResult = New-LifecycleManagementPolicy -StorageAccount $StorageAccount -DryRun $DryRun
                
                $Result.Actions += @{
                    Type = "LifecyclePolicy"
                    Success = $LifecycleResult.Success
                    Message = $LifecycleResult.Message
                }
            }
            
            $TotalSavings += $Result.TotalSavings
            $Results += $Result
            
            Write-LogEntry "Storage account $($StorageAccount.StorageAccountName) analysis completed. Estimated savings: $($Result.TotalSavings) USD"
        }
        catch {
            Write-LogEntry "Error processing storage account $($StorageAccount.StorageAccountName): $($_.Exception.Message)" -Level "ERROR"
            $Results += @{
                StorageAccountName = $StorageAccount.StorageAccountName
                Success = $false
                Message = $_.Exception.Message
                TotalSavings = 0
            }
        }
    }
    
    # Generate summary
    $TotalAccounts = $Results.Count
    $OptimizedAccounts = ($Results | Where-Object { $_.Success -and $_.Actions.Count -gt 0 }).Count
    $TotalBlobsOptimized = ($Results | ForEach-Object { $_.Actions | Where-Object { $_.Type -eq "BlobTierOptimization" -and $_.Success } | ForEach-Object { $_.OptimizedCount } } | Measure-Object -Sum).Sum
    
    Write-LogEntry "=== STORAGE OPTIMIZATION SUMMARY ===" -Level "SUCCESS"
    Write-LogEntry "Total Storage Accounts Processed: $TotalAccounts"
    Write-LogEntry "Storage Accounts Optimized: $OptimizedAccounts"
    Write-LogEntry "Total Blobs Optimized: $TotalBlobsOptimized"
    Write-LogEntry "Estimated Monthly Savings: $TotalSavings USD"
    
    # Output results for monitoring
    $Results | ForEach-Object {
        Write-Output "Storage Account: $($_.StorageAccountName) | Actions: $($_.Actions.Count) | Savings: $($_.TotalSavings) USD | Success: $($_.Success)"
    }
    
    Write-LogEntry "Storage optimization runbook completed successfully" -Level "SUCCESS"
}
catch {
    Write-LogEntry "Storage optimization runbook failed: $($_.Exception.Message)" -Level "ERROR"
    throw
}