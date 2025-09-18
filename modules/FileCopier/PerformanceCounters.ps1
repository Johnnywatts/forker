# PerformanceCounters.ps1 - Windows Performance Counters Integration
# Part of Phase 5B: Monitoring & Diagnostics

using namespace System.Diagnostics

# Performance counter category and counter definitions
$script:CategoryName = "FileCopier Service"
$script:CategoryHelp = "Performance counters for FileCopier Service monitoring SVS file operations"

# Performance counter definitions
$script:CounterDefinitions = @{
    # File Processing Counters
    'FilesProcessedPerSecond' = @{
        Name = "Files Processed/sec"
        Help = "Number of files processed per second"
        Type = [PerformanceCounterType]::RateOfCountsPerSecond32
    }
    'FilesInQueue' = @{
        Name = "Files in Queue"
        Help = "Current number of files waiting to be processed"
        Type = [PerformanceCounterType]::NumberOfItems32
    }
    'FilesSucceeded' = @{
        Name = "Files Succeeded"
        Help = "Total number of files successfully processed"
        Type = [PerformanceCounterType]::NumberOfItems64
    }
    'FilesFailed' = @{
        Name = "Files Failed"
        Help = "Total number of files that failed processing"
        Type = [PerformanceCounterType]::NumberOfItems64
    }
    'FilesQuarantined' = @{
        Name = "Files Quarantined"
        Help = "Total number of files moved to quarantine"
        Type = [PerformanceCounterType]::NumberOfItems64
    }

    # Performance Counters
    'AverageProcessingTime' = @{
        Name = "Average Processing Time"
        Help = "Average time to process a file in milliseconds"
        Type = [PerformanceCounterType]::AverageTimer32
    }
    'AverageProcessingTimeBase' = @{
        Name = "Average Processing Time Base"
        Help = "Base counter for average processing time"
        Type = [PerformanceCounterType]::AverageBase
    }
    'AverageCopySpeed' = @{
        Name = "Average Copy Speed (MB/sec)"
        Help = "Average file copy speed in megabytes per second"
        Type = [PerformanceCounterType]::AverageTimer32
    }
    'AverageCopySpeedBase' = @{
        Name = "Average Copy Speed Base"
        Help = "Base counter for average copy speed"
        Type = [PerformanceCounterType]::AverageBase
    }

    # System Resource Counters
    'MemoryUsageMB' = @{
        Name = "Memory Usage (MB)"
        Help = "Current memory usage in megabytes"
        Type = [PerformanceCounterType]::NumberOfItems32
    }
    'ThreadCount' = @{
        Name = "Active Threads"
        Help = "Number of active processing threads"
        Type = [PerformanceCounterType]::NumberOfItems32
    }

    # Error and Retry Counters
    'ErrorsPerSecond' = @{
        Name = "Errors/sec"
        Help = "Number of errors occurring per second"
        Type = [PerformanceCounterType]::RateOfCountsPerSecond32
    }
    'RetryAttemptsPerSecond' = @{
        Name = "Retry Attempts/sec"
        Help = "Number of retry attempts per second"
        Type = [PerformanceCounterType]::RateOfCountsPerSecond32
    }
    'CircuitBreakerTrips' = @{
        Name = "Circuit Breaker Trips"
        Help = "Total number of circuit breaker activations"
        Type = [PerformanceCounterType]::NumberOfItems64
    }

    # Data Volume Counters
    'BytesProcessedPerSecond' = @{
        Name = "Bytes Processed/sec"
        Help = "Number of bytes processed per second"
        Type = [PerformanceCounterType]::RateOfCountsPerSecond64
    }
    'TotalBytesProcessed' = @{
        Name = "Total Bytes Processed"
        Help = "Total number of bytes processed since service start"
        Type = [PerformanceCounterType]::NumberOfItems64
    }
}

# Performance counter manager class
class PerformanceCounterManager {
    [string] $LogContext = "PerformanceCounters"
    [hashtable] $Config
    [hashtable] $Counters
    [bool] $CountersEnabled
    [string] $CategoryName
    [bool] $IsInitialized

    PerformanceCounterManager([hashtable] $config) {
        $this.Config = $config
        $this.Counters = @{}
        $this.CountersEnabled = $false
        $this.CategoryName = $script:CategoryName
        $this.IsInitialized = $false

        # Check if performance counters are enabled in config
        if ($this.Config.ContainsKey('Performance') -and
            $this.Config.Performance.ContainsKey('Monitoring') -and
            $this.Config.Performance.Monitoring.PerformanceCounters -eq $true) {

            $this.CountersEnabled = $true
            Write-FileCopierLog -Level "Information" -Message "Performance counters enabled" -Category $this.LogContext
        } else {
            Write-FileCopierLog -Level "Information" -Message "Performance counters disabled in configuration" -Category $this.LogContext
        }
    }

    # Initialize performance counter category and counters
    [bool] InitializeCounters() {
        if (-not $this.CountersEnabled) {
            return $false
        }

        try {
            Write-FileCopierLog -Level "Information" -Message "Initializing performance counters..." -Category $this.LogContext

            # Check if we need to create the category
            if (-not [PerformanceCounterCategory]::Exists($this.CategoryName)) {
                $this.CreateCounterCategory()
            } else {
                Write-FileCopierLog -Level "Information" -Message "Performance counter category already exists" -Category $this.LogContext
            }

            # Initialize individual counters
            $this.InitializeIndividualCounters()

            $this.IsInitialized = $true
            Write-FileCopierLog -Level "Information" -Message "Performance counters initialized successfully" -Category $this.LogContext -Properties @{
                CounterCount = $this.Counters.Count
                CategoryName = $this.CategoryName
            }

            return $true
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to initialize performance counters: $($_.Exception.Message)" -Category $this.LogContext
            $this.CountersEnabled = $false
            return $false
        }
    }

    # Create performance counter category with all counters
    [void] CreateCounterCategory() {
        try {
            Write-FileCopierLog -Level "Information" -Message "Creating performance counter category: $($this.CategoryName)" -Category $this.LogContext

            # Build counter creation data
            $counterData = [System.Diagnostics.CounterCreationDataCollection]::new()

            foreach ($counterKey in $script:CounterDefinitions.Keys) {
                $counterDef = $script:CounterDefinitions[$counterKey]

                $creationData = [System.Diagnostics.CounterCreationData]::new()
                $creationData.CounterName = $counterDef.Name
                $creationData.CounterHelp = $counterDef.Help
                $creationData.CounterType = $counterDef.Type

                $counterData.Add($creationData)

                Write-FileCopierLog -Level "Debug" -Message "Added counter definition: $($counterDef.Name)" -Category $this.LogContext
            }

            # Create the category
            [PerformanceCounterCategory]::Create(
                $this.CategoryName,
                $script:CategoryHelp,
                [PerformanceCounterCategoryType]::SingleInstance,
                $counterData
            ) | Out-Null

            Write-FileCopierLog -Level "Success" -Message "Performance counter category created successfully" -Category $this.LogContext -Properties @{
                CounterCount = $counterData.Count
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to create performance counter category: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Initialize individual performance counter instances
    [void] InitializeIndividualCounters() {
        foreach ($counterKey in $script:CounterDefinitions.Keys) {
            try {
                $counterDef = $script:CounterDefinitions[$counterKey]

                $counter = [PerformanceCounter]::new()
                $counter.CategoryName = $this.CategoryName
                $counter.CounterName = $counterDef.Name
                $counter.ReadOnly = $false
                $counter.RawValue = 0

                $this.Counters[$counterKey] = $counter

                Write-FileCopierLog -Level "Debug" -Message "Initialized counter: $($counterDef.Name)" -Category $this.LogContext
            }
            catch {
                Write-FileCopierLog -Level "Warning" -Message "Failed to initialize counter $counterKey : $($_.Exception.Message)" -Category $this.LogContext
            }
        }
    }

    # Update a performance counter value
    [void] UpdateCounter([string] $counterKey, [long] $value) {
        if (-not $this.IsInitialized -or -not $this.Counters.ContainsKey($counterKey)) {
            return
        }

        try {
            $this.Counters[$counterKey].RawValue = $value
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to update counter $counterKey : $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Increment a performance counter
    [void] IncrementCounter([string] $counterKey, [long] $incrementBy = 1) {
        if (-not $this.IsInitialized -or -not $this.Counters.ContainsKey($counterKey)) {
            return
        }

        try {
            $this.Counters[$counterKey].IncrementBy($incrementBy)
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to increment counter $counterKey : $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Update processing time counter (for average calculations)
    [void] UpdateProcessingTime([long] $processingTimeMs) {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            # Update the average processing time counter
            if ($this.Counters.ContainsKey('AverageProcessingTime')) {
                $this.Counters['AverageProcessingTime'].IncrementBy($processingTimeMs)
            }
            if ($this.Counters.ContainsKey('AverageProcessingTimeBase')) {
                $this.Counters['AverageProcessingTimeBase'].Increment()
            }
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to update processing time counters: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Update copy speed counter (for average calculations)
    [void] UpdateCopySpeed([long] $fileSizeBytes, [long] $copyTimeMs) {
        if (-not $this.IsInitialized -or $copyTimeMs -le 0) {
            return
        }

        try {
            # Calculate speed in MB/sec (* 1000 to convert ms to seconds, / 1048576 to convert bytes to MB)
            $speedMBPerSec = ($fileSizeBytes * 1000) / ($copyTimeMs * 1048576)
            $speedAsLong = [long]($speedMBPerSec * 1000)  # Store as thousandths for precision

            if ($this.Counters.ContainsKey('AverageCopySpeed')) {
                $this.Counters['AverageCopySpeed'].IncrementBy($speedAsLong)
            }
            if ($this.Counters.ContainsKey('AverageCopySpeedBase')) {
                $this.Counters['AverageCopySpeedBase'].Increment()
            }
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to update copy speed counters: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Update system resource counters
    [void] UpdateSystemCounters() {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            # Memory usage
            $currentProcess = Get-Process -Id $global:PID
            $memoryMB = [long]($currentProcess.WorkingSet64 / 1MB)
            $this.UpdateCounter('MemoryUsageMB', $memoryMB)

            # Thread count
            $threadCount = $currentProcess.Threads.Count
            $this.UpdateCounter('ThreadCount', $threadCount)
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to update system counters: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Record file processing event
    [void] RecordFileProcessed([long] $fileSizeBytes, [long] $processingTimeMs, [bool] $success) {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            # Update processing counters
            $this.IncrementCounter('FilesProcessedPerSecond')
            $this.IncrementCounter('BytesProcessedPerSecond', $fileSizeBytes)
            $this.IncrementCounter('TotalBytesProcessed', $fileSizeBytes)

            # Update timing counters
            $this.UpdateProcessingTime($processingTimeMs)

            # Update success/failure counters
            if ($success) {
                $this.IncrementCounter('FilesSucceeded')
            } else {
                $this.IncrementCounter('FilesFailed')
                $this.IncrementCounter('ErrorsPerSecond')
            }
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to record file processing: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Record file copy event
    [void] RecordFileCopied([long] $fileSizeBytes, [long] $copyTimeMs) {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            $this.UpdateCopySpeed($fileSizeBytes, $copyTimeMs)
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to record file copy: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Record error event
    [void] RecordError([string] $errorType = "General") {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            $this.IncrementCounter('ErrorsPerSecond')
            $this.IncrementCounter('FilesFailed')
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to record error: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Record retry attempt
    [void] RecordRetryAttempt() {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            $this.IncrementCounter('RetryAttemptsPerSecond')
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to record retry attempt: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Record circuit breaker trip
    [void] RecordCircuitBreakerTrip() {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            $this.IncrementCounter('CircuitBreakerTrips')
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to record circuit breaker trip: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Record file quarantined
    [void] RecordFileQuarantined() {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            $this.IncrementCounter('FilesQuarantined')
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to record quarantined file: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Update queue size
    [void] UpdateQueueSize([int] $queueSize) {
        if (-not $this.IsInitialized) {
            return
        }

        try {
            $this.UpdateCounter('FilesInQueue', $queueSize)
        }
        catch {
            Write-FileCopierLog -Level "Debug" -Message "Failed to update queue size: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Get current counter values
    [hashtable] GetCounterValues() {
        $values = @{}

        if (-not $this.IsInitialized) {
            return $values
        }

        foreach ($counterKey in $this.Counters.Keys) {
            try {
                $counter = $this.Counters[$counterKey]
                $values[$counterKey] = @{
                    Name = $counter.CounterName
                    Value = $counter.RawValue
                    Type = $counter.CounterType.ToString()
                }
            }
            catch {
                $values[$counterKey] = @{
                    Name = $counterKey
                    Value = 0
                    Error = $_.Exception.Message
                }
            }
        }

        return $values
    }

    # Get performance counter statistics
    [hashtable] GetStatistics() {
        $stats = @{
            CategoryName = $this.CategoryName
            IsEnabled = $this.CountersEnabled
            IsInitialized = $this.IsInitialized
            CounterCount = $this.Counters.Count
            LastUpdate = Get-Date
        }

        if ($this.IsInitialized) {
            $stats.CounterValues = $this.GetCounterValues()
        }

        return $stats
    }

    # Remove performance counter category (for cleanup)
    [bool] RemoveCounterCategory() {
        if (-not [PerformanceCounterCategory]::Exists($this.CategoryName)) {
            Write-FileCopierLog -Level "Information" -Message "Performance counter category does not exist" -Category $this.LogContext
            return $true
        }

        try {
            Write-FileCopierLog -Level "Information" -Message "Removing performance counter category: $($this.CategoryName)" -Category $this.LogContext
            [PerformanceCounterCategory]::Delete($this.CategoryName)

            Write-FileCopierLog -Level "Success" -Message "Performance counter category removed successfully" -Category $this.LogContext
            return $true
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to remove performance counter category: $($_.Exception.Message)" -Category $this.LogContext
            return $false
        }
    }

    # Dispose of performance counters
    [void] Dispose() {
        try {
            foreach ($counter in $this.Counters.Values) {
                if ($counter) {
                    $counter.Dispose()
                }
            }
            $this.Counters.Clear()
            $this.IsInitialized = $false

            Write-FileCopierLog -Level "Information" -Message "Performance counters disposed" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Warning" -Message "Error disposing performance counters: $($_.Exception.Message)" -Category $this.LogContext
        }
    }
}

# Helper functions for performance counter management

function New-FileCopierPerformanceCounters {
    <#
    .SYNOPSIS
        Creates a new FileCopier performance counter manager

    .PARAMETER Config
        Configuration hashtable containing performance counter settings

    .EXAMPLE
        $perfCounters = New-FileCopierPerformanceCounters -Config $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    return [PerformanceCounterManager]::new($Config)
}

function Install-FileCopierPerformanceCounters {
    <#
    .SYNOPSIS
        Installs FileCopier performance counter category

    .PARAMETER Config
        Configuration hashtable containing performance counter settings

    .EXAMPLE
        Install-FileCopierPerformanceCounters -Config $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    try {
        $perfManager = [PerformanceCounterManager]::new($Config)
        return $perfManager.InitializeCounters()
    }
    catch {
        Write-Error "Failed to install performance counters: $($_.Exception.Message)"
        return $false
    }
}

function Uninstall-FileCopierPerformanceCounters {
    <#
    .SYNOPSIS
        Uninstalls FileCopier performance counter category

    .EXAMPLE
        Uninstall-FileCopierPerformanceCounters
    #>
    [CmdletBinding()]
    param()

    try {
        $perfManager = [PerformanceCounterManager]::new(@{})
        return $perfManager.RemoveCounterCategory()
    }
    catch {
        Write-Error "Failed to uninstall performance counters: $($_.Exception.Message)"
        return $false
    }
}

function Test-FileCopierPerformanceCounters {
    <#
    .SYNOPSIS
        Tests if FileCopier performance counters are installed and accessible

    .EXAMPLE
        $isInstalled = Test-FileCopierPerformanceCounters
    #>
    [CmdletBinding()]
    param()

    try {
        return [PerformanceCounterCategory]::Exists($script:CategoryName)
    }
    catch {
        Write-Error "Failed to test performance counters: $($_.Exception.Message)"
        return $false
    }
}