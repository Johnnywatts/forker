# Processing Queue Module
# Implements thread-safe processing queue for coordinating multi-target copy operations
# Part of Phase 3B: Processing Queue Implementation

using namespace System.Collections.Concurrent
using namespace System.Threading
using namespace System.Threading.Tasks

class ProcessingQueue {
    [string] $LogContext = "ProcessingQueue"
    [hashtable] $Config
    [ConcurrentQueue[hashtable]] $Queue
    [ConcurrentDictionary[string, hashtable]] $ActiveItems
    [ConcurrentDictionary[string, hashtable]] $CompletedItems
    [System.Threading.Timer] $ProcessingTimer
    [bool] $IsRunning = $false
    [int] $MaxConcurrentOperations
    [hashtable] $PerformanceCounters
    [System.Threading.SemaphoreSlim] $ConcurrencyControl

    ProcessingQueue([hashtable] $configuration) {
        $this.Config = $configuration
        $this.Queue = [ConcurrentQueue[hashtable]]::new()
        $this.ActiveItems = [ConcurrentDictionary[string, hashtable]]::new()
        $this.CompletedItems = [ConcurrentDictionary[string, hashtable]]::new()
        $this.MaxConcurrentOperations = $this.Config['Processing']['MaxConcurrentOperations']
        $this.ConcurrencyControl = [System.Threading.SemaphoreSlim]::new($this.MaxConcurrentOperations, $this.MaxConcurrentOperations)

        $this.PerformanceCounters = @{
            ItemsQueued = 0
            ItemsProcessing = 0
            ItemsCompleted = 0
            ItemsFailed = 0
            RetryAttempts = 0
            TotalBytesProcessed = 0
            AverageProcessingTimeMs = 0
            ConcurrentOperations = 0
        }

        Write-FileCopierLog -Level "Information" -Message "ProcessingQueue module initialized" -Category $this.LogContext
    }

    # Start the processing queue
    [void] Start() {
        if ($this.IsRunning) {
            Write-FileCopierLog -Level "Warning" -Message "ProcessingQueue already running" -Category $this.LogContext
            return
        }

        try {
            Write-FileCopierLog -Level "Information" -Message "Starting processing queue" -Category $this.LogContext

            $this.IsRunning = $true

            # Start processing timer (checks for work every few seconds)
            $processingInterval = $this.Config['Processing']['ProcessingInterval'] * 1000  # Convert to milliseconds
            $this.ProcessingTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{ $this.ProcessPendingItems() },
                $null,
                $processingInterval,
                $processingInterval
            )

            Write-FileCopierLog -Level "Information" -Message "ProcessingQueue started successfully" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to start ProcessingQueue: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Stop the processing queue
    [void] Stop() {
        if (-not $this.IsRunning) {
            return
        }

        try {
            Write-FileCopierLog -Level "Information" -Message "Stopping processing queue" -Category $this.LogContext

            $this.IsRunning = $false

            if ($this.ProcessingTimer) {
                $this.ProcessingTimer.Dispose()
                $this.ProcessingTimer = $null
            }

            # Wait for active operations to complete with timeout
            $timeout = $this.Config['Processing']['ShutdownTimeoutSeconds']
            $this.WaitForActiveOperations($timeout)

            Write-FileCopierLog -Level "Information" -Message "ProcessingQueue stopped" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error stopping ProcessingQueue: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Add item to processing queue
    [void] EnqueueItem([hashtable] $detectionItem) {
        try {
            # Convert detection item to processing item
            $processingItem = $this.CreateProcessingItem($detectionItem)

            $this.Queue.Enqueue($processingItem)
            $this.PerformanceCounters.ItemsQueued++

            Write-FileCopierLog -Level "Information" -Message "Item queued for processing: $($processingItem.FilePath)" -Category $this.LogContext -Properties @{
                FileSize = $processingItem.SourceInfo.FileSize
                QueueDepth = $this.Queue.Count
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error enqueueing item: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Create processing item from detection item
    [hashtable] CreateProcessingItem([hashtable] $detectionItem) {
        $operationId = [System.Guid]::NewGuid().ToString()
        $destinations = @{}

        # Create destination entries based on configuration
        foreach ($destName in $this.Config['Processing']['Destinations'].Keys) {
            $destinations[$destName] = @{
                TargetPath = $null  # Will be calculated during processing
                Status = "Pending"  # Pending, InProgress, Completed, Failed
                Progress = 0
                LastError = $null
                RetryCount = 0
                StartTime = $null
                CompletionTime = $null
                BytesCopied = 0
            }
        }

        return @{
            OperationId = $operationId
            FilePath = $detectionItem.FilePath
            SourceInfo = $detectionItem
            ProcessingState = "Queued"  # Queued, Processing, Completed, Failed
            Destinations = $destinations
            OverallProgress = 0
            CreatedTime = Get-Date
            StartTime = $null
            CompletionTime = $null
            RetryCount = 0
            ErrorHistory = @()
            LastActivity = Get-Date
        }
    }

    # Process pending items (called by timer)
    [void] ProcessPendingItems() {
        if (-not $this.IsRunning) {
            return
        }

        try {
            # Process items while we have capacity and queue items
            while ($this.ConcurrencyControl.CurrentCount -gt 0 -and $this.Queue.Count -gt 0) {
                $item = $null
                if ($this.Queue.TryDequeue([ref]$item)) {
                    # Start processing item asynchronously
                    $this.StartProcessingItem($item)
                }
            }

            # Check for stalled operations and retry failed items
            $this.CheckActiveOperations()
            $this.RetryFailedItems()
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error in ProcessPendingItems: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Start processing an item asynchronously
    [void] StartProcessingItem([hashtable] $item) {
        try {
            # Acquire concurrency control
            $this.ConcurrencyControl.Wait()

            # Move item to active processing
            $item.ProcessingState = "Processing"
            $item.StartTime = Get-Date
            $item.LastActivity = Get-Date
            $this.ActiveItems.TryAdd($item.OperationId, $item) | Out-Null
            $this.PerformanceCounters.ItemsProcessing++

            Write-FileCopierLog -Level "Information" -Message "Starting processing: $($item.FilePath)" -Category $this.LogContext -Properties @{
                OperationId = $item.OperationId
                FileSize = $item.SourceInfo.FileSize
            }

            # Start processing task
            $task = [Task]::Run({
                try {
                    $this.ProcessItem($item)
                }
                catch {
                    $this.HandleProcessingError($item, $_.Exception)
                }
                finally {
                    $this.ConcurrencyControl.Release()
                }
            })

            # Don't wait for task completion - it runs asynchronously
        }
        catch {
            $this.ConcurrencyControl.Release()
            Write-FileCopierLog -Level "Error" -Message "Error starting item processing: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Process a single item (copy to all destinations)
    [void] ProcessItem([hashtable] $item) {
        try {
            Write-FileCopierLog -Level "Information" -Message "Processing item: $($item.FilePath)" -Category $this.LogContext -Properties @{
                OperationId = $item.OperationId
            }

            # Calculate destination paths
            foreach ($destName in $item.Destinations.Keys) {
                $destConfig = $this.Config['Processing']['Destinations'][$destName]
                $fileName = [System.IO.Path]::GetFileName($item.FilePath)
                $item.Destinations[$destName].TargetPath = Join-Path $destConfig.Directory $fileName
            }

            # Prepare destination arrays for multi-target copy
            $destinationPaths = @()
            foreach ($destName in $item.Destinations.Keys) {
                $destinationPaths += $item.Destinations[$destName].TargetPath
                $item.Destinations[$destName].Status = "InProgress"
                $item.Destinations[$destName].StartTime = Get-Date
            }

            # Perform multi-destination copy using CopyEngine
            $copyResult = Copy-FileToMultipleDestinations -SourcePath $item.FilePath -DestinationPaths $destinationPaths -ProgressCallback {
                param($BytesCopied, $TotalBytes, $PercentComplete, $OperationId)
                $this.UpdateProgress($item, $BytesCopied, $TotalBytes, $PercentComplete)
            } -OperationId $item.OperationId

            # Process copy results
            $this.ProcessCopyResults($item, $copyResult, $destinationPaths)

        }
        catch {
            $this.HandleProcessingError($item, $_.Exception)
        }
        finally {
            # Move item from active to completed
            $this.CompleteItemProcessing($item)
        }
    }

    # Process copy results and update destination statuses
    [void] ProcessCopyResults([hashtable] $item, [hashtable] $copyResult, [string[]] $destinationPaths) {
        try {
            $completionTime = Get-Date
            $allSuccessful = $copyResult.Success

            # Update individual destination statuses
            $destIndex = 0
            foreach ($destName in $item.Destinations.Keys) {
                $destInfo = $item.Destinations[$destName]
                $destInfo.CompletionTime = $completionTime

                if ($allSuccessful) {
                    $destInfo.Status = "Completed"
                    $destInfo.Progress = 100
                    $destInfo.BytesCopied = $item.SourceInfo.FileSize
                } else {
                    # Check if this specific destination failed
                    $destInfo.Status = "Failed"
                    $destInfo.LastError = $copyResult.Error ?? "Copy operation failed"
                }
                $destIndex++
            }

            # Update overall item status
            if ($allSuccessful) {
                $item.ProcessingState = "Completed"
                $item.OverallProgress = 100
                $this.PerformanceCounters.ItemsCompleted++
                $this.PerformanceCounters.TotalBytesProcessed += $item.SourceInfo.FileSize

                Write-FileCopierLog -Level "Information" -Message "Item processing completed successfully: $($item.FilePath)" -Category $this.LogContext -Properties @{
                    OperationId = $item.OperationId
                    ProcessingTime = ((Get-Date) - $item.StartTime).TotalSeconds
                    FileSize = $item.SourceInfo.FileSize
                }
            } else {
                $item.ProcessingState = "Failed"
                $item.ErrorHistory += @{
                    Timestamp = Get-Date
                    Error = $copyResult.Error
                    RetryCount = $item.RetryCount
                }
                $this.PerformanceCounters.ItemsFailed++

                Write-FileCopierLog -Level "Error" -Message "Item processing failed: $($item.FilePath)" -Category $this.LogContext -Properties @{
                    OperationId = $item.OperationId
                    Error = $copyResult.Error
                    RetryCount = $item.RetryCount
                }
            }

            $item.CompletionTime = $completionTime
            $item.LastActivity = $completionTime
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error processing copy results: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Update progress for an item
    [void] UpdateProgress([hashtable] $item, [long] $bytesCopied, [long] $totalBytes, [double] $percentComplete) {
        try {
            $item.OverallProgress = $percentComplete
            $item.LastActivity = Get-Date

            # Update progress for all in-progress destinations
            foreach ($destName in $item.Destinations.Keys) {
                $destInfo = $item.Destinations[$destName]
                if ($destInfo.Status -eq "InProgress") {
                    $destInfo.Progress = $percentComplete
                    $destInfo.BytesCopied = $bytesCopied
                }
            }

            # Log progress periodically
            if ($percentComplete % 10 -eq 0) {  # Every 10%
                Write-FileCopierLog -Level "Debug" -Message "Copy progress: $($item.FilePath) - $($percentComplete)%" -Category $this.LogContext -Properties @{
                    OperationId = $item.OperationId
                    BytesCopied = $bytesCopied
                    TotalBytes = $totalBytes
                }
            }
        }
        catch {
            Write-FileCopierLog -Level "Warning" -Message "Error updating progress: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Handle processing errors
    [void] HandleProcessingError([hashtable] $item, [System.Exception] $exception) {
        try {
            $item.ProcessingState = "Failed"
            $item.ErrorHistory += @{
                Timestamp = Get-Date
                Error = $exception.Message
                RetryCount = $item.RetryCount
            }
            $item.LastActivity = Get-Date

            # Mark all destinations as failed
            foreach ($destName in $item.Destinations.Keys) {
                $destInfo = $item.Destinations[$destName]
                if ($destInfo.Status -eq "InProgress") {
                    $destInfo.Status = "Failed"
                    $destInfo.LastError = $exception.Message
                    $destInfo.CompletionTime = Get-Date
                }
            }

            $this.PerformanceCounters.ItemsFailed++

            Write-FileCopierLog -Level "Error" -Message "Processing error for item: $($item.FilePath)" -Category $this.LogContext -Properties @{
                OperationId = $item.OperationId
                Error = $exception.Message
                RetryCount = $item.RetryCount
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error in HandleProcessingError: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Complete item processing (move from active to completed)
    [void] CompleteItemProcessing([hashtable] $item) {
        try {
            # Remove from active items
            $this.ActiveItems.TryRemove($item.OperationId, [ref]$null) | Out-Null
            $this.PerformanceCounters.ItemsProcessing--

            # Add to completed items (with retention limit)
            $this.CompletedItems.TryAdd($item.OperationId, $item) | Out-Null

            # Clean up old completed items
            $this.CleanupCompletedItems()

            Write-FileCopierLog -Level "Debug" -Message "Item processing completed: $($item.FilePath)" -Category $this.LogContext -Properties @{
                OperationId = $item.OperationId
                FinalState = $item.ProcessingState
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error completing item processing: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Check active operations for stalls and timeouts
    [void] CheckActiveOperations() {
        try {
            $timeout = $this.Config['Processing']['OperationTimeoutMinutes']
            $cutoffTime = (Get-Date).AddMinutes(-$timeout)
            $stalledItems = @()

            foreach ($operationId in $this.ActiveItems.Keys) {
                $item = $this.ActiveItems[$operationId]
                if ($item.LastActivity -lt $cutoffTime) {
                    $stalledItems += $item
                }
            }

            foreach ($item in $stalledItems) {
                Write-FileCopierLog -Level "Warning" -Message "Operation timeout detected: $($item.FilePath)" -Category $this.LogContext -Properties @{
                    OperationId = $item.OperationId
                    LastActivity = $item.LastActivity
                }

                $this.HandleProcessingError($item, [System.TimeoutException]::new("Operation timed out"))
                $this.CompleteItemProcessing($item)
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error checking active operations: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Retry failed items that are eligible for retry
    [void] RetryFailedItems() {
        try {
            $maxRetries = $this.Config['Processing']['MaxRetries']
            $retryDelay = $this.Config['Processing']['RetryDelayMinutes']
            $retryTime = (Get-Date).AddMinutes(-$retryDelay)

            $itemsToRetry = @()

            foreach ($operationId in $this.CompletedItems.Keys) {
                $item = $this.CompletedItems[$operationId]

                if ($item.ProcessingState -eq "Failed" -and
                    $item.RetryCount -lt $maxRetries -and
                    $item.LastActivity -lt $retryTime) {

                    $itemsToRetry += $item
                }
            }

            foreach ($item in $itemsToRetry) {
                $this.RetryItem($item)
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error retrying failed items: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Retry a failed item
    [void] RetryItem([hashtable] $item) {
        try {
            Write-FileCopierLog -Level "Information" -Message "Retrying failed item: $($item.FilePath)" -Category $this.LogContext -Properties @{
                OperationId = $item.OperationId
                RetryCount = $item.RetryCount + 1
            }

            # Reset item for retry
            $item.RetryCount++
            $item.ProcessingState = "Queued"
            $item.StartTime = $null
            $item.CompletionTime = $null
            $item.OverallProgress = 0
            $item.LastActivity = Get-Date

            # Reset destination statuses
            foreach ($destName in $item.Destinations.Keys) {
                $destInfo = $item.Destinations[$destName]
                $destInfo.Status = "Pending"
                $destInfo.Progress = 0
                $destInfo.LastError = $null
                $destInfo.StartTime = $null
                $destInfo.CompletionTime = $null
                $destInfo.BytesCopied = 0
            }

            # Remove from completed and re-queue
            $this.CompletedItems.TryRemove($item.OperationId, [ref]$null) | Out-Null
            $this.Queue.Enqueue($item)
            $this.PerformanceCounters.RetryAttempts++
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error retrying item: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Clean up old completed items
    [void] CleanupCompletedItems() {
        try {
            $maxCompletedItems = $this.Config['Processing']['MaxCompletedItems']
            $retentionHours = $this.Config['Processing']['CompletedItemRetentionHours']
            $cutoffTime = (Get-Date).AddHours(-$retentionHours)

            # Remove old items
            $itemsToRemove = @()
            foreach ($operationId in $this.CompletedItems.Keys) {
                $item = $this.CompletedItems[$operationId]
                if ($item.CompletionTime -and $item.CompletionTime -lt $cutoffTime) {
                    $itemsToRemove += $operationId
                }
            }

            foreach ($operationId in $itemsToRemove) {
                $this.CompletedItems.TryRemove($operationId, [ref]$null) | Out-Null
            }

            # If still too many, remove oldest
            while ($this.CompletedItems.Count -gt $maxCompletedItems) {
                $oldestItem = $null
                $oldestTime = [DateTime]::MaxValue
                $oldestId = $null

                foreach ($operationId in $this.CompletedItems.Keys) {
                    $item = $this.CompletedItems[$operationId]
                    if ($item.CompletionTime -and $item.CompletionTime -lt $oldestTime) {
                        $oldestTime = $item.CompletionTime
                        $oldestId = $operationId
                    }
                }

                if ($oldestId) {
                    $this.CompletedItems.TryRemove($oldestId, [ref]$null) | Out-Null
                }
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error cleaning up completed items: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Wait for active operations to complete
    [void] WaitForActiveOperations([int] $timeoutSeconds) {
        try {
            $timeout = (Get-Date).AddSeconds($timeoutSeconds)

            while ($this.ActiveItems.Count -gt 0 -and (Get-Date) -lt $timeout) {
                Write-FileCopierLog -Level "Information" -Message "Waiting for $($this.ActiveItems.Count) active operations to complete" -Category $this.LogContext
                Start-Sleep -Seconds 2
            }

            if ($this.ActiveItems.Count -gt 0) {
                Write-FileCopierLog -Level "Warning" -Message "Timeout waiting for active operations. $($this.ActiveItems.Count) operations still active." -Category $this.LogContext
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error waiting for active operations: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Get queue status
    [hashtable] GetQueueStatus() {
        return @{
            QueueCount = $this.Queue.Count
            ActiveCount = $this.ActiveItems.Count
            CompletedCount = $this.CompletedItems.Count
            IsRunning = $this.IsRunning
            ConcurrentCapacity = $this.MaxConcurrentOperations
            AvailableCapacity = $this.ConcurrencyControl.CurrentCount
            PerformanceCounters = $this.PerformanceCounters
        }
    }

    # Get health status
    [hashtable] GetHealthStatus() {
        $status = "Healthy"
        $issues = @()

        if (-not $this.IsRunning) {
            $status = "Stopped"
            $issues += "ProcessingQueue not running"
        }

        if ($this.Queue.Count -gt $this.Config['Processing']['HighQueueThreshold']) {
            $status = "Warning"
            $issues += "High queue depth: $($this.Queue.Count)"
        }

        if ($this.PerformanceCounters.ItemsFailed -gt $this.PerformanceCounters.ItemsCompleted * 0.1) {
            $status = "Warning"
            $issues += "High failure rate: $($this.PerformanceCounters.ItemsFailed) failures vs $($this.PerformanceCounters.ItemsCompleted) successes"
        }

        return @{
            Status = $status
            Issues = $issues
            QueueStatus = $this.GetQueueStatus()
            PerformanceCounters = $this.PerformanceCounters
        }
    }
}

# Static utility functions for processing queue operations

function Start-ProcessingQueue {
    <#
    .SYNOPSIS
        Starts a processing queue for file copy operations.

    .DESCRIPTION
        Creates and starts a ProcessingQueue instance for coordinating multi-target copy operations.

    .PARAMETER Configuration
        Configuration hashtable for processing settings.

    .EXAMPLE
        $config = Get-DefaultProcessingConfig
        $processor = Start-ProcessingQueue -Configuration $config
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Configuration = (Get-DefaultProcessingConfig)
    )

    try {
        $processor = [ProcessingQueue]::new($Configuration)
        $processor.Start()
        return $processor
    }
    catch {
        Write-FileCopierLog -Level "Error" -Message "Failed to start processing queue: $($_.Exception.Message)" -Category "Start-ProcessingQueue"
        throw
    }
}

function Stop-ProcessingQueue {
    <#
    .SYNOPSIS
        Stops a processing queue.

    .DESCRIPTION
        Stops a ProcessingQueue instance and waits for operations to complete.

    .PARAMETER ProcessingQueue
        ProcessingQueue instance to stop.

    .EXAMPLE
        Stop-ProcessingQueue -ProcessingQueue $processor
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ProcessingQueue]$ProcessingQueue
    )

    try {
        $ProcessingQueue.Stop()
        Write-FileCopierLog -Level "Information" -Message "Processing queue stopped successfully" -Category "Stop-ProcessingQueue"
    }
    catch {
        Write-FileCopierLog -Level "Error" -Message "Error stopping processing queue: $($_.Exception.Message)" -Category "Stop-ProcessingQueue"
        throw
    }
}

function Get-DefaultProcessingConfig {
    return @{
        Processing = @{
            MaxConcurrentOperations = 3
            ProcessingInterval = 2  # seconds
            OperationTimeoutMinutes = 60
            MaxRetries = 3
            RetryDelayMinutes = 5
            ShutdownTimeoutSeconds = 30
            MaxCompletedItems = 1000
            CompletedItemRetentionHours = 24
            HighQueueThreshold = 100
            Destinations = @{
                TargetA = @{ Directory = "C:\TargetA" }
                TargetB = @{ Directory = "C:\TargetB" }
            }
        }
    }
}

# Functions are exported by the root module (FileCopier.psm1)
# No individual exports needed