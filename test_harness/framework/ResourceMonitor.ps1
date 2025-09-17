# Resource Monitoring Framework for Contention Testing
# Provides cross-platform resource tracking and leak detection

# Base class for resource monitoring
class ResourceMonitor {
    [string] $MonitorId
    [hashtable] $BaselineMetrics
    [hashtable] $CurrentMetrics
    [array] $ResourceHistory
    [datetime] $MonitoringStartTime
    [bool] $IsMonitoring
    [hashtable] $Thresholds
    [string] $Platform

    ResourceMonitor([string] $monitorId) {
        $this.MonitorId = $monitorId
        $this.BaselineMetrics = @{}
        $this.CurrentMetrics = @{}
        $this.ResourceHistory = @()
        $this.IsMonitoring = $false
        $this.Thresholds = $this.GetDefaultThresholds()
        $this.Platform = $this.DetectPlatform()

        Write-TestLog -Message "Resource monitor initialized: $monitorId" -Level "INFO" -TestId "MONITOR"
    }

    [string] DetectPlatform() {
        if ($env:OS -eq $null -and $env:HOME -ne $null) {
            return "Linux"
        } elseif ($env:OS -ne $null) {
            return "Windows"
        } else {
            return "Unknown"
        }
    }

    [hashtable] GetDefaultThresholds() {
        return @{
            MaxMemoryIncreaseMB = 100      # Maximum memory increase allowed (MB)
            MaxFileHandleIncrease = 50     # Maximum file handle increase
            MaxProcessIncrease = 5         # Maximum process count increase
            MonitoringIntervalMs = 1000    # Resource sampling interval
            MaxHistoryEntries = 100        # Maximum history entries to keep
        }
    }

    [void] SetThreshold([string] $thresholdName, [int] $value) {
        $this.Thresholds[$thresholdName] = $value
        Write-TestLog -Message "Set threshold $thresholdName = $value" -Level "INFO" -TestId "MONITOR"
    }

    [void] StartMonitoring() {
        if ($this.IsMonitoring) {
            Write-TestLog -Message "Resource monitoring already active" -Level "WARN" -TestId "MONITOR"
            return
        }

        $this.MonitoringStartTime = Get-Date
        $this.BaselineMetrics = $this.CaptureResourceSnapshot("Baseline")
        $this.CurrentMetrics = $this.BaselineMetrics.Clone()
        $this.IsMonitoring = $true

        Write-TestLog -Message "Resource monitoring started for $($this.MonitorId)" -Level "INFO" -TestId "MONITOR"
        Write-TestLog -Message "Baseline: Memory=$($this.BaselineMetrics.MemoryMB)MB, Handles=$($this.BaselineMetrics.FileHandles), Processes=$($this.BaselineMetrics.ProcessCount)" -Level "INFO" -TestId "MONITOR"
    }

    [void] StopMonitoring() {
        if (-not $this.IsMonitoring) {
            return
        }

        $this.IsMonitoring = $false
        $finalSnapshot = $this.CaptureResourceSnapshot("Final")
        $this.AddResourceSnapshot($finalSnapshot)

        $duration = (Get-Date) - $this.MonitoringStartTime
        Write-TestLog -Message "Resource monitoring stopped after $($duration.TotalSeconds) seconds" -Level "INFO" -TestId "MONITOR"
    }

    [hashtable] CaptureResourceSnapshot([string] $snapshotType) {
        $snapshot = @{
            Timestamp = Get-Date
            SnapshotType = $snapshotType
            MonitorId = $this.MonitorId
            Platform = $this.Platform
            MemoryMB = 0
            FileHandles = 0
            ProcessCount = 0
            DiskSpaceMB = 0
            Error = $null
        }

        try {
            switch ($this.Platform) {
                "Windows" {
                    $snapshot = $this.CaptureWindowsSnapshot($snapshot)
                }
                "Linux" {
                    $snapshot = $this.CaptureLinuxSnapshot($snapshot)
                }
                default {
                    $snapshot.Error = "Unsupported platform: $($this.Platform)"
                }
            }
        }
        catch {
            $snapshot.Error = $_.Exception.Message
            Write-TestLog -Message "Error capturing resource snapshot: $($_.Exception.Message)" -Level "ERROR" -TestId "MONITOR"
        }

        return $snapshot
    }

    [hashtable] CaptureWindowsSnapshot([hashtable] $snapshot) {
        # Memory usage (current process)
        $currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
        $process = Get-Process -Id $currentPid
        $snapshot.MemoryMB = [math]::Round($process.WorkingSet64 / 1MB, 2)

        # File handles (current process)
        $snapshot.FileHandles = $process.HandleCount

        # Process count (all processes)
        $snapshot.ProcessCount = (Get-Process).Count

        # Available disk space (temp directory)
        $tempDrive = (Get-Item $env:TEMP).PSDrive
        $snapshot.DiskSpaceMB = [math]::Round($tempDrive.Free / 1MB, 2)

        return $snapshot
    }

    [hashtable] CaptureLinuxSnapshot([hashtable] $snapshot) {
        # Memory usage (current process)
        $currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
        $memInfo = Get-Content "/proc/$currentPid/status" | Where-Object { $_ -match "VmRSS:" }
        if ($memInfo) {
            $memKB = ($memInfo -split "\s+")[1]
            $snapshot.MemoryMB = [math]::Round([int]$memKB / 1024, 2)
        }

        # File handles (current process)
        $fdCount = 0
        $fdDir = "/proc/$currentPid/fd"
        if (Test-Path $fdDir) {
            $fdCount = (Get-ChildItem $fdDir -ErrorAction SilentlyContinue).Count
        }
        $snapshot.FileHandles = $fdCount

        # Process count (all processes)
        $procCount = (Get-ChildItem "/proc" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^\d+$" }).Count
        $snapshot.ProcessCount = $procCount

        # Available disk space (tmp directory)
        $dfOutput = df /tmp 2>/dev/null | Select-Object -Skip 1
        if ($dfOutput) {
            $fields = $dfOutput -split "\s+"
            if ($fields.Count -ge 4) {
                $availableKB = [int]$fields[3]
                $snapshot.DiskSpaceMB = [math]::Round($availableKB / 1024, 2)
            }
        }

        return $snapshot
    }

    [void] AddResourceSnapshot([hashtable] $snapshot) {
        $this.ResourceHistory += $snapshot
        $this.CurrentMetrics = $snapshot

        # Keep history size manageable
        if ($this.ResourceHistory.Count -gt $this.Thresholds.MaxHistoryEntries) {
            $this.ResourceHistory = $this.ResourceHistory[-$this.Thresholds.MaxHistoryEntries..-1]
        }
    }

    [hashtable] TakeSnapshot([string] $snapshotType = "Manual") {
        $snapshot = $this.CaptureResourceSnapshot($snapshotType)
        $this.AddResourceSnapshot($snapshot)
        return $snapshot
    }

    [hashtable] GetResourceDelta() {
        if (-not $this.BaselineMetrics -or -not $this.CurrentMetrics) {
            return @{ Error = "Baseline or current metrics not available" }
        }

        return @{
            MemoryDeltaMB = $this.CurrentMetrics.MemoryMB - $this.BaselineMetrics.MemoryMB
            FileHandlesDelta = $this.CurrentMetrics.FileHandles - $this.BaselineMetrics.FileHandles
            ProcessCountDelta = $this.CurrentMetrics.ProcessCount - $this.BaselineMetrics.ProcessCount
            DiskSpaceDeltaMB = $this.CurrentMetrics.DiskSpaceMB - $this.BaselineMetrics.DiskSpaceMB
            MonitoringDurationSeconds = if ($this.MonitoringStartTime) { ((Get-Date) - $this.MonitoringStartTime).TotalSeconds } else { 0 }
        }
    }

    [hashtable] DetectResourceLeaks() {
        $delta = $this.GetResourceDelta()
        if ($delta.ContainsKey("Error")) {
            return $delta
        }

        $leaks = @{
            HasLeaks = $false
            LeakTypes = @()
            Summary = @{}
            Violations = @()
        }

        # Check memory leaks
        if ($delta.MemoryDeltaMB -gt $this.Thresholds.MaxMemoryIncreaseMB) {
            $leaks.HasLeaks = $true
            $leaks.LeakTypes += "Memory"
            $leaks.Violations += @{
                Type = "Memory"
                Current = $delta.MemoryDeltaMB
                Threshold = $this.Thresholds.MaxMemoryIncreaseMB
                Severity = if ($delta.MemoryDeltaMB -gt ($this.Thresholds.MaxMemoryIncreaseMB * 2)) { "High" } else { "Medium" }
            }
        }

        # Check file handle leaks
        if ($delta.FileHandlesDelta -gt $this.Thresholds.MaxFileHandleIncrease) {
            $leaks.HasLeaks = $true
            $leaks.LeakTypes += "FileHandles"
            $leaks.Violations += @{
                Type = "FileHandles"
                Current = $delta.FileHandlesDelta
                Threshold = $this.Thresholds.MaxFileHandleIncrease
                Severity = if ($delta.FileHandlesDelta -gt ($this.Thresholds.MaxFileHandleIncrease * 2)) { "High" } else { "Medium" }
            }
        }

        # Check process leaks
        if ($delta.ProcessCountDelta -gt $this.Thresholds.MaxProcessIncrease) {
            $leaks.HasLeaks = $true
            $leaks.LeakTypes += "Processes"
            $leaks.Violations += @{
                Type = "Processes"
                Current = $delta.ProcessCountDelta
                Threshold = $this.Thresholds.MaxProcessIncrease
                Severity = "High"  # Process leaks are always high severity
            }
        }

        # Add summary
        $leaks.Summary = @{
            BaselineMemoryMB = $this.BaselineMetrics.MemoryMB
            CurrentMemoryMB = $this.CurrentMetrics.MemoryMB
            BaselineHandles = $this.BaselineMetrics.FileHandles
            CurrentHandles = $this.CurrentMetrics.FileHandles
            BaselineProcesses = $this.BaselineMetrics.ProcessCount
            CurrentProcesses = $this.CurrentMetrics.ProcessCount
            MonitoringDuration = $delta.MonitoringDurationSeconds
        }

        return $leaks
    }

    [hashtable] GetResourceReport() {
        $report = @{
            MonitorId = $this.MonitorId
            Platform = $this.Platform
            MonitoringActive = $this.IsMonitoring
            StartTime = $this.MonitoringStartTime
            Baseline = $this.BaselineMetrics
            Current = $this.CurrentMetrics
            Delta = $this.GetResourceDelta()
            Leaks = $this.DetectResourceLeaks()
            HistoryCount = $this.ResourceHistory.Count
            Thresholds = $this.Thresholds
        }

        # Add trend analysis if we have enough history
        if ($this.ResourceHistory.Count -gt 5) {
            $report.Trends = $this.AnalyzeTrends()
        }

        return $report
    }

    [hashtable] AnalyzeTrends() {
        $trends = @{
            MemoryTrend = "Stable"
            HandlesTrend = "Stable"
            ProcessesTrend = "Stable"
        }

        if ($this.ResourceHistory.Count -lt 3) {
            return $trends
        }

        # Analyze last 5 snapshots for trends
        $recentHistory = $this.ResourceHistory[-5..-1]

        # Memory trend
        $memoryValues = $recentHistory | ForEach-Object { $_.MemoryMB }
        $memoryTrend = $this.CalculateTrend($memoryValues)
        $trends.MemoryTrend = $memoryTrend

        # Handles trend
        $handleValues = $recentHistory | ForEach-Object { $_.FileHandles }
        $handlesTrend = $this.CalculateTrend($handleValues)
        $trends.HandlesTrend = $handlesTrend

        # Processes trend
        $processValues = $recentHistory | ForEach-Object { $_.ProcessCount }
        $processesTrend = $this.CalculateTrend($processValues)
        $trends.ProcessesTrend = $processesTrend

        return $trends
    }

    [string] CalculateTrend([array] $values) {
        if ($values.Count -lt 2) {
            return "Insufficient Data"
        }

        $first = $values[0]
        $last = $values[-1]
        $change = $last - $first

        # Calculate percentage change
        $percentChange = if ($first -ne 0) { ($change / $first) * 100 } else { 0 }

        if ([Math]::Abs($percentChange) -lt 5) {
            return "Stable"
        } elseif ($percentChange -gt 0) {
            return if ($percentChange -gt 20) { "Rapidly Increasing" } else { "Increasing" }
        } else {
            return if ($percentChange -lt -20) { "Rapidly Decreasing" } else { "Decreasing" }
        }
    }

    [void] LogResourceStatus([string] $context = "Status") {
        $report = $this.GetResourceReport()

        Write-TestLog -Message "Resource Status [$context] - Memory: $($report.Current.MemoryMB)MB, Handles: $($report.Current.FileHandles), Processes: $($report.Current.ProcessCount)" -Level "INFO" -TestId "MONITOR"

        if ($report.Leaks.HasLeaks) {
            Write-TestLog -Message "RESOURCE LEAKS DETECTED: $($report.Leaks.LeakTypes -join ', ')" -Level "ERROR" -TestId "MONITOR"
            foreach ($violation in $report.Leaks.Violations) {
                Write-TestLog -Message "$($violation.Type) leak: $($violation.Current) (threshold: $($violation.Threshold)) - Severity: $($violation.Severity)" -Level "ERROR" -TestId "MONITOR"
            }
        }
    }

    [void] Cleanup() {
        if ($this.IsMonitoring) {
            $this.StopMonitoring()
        }
        Write-TestLog -Message "Resource monitor $($this.MonitorId) cleaned up" -Level "INFO" -TestId "MONITOR"
    }
}

# Factory function for creating resource monitors
function New-ResourceMonitor {
    param(
        [Parameter(Mandatory = $true)]
        [string] $MonitorId,

        [Parameter(Mandatory = $false)]
        [hashtable] $CustomThresholds = @{}
    )

    $monitor = [ResourceMonitor]::new($MonitorId)

    # Apply custom thresholds if provided
    foreach ($threshold in $CustomThresholds.GetEnumerator()) {
        $monitor.SetThreshold($threshold.Key, $threshold.Value)
    }

    return $monitor
}

# Utility function for monitoring a code block
function Invoke-WithResourceMonitoring {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string] $MonitorId,

        [Parameter(Mandatory = $false)]
        [hashtable] $CustomThresholds = @{},

        [Parameter(Mandatory = $false)]
        [switch] $ThrowOnLeaks
    )

    $monitor = New-ResourceMonitor -MonitorId $MonitorId -CustomThresholds $CustomThresholds

    try {
        $monitor.StartMonitoring()
        $result = & $ScriptBlock
        $monitor.StopMonitoring()

        $leaks = $monitor.DetectResourceLeaks()
        if ($leaks.HasLeaks) {
            $monitor.LogResourceStatus("Post-Execution")
            if ($ThrowOnLeaks) {
                throw "Resource leaks detected during execution of $MonitorId"
            }
        }

        return @{
            Result = $result
            ResourceReport = $monitor.GetResourceReport()
            HasLeaks = $leaks.HasLeaks
        }
    }
    finally {
        $monitor.Cleanup()
    }
}

# Cross-platform utilities for resource monitoring
class ResourceMonitorUtils {
    static [hashtable] GetSystemInfo() {
        $info = @{
            Platform = $null
            TotalMemoryMB = 0
            AvailableMemoryMB = 0
            CPUCoreCount = 0
            PowerShellVersion = "7.0+"
            ProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
        }

        try {
            # Detect platform
            if ($env:OS -eq $null -and $env:HOME -ne $null) {
                $info.Platform = "Linux"
                $info = [ResourceMonitorUtils]::GetLinuxSystemInfo($info)
            } elseif ($env:OS -ne $null) {
                $info.Platform = "Windows"
                $info = [ResourceMonitorUtils]::GetWindowsSystemInfo($info)
            } else {
                $info.Platform = "Unknown"
            }
        }
        catch {
            $info.Error = $_.Exception.Message
        }

        return $info
    }

    static [hashtable] GetWindowsSystemInfo([hashtable] $info) {
        # Get system memory info
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $info.TotalMemoryMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 2)
        $info.AvailableMemoryMB = [math]::Round($os.FreePhysicalMemory / 1024, 2)

        # Get CPU core count
        $info.CPUCoreCount = (Get-CimInstance -ClassName Win32_Processor).NumberOfLogicalProcessors

        return $info
    }

    static [hashtable] GetLinuxSystemInfo([hashtable] $info) {
        # Get memory info from /proc/meminfo
        if (Test-Path "/proc/meminfo") {
            $memInfo = Get-Content "/proc/meminfo"
            $totalMem = ($memInfo | Where-Object { $_ -match "MemTotal:" } | ForEach-Object { ($_ -split "\s+")[1] }) -as [int]
            $availMem = ($memInfo | Where-Object { $_ -match "MemAvailable:" } | ForEach-Object { ($_ -split "\s+")[1] }) -as [int]

            if ($totalMem) { $info.TotalMemoryMB = [math]::Round($totalMem / 1024, 2) }
            if ($availMem) { $info.AvailableMemoryMB = [math]::Round($availMem / 1024, 2) }
        }

        # Get CPU core count
        if (Test-Path "/proc/cpuinfo") {
            $cpuInfo = Get-Content "/proc/cpuinfo"
            $coreCount = ($cpuInfo | Where-Object { $_ -match "^processor" }).Count
            $info.CPUCoreCount = $coreCount
        }

        return $info
    }
}