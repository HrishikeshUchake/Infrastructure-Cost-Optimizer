#Requires -Modules Az.Accounts, Az.Compute, Az.Monitor

<#
.SYNOPSIS
    VM Right-sizing Automation Runbook for Cost Optimization

.DESCRIPTION
    This runbook analyzes VM utilization metrics from Azure Monitor and automatically
    resizes VMs to more cost-effective sizes based on CPU, memory, and disk utilization.
    Implements safety checks and approval workflows for high-impact changes.

.PARAMETER ResourceGroupName
    Name of the resource group containing the VM

.PARAMETER VMName
    Name of the virtual machine to optimize (optional, if not provided will scan all VMs)

.PARAMETER NewSize
    Specific VM size to resize to (optional, if not provided will auto-calculate)

.PARAMETER Force
    Skip approval for automated resizing (use with caution)

.PARAMETER DryRun
    Simulate the operation without making actual changes

.NOTES
    Author: Infrastructure Cost Optimization System
    Version: 1.0
    Last Modified: 2025-10-06
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$VMName,
    
    [Parameter(Mandatory=$false)]
    [string]$NewSize,
    
    [Parameter(Mandatory=$false)]
    [bool]$Force = $false,
    
    [Parameter(Mandatory=$false)]
    [bool]$DryRun = $false
)

# Initialize logging
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"

# VM size mapping for cost optimization
$VMSizeMapping = @{
    # Standard D-Series to B-Series (burstable)
    "Standard_D2s_v3" = @{ "Recommended" = "Standard_B2s"; "Savings" = "60%" }
    "Standard_D4s_v3" = @{ "Recommended" = "Standard_B4ms"; "Savings" = "40%" }
    "Standard_D8s_v3" = @{ "Recommended" = "Standard_D4s_v3"; "Savings" = "50%" }
    "Standard_D16s_v3" = @{ "Recommended" = "Standard_D8s_v3"; "Savings" = "50%" }
    
    # Standard F-Series to D-Series
    "Standard_F4s_v2" = @{ "Recommended" = "Standard_D2s_v3"; "Savings" = "30%" }
    "Standard_F8s_v2" = @{ "Recommended" = "Standard_D4s_v3"; "Savings" = "35%" }
    
    # General purpose alternatives
    "Standard_E2s_v3" = @{ "Recommended" = "Standard_B2ms"; "Savings" = "45%" }
    "Standard_E4s_v3" = @{ "Recommended" = "Standard_D2s_v3"; "Savings" = "40%" }
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
        ResourceId = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName"
        ResourceType = "Microsoft.Compute/virtualMachines"
        OptimizationType = "VM_Rightsizing"
        Action = $Message
        EstimatedSavings = 0
        Status = $Level
        Details = @{
            RunbookName = "Optimize-VMSize"
            Parameters = @{
                ResourceGroupName = $ResourceGroupName
                VMName = $VMName
                NewSize = $NewSize
                DryRun = $DryRun
            }
        }
    }
    
    # In a real implementation, this would send to Log Analytics
    Write-Verbose "Log entry created: $($LogData | ConvertTo-Json -Depth 3)"
}

function Connect-ToAzure {
    try {
        Write-LogEntry "Connecting to Azure using Managed Identity..."
        
        # Connect using the Automation Account's Managed Identity
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

function Get-VMUtilizationMetrics {
    param(
        [string]$VMResourceId,
        [int]$DaysBack = 7
    )
    
    try {
        Write-LogEntry "Retrieving utilization metrics for VM: $VMResourceId"
        
        $EndTime = Get-Date
        $StartTime = $EndTime.AddDays(-$DaysBack)
        
        # Get CPU utilization
        $CPUMetrics = Get-AzMetric -ResourceId $VMResourceId -MetricName "Percentage CPU" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Average
        
        # Calculate averages
        $AvgCPU = if ($CPUMetrics.Data.Count -gt 0) {
            ($CPUMetrics.Data | Measure-Object -Property Average -Average).Average
        } else { 0 }
        
        # Get memory metrics (requires VM insights)
        $MemoryMetrics = Get-AzMetric -ResourceId $VMResourceId -MetricName "Available Memory Bytes" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Average -ErrorAction SilentlyContinue
        
        $AvgMemoryAvailable = if ($MemoryMetrics -and $MemoryMetrics.Data.Count -gt 0) {
            ($MemoryMetrics.Data | Measure-Object -Property Average -Average).Average
        } else { 0 }
        
        # Get disk metrics
        $DiskMetrics = Get-AzMetric -ResourceId $VMResourceId -MetricName "Disk Read Operations/Sec" `
            -StartTime $StartTime -EndTime $EndTime -TimeGrain 01:00:00 -AggregationType Average
        
        $AvgDiskOps = if ($DiskMetrics.Data.Count -gt 0) {
            ($DiskMetrics.Data | Measure-Object -Property Average -Average).Average
        } else { 0 }
        
        $Metrics = @{
            AvgCPUUtilization = [math]::Round($AvgCPU, 2)
            AvgMemoryAvailable = [math]::Round($AvgMemoryAvailable / 1GB, 2)
            AvgDiskOpsPerSec = [math]::Round($AvgDiskOps, 2)
            SamplePeriodDays = $DaysBack
            DataPoints = $CPUMetrics.Data.Count
        }
        
        Write-LogEntry "Metrics retrieved - CPU: $($Metrics.AvgCPUUtilization)%, Memory Available: $($Metrics.AvgMemoryAvailable)GB, Disk Ops/Sec: $($Metrics.AvgDiskOpsPerSec)"
        
        return $Metrics
    }
    catch {
        Write-LogEntry "Failed to retrieve VM metrics: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Get-OptimizationRecommendation {
    param(
        [object]$VM,
        [hashtable]$Metrics
    )
    
    $CurrentSize = $VM.HardwareProfile.VmSize
    $Recommendation = @{
        CurrentSize = $CurrentSize
        RecommendedSize = $null
        Reason = ""
        EstimatedMonthlySavings = 0
        Confidence = "Low"
        ShouldOptimize = $false
    }
    
    # Check if VM is underutilized
    $IsUnderutilized = $Metrics.AvgCPUUtilization -lt 10 -and $Metrics.DataPoints -gt 24
    
    if ($IsUnderutilized) {
        # Look for optimization mapping
        if ($VMSizeMapping.ContainsKey($CurrentSize)) {
            $Mapping = $VMSizeMapping[$CurrentSize]
            $Recommendation.RecommendedSize = $Mapping.Recommended
            $Recommendation.Reason = "VM shows consistently low CPU utilization ($($Metrics.AvgCPUUtilization)%) over $($Metrics.SamplePeriodDays) days"
            $Recommendation.ShouldOptimize = $true
            $Recommendation.Confidence = "High"
            
            # Estimate savings (simplified calculation)
            $CurrentCost = Get-VMCostEstimate -VMSize $CurrentSize
            $NewCost = Get-VMCostEstimate -VMSize $Mapping.Recommended
            $Recommendation.EstimatedMonthlySavings = [math]::Round($CurrentCost - $NewCost, 2)
        }
        else {
            $Recommendation.Reason = "VM is underutilized but no optimization mapping available for size: $CurrentSize"
            $Recommendation.Confidence = "Medium"
        }
    }
    elseif ($Metrics.AvgCPUUtilization -lt 20) {
        $Recommendation.Reason = "VM shows moderate utilization ($($Metrics.AvgCPUUtilization)%). Consider monitoring longer or manual review."
        $Recommendation.Confidence = "Low"
    }
    else {
        $Recommendation.Reason = "VM utilization ($($Metrics.AvgCPUUtilization)%) is within acceptable range"
        $Recommendation.Confidence = "High"
    }
    
    return $Recommendation
}

function Get-VMCostEstimate {
    param([string]$VMSize)
    
    # Simplified cost estimates (USD per month) - in real implementation, use Azure pricing API
    $CostMapping = @{
        "Standard_D2s_v3" = 85.68
        "Standard_D4s_v3" = 171.36
        "Standard_D8s_v3" = 342.72
        "Standard_D16s_v3" = 685.44
        "Standard_B2s" = 35.04
        "Standard_B2ms" = 60.74
        "Standard_B4ms" = 121.47
        "Standard_F4s_v2" = 136.80
        "Standard_F8s_v2" = 273.60
        "Standard_E2s_v3" = 102.19
        "Standard_E4s_v3" = 204.38
    }
    
    return $CostMapping[$VMSize] -or 100 # Default estimate if not found
}

function Invoke-VMResize {
    param(
        [object]$VM,
        [string]$NewSize,
        [bool]$DryRun = $false
    )
    
    try {
        $VMName = $VM.Name
        $CurrentSize = $VM.HardwareProfile.VmSize
        
        Write-LogEntry "Starting VM resize operation: $VMName ($CurrentSize → $NewSize)"
        
        if ($DryRun) {
            Write-LogEntry "[DRY RUN] Would resize VM $VMName from $CurrentSize to $NewSize"
            return @{ Success = $true; Message = "Dry run completed successfully" }
        }
        
        # Check if VM is running
        $VMStatus = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VMName -Status
        $PowerState = ($VMStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        
        $WasRunning = $PowerState -eq "VM running"
        
        if ($WasRunning) {
            Write-LogEntry "Stopping VM $VMName for resize..."
            $null = Stop-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VMName -Force
            
            # Wait for VM to fully stop
            do {
                Start-Sleep -Seconds 10
                $VMStatus = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VMName -Status
                $PowerState = ($VMStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
            } while ($PowerState -ne "VM deallocated")
        }
        
        # Resize the VM
        Write-LogEntry "Resizing VM $VMName to $NewSize..."
        $VM.HardwareProfile.VmSize = $NewSize
        $null = Update-AzVM -VM $VM -ResourceGroupName $VM.ResourceGroupName
        
        # Start VM if it was originally running
        if ($WasRunning) {
            Write-LogEntry "Starting VM $VMName after resize..."
            $null = Start-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VMName
        }
        
        Write-LogEntry "VM $VMName successfully resized from $CurrentSize to $NewSize"
        
        return @{ 
            Success = $true
            Message = "VM resized successfully"
            OriginalSize = $CurrentSize
            NewSize = $NewSize
            WasRunning = $WasRunning
        }
    }
    catch {
        Write-LogEntry "Failed to resize VM $($VM.Name): $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Request-Approval {
    param(
        [string]$VMName,
        [string]$CurrentSize,
        [string]$RecommendedSize,
        [decimal]$EstimatedSavings
    )
    
    # In a real implementation, this would integrate with approval systems
    # For now, we'll use a simple threshold-based approach
    
    if ($EstimatedSavings -lt $AutoApprovalThreshold) {
        Write-LogEntry "Auto-approved: Savings ($EstimatedSavings USD) below threshold ($AutoApprovalThreshold USD)"
        return $true
    }
    elseif ($EstimatedSavings -lt $RequireApprovalThreshold) {
        Write-LogEntry "Manual approval required: Savings ($EstimatedSavings USD) requires review"
        # In real implementation, send to approval workflow
        return $Force # Only proceed if Force is specified
    }
    else {
        Write-LogEntry "High-impact change: Savings ($EstimatedSavings USD) requires senior approval"
        return $false # Always require explicit approval for high-impact changes
    }
}

# Main execution logic
try {
    Write-LogEntry "Starting VM optimization runbook execution"
    Write-LogEntry "Parameters - ResourceGroup: $ResourceGroupName, VM: $VMName, NewSize: $NewSize, DryRun: $DryRun"
    
    # Connect to Azure
    $null = Connect-ToAzure
    
    # Get VMs to process
    if ($VMName) {
        $VMs = @(Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName)
        Write-LogEntry "Processing single VM: $VMName"
    }
    else {
        $VMs = Get-AzVM -ResourceGroupName $ResourceGroupName
        Write-LogEntry "Processing all VMs in resource group: $ResourceGroupName (Count: $($VMs.Count))"
    }
    
    $Results = @()
    
    foreach ($VM in $VMs) {
        try {
            Write-LogEntry "Analyzing VM: $($VM.Name)"
            
            # Skip if VM is not running (for metrics collection)
            $VMStatus = Get-AzVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -Status
            $PowerState = ($VMStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
            
            if ($PowerState -ne "VM running" -and $PowerState -ne "VM deallocated") {
                Write-LogEntry "Skipping VM $($VM.Name) - PowerState: $PowerState"
                continue
            }
            
            # Get utilization metrics
            $VMResourceId = $VM.Id
            $Metrics = Get-VMUtilizationMetrics -VMResourceId $VMResourceId
            
            # Get optimization recommendation
            $Recommendation = Get-OptimizationRecommendation -VM $VM -Metrics $Metrics
            
            # Use provided size or recommendation
            $TargetSize = if ($NewSize) { $NewSize } else { $Recommendation.RecommendedSize }
            
            $Result = @{
                VMName = $VM.Name
                CurrentSize = $VM.HardwareProfile.VmSize
                TargetSize = $TargetSize
                Metrics = $Metrics
                Recommendation = $Recommendation
                Action = "None"
                Success = $false
                Message = ""
            }
            
            if ($TargetSize -and $Recommendation.ShouldOptimize) {
                # Check approval requirements
                $Approved = Request-Approval -VMName $VM.Name -CurrentSize $VM.HardwareProfile.VmSize `
                    -RecommendedSize $TargetSize -EstimatedSavings $Recommendation.EstimatedMonthlySavings
                
                if ($Approved) {
                    # Perform the resize
                    $ResizeResult = Invoke-VMResize -VM $VM -NewSize $TargetSize -DryRun $DryRun
                    
                    $Result.Action = if ($DryRun) { "Simulated" } else { "Resized" }
                    $Result.Success = $ResizeResult.Success
                    $Result.Message = $ResizeResult.Message
                    
                    Write-LogEntry "VM $($VM.Name) optimization completed successfully" -Level "SUCCESS"
                }
                else {
                    $Result.Action = "Approval Required"
                    $Result.Message = "Optimization requires approval due to high impact or cost"
                    Write-LogEntry "VM $($VM.Name) optimization requires approval"
                }
            }
            else {
                $Result.Message = $Recommendation.Reason
                Write-LogEntry "VM $($VM.Name) - No optimization needed: $($Recommendation.Reason)"
            }
            
            $Results += $Result
        }
        catch {
            Write-LogEntry "Error processing VM $($VM.Name): $($_.Exception.Message)" -Level "ERROR"
            $Results += @{
                VMName = $VM.Name
                CurrentSize = $VM.HardwareProfile.VmSize
                Action = "Error"
                Success = $false
                Message = $_.Exception.Message
            }
        }
    }
    
    # Generate summary
    $TotalVMs = $Results.Count
    $OptimizedVMs = ($Results | Where-Object { $_.Action -eq "Resized" }).Count
    $SimulatedVMs = ($Results | Where-Object { $_.Action -eq "Simulated" }).Count
    $TotalSavings = ($Results | Where-Object { $_.Recommendation.EstimatedMonthlySavings } | 
        Measure-Object -Property @{Expression={$_.Recommendation.EstimatedMonthlySavings}} -Sum).Sum
    
    Write-LogEntry "=== VM OPTIMIZATION SUMMARY ===" -Level "SUCCESS"
    Write-LogEntry "Total VMs Processed: $TotalVMs"
    Write-LogEntry "VMs Optimized: $OptimizedVMs"
    Write-LogEntry "VMs Simulated: $SimulatedVMs"
    Write-LogEntry "Estimated Monthly Savings: $TotalSavings USD"
    
    # Output results for monitoring
    $Results | ForEach-Object {
        Write-Output "VM: $($_.VMName) | Current: $($_.CurrentSize) | Target: $($_.TargetSize) | Action: $($_.Action) | Success: $($_.Success)"
    }
    
    Write-LogEntry "VM optimization runbook completed successfully" -Level "SUCCESS"
}
catch {
    Write-LogEntry "VM optimization runbook failed: $($_.Exception.Message)" -Level "ERROR"
    throw
}