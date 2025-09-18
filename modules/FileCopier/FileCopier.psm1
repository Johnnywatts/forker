# FileCopier.psm1 - Root module for File Copier Service
# Main service orchestration and lifecycle management
# Part of Phase 4A: Main Service Logic Integration

using namespace System.Threading
using namespace System.Threading.Tasks

# Get the module directory
$ModuleRoot = $PSScriptRoot

# Dot-source the component scripts in the correct order
. (Join-Path $ModuleRoot "Configuration.ps1")
. (Join-Path $ModuleRoot "Logging.ps1")
. (Join-Path $ModuleRoot "Utils.ps1")
. (Join-Path $ModuleRoot "CopyEngine.ps1")
. (Join-Path $ModuleRoot "Verification.ps1")
. (Join-Path $ModuleRoot "FileWatcher.ps1")
. (Join-Path $ModuleRoot "ProcessingQueue.ps1")

class FileCopierService {
    [string] $LogContext = "FileCopierService"
    [hashtable] $Config
    [FileWatcher] $FileWatcher
    [ProcessingQueue] $ProcessingQueue
    [System.Threading.Timer] $IntegrationTimer
    [System.Threading.Timer] $HealthCheckTimer
    [System.Threading.Timer] $ConfigReloadTimer
    [bool] $IsRunning = $false
    [bool] $IsShuttingDown = $false
    [DateTime] $StartTime
    [hashtable] $ServiceCounters
    [string] $SourceDirectory
    [string] $ConfigFilePath

    FileCopierService([string] $sourceDirectory, [string] $configFilePath = $null) {
        $this.SourceDirectory = $sourceDirectory
        $this.ConfigFilePath = $configFilePath
        $this.ServiceCounters = @{
            TotalFilesProcessed = 0
            TotalFilesSucceeded = 0
            TotalFilesFailed = 0
            TotalBytesProcessed = 0
            ServiceRestarts = 0
            ConfigReloads = 0
            ErrorsRecovered = 0
            UptimeHours = 0
        }

        # Initialize configuration
        $this.LoadConfiguration()

        Write-FileCopierLog -Level "Information" -Message "FileCopierService initialized for directory: $sourceDirectory" -Category $this.LogContext
    }

    # Load or reload configuration
    [void] LoadConfiguration() {
        try {
            if ($this.ConfigFilePath) {
                $this.Config = Initialize-FileCopierConfig -ConfigPath $this.ConfigFilePath
            } else {
                $this.Config = Initialize-FileCopierConfig
            }

            Write-FileCopierLog -Level "Information" -Message "Configuration loaded successfully" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to load configuration: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Start the file copier service
    [void] Start() {
        if ($this.IsRunning) {
            Write-FileCopierLog -Level "Warning" -Message "Service already running" -Category $this.LogContext
            return
        }

        try {
            Write-FileCopierLog -Level "Information" -Message "Starting FileCopier Service" -Category $this.LogContext

            $this.IsRunning = $true
            $this.IsShuttingDown = $false
            $this.StartTime = Get-Date

            # Initialize and start components
            $this.InitializeComponents()
            $this.StartComponents()
            $this.StartServiceTimers()

            Write-FileCopierLog -Level "Information" -Message "FileCopier Service started successfully" -Category $this.LogContext -Properties @{
                SourceDirectory = $this.SourceDirectory
                TargetDirectories = ($this.Config.directories.targetA, $this.Config.directories.targetB | Where-Object { $_ }) -join ", "
                MaxConcurrentOperations = $this.Config.copying.maxConcurrentCopies
            }
        }
        catch {
            $this.IsRunning = $false
            Write-FileCopierLog -Level "Error" -Message "Failed to start service: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Stop the file copier service
    [void] Stop() {
        if (-not $this.IsRunning) {
            Write-FileCopierLog -Level "Warning" -Message "Service not running" -Category $this.LogContext
            return
        }

        try {
            Write-FileCopierLog -Level "Information" -Message "Stopping FileCopier Service" -Category $this.LogContext

            $this.IsShuttingDown = $true

            # Stop service timers
            $this.StopServiceTimers()

            # Stop components gracefully
            $this.StopComponents()

            $this.IsRunning = $false
            $this.IsShuttingDown = $false

            Write-FileCopierLog -Level "Information" -Message "FileCopier Service stopped successfully" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error stopping service: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Restart the service
    [void] Restart() {
        try {
            Write-FileCopierLog -Level "Information" -Message "Restarting FileCopier Service" -Category $this.LogContext

            $this.Stop()
            Start-Sleep -Seconds 2  # Brief pause between stop and start
            $this.Start()

            $this.ServiceCounters.ServiceRestarts++
            Write-FileCopierLog -Level "Information" -Message "Service restarted successfully" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to restart service: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Initialize service components
    [void] InitializeComponents() {
        try {
            Write-FileCopierLog -Level "Information" -Message "Initializing service components" -Category $this.LogContext

            # Create FileWatcher configuration
            $watcherConfig = @{
                Monitoring = $this.Config.monitoring
            }

            # Create ProcessingQueue configuration
            $processingConfig = @{
                Processing = @{
                    MaxConcurrentOperations = $this.Config.copying.maxConcurrentCopies
                    ProcessingInterval = 2
                    OperationTimeoutMinutes = 60
                    MaxRetries = $this.Config.copying.maxRetries
                    RetryDelayMinutes = 5
                    ShutdownTimeoutSeconds = $this.Config.service.shutdownTimeoutSeconds
                    MaxCompletedItems = 1000
                    CompletedItemRetentionHours = 24
                    HighQueueThreshold = $this.Config.service.maxProcessingQueueSize
                    Destinations = @{}
                }
            }

            # Configure destinations
            if ($this.Config.directories.targetA) {
                $processingConfig.Processing.Destinations["TargetA"] = @{ Directory = $this.Config.directories.targetA }
            }
            if ($this.Config.directories.targetB) {
                $processingConfig.Processing.Destinations["TargetB"] = @{ Directory = $this.Config.directories.targetB }
            }

            # Initialize components
            $this.FileWatcher = [FileWatcher]::new($watcherConfig)
            $this.ProcessingQueue = [ProcessingQueue]::new($processingConfig)

            Write-FileCopierLog -Level "Information" -Message "Service components initialized successfully" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to initialize components: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Start service components
    [void] StartComponents() {
        try {
            Write-FileCopierLog -Level "Information" -Message "Starting service components" -Category $this.LogContext

            # Start ProcessingQueue first
            $this.ProcessingQueue.Start()

            # Start FileWatcher
            $this.FileWatcher.StartWatching($this.SourceDirectory)

            Write-FileCopierLog -Level "Information" -Message "Service components started successfully" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to start components: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Stop service components
    [void] StopComponents() {
        try {
            Write-FileCopierLog -Level "Information" -Message "Stopping service components" -Category $this.LogContext

            # Stop FileWatcher first (stop new files from being detected)
            if ($this.FileWatcher) {
                $this.FileWatcher.StopWatching()
            }

            # Stop ProcessingQueue (let active operations complete)
            if ($this.ProcessingQueue) {
                $this.ProcessingQueue.Stop()
            }

            Write-FileCopierLog -Level "Information" -Message "Service components stopped successfully" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error stopping components: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Start service timers
    [void] StartServiceTimers() {
        try {
            # Integration timer - transfers files from FileWatcher to ProcessingQueue
            $integrationInterval = 3000  # 3 seconds
            $this.IntegrationTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{ $this.ProcessIntegration() },
                $null,
                $integrationInterval,
                $integrationInterval
            )

            # Health check timer
            $healthInterval = $this.Config.service.healthCheckIntervalMinutes * 60 * 1000  # Convert to milliseconds
            $this.HealthCheckTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{ $this.PerformHealthCheck() },
                $null,
                $healthInterval,
                $healthInterval
            )

            # Configuration reload timer (if enabled)
            if ($this.Config.service.enableHotConfigReload) {
                $configInterval = 30000  # 30 seconds
                $this.ConfigReloadTimer = [System.Threading.Timer]::new(
                    [System.Threading.TimerCallback]{ $this.CheckConfigurationReload() },
                    $null,
                    $configInterval,
                    $configInterval
                )
            }

            Write-FileCopierLog -Level "Debug" -Message "Service timers started" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to start service timers: $($_.Exception.Message)" -Category $this.LogContext
            throw
        }
    }

    # Stop service timers
    [void] StopServiceTimers() {
        try {
            if ($this.IntegrationTimer) {
                $this.IntegrationTimer.Dispose()
                $this.IntegrationTimer = $null
            }

            if ($this.HealthCheckTimer) {
                $this.HealthCheckTimer.Dispose()
                $this.HealthCheckTimer = $null
            }

            if ($this.ConfigReloadTimer) {
                $this.ConfigReloadTimer.Dispose()
                $this.ConfigReloadTimer = $null
            }

            Write-FileCopierLog -Level "Debug" -Message "Service timers stopped" -Category $this.LogContext
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error stopping service timers: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Process integration between FileWatcher and ProcessingQueue
    [void] ProcessIntegration() {
        if ($this.IsShuttingDown) {
            return
        }

        try {
            # Transfer files from FileWatcher queue to ProcessingQueue
            $filesTransferred = 0
            while ($true) {
                $detectedFile = $this.FileWatcher.GetNextFile()
                if (-not $detectedFile) {
                    break
                }

                # Transfer to processing queue
                $this.ProcessingQueue.EnqueueItem($detectedFile)
                $filesTransferred++

                Write-FileCopierLog -Level "Information" -Message "File transferred to processing queue: $($detectedFile.FilePath)" -Category $this.LogContext -Properties @{
                    FileSize = $detectedFile.FileSize
                    DetectionTime = $detectedFile.DetectedTime
                    QueueDepth = $this.ProcessingQueue.GetQueueStatus().QueueCount
                }
            }

            if ($filesTransferred -gt 0) {
                Write-FileCopierLog -Level "Debug" -Message "Integration cycle completed: $filesTransferred files transferred" -Category $this.LogContext
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error in integration processing: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Perform health check
    [void] PerformHealthCheck() {
        if ($this.IsShuttingDown) {
            return
        }

        try {
            Write-FileCopierLog -Level "Debug" -Message "Performing health check" -Category $this.LogContext

            $overallHealth = "Healthy"
            $issues = @()

            # Check FileWatcher health
            $watcherHealth = $this.FileWatcher.GetHealthStatus()
            if ($watcherHealth.Status -ne "Healthy") {
                $overallHealth = "Warning"
                $issues += "FileWatcher: $($watcherHealth.Status) - $($watcherHealth.Issues -join ', ')"
            }

            # Check ProcessingQueue health
            $queueHealth = $this.ProcessingQueue.GetHealthStatus()
            if ($queueHealth.Status -ne "Healthy") {
                $overallHealth = "Warning"
                $issues += "ProcessingQueue: $($queueHealth.Status) - $($queueHealth.Issues -join ', ')"
            }

            # Update service counters
            $this.UpdateServiceCounters()

            # Log health status
            if ($overallHealth -eq "Healthy") {
                Write-FileCopierLog -Level "Information" -Message "Health check completed - Service healthy" -Category $this.LogContext -Properties @{
                    UptimeHours = $this.ServiceCounters.UptimeHours
                    FilesProcessed = $this.ServiceCounters.TotalFilesProcessed
                    WatcherQueue = $watcherHealth.QueueStatus.QueueCount
                    ProcessingQueue = $queueHealth.QueueStatus.QueueCount
                }
            } else {
                Write-FileCopierLog -Level "Warning" -Message "Health check completed - Issues detected" -Category $this.LogContext -Properties @{
                    OverallHealth = $overallHealth
                    Issues = $issues -join "; "
                }
            }

            # Attempt automatic recovery for certain issues
            $this.AttemptAutomaticRecovery($watcherHealth, $queueHealth)
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error during health check: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Update service performance counters
    [void] UpdateServiceCounters() {
        try {
            # Calculate uptime
            if ($this.StartTime) {
                $this.ServiceCounters.UptimeHours = [Math]::Round(((Get-Date) - $this.StartTime).TotalHours, 2)
            }

            # Get component counters
            $watcherCounters = $this.FileWatcher.PerformanceCounters
            $queueCounters = $this.ProcessingQueue.PerformanceCounters

            # Update totals
            $this.ServiceCounters.TotalFilesProcessed = $queueCounters.ItemsQueued
            $this.ServiceCounters.TotalFilesSucceeded = $queueCounters.ItemsCompleted
            $this.ServiceCounters.TotalFilesFailed = $queueCounters.ItemsFailed
            $this.ServiceCounters.TotalBytesProcessed = $queueCounters.TotalBytesProcessed
        }
        catch {
            Write-FileCopierLog -Level "Warning" -Message "Error updating service counters: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Attempt automatic recovery for known issues
    [void] AttemptAutomaticRecovery([hashtable] $watcherHealth, [hashtable] $queueHealth) {
        try {
            $recoveryAttempted = $false

            # FileWatcher recovery
            if ($watcherHealth.Status -eq "Stopped") {
                Write-FileCopierLog -Level "Warning" -Message "Attempting FileWatcher recovery" -Category $this.LogContext
                try {
                    $this.FileWatcher.StartWatching($this.SourceDirectory)
                    $recoveryAttempted = $true
                    $this.ServiceCounters.ErrorsRecovered++
                    Write-FileCopierLog -Level "Information" -Message "FileWatcher recovery successful" -Category $this.LogContext
                }
                catch {
                    Write-FileCopierLog -Level "Error" -Message "FileWatcher recovery failed: $($_.Exception.Message)" -Category $this.LogContext
                }
            }

            # ProcessingQueue recovery
            if ($queueHealth.Status -eq "Stopped") {
                Write-FileCopierLog -Level "Warning" -Message "Attempting ProcessingQueue recovery" -Category $this.LogContext
                try {
                    $this.ProcessingQueue.Start()
                    $recoveryAttempted = $true
                    $this.ServiceCounters.ErrorsRecovered++
                    Write-FileCopierLog -Level "Information" -Message "ProcessingQueue recovery successful" -Category $this.LogContext
                }
                catch {
                    Write-FileCopierLog -Level "Error" -Message "ProcessingQueue recovery failed: $($_.Exception.Message)" -Category $this.LogContext
                }
            }

            if ($recoveryAttempted) {
                Write-FileCopierLog -Level "Information" -Message "Automatic recovery completed" -Category $this.LogContext
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error during automatic recovery: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Check for configuration reload
    [void] CheckConfigurationReload() {
        if ($this.IsShuttingDown -or -not $this.ConfigFilePath) {
            return
        }

        try {
            # Check if config file has been modified
            $configFile = Get-Item $this.ConfigFilePath -ErrorAction SilentlyContinue
            if (-not $configFile) {
                return
            }

            # Simple check - reload if file is newer than service start
            if ($configFile.LastWriteTime -gt $this.StartTime) {
                Write-FileCopierLog -Level "Information" -Message "Configuration file change detected, reloading" -Category $this.LogContext

                $this.ReloadConfiguration()
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Error checking configuration reload: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Reload configuration without stopping service
    [void] ReloadConfiguration() {
        try {
            Write-FileCopierLog -Level "Information" -Message "Reloading configuration" -Category $this.LogContext

            # Load new configuration
            $oldConfig = $this.Config
            $this.LoadConfiguration()

            # Check if critical settings changed that require restart
            $requiresRestart = $this.CheckIfRestartRequired($oldConfig, $this.Config)

            if ($requiresRestart) {
                Write-FileCopierLog -Level "Warning" -Message "Configuration changes require service restart" -Category $this.LogContext
                $this.Restart()
            } else {
                Write-FileCopierLog -Level "Information" -Message "Configuration reloaded successfully without restart" -Category $this.LogContext
                $this.ServiceCounters.ConfigReloads++
            }
        }
        catch {
            Write-FileCopierLog -Level "Error" -Message "Failed to reload configuration: $($_.Exception.Message)" -Category $this.LogContext
        }
    }

    # Check if configuration changes require restart
    [bool] CheckIfRestartRequired([hashtable] $oldConfig, [hashtable] $newConfig) {
        try {
            # Check critical settings that require restart
            $criticalPaths = @(
                'directories.source',
                'directories.targetA',
                'directories.targetB',
                'copying.maxConcurrentCopies',
                'monitoring.includeSubdirectories'
            )

            foreach ($path in $criticalPaths) {
                $pathParts = $path.Split('.')
                $oldValue = $oldConfig
                $newValue = $newConfig

                foreach ($part in $pathParts) {
                    $oldValue = $oldValue[$part]
                    $newValue = $newValue[$part]
                }

                if ($oldValue -ne $newValue) {
                    Write-FileCopierLog -Level "Information" -Message "Critical setting changed: $path" -Category $this.LogContext
                    return $true
                }
            }

            return $false
        }
        catch {
            Write-FileCopierLog -Level "Warning" -Message "Error checking restart requirement, assuming restart needed: $($_.Exception.Message)" -Category $this.LogContext
            return $true
        }
    }

    # Get service status
    [hashtable] GetServiceStatus() {
        $status = @{
            IsRunning = $this.IsRunning
            IsShuttingDown = $this.IsShuttingDown
            StartTime = $this.StartTime
            SourceDirectory = $this.SourceDirectory
            ServiceCounters = $this.ServiceCounters
        }

        if ($this.IsRunning) {
            $status.FileWatcherStatus = $this.FileWatcher.GetHealthStatus()
            $status.ProcessingQueueStatus = $this.ProcessingQueue.GetHealthStatus()
        }

        return $status
    }

    # Wait for shutdown completion
    [void] WaitForShutdown([int] $timeoutSeconds = 30) {
        $timeout = (Get-Date).AddSeconds($timeoutSeconds)

        while ($this.IsRunning -and (Get-Date) -lt $timeout) {
            Start-Sleep -Seconds 1
        }

        if ($this.IsRunning) {
            Write-FileCopierLog -Level "Warning" -Message "Service shutdown timeout exceeded" -Category $this.LogContext
        }
    }
}

# Static service management functions

function Start-FileCopierService {
    <#
    .SYNOPSIS
        Starts the FileCopier service for a source directory.

    .DESCRIPTION
        Creates and starts a FileCopierService instance with complete orchestration.

    .PARAMETER SourceDirectory
        Directory to monitor for files.

    .PARAMETER ConfigPath
        Optional path to configuration file.

    .EXAMPLE
        $service = Start-FileCopierService -SourceDirectory "C:\Source" -ConfigPath "C:\Config\settings.json"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [string]$ConfigPath
    )

    try {
        if ($ConfigPath) {
            $service = [FileCopierService]::new($SourceDirectory, $ConfigPath)
        } else {
            $service = [FileCopierService]::new($SourceDirectory)
        }

        $service.Start()
        return $service
    }
    catch {
        Write-FileCopierLog -Level "Error" -Message "Failed to start FileCopier service: $($_.Exception.Message)" -Category "Start-FileCopierService"
        throw
    }
}

function Stop-FileCopierService {
    <#
    .SYNOPSIS
        Stops a FileCopier service.

    .DESCRIPTION
        Gracefully stops a FileCopierService instance.

    .PARAMETER Service
        FileCopierService instance to stop.

    .PARAMETER TimeoutSeconds
        Maximum time to wait for shutdown.

    .EXAMPLE
        Stop-FileCopierService -Service $service -TimeoutSeconds 60
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [FileCopierService]$Service,

        [int]$TimeoutSeconds = 30
    )

    try {
        $Service.Stop()
        $Service.WaitForShutdown($TimeoutSeconds)
        Write-FileCopierLog -Level "Information" -Message "FileCopier service stopped successfully" -Category "Stop-FileCopierService"
    }
    catch {
        Write-FileCopierLog -Level "Error" -Message "Error stopping FileCopier service: $($_.Exception.Message)" -Category "Stop-FileCopierService"
        throw
    }
}

function Restart-FileCopierService {
    <#
    .SYNOPSIS
        Restarts a FileCopier service.

    .DESCRIPTION
        Gracefully restarts a FileCopierService instance.

    .PARAMETER Service
        FileCopierService instance to restart.

    .EXAMPLE
        Restart-FileCopierService -Service $service
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [FileCopierService]$Service
    )

    try {
        $Service.Restart()
        Write-FileCopierLog -Level "Information" -Message "FileCopier service restarted successfully" -Category "Restart-FileCopierService"
    }
    catch {
        Write-FileCopierLog -Level "Error" -Message "Error restarting FileCopier service: $($_.Exception.Message)" -Category "Restart-FileCopierService"
        throw
    }
}

function Get-FileCopierServiceStatus {
    <#
    .SYNOPSIS
        Gets the status of a FileCopier service.

    .DESCRIPTION
        Returns detailed status information for a FileCopierService instance.

    .PARAMETER Service
        FileCopierService instance to check.

    .EXAMPLE
        $status = Get-FileCopierServiceStatus -Service $service
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [FileCopierService]$Service
    )

    try {
        return $Service.GetServiceStatus()
    }
    catch {
        Write-FileCopierLog -Level "Error" -Message "Error getting service status: $($_.Exception.Message)" -Category "Get-FileCopierServiceStatus"
        throw
    }
}

# Export all functions including new service management functions
Export-ModuleMember -Function @(
    'Initialize-FileCopierConfig',
    'Get-FileCopierConfig',
    'Set-FileCopierConfig',
    'Test-FileCopierConfig',
    'Reload-FileCopierConfig',
    'Initialize-FileCopierLogging',
    'Write-FileCopierLog',
    'Set-FileCopierLogLevel',
    'Get-FileCopierLogLevel',
    'Get-LoggingPerformanceCounters',
    'Reset-LoggingPerformanceCounters',
    'Stop-FileCopierLogging',
    'Test-DirectoryAccess',
    'Get-FileStability',
    'Get-SafeFileName',
    'Measure-ExecutionTime',
    'Get-MemoryUsage',
    'Format-ByteSize',
    'Format-Duration',
    'Invoke-WithRetry',
    'Copy-FileStreaming',
    'Copy-FileToMultipleDestinations',
    'Get-CopyOperationInfo',
    'Get-CopyEngineStatistics',
    'Reset-CopyEngineStatistics',
    'Start-FileCopierService',
    'Stop-FileCopierService',
    'Restart-FileCopierService',
    'Get-FileCopierServiceStatus'
)