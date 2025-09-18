# File Watcher Module
# Implements FileSystemWatcher for SVS file monitoring with completion detection
# Part of Phase 3A: FileSystemWatcher Implementation

using namespace System.IO
using namespace System.Collections.Concurrent
using namespace System.Threading

class FileWatcher {
    [string] $LogContext = "FileWatcher"
    [hashtable] $Config
    [FileSystemWatcher] $Watcher
    [ConcurrentQueue[hashtable]] $FileQueue
    [ConcurrentDictionary[string, hashtable]] $PendingFiles
    [System.Threading.Timer] $StabilityTimer
    [bool] $IsRunning = $false
    [hashtable] $PerformanceCounters

    FileWatcher([hashtable] $configuration) {
        $this.Config = $configuration
        $this.FileQueue = [ConcurrentQueue[hashtable]]::new()
        $this.PendingFiles = [ConcurrentDictionary[string, hashtable]]::new()
        $this.PerformanceCounters = @{
            FilesDetected = 0
            FilesQueued = 0
            FilesSkipped = 0
            StabilityChecks = 0
            WatcherErrors = 0
        }

        Write-FileCopierLog -Level "Information" -Message "FileWatcher module initialized" -Category $this.LogContext
    }

    # Start monitoring specified directory
    [void] StartWatching([string] $directoryPath) {
        if ($this.IsRunning) {
            Write-FileCopierLog -Level "Warning" -Message "FileWatcher already running" -Category $this.LogContext
            return
        }

        try {
            if (-not (Test-Path $directoryPath)) {
                throw "Directory not found: $directoryPath"
            }

            Write-FileCopierLog -Level "Information" -Message "Starting file system monitoring: $directoryPath" -Category $this.LogContext

            # Configure FileSystemWatcher
            $this.Watcher = [FileSystemWatcher]::new()
            $this.Watcher.Path = $directoryPath
            $this.Watcher.IncludeSubdirectories = $this.Config['Monitoring']['IncludeSubdirectories']
            $this.Watcher.NotifyFilter = [NotifyFilters]::FileName -bor [NotifyFilters]::Size -bor [NotifyFilters]::LastWrite

            # Set file filters from configuration
            foreach ($filter in $this.Config['Monitoring']['FileFilters']) {
                $this.Watcher.Filter = $filter
            }

            # Register event handlers
            $this.RegisterEventHandlers()

            # Start the watcher
            $this.Watcher.EnableRaisingEvents = $true
            $this.IsRunning = $true

            # Start stability check timer (runs every few seconds to check pending files)
            $stabilityInterval = $this.Config['Monitoring']['StabilityCheckInterval'] * 1000  # Convert to milliseconds
            $this.StabilityTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{ $this.CheckFileStability() },
                $null,
                $stabilityInterval,
                $stabilityInterval
            )

            Write-FileCopierLog -Level "Information" -Message "FileSystemWatcher started successfully" -Category $this.LogContext
        }
        catch {
            $this.PerformanceCounters.WatcherErrors++
            Write-FileCopierLog -Level "Error" -Message "Failed to start FileSystemWatcher: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Stop monitoring
    [void] StopWatching() {
        if (-not $this.IsRunning) {
            return
        }

        try {
            Write-FileCopierLog -Level "Information" -Message "Stopping file system monitoring" -Category $this.LogContext

            if ($this.Watcher) {
                $this.Watcher.EnableRaisingEvents = $false
                $this.Watcher.Dispose()
                $this.Watcher = $null
            }

            if ($this.StabilityTimer) {
                $this.StabilityTimer.Dispose()
                $this.StabilityTimer = $null
            }

            $this.IsRunning = $false
            Write-FileCopierLog -Level "Information" -Message "FileSystemWatcher stopped" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error stopping FileSystemWatcher: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Register FileSystemWatcher event handlers
    [void] RegisterEventHandlers() {
        # File created event
        Register-ObjectEvent -InputObject $this.Watcher -EventName "Created" -Action {
            $watcher = $Event.SourceEventArgs.SourceIdentifier
            $filePath = $Event.SourceEventArgs.FullPath
            $this.OnFileCreated($filePath)
        } | Out-Null

        # File changed event (for detecting completion of large file writes)
        Register-ObjectEvent -InputObject $this.Watcher -EventName "Changed" -Action {
            $filePath = $Event.SourceEventArgs.FullPath
            $this.OnFileChanged($filePath)
        } | Out-Null

        # File renamed event
        Register-ObjectEvent -InputObject $this.Watcher -EventName "Renamed" -Action {
            $filePath = $Event.SourceEventArgs.FullPath
            $oldPath = $Event.SourceEventArgs.OldFullPath
            $this.OnFileRenamed($oldPath, $filePath)
        } | Out-Null

        # Error event
        Register-ObjectEvent -InputObject $this.Watcher -EventName "Error" -Action {
            $error = $Event.SourceEventArgs.GetException()
            $this.OnWatcherError($error)
        } | Out-Null
    }

    # Handle file created event
    [void] OnFileCreated([string] $filePath) {
        try {
            Write-FileCopierLog -Level "Debug" -Message "File created detected: $filePath" -Category $this.LogContext
            $this.PerformanceCounters.FilesDetected++

            # Check if file matches our criteria
            if (-not $this.ShouldProcessFile($filePath)) {
                $this.PerformanceCounters.FilesSkipped++
                Write-FileCopierLog -Level "Debug" -Message "File skipped (filters): $filePath" -Category $this.LogContext
                return
            }

            # Add to pending files for stability monitoring
            $fileInfo = @{
                FilePath = $filePath
                DetectedTime = Get-Date
                LastSize = -1
                LastModified = [DateTime]::MinValue
                StabilityChecks = 0
                IsComplete = $false
            }

            $this.PendingFiles.TryAdd($filePath, $fileInfo) | Out-Null
            Write-FileCopierLog -Level "Information" -Message "File added to pending queue: $filePath" -Category $this.LogContext
        }
        catch {
            $this.PerformanceCounters.WatcherErrors++
            Write-FileCopierLog -Level "Error" -Message "Error processing file created event: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Handle file changed event (used for stability detection)
    [void] OnFileChanged([string] $filePath) {
        try {
            # Only track changes for files we're monitoring
            if ($this.PendingFiles.ContainsKey($filePath)) {
                $fileInfo = $this.PendingFiles[$filePath]
                $fileInfo.LastModified = Get-Date
                Write-FileCopierLog -Level "Debug" -Message "File change detected: $filePath" -Category $this.LogContext
            }
        }
        catch {
            Write-FileCopierLog -Level "Warning" -Message "Error processing file changed event: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Handle file renamed event
    [void] OnFileRenamed([string] $oldPath, [string] $newPath) {
        try {
            Write-FileCopierLog -Level "Information" -Message "File renamed: $oldPath -> $newPath" -Category $this.LogContext

            # If we were tracking the old file, update to new path
            if ($this.PendingFiles.ContainsKey($oldPath)) {
                $fileInfo = $this.PendingFiles[$oldPath]
                $this.PendingFiles.TryRemove($oldPath, [ref]$null) | Out-Null

                # Check if new path should be processed
                if ($this.ShouldProcessFile($newPath)) {
                    $fileInfo.FilePath = $newPath
                    $this.PendingFiles.TryAdd($newPath, $fileInfo) | Out-Null
                    Write-FileCopierLog -Level "Information" -Message "Renamed file re-queued: $newPath" -Category $this.LogContext
                }
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error processing file renamed event: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Handle watcher errors
    [void] OnWatcherError([System.Exception] $error) {
        $this.PerformanceCounters.WatcherErrors++
        Write-FileCopierLog -Level "Error" -Message "FileSystemWatcher error: $($error.Message)" -Category $this.LogContext

        # Attempt to restart watcher if it's a recoverable error
        if ($this.IsRunning) {
            Write-FileCopierLog -Level "Warning" -Message "Attempting to restart FileSystemWatcher" -Category $this.LogContext
            try {
                $this.StopWatching()
                Start-Sleep -Seconds 5
                $this.StartWatching($this.Watcher.Path)
            }
            catch {
                Write-FileCopierLog -Level "Error" -Message "Failed to restart FileSystemWatcher: $($_.Exception.Message)" -Category $this.LogContext
            }
        }
    }

    # Check if file should be processed based on filters
    [bool] ShouldProcessFile([string] $filePath) {
        try {
            $fileName = [System.IO.Path]::GetFileName($filePath)
            $extension = [System.IO.Path]::GetExtension($filePath).ToLower()

            # Check exclude patterns first
            foreach ($excludeExt in $this.Config['Monitoring']['ExcludeExtensions']) {
                if ($extension -eq $excludeExt.ToLower()) {
                    return $false
                }
            }

            # Check include patterns
            foreach ($filter in $this.Config['Monitoring']['FileFilters']) {
                if ($fileName -like $filter) {
                    return $true
                }
            }

            return $false
        }
        catch {
            Write-FileCopierLog -Level "Warning" -Message "Error checking file filters: $($_.Exception.Message)" -Category $this.LogContext
            return $false
        }
    }

    # Check stability of pending files (called by timer)
    [void] CheckFileStability() {
        try {
            $this.PerformanceCounters.StabilityChecks++
            $completedFiles = @()

            foreach ($filePath in $this.PendingFiles.Keys) {
                $fileInfo = $this.PendingFiles[$filePath]

                if ($this.IsFileStable($fileInfo)) {
                    $completedFiles += $filePath
                }
            }

            # Queue completed files and remove from pending
            foreach ($filePath in $completedFiles) {
                $fileInfo = $this.PendingFiles[$filePath]
                $this.QueueFile($fileInfo)
                $this.PendingFiles.TryRemove($filePath, [ref]$null) | Out-Null
            }

            # Clean up files that have been pending too long
            $this.CleanupStalePendingFiles()
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error in stability check: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Determine if a file is stable (not being written to)
    [bool] IsFileStable([hashtable] $fileInfo) {
        try {
            $filePath = $fileInfo.FilePath

            # Check if file still exists
            if (-not (Test-Path $filePath)) {
                Write-FileCopierLog -Level "Warning" -Message "File disappeared during monitoring: $filePath" -Category $this.LogContext
                return $false
            }

            $currentFileInfo = Get-Item $filePath
            $currentSize = $currentFileInfo.Length
            $currentModified = $currentFileInfo.LastWriteTime

            # First check
            if ($fileInfo.LastSize -eq -1) {
                $fileInfo.LastSize = $currentSize
                $fileInfo.LastModified = $currentModified
                $fileInfo.StabilityChecks = 1
                return $false
            }

            # Check if file size and timestamp are stable
            $sizeStable = ($currentSize -eq $fileInfo.LastSize)
            $timeStable = ($currentModified -eq $fileInfo.LastModified)

            if ($sizeStable -and $timeStable) {
                $fileInfo.StabilityChecks++

                # File is considered stable after minimum age and stability checks
                $ageSeconds = ((Get-Date) - $fileInfo.DetectedTime).TotalSeconds
                $minAge = $this.Config['Monitoring']['MinimumFileAge']
                $maxChecks = $this.Config['Monitoring']['MaxStabilityChecks']

                if ($ageSeconds -ge $minAge -and $fileInfo.StabilityChecks -ge 2) {
                    Write-FileCopierLog -Level "Information" -Message "File stable after $($fileInfo.StabilityChecks) checks: $filePath" -Category $this.LogContext
                    return $true
                }
            } else {
                # File changed, reset stability counter
                $fileInfo.LastSize = $currentSize
                $fileInfo.LastModified = $currentModified
                $fileInfo.StabilityChecks = 1
                Write-FileCopierLog -Level "Debug" -Message "File still changing: $filePath (Size: $currentSize)" -Category $this.LogContext
            }

            return $false
        }
        catch {
            Write-FileCopierLog -Level "Warning" -Message "Error checking file stability: $($_.Exception.Message)" -Category $this.LogContext
            return $false
        }
    }

    # Add stable file to processing queue
    [void] QueueFile([hashtable] $fileInfo) {
        try {
            $filePath = $fileInfo.FilePath
            $currentFileInfo = Get-Item $filePath

            $queueItem = @{
                FilePath = $filePath
                DetectedTime = $fileInfo.DetectedTime
                QueuedTime = Get-Date
                FileSize = $currentFileInfo.Length
                LastModified = $currentFileInfo.LastWriteTime
                StabilityChecks = $fileInfo.StabilityChecks
            }

            $this.FileQueue.Enqueue($queueItem)
            $this.PerformanceCounters.FilesQueued++

            Write-FileCopierLog -Level "Information" -Message "File queued for processing: $filePath (Size: $([math]::Round($queueItem.FileSize / 1MB, 2))MB)" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error queuing file: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Remove files that have been pending for too long
    [void] CleanupStalePendingFiles() {
        try {
            $maxPendingMinutes = 60  # Remove files pending for more than 1 hour
            $cutoffTime = (Get-Date).AddMinutes(-$maxPendingMinutes)
            $staleFiles = @()

            foreach ($filePath in $this.PendingFiles.Keys) {
                $fileInfo = $this.PendingFiles[$filePath]
                if ($fileInfo.DetectedTime -lt $cutoffTime) {
                    $staleFiles += $filePath
                }
            }

            foreach ($filePath in $staleFiles) {
                $this.PendingFiles.TryRemove($filePath, [ref]$null) | Out-Null
                Write-FileCopierLog -Level "Warning" -Message "Removed stale pending file: $filePath" -Category $this.LogContext
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error cleaning up stale files: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Get next file from queue
    [hashtable] GetNextFile() {
        $queueItem = $null
        if ($this.FileQueue.TryDequeue([ref]$queueItem)) {
            Write-FileCopierLog -Level "Debug" -Message "Dequeued file for processing: $($queueItem.FilePath)" -Category $this.LogContext
            return $queueItem
        }
        return $null
    }

    # Get current queue status
    [hashtable] GetQueueStatus() {
        return @{
            QueueCount = $this.FileQueue.Count
            PendingCount = $this.PendingFiles.Count
            IsRunning = $this.IsRunning
            PerformanceCounters = $this.PerformanceCounters
        }
    }

    # Get health check information
    [hashtable] GetHealthStatus() {
        $status = "Healthy"
        $issues = @()

        if (-not $this.IsRunning) {
            $status = "Stopped"
            $issues += "FileWatcher not running"
        }

        if ($this.PerformanceCounters.WatcherErrors -gt 0) {
            $status = "Warning"
            $issues += "Watcher errors detected: $($this.PerformanceCounters.WatcherErrors)"
        }

        if ($this.PendingFiles.Count -gt 100) {
            $status = "Warning"
            $issues += "High pending file count: $($this.PendingFiles.Count)"
        }

        return @{
            Status = $status
            Issues = $issues
            Uptime = if ($this.IsRunning) { (Get-Date) - $this.StartTime } else { [TimeSpan]::Zero }
            PerformanceCounters = $this.PerformanceCounters
            QueueStatus = $this.GetQueueStatus()
        }
    }
}

# Static utility functions for file watching operations

function Start-FileWatching {
    <#
    .SYNOPSIS
        Starts file system monitoring for a directory.

    .DESCRIPTION
        Creates and starts a FileWatcher instance for monitoring SVS files.

    .PARAMETER DirectoryPath
        Directory to monitor for file changes.

    .PARAMETER Configuration
        Configuration hashtable for monitoring settings.

    .EXAMPLE
        $config = Get-DefaultFileWatcherConfig
        $watcher = Start-FileWatching -DirectoryPath "C:\SVS\Source" -Configuration $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DirectoryPath,

        [hashtable]$Configuration = (Get-DefaultFileWatcherConfig)
    )

    try {
        $watcher = [FileWatcher]::new($Configuration)
        $watcher.StartWatching($DirectoryPath)
        return $watcher
    }
    catch {
        Write-FileCopierLog -Level "Error" -Message "Failed to start file watching: $($_.Exception.Message)" -Category "Start-FileWatching"
        throw
    }
}

function Stop-FileWatching {
    <#
    .SYNOPSIS
        Stops file system monitoring.

    .DESCRIPTION
        Stops a FileWatcher instance and cleans up resources.

    .PARAMETER FileWatcher
        FileWatcher instance to stop.

    .EXAMPLE
        Stop-FileWatching -FileWatcher $watcher
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [FileWatcher]$FileWatcher
    )

    try {
        $FileWatcher.StopWatching()
        Write-FileCopierLog -Level "Information" -Message "File watching stopped successfully" -Category "Stop-FileWatching"
    }
    catch {
        Write-FileCopierLog -Level "Error" -Message "Error stopping file watcher: $($_.Exception.Message)" -Category "Stop-FileWatching"
        throw
    }
}

function Get-DefaultFileWatcherConfig {
    return @{
        Monitoring = @{
            IncludeSubdirectories = $false
            FileFilters = @("*.svs", "*.tiff", "*.tif")
            ExcludeExtensions = @(".tmp", ".temp", ".part", ".lock")
            MinimumFileAge = 5
            StabilityCheckInterval = 2
            MaxStabilityChecks = 10
        }
    }
}

# Functions are exported by the root module (FileCopier.psm1)
# No individual exports needed