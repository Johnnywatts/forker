using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.Threading
using namespace System.IO
using namespace System.Net.Mail
using namespace System.Diagnostics

enum AlertSeverity {
    Info = 0
    Warning = 1
    Critical = 2
    Emergency = 3
}

enum AlertCategory {
    Performance = 0
    SystemHealth = 1
    FileProcessing = 2
    Connectivity = 3
    Configuration = 4
    Security = 5
}

class Alert {
    [string] $Id
    [DateTime] $Timestamp
    [AlertSeverity] $Severity
    [AlertCategory] $Category
    [string] $Title
    [string] $Message
    [hashtable] $Details
    [bool] $Acknowledged
    [DateTime] $ExpiresAt

    Alert([AlertSeverity]$severity, [AlertCategory]$category, [string]$title, [string]$message) {
        $this.Id = [Guid]::NewGuid().ToString()
        $this.Timestamp = Get-Date
        $this.Severity = $severity
        $this.Category = $category
        $this.Title = $title
        $this.Message = $message
        $this.Details = @{}
        $this.Acknowledged = $false
        $this.ExpiresAt = (Get-Date).AddHours(24)  # Default 24 hour expiration
    }

    [hashtable] ToHashtable() {
        return @{
            Id = $this.Id
            Timestamp = $this.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
            Severity = $this.Severity.ToString()
            Category = $this.Category.ToString()
            Title = $this.Title
            Message = $this.Message
            Details = $this.Details
            Acknowledged = $this.Acknowledged
            ExpiresAt = $this.ExpiresAt.ToString("yyyy-MM-dd HH:mm:ss")
        }
    }
}

class AlertingSystem {
    [hashtable] $Config
    [object] $Logger
    [ConcurrentDictionary[string, Alert]] $ActiveAlerts
    [List[Alert]] $AlertHistory
    [System.Threading.Timer] $MonitoringTimer
    [System.Threading.Timer] $CleanupTimer
    [DiagnosticCommands] $Diagnostics
    [PerformanceCounterManager] $PerfCounters
    [bool] $IsRunning
    [object] $LockObject

    AlertingSystem([hashtable]$config, [object]$logger) {
        $this.Config = $config
        $this.Logger = $logger
        $this.ActiveAlerts = [ConcurrentDictionary[string, Alert]]::new()
        $this.AlertHistory = [List[Alert]]::new()
        $this.IsRunning = $false
        $this.LockObject = [object]::new()

        $this.Diagnostics = [DiagnosticCommands]::new($config, $logger)

        if ($config['Performance']['Monitoring']['PerformanceCounters']) {
            $this.PerfCounters = [PerformanceCounterManager]::new($config, $logger)
        }
    }

    [void] Start() {
        if ($this.IsRunning) {
            $this.Logger.LogWarning("Alerting system is already running")
            return
        }

        try {
            $this.IsRunning = $true

            # Start monitoring timer (check every 60 seconds)
            $this.MonitoringTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{
                    param($state)
                    $alerting = $state
                    $alerting.PerformHealthChecks()
                },
                $this,
                [TimeSpan]::FromSeconds(10),  # Initial delay
                [TimeSpan]::FromSeconds(60)   # Check interval
            )

            # Start cleanup timer (clean expired alerts every 5 minutes)
            $this.CleanupTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{
                    param($state)
                    $alerting = $state
                    $alerting.CleanupExpiredAlerts()
                },
                $this,
                [TimeSpan]::FromMinutes(1),   # Initial delay
                [TimeSpan]::FromMinutes(5)    # Cleanup interval
            )

            $this.Logger.LogInformation("Alerting system started")
        }
        catch {
            $this.IsRunning = $false
            $this.Logger.LogError("Failed to start alerting system", $_.Exception)
            throw
        }
    }

    [void] Stop() {
        if (-not $this.IsRunning) {
            return
        }

        try {
            $this.IsRunning = $false

            if ($this.MonitoringTimer) {
                $this.MonitoringTimer.Dispose()
                $this.MonitoringTimer = $null
            }

            if ($this.CleanupTimer) {
                $this.CleanupTimer.Dispose()
                $this.CleanupTimer = $null
            }

            $this.Logger.LogInformation("Alerting system stopped")
        }
        catch {
            $this.Logger.LogError("Error stopping alerting system", $_.Exception)
        }
    }

    [void] PerformHealthChecks() {
        try {
            # Check system resources
            $this.CheckMemoryUsage()
            $this.CheckCpuUsage()
            $this.CheckDiskSpace()

            # Check processing performance
            $this.CheckQueueDepth()
            $this.CheckProcessingTime()
            $this.CheckErrorRate()

            # Check connectivity
            $this.CheckConnectivity()

            # Check service health
            $this.CheckServiceHealth()
        }
        catch {
            $this.Logger.LogError("Error during health checks", $_.Exception)
        }
    }

    [void] CheckMemoryUsage() {
        try {
            $currentProcess = Get-Process -Id $global:PID
            $memoryMB = [math]::Round($currentProcess.WorkingSet64 / 1MB, 2)
            $maxMemoryMB = $this.Config['Service']['MaxMemoryMB']
            $thresholdMB = $this.Config['Performance']['Alerting']['MemoryThresholdMB']

            $usagePercent = ($memoryMB / $maxMemoryMB) * 100

            if ($memoryMB -gt $thresholdMB) {
                $severity = if ($usagePercent -gt 95) { [AlertSeverity]::Critical } else { [AlertSeverity]::Warning }

                $alert = [Alert]::new(
                    $severity,
                    [AlertCategory]::Performance,
                    "High Memory Usage",
                    "Memory usage is $memoryMB MB ($([math]::Round($usagePercent, 1))% of limit)"
                )

                $alert.Details['CurrentMemoryMB'] = $memoryMB
                $alert.Details['MaxMemoryMB'] = $maxMemoryMB
                $alert.Details['ThresholdMB'] = $thresholdMB
                $alert.Details['UsagePercent'] = [math]::Round($usagePercent, 1)

                $this.RaiseAlert($alert)
            } else {
                # Clear existing memory alerts
                $this.ClearAlertsOfType("High Memory Usage")
            }
        }
        catch {
            $this.Logger.LogError("Error checking memory usage", $_.Exception)
        }
    }

    [void] CheckCpuUsage() {
        try {
            $cpuThreshold = $this.Config['Performance']['Alerting']['CPUThresholdPercent']

            # Get CPU usage (simplified approach)
            $cpuCounter = Get-Counter "\Process(powershell*)\% Processor Time" -MaxSamples 1 -ErrorAction SilentlyContinue

            if ($cpuCounter) {
                $cpuPercent = [math]::Round($cpuCounter.CounterSamples[0].CookedValue, 1)

                if ($cpuPercent -gt $cpuThreshold) {
                    $severity = if ($cpuPercent -gt ($cpuThreshold * 1.5)) { [AlertSeverity]::Critical } else { [AlertSeverity]::Warning }

                    $alert = [Alert]::new(
                        $severity,
                        [AlertCategory]::Performance,
                        "High CPU Usage",
                        "CPU usage is $cpuPercent% (threshold: $cpuThreshold%)"
                    )

                    $alert.Details['CurrentCpuPercent'] = $cpuPercent
                    $alert.Details['ThresholdPercent'] = $cpuThreshold

                    $this.RaiseAlert($alert)
                } else {
                    $this.ClearAlertsOfType("High CPU Usage")
                }
            }
        }
        catch {
            $this.Logger.LogError("Error checking CPU usage", $_.Exception)
        }
    }

    [void] CheckDiskSpace() {
        try {
            $criticalPaths = @(
                $this.Config['SourceDirectory'],
                $this.Config['Processing']['QuarantineDirectory'],
                $this.Config['Processing']['TempDirectory']
            )

            foreach ($path in $criticalPaths | Where-Object { $_ }) {
                if (Test-Path $path) {
                    $freeSpace = $this.GetDiskSpace($path)
                    $freeSpaceGB = [math]::Round($freeSpace / 1GB, 2)

                    if ($freeSpaceGB -lt 1) {
                        $severity = if ($freeSpaceGB -lt 0.5) { [AlertSeverity]::Critical } else { [AlertSeverity]::Warning }

                        $alert = [Alert]::new(
                            $severity,
                            [AlertCategory]::SystemHealth,
                            "Low Disk Space",
                            "Low disk space for $path`: $freeSpaceGB GB remaining"
                        )

                        $alert.Details['Path'] = $path
                        $alert.Details['FreeSpaceGB'] = $freeSpaceGB

                        $this.RaiseAlert($alert)
                    } else {
                        $this.ClearAlertsOfType("Low Disk Space", $path)
                    }
                }
            }
        }
        catch {
            $this.Logger.LogError("Error checking disk space", $_.Exception)
        }
    }

    [void] CheckQueueDepth() {
        try {
            # This would integrate with actual queue monitoring
            $queueDepthThreshold = $this.Config['Performance']['Alerting']['QueueDepthThreshold']

            # Simulate queue depth check (would use actual queue metrics)
            $currentDepth = 0  # Would get from ProcessingQueue class

            if ($this.PerfCounters) {
                $counters = $this.PerfCounters.GetAllCounterValues()
                $currentDepth = $counters['QueueDepth']
            }

            if ($currentDepth -gt $queueDepthThreshold) {
                $severity = if ($currentDepth -gt ($queueDepthThreshold * 2)) { [AlertSeverity]::Critical } else { [AlertSeverity]::Warning }

                $alert = [Alert]::new(
                    $severity,
                    [AlertCategory]::Performance,
                    "High Queue Depth",
                    "Processing queue depth is $currentDepth (threshold: $queueDepthThreshold)"
                )

                $alert.Details['CurrentDepth'] = $currentDepth
                $alert.Details['ThresholdDepth'] = $queueDepthThreshold

                $this.RaiseAlert($alert)
            } else {
                $this.ClearAlertsOfType("High Queue Depth")
            }
        }
        catch {
            $this.Logger.LogError("Error checking queue depth", $_.Exception)
        }
    }

    [void] CheckProcessingTime() {
        try {
            $timeThresholdMinutes = $this.Config['Performance']['Alerting']['ProcessingTimeThresholdMinutes']

            if ($this.PerfCounters) {
                $counters = $this.PerfCounters.GetAllCounterValues()
                $avgProcessingTime = $counters['AverageProcessingTimeSeconds']
                $avgProcessingMinutes = $avgProcessingTime / 60

                if ($avgProcessingMinutes -gt $timeThresholdMinutes) {
                    $severity = if ($avgProcessingMinutes -gt ($timeThresholdMinutes * 2)) { [AlertSeverity]::Critical } else { [AlertSeverity]::Warning }

                    $alert = [Alert]::new(
                        $severity,
                        [AlertCategory]::Performance,
                        "Slow Processing Time",
                        "Average processing time is $([math]::Round($avgProcessingMinutes, 1)) minutes (threshold: $timeThresholdMinutes minutes)"
                    )

                    $alert.Details['CurrentTimeMinutes'] = [math]::Round($avgProcessingMinutes, 1)
                    $alert.Details['ThresholdMinutes'] = $timeThresholdMinutes

                    $this.RaiseAlert($alert)
                } else {
                    $this.ClearAlertsOfType("Slow Processing Time")
                }
            }
        }
        catch {
            $this.Logger.LogError("Error checking processing time", $_.Exception)
        }
    }

    [void] CheckErrorRate() {
        try {
            $errorRateThreshold = $this.Config['Performance']['Alerting']['ErrorRateThresholdPercent']

            if ($this.PerfCounters) {
                $counters = $this.PerfCounters.GetAllCounterValues()
                $totalProcessed = $counters['FilesProcessedTotal']
                $totalErrors = $counters['FilesInError']

                if ($totalProcessed -gt 0) {
                    $errorRate = ($totalErrors / $totalProcessed) * 100

                    if ($errorRate -gt $errorRateThreshold) {
                        $severity = if ($errorRate -gt ($errorRateThreshold * 2)) { [AlertSeverity]::Critical } else { [AlertSeverity]::Warning }

                        $alert = [Alert]::new(
                            $severity,
                            [AlertCategory]::FileProcessing,
                            "High Error Rate",
                            "File processing error rate is $([math]::Round($errorRate, 1))% (threshold: $errorRateThreshold%)"
                        )

                        $alert.Details['CurrentErrorRate'] = [math]::Round($errorRate, 1)
                        $alert.Details['ThresholdPercent'] = $errorRateThreshold
                        $alert.Details['TotalProcessed'] = $totalProcessed
                        $alert.Details['TotalErrors'] = $totalErrors

                        $this.RaiseAlert($alert)
                    } else {
                        $this.ClearAlertsOfType("High Error Rate")
                    }
                }
            }
        }
        catch {
            $this.Logger.LogError("Error checking error rate", $_.Exception)
        }
    }

    [void] CheckConnectivity() {
        try {
            $connectivity = $this.Diagnostics.TestConnectivity()

            if ($connectivity.Status -eq 'Failed') {
                $alert = [Alert]::new(
                    [AlertSeverity]::Critical,
                    [AlertCategory]::Connectivity,
                    "Connectivity Failure",
                    "One or more critical directories are not accessible"
                )

                $alert.Details['ConnectivityTests'] = $connectivity.Tests

                $this.RaiseAlert($alert)
            } elseif ($connectivity.Status -eq 'Warning') {
                $alert = [Alert]::new(
                    [AlertSeverity]::Warning,
                    [AlertCategory]::Connectivity,
                    "Connectivity Issues",
                    "Some connectivity issues detected"
                )

                $alert.Details['ConnectivityTests'] = $connectivity.Tests

                $this.RaiseAlert($alert)
            } else {
                $this.ClearAlertsOfType("Connectivity Failure")
                $this.ClearAlertsOfType("Connectivity Issues")
            }
        }
        catch {
            $this.Logger.LogError("Error checking connectivity", $_.Exception)
        }
    }

    [void] CheckServiceHealth() {
        try {
            $health = $this.Diagnostics.GetSystemHealth()

            if ($health.Status -eq 'Critical') {
                $alert = [Alert]::new(
                    [AlertSeverity]::Emergency,
                    [AlertCategory]::SystemHealth,
                    "Service Health Critical",
                    "FileCopier service is in critical state"
                )

                $alert.Details['HealthComponents'] = $health.Components
                $alert.Details['Issues'] = $health.Alerts

                $this.RaiseAlert($alert)
            } elseif ($health.Status -eq 'Warning') {
                $alert = [Alert]::new(
                    [AlertSeverity]::Warning,
                    [AlertCategory]::SystemHealth,
                    "Service Health Warning",
                    "FileCopier service has health warnings"
                )

                $alert.Details['HealthComponents'] = $health.Components

                $this.RaiseAlert($alert)
            } else {
                $this.ClearAlertsOfType("Service Health Critical")
                $this.ClearAlertsOfType("Service Health Warning")
            }
        }
        catch {
            $this.Logger.LogError("Error checking service health", $_.Exception)
        }
    }

    [void] RaiseAlert([Alert]$alert) {
        $existingAlert = $this.FindSimilarAlert($alert)

        if ($existingAlert) {
            # Update existing alert instead of creating duplicate
            $existingAlert.Timestamp = Get-Date
            $existingAlert.Message = $alert.Message
            $existingAlert.Details = $alert.Details
            $existingAlert.ExpiresAt = $alert.ExpiresAt
        } else {
            # Add new alert
            $this.ActiveAlerts.TryAdd($alert.Id, $alert) | Out-Null

            # Log the alert
            $this.LogAlert($alert)

            # Send notifications if configured
            $this.SendNotifications($alert)

            # Add to history
            lock ($this.LockObject) {
                $this.AlertHistory.Add($alert)

                # Keep only last 1000 alerts in memory
                while ($this.AlertHistory.Count -gt 1000) {
                    $this.AlertHistory.RemoveAt(0)
                }
            }
        }
    }

    [Alert] FindSimilarAlert([Alert]$alert) {
        foreach ($existingAlert in $this.ActiveAlerts.Values) {
            if ($existingAlert.Title -eq $alert.Title -and
                $existingAlert.Category -eq $alert.Category -and
                -not $existingAlert.Acknowledged) {
                return $existingAlert
            }
        }
        return $null
    }

    [void] ClearAlertsOfType([string]$title, [string]$additionalCriteria = $null) {
        $alertsToRemove = @()

        foreach ($alert in $this.ActiveAlerts.Values) {
            if ($alert.Title -eq $title) {
                if (-not $additionalCriteria -or $alert.Message -like "*$additionalCriteria*") {
                    $alertsToRemove += $alert.Id
                }
            }
        }

        foreach ($alertId in $alertsToRemove) {
            $this.ActiveAlerts.TryRemove($alertId, [ref]$null) | Out-Null
        }
    }

    [void] LogAlert([Alert]$alert) {
        $logMessage = "ALERT [$($alert.Severity)] $($alert.Title): $($alert.Message)"

        switch ($alert.Severity) {
            ([AlertSeverity]::Info) { $this.Logger.LogInformation($logMessage) }
            ([AlertSeverity]::Warning) { $this.Logger.LogWarning($logMessage) }
            ([AlertSeverity]::Critical) { $this.Logger.LogError($logMessage) }
            ([AlertSeverity]::Emergency) { $this.Logger.LogCritical($logMessage) }
        }
    }

    [void] SendNotifications([Alert]$alert) {
        try {
            # Send to Windows Event Log
            $this.SendToEventLog($alert)

            # Could add email notifications, SNMP traps, etc.
            # if ($this.Config.ContainsKey('Notifications')) {
            #     $this.SendEmailNotification($alert)
            # }
        }
        catch {
            $this.Logger.LogError("Error sending alert notifications", $_.Exception)
        }
    }

    [void] SendToEventLog([Alert]$alert) {
        try {
            $eventId = 3000 + [int]$alert.Severity
            $entryType = switch ($alert.Severity) {
                ([AlertSeverity]::Info) { [System.Diagnostics.EventLogEntryType]::Information }
                ([AlertSeverity]::Warning) { [System.Diagnostics.EventLogEntryType]::Warning }
                ([AlertSeverity]::Critical) { [System.Diagnostics.EventLogEntryType]::Error }
                ([AlertSeverity]::Emergency) { [System.Diagnostics.EventLogEntryType]::Error }
                default { [System.Diagnostics.EventLogEntryType]::Information }
            }

            $message = "$($alert.Title)`n`n$($alert.Message)`n`nDetails: $($alert.Details | ConvertTo-Json -Depth 2)"

            Write-EventLog -LogName Application -Source "FileCopier Service" -EventId $eventId -EntryType $entryType -Message $message -ErrorAction SilentlyContinue
        }
        catch {
            # Silently continue if event log writing fails
        }
    }

    [void] AcknowledgeAlert([string]$alertId) {
        $alert = $null
        if ($this.ActiveAlerts.TryGetValue($alertId, [ref]$alert)) {
            $alert.Acknowledged = $true
            $this.Logger.LogInformation("Alert acknowledged: $($alert.Title)")
        }
    }

    [void] CleanupExpiredAlerts() {
        try {
            $now = Get-Date
            $alertsToRemove = @()

            foreach ($alert in $this.ActiveAlerts.Values) {
                if ($now -gt $alert.ExpiresAt) {
                    $alertsToRemove += $alert.Id
                }
            }

            foreach ($alertId in $alertsToRemove) {
                $this.ActiveAlerts.TryRemove($alertId, [ref]$null) | Out-Null
            }

            if ($alertsToRemove.Count -gt 0) {
                $this.Logger.LogInformation("Cleaned up $($alertsToRemove.Count) expired alerts")
            }
        }
        catch {
            $this.Logger.LogError("Error cleaning up expired alerts", $_.Exception)
        }
    }

    [long] GetDiskSpace([string]$path) {
        try {
            $drive = [System.IO.Path]::GetPathRoot($path)
            $driveInfo = New-Object System.IO.DriveInfo($drive)
            return $driveInfo.AvailableFreeSpace
        }
        catch {
            return 0
        }
    }

    [hashtable[]] GetActiveAlerts() {
        $alerts = @()
        foreach ($alert in $this.ActiveAlerts.Values) {
            $alerts += $alert.ToHashtable()
        }
        return $alerts | Sort-Object Timestamp -Descending
    }

    [hashtable[]] GetAlertHistory([int]$count = 100) {
        lock ($this.LockObject) {
            $alerts = @()
            $historyToReturn = if ($this.AlertHistory.Count -gt $count) {
                $this.AlertHistory.GetRange($this.AlertHistory.Count - $count, $count)
            } else {
                $this.AlertHistory
            }

            foreach ($alert in $historyToReturn) {
                $alerts += $alert.ToHashtable()
            }

            return $alerts | Sort-Object Timestamp -Descending
        }
        return @()
    }
}

# Export alerting functions for console use
function Start-FileCopierAlerting {
    param(
        [hashtable]$Config,
        [object]$Logger
    )

    $alerting = [AlertingSystem]::new($Config, $Logger)
    $alerting.Start()
    return $alerting
}

function Stop-FileCopierAlerting {
    param(
        [AlertingSystem]$AlertingSystem
    )

    $AlertingSystem.Stop()
}

function Get-FileCopierAlerts {
    param(
        [AlertingSystem]$AlertingSystem,
        [switch]$IncludeHistory,
        [int]$HistoryCount = 100
    )

    $result = @{
        ActiveAlerts = $AlertingSystem.GetActiveAlerts()
    }

    if ($IncludeHistory) {
        $result.AlertHistory = $AlertingSystem.GetAlertHistory($HistoryCount)
    }

    return $result
}

function Confirm-FileCopierAlert {
    param(
        [AlertingSystem]$AlertingSystem,
        [string]$AlertId
    )

    $AlertingSystem.AcknowledgeAlert($AlertId)
}