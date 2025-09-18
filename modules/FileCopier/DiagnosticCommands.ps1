using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.Threading
using namespace System.IO
using namespace System.Diagnostics

class DiagnosticCommands {
    [hashtable] $Config
    [object] $Logger
    [PerformanceCounterManager] $PerfCounters

    DiagnosticCommands([hashtable]$config, [object]$logger) {
        $this.Config = $config
        $this.Logger = $logger

        if ($config['Performance']['Monitoring']['PerformanceCounters']) {
            $this.PerfCounters = [PerformanceCounterManager]::new($config, $logger)
        }
    }

    [hashtable] GetSystemHealth() {
        $health = @{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Status = "Unknown"
            Components = @{}
            Alerts = @()
            Recommendations = @()
        }

        try {
            # Check file system components
            $health.Components.FileSystem = $this.CheckFileSystemHealth()

            # Check processing queues
            $health.Components.ProcessingQueues = $this.CheckQueueHealth()

            # Check system resources
            $health.Components.SystemResources = $this.CheckSystemResources()

            # Check service configuration
            $health.Components.Configuration = $this.CheckConfigurationHealth()

            # Check log files and audit trail
            $health.Components.Logging = $this.CheckLoggingHealth()

            # Determine overall status
            $componentStatuses = $health.Components.Values | ForEach-Object { $_['Status'] }
            if ($componentStatuses -contains 'Critical') {
                $health.Status = 'Critical'
            }
            elseif ($componentStatuses -contains 'Warning') {
                $health.Status = 'Warning'
            }
            else {
                $health.Status = 'Healthy'
            }

            $this.Logger.LogInformation("System health check completed: $($health.Status)")
        }
        catch {
            $health.Status = 'Error'
            $health.Error = $_.Exception.Message
            $this.Logger.LogError("System health check failed", $_.Exception)
        }

        return $health
    }

    [hashtable] CheckFileSystemHealth() {
        $result = @{
            Status = 'Healthy'
            Details = @{}
            Issues = @()
        }

        try {
            # Check source directory
            $sourceDir = $this.Config['SourceDirectory']
            if (-not (Test-Path $sourceDir)) {
                $result.Issues += "Source directory not accessible: $sourceDir"
                $result.Status = 'Critical'
            } else {
                $result.Details.SourceDirectory = @{
                    Path = $sourceDir
                    Accessible = $true
                    FreeSpace = $this.GetDiskSpace($sourceDir)
                }
            }

            # Check target directories
            $result.Details.TargetDirectories = @{}
            foreach ($target in $this.Config['Targets'].GetEnumerator()) {
                $targetPath = $target.Value['Path']
                $accessible = Test-Path $targetPath

                if (-not $accessible) {
                    $result.Issues += "Target directory not accessible: $targetPath"
                    $result.Status = 'Critical'
                }

                $result.Details.TargetDirectories[$target.Key] = @{
                    Path = $targetPath
                    Enabled = $target.Value['Enabled']
                    Accessible = $accessible
                    FreeSpace = if ($accessible) { $this.GetDiskSpace($targetPath) } else { 0 }
                }
            }

            # Check quarantine directory
            $quarantineDir = $this.Config['Processing']['QuarantineDirectory']
            if ($quarantineDir -and -not (Test-Path $quarantineDir)) {
                $result.Issues += "Quarantine directory not accessible: $quarantineDir"
                if ($result.Status -eq 'Healthy') { $result.Status = 'Warning' }
            }

            # Check temp directory
            $tempDir = $this.Config['Processing']['TempDirectory']
            if ($tempDir -and -not (Test-Path $tempDir)) {
                $result.Issues += "Temp directory not accessible: $tempDir"
                if ($result.Status -eq 'Healthy') { $result.Status = 'Warning' }
            }
        }
        catch {
            $result.Status = 'Error'
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    [hashtable] CheckQueueHealth() {
        $result = @{
            Status = 'Healthy'
            Details = @{}
            Issues = @()
        }

        try {
            # Simulate queue status check (would integrate with actual queue classes)
            $result.Details.DetectionQueue = @{
                Size = 0
                Processing = $false
                LastActivity = Get-Date
            }

            $result.Details.ProcessingQueue = @{
                Size = 0
                ActiveJobs = 0
                CompletedToday = 0
                FailedToday = 0
                LastActivity = Get-Date
            }

            # Check for queue depth issues
            $queueDepthThreshold = $this.Config['Performance']['Alerting']['QueueDepthThreshold']
            if ($result.Details.ProcessingQueue.Size -gt $queueDepthThreshold) {
                $result.Issues += "Processing queue depth exceeds threshold: $($result.Details.ProcessingQueue.Size) > $queueDepthThreshold"
                $result.Status = 'Warning'
            }
        }
        catch {
            $result.Status = 'Error'
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    [hashtable] CheckSystemResources() {
        $result = @{
            Status = 'Healthy'
            Details = @{}
            Issues = @()
        }

        try {
            # Memory usage
            $currentProcess = Get-Process -Id $global:PID
            $memoryMB = [math]::Round($currentProcess.WorkingSet64 / 1MB, 2)
            $maxMemoryMB = $this.Config['Service']['MaxMemoryMB']

            $result.Details.Memory = @{
                CurrentMB = $memoryMB
                MaxAllowedMB = $maxMemoryMB
                PercentUsed = [math]::Round(($memoryMB / $maxMemoryMB) * 100, 1)
            }

            if ($memoryMB -gt ($maxMemoryMB * 0.9)) {
                $result.Issues += "Memory usage is high: $memoryMB MB (90% of limit)"
                $result.Status = 'Warning'
            }

            # CPU usage (approximation)
            $cpuCounter = Get-Counter "\Process(powershell*)\% Processor Time" -MaxSamples 1 -ErrorAction SilentlyContinue
            if ($cpuCounter) {
                $cpuPercent = [math]::Round($cpuCounter.CounterSamples[0].CookedValue, 1)
                $result.Details.CPU = @{
                    PercentUsed = $cpuPercent
                    Threshold = $this.Config['Service']['CPUThresholdPercent']
                }

                if ($cpuPercent -gt $this.Config['Service']['CPUThresholdPercent']) {
                    $result.Issues += "CPU usage is high: $cpuPercent%"
                    $result.Status = 'Warning'
                }
            }

            # Disk space for critical directories
            $result.Details.DiskSpace = @{}
            $criticalPaths = @(
                $this.Config['SourceDirectory'],
                $this.Config['Processing']['QuarantineDirectory'],
                $this.Config['Processing']['TempDirectory']
            )

            foreach ($path in $criticalPaths | Where-Object { $_ }) {
                if (Test-Path $path) {
                    $freeSpace = $this.GetDiskSpace($path)
                    $result.Details.DiskSpace[$path] = $freeSpace

                    if ($freeSpace -lt 1GB) {
                        $result.Issues += "Low disk space for $path`: $([math]::Round($freeSpace / 1GB, 2)) GB free"
                        $result.Status = 'Warning'
                    }
                }
            }
        }
        catch {
            $result.Status = 'Error'
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    [hashtable] CheckConfigurationHealth() {
        $result = @{
            Status = 'Healthy'
            Details = @{}
            Issues = @()
        }

        try {
            # Validate critical configuration sections
            $requiredSections = @('SourceDirectory', 'Targets', 'FileWatcher', 'Processing', 'Logging')
            foreach ($section in $requiredSections) {
                if (-not $this.Config.ContainsKey($section)) {
                    $result.Issues += "Missing configuration section: $section"
                    $result.Status = 'Critical'
                }
            }

            # Check for at least one enabled target
            $enabledTargets = 0
            foreach ($target in $this.Config['Targets'].GetEnumerator()) {
                if ($target.Value['Enabled']) {
                    $enabledTargets++
                }
            }

            if ($enabledTargets -eq 0) {
                $result.Issues += "No enabled targets found"
                $result.Status = 'Critical'
            }

            $result.Details.EnabledTargets = $enabledTargets
            $result.Details.TotalTargets = $this.Config['Targets'].Count

            # Validate file patterns
            $includePatterns = $this.Config['FileWatcher']['IncludePatterns']
            $excludePatterns = $this.Config['FileWatcher']['ExcludePatterns']

            $result.Details.FilePatterns = @{
                IncludeCount = $includePatterns.Count
                ExcludeCount = $excludePatterns.Count
                IncludePatterns = $includePatterns
                ExcludePatterns = $excludePatterns
            }

            # Check for reasonable polling intervals
            $pollingInterval = $this.Config['FileWatcher']['PollingInterval']
            if ($pollingInterval -lt 1000) {
                $result.Issues += "Polling interval may be too aggressive: $pollingInterval ms"
                if ($result.Status -eq 'Healthy') { $result.Status = 'Warning' }
            }
        }
        catch {
            $result.Status = 'Error'
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    [hashtable] CheckLoggingHealth() {
        $result = @{
            Status = 'Healthy'
            Details = @{}
            Issues = @()
        }

        try {
            # Check log file accessibility
            $logPath = $this.Config['Logging']['FilePath']
            $logDir = Split-Path $logPath -Parent

            if (-not (Test-Path $logDir)) {
                $result.Issues += "Log directory not accessible: $logDir"
                $result.Status = 'Critical'
            } else {
                $result.Details.LogDirectory = @{
                    Path = $logDir
                    Accessible = $true
                }

                # Check log file size
                if (Test-Path $logPath) {
                    $logFile = Get-Item $logPath
                    $logSizeMB = [math]::Round($logFile.Length / 1MB, 2)
                    $maxSizeMB = $this.Config['Logging']['MaxFileSizeMB']

                    $result.Details.CurrentLogFile = @{
                        Path = $logPath
                        SizeMB = $logSizeMB
                        MaxSizeMB = $maxSizeMB
                        LastModified = $logFile.LastWriteTime
                    }

                    if ($logSizeMB -gt ($maxSizeMB * 0.9)) {
                        $result.Issues += "Log file approaching size limit: $logSizeMB MB"
                        if ($result.Status -eq 'Healthy') { $result.Status = 'Warning' }
                    }
                }
            }

            # Check audit directory
            $auditDir = $this.Config['Logging']['AuditDirectory']
            if ($auditDir) {
                if (-not (Test-Path $auditDir)) {
                    $result.Issues += "Audit directory not accessible: $auditDir"
                    if ($result.Status -eq 'Healthy') { $result.Status = 'Warning' }
                } else {
                    $auditFiles = Get-ChildItem $auditDir -Filter "*.jsonl" | Measure-Object
                    $result.Details.AuditDirectory = @{
                        Path = $auditDir
                        FileCount = $auditFiles.Count
                        Accessible = $true
                    }
                }
            }
        }
        catch {
            $result.Status = 'Error'
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    [hashtable] GetPerformanceMetrics() {
        $metrics = @{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Counters = @{}
            Summary = @{}
        }

        if ($this.PerfCounters) {
            try {
                $metrics.Counters = $this.PerfCounters.GetAllCounterValues()

                # Calculate summary statistics
                $metrics.Summary = @{
                    TotalFilesProcessed = $metrics.Counters['FilesProcessedTotal']
                    TotalFilesInError = $metrics.Counters['FilesInError']
                    SuccessRate = if ($metrics.Counters['FilesProcessedTotal'] -gt 0) {
                        [math]::Round((($metrics.Counters['FilesProcessedTotal'] - $metrics.Counters['FilesInError']) / $metrics.Counters['FilesProcessedTotal']) * 100, 2)
                    } else { 0 }
                    AverageProcessingTimeSeconds = $metrics.Counters['AverageProcessingTimeSeconds']
                    AverageCopySpeedMBps = $metrics.Counters['AverageCopySpeedMBps']
                    CurrentQueueDepth = $metrics.Counters['QueueDepth']
                }
            }
            catch {
                $metrics.Error = $_.Exception.Message
                $this.Logger.LogError("Failed to retrieve performance metrics", $_.Exception)
            }
        }

        return $metrics
    }

    [hashtable] GetRecentErrors([int]$hours = 24) {
        $result = @{
            TimeRange = "$hours hours"
            Errors = @()
            Summary = @{
                TotalErrors = 0
                ErrorsByCategory = @{}
                ErrorsByType = @{}
            }
        }

        try {
            # This would integrate with the actual logging system
            # For now, simulate error retrieval from log files
            $logPath = $this.Config['Logging']['FilePath']

            if (Test-Path $logPath) {
                $cutoffTime = (Get-Date).AddHours(-$hours)

                # Read recent log entries (simplified)
                $logContent = Get-Content $logPath -Tail 1000 | Where-Object {
                    $_ -match '\[ERROR\]|\[FATAL\]'
                }

                foreach ($line in $logContent) {
                    # Parse log line (simplified)
                    if ($line -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*\[(ERROR|FATAL)\](.*)') {
                        $timestamp = [DateTime]::ParseExact($matches[1], "yyyy-MM-dd HH:mm:ss", $null)

                        if ($timestamp -ge $cutoffTime) {
                            $error = @{
                                Timestamp = $timestamp.ToString("yyyy-MM-dd HH:mm:ss")
                                Level = $matches[2]
                                Message = $matches[3].Trim()
                            }

                            $result.Errors += $error
                            $result.Summary.TotalErrors++
                        }
                    }
                }
            }
        }
        catch {
            $result.Error = $_.Exception.Message
            $this.Logger.LogError("Failed to retrieve recent errors", $_.Exception)
        }

        return $result
    }

    [hashtable] TestConnectivity() {
        $result = @{
            Status = 'Unknown'
            Tests = @{}
        }

        try {
            # Test source directory connectivity
            $sourceDir = $this.Config['SourceDirectory']
            $result.Tests.SourceDirectory = $this.TestDirectoryConnectivity($sourceDir)

            # Test target directories
            $result.Tests.TargetDirectories = @{}
            foreach ($target in $this.Config['Targets'].GetEnumerator()) {
                $targetPath = $target.Value['Path']
                $result.Tests.TargetDirectories[$target.Key] = $this.TestDirectoryConnectivity($targetPath)
            }

            # Test quarantine directory
            $quarantineDir = $this.Config['Processing']['QuarantineDirectory']
            if ($quarantineDir) {
                $result.Tests.QuarantineDirectory = $this.TestDirectoryConnectivity($quarantineDir)
            }

            # Determine overall connectivity status
            $allTests = @()
            $allTests += $result.Tests.SourceDirectory.Status
            $allTests += $result.Tests.TargetDirectories.Values | ForEach-Object { $_.Status }
            if ($result.Tests.QuarantineDirectory) {
                $allTests += $result.Tests.QuarantineDirectory.Status
            }

            if ($allTests -contains 'Failed') {
                $result.Status = 'Failed'
            }
            elseif ($allTests -contains 'Warning') {
                $result.Status = 'Warning'
            }
            else {
                $result.Status = 'Passed'
            }
        }
        catch {
            $result.Status = 'Error'
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    [hashtable] TestDirectoryConnectivity([string]$path) {
        $result = @{
            Path = $path
            Status = 'Unknown'
            Details = @{}
        }

        try {
            # Test basic accessibility
            if (-not (Test-Path $path)) {
                $result.Status = 'Failed'
                $result.Details.Error = 'Directory not accessible'
                return $result
            }

            # Test read access
            try {
                $null = Get-ChildItem $path -ErrorAction Stop
                $result.Details.ReadAccess = $true
            }
            catch {
                $result.Status = 'Failed'
                $result.Details.ReadAccess = $false
                $result.Details.ReadError = $_.Exception.Message
                return $result
            }

            # Test write access
            $testFile = Join-Path $path ".connectivity_test_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            try {
                "test" | Out-File $testFile -ErrorAction Stop
                Remove-Item $testFile -ErrorAction SilentlyContinue
                $result.Details.WriteAccess = $true
            }
            catch {
                $result.Details.WriteAccess = $false
                $result.Details.WriteError = $_.Exception.Message
                if ($result.Status -eq 'Unknown') { $result.Status = 'Warning' }
            }

            # Get disk space
            $freeSpace = $this.GetDiskSpace($path)
            $result.Details.FreeSpaceGB = [math]::Round($freeSpace / 1GB, 2)

            if ($freeSpace -lt 1GB) {
                if ($result.Status -eq 'Unknown') { $result.Status = 'Warning' }
                $result.Details.LowDiskSpace = $true
            }

            if ($result.Status -eq 'Unknown') {
                $result.Status = 'Passed'
            }
        }
        catch {
            $result.Status = 'Error'
            $result.Details.Error = $_.Exception.Message
        }

        return $result
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

    [string] GenerateHealthReport([bool]$detailed = $false) {
        $report = New-Object System.Text.StringBuilder
        $health = $this.GetSystemHealth()

        $report.AppendLine("=" * 80)
        $report.AppendLine("FileCopier Service Health Report")
        $report.AppendLine("Generated: $($health.Timestamp)")
        $report.AppendLine("Overall Status: $($health.Status)")
        $report.AppendLine("=" * 80)

        # Component status summary
        $report.AppendLine()
        $report.AppendLine("COMPONENT STATUS:")
        foreach ($component in $health.Components.GetEnumerator()) {
            $status = $component.Value.Status
            $statusIcon = switch ($status) {
                'Healthy' { '✓' }
                'Warning' { '⚠' }
                'Critical' { '✗' }
                'Error' { '!' }
                default { '?' }
            }
            $report.AppendLine("  $statusIcon $($component.Key): $status")
        }

        # Issues and recommendations
        if ($health.Alerts.Count -gt 0) {
            $report.AppendLine()
            $report.AppendLine("ALERTS:")
            foreach ($alert in $health.Alerts) {
                $report.AppendLine("  • $alert")
            }
        }

        if ($health.Recommendations.Count -gt 0) {
            $report.AppendLine()
            $report.AppendLine("RECOMMENDATIONS:")
            foreach ($recommendation in $health.Recommendations) {
                $report.AppendLine("  • $recommendation")
            }
        }

        if ($detailed) {
            $report.AppendLine()
            $report.AppendLine("DETAILED INFORMATION:")
            $report.AppendLine("-" * 40)

            foreach ($component in $health.Components.GetEnumerator()) {
                $report.AppendLine()
                $report.AppendLine("$($component.Key):")

                if ($component.Value.Details) {
                    $detailsJson = $component.Value.Details | ConvertTo-Json -Depth 3 -Compress
                    $report.AppendLine("  Details: $detailsJson")
                }

                if ($component.Value.Issues -and $component.Value.Issues.Count -gt 0) {
                    $report.AppendLine("  Issues:")
                    foreach ($issue in $component.Value.Issues) {
                        $report.AppendLine("    • $issue")
                    }
                }
            }
        }

        return $report.ToString()
    }
}

# Export diagnostic functions for console use
function Get-FileCopierHealth {
    param(
        [hashtable]$Config,
        [object]$Logger,
        [switch]$Detailed
    )

    $diagnostics = [DiagnosticCommands]::new($Config, $Logger)
    return $diagnostics.GetSystemHealth()
}

function Get-FileCopierPerformance {
    param(
        [hashtable]$Config,
        [object]$Logger
    )

    $diagnostics = [DiagnosticCommands]::new($Config, $Logger)
    return $diagnostics.GetPerformanceMetrics()
}

function Test-FileCopierConnectivity {
    param(
        [hashtable]$Config,
        [object]$Logger
    )

    $diagnostics = [DiagnosticCommands]::new($Config, $Logger)
    return $diagnostics.TestConnectivity()
}

function Get-FileCopierErrors {
    param(
        [hashtable]$Config,
        [object]$Logger,
        [int]$Hours = 24
    )

    $diagnostics = [DiagnosticCommands]::new($Config, $Logger)
    return $diagnostics.GetRecentErrors($Hours)
}

function Get-FileCopierReport {
    param(
        [hashtable]$Config,
        [object]$Logger,
        [switch]$Detailed
    )

    $diagnostics = [DiagnosticCommands]::new($Config, $Logger)
    return $diagnostics.GenerateHealthReport($Detailed)
}