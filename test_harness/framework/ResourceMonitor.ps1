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
            OpenFileCount = 0
            OpenFiles = @()
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

        # File handles (current process) - enhanced tracking
        $snapshot.FileHandles = $process.HandleCount
        $snapshot.OpenFileCount = $this.GetWindowsOpenFileCount($currentPid)
        $snapshot.OpenFiles = $this.GetWindowsOpenFiles($currentPid)

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

        # File handles (current process) - enhanced tracking
        $fdCount = 0
        $fdDir = "/proc/$currentPid/fd"
        if (Test-Path $fdDir) {
            $fdCount = (Get-ChildItem $fdDir -ErrorAction SilentlyContinue).Count
        }
        $snapshot.FileHandles = $fdCount
        $snapshot.OpenFileCount = $fdCount  # On Linux, fd count is the open file count
        $snapshot.OpenFiles = $this.GetLinuxOpenFiles($currentPid)

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
            DetailedAnalysis = @{}
        }

        # Enhanced memory leak detection
        $memoryLeaks = $this.DetectMemoryLeaks($this.BaselineMetrics, $this.CurrentMetrics)
        if ($memoryLeaks.HasLeaks) {
            $leaks.HasLeaks = $true
            $leaks.LeakTypes += "Memory"
            $leaks.Violations += @{
                Type = "Memory"
                Current = $memoryLeaks.MemoryIncreaseMB
                Threshold = $this.Thresholds.MaxMemoryIncreaseMB
                Severity = $memoryLeaks.LeakSeverity
                GrowthRate = $memoryLeaks.GrowthRate
                Recommendations = $memoryLeaks.Recommendations
            }
            $leaks.DetailedAnalysis.Memory = $memoryLeaks
        }

        # Enhanced file handle leak detection
        $handleLeaks = $this.DetectFileHandleLeaks($this.BaselineMetrics, $this.CurrentMetrics)
        if ($handleLeaks.HasLeaks) {
            $leaks.HasLeaks = $true
            $leaks.LeakTypes += "FileHandles"
            $leaks.Violations += @{
                Type = "FileHandles"
                Current = $handleLeaks.LeakCount
                Threshold = $this.Thresholds.MaxFileHandleIncrease
                Severity = ($handleLeaks.LeakDetails | ForEach-Object { $_.Severity } | Sort-Object)[-1]  # Highest severity
                SuspiciousFiles = $handleLeaks.SuspiciousFiles.Count
                Recommendations = $handleLeaks.Recommendations
            }
            $leaks.DetailedAnalysis.FileHandles = $handleLeaks
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
                Recommendations = @("Check for orphaned background processes", "Review process cleanup in test teardown")
            }
        }

        # Enhanced summary with memory details
        $memoryDetails = $this.GetMemoryUsageDetails()
        $leaks.Summary = @{
            BaselineMemoryMB = $this.BaselineMetrics.MemoryMB
            CurrentMemoryMB = $this.CurrentMetrics.MemoryMB
            SystemMemoryPressure = $memoryDetails.MemoryPressure
            ProcessMemoryPercentage = $memoryDetails.ProcessMemoryPercentage
            BaselineHandles = $this.BaselineMetrics.FileHandles
            CurrentHandles = $this.CurrentMetrics.FileHandles
            BaselineOpenFiles = if ($this.BaselineMetrics.OpenFiles) { $this.BaselineMetrics.OpenFiles.Count } else { 0 }
            CurrentOpenFiles = if ($this.CurrentMetrics.OpenFiles) { $this.CurrentMetrics.OpenFiles.Count } else { 0 }
            BaselineProcesses = $this.BaselineMetrics.ProcessCount
            CurrentProcesses = $this.CurrentMetrics.ProcessCount
            MonitoringDuration = $delta.MonitoringDurationSeconds
            SystemTotalMemoryMB = $memoryDetails.SystemTotalMemoryMB
            SystemAvailableMemoryMB = $memoryDetails.SystemAvailableMemoryMB
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
        $memoryDetails = $this.GetMemoryUsageDetails()

        # Log basic resource status with enhanced information
        $baseMsg = "Resource Status [$context] - Memory: $($report.Current.MemoryMB)MB"
        if ($memoryDetails.ProcessMemoryPercentage -gt 0) {
            $baseMsg += " ($($memoryDetails.ProcessMemoryPercentage)% of system)"
        }
        $baseMsg += ", Handles: $($report.Current.FileHandles)"
        if ($report.Current.OpenFiles) {
            $baseMsg += " (Files: $($report.Current.OpenFiles.Count))"
        }
        $baseMsg += ", Processes: $($report.Current.ProcessCount)"
        if ($memoryDetails.MemoryPressure -ne "Low") {
            $baseMsg += " - Memory Pressure: $($memoryDetails.MemoryPressure)"
        }

        Write-TestLog -Message $baseMsg -Level "INFO" -TestId "MONITOR"

        # Log detailed leak information
        if ($report.Leaks.HasLeaks) {
            Write-TestLog -Message "RESOURCE LEAKS DETECTED: $($report.Leaks.LeakTypes -join ', ')" -Level "ERROR" -TestId "MONITOR"

            foreach ($violation in $report.Leaks.Violations) {
                $leakMsg = "$($violation.Type) leak: $($violation.Current) (threshold: $($violation.Threshold)) - Severity: $($violation.Severity)"

                # Add specific details for each leak type
                if ($violation.Type -eq "Memory" -and $violation.GrowthRate -gt 0) {
                    $leakMsg += " - Growth: $($violation.GrowthRate) MB/min"
                }
                if ($violation.Type -eq "FileHandles" -and $violation.SuspiciousFiles -gt 0) {
                    $leakMsg += " - Suspicious files: $($violation.SuspiciousFiles)"
                }

                Write-TestLog -Message $leakMsg -Level "ERROR" -TestId "MONITOR"

                # Log recommendations for this violation
                if ($violation.Recommendations -and $violation.Recommendations.Count -gt 0) {
                    foreach ($recommendation in $violation.Recommendations) {
                        Write-TestLog -Message "  Recommendation: $recommendation" -Level "WARN" -TestId "MONITOR"
                    }
                }
            }

            # Log system memory status if under pressure
            if ($memoryDetails.MemoryPressure -ne "Low") {
                Write-TestLog -Message "System Memory Status: $($memoryDetails.SystemAvailableMemoryMB)MB available of $($memoryDetails.SystemTotalMemoryMB)MB total" -Level "WARN" -TestId "MONITOR"
            }
        }
    }

    [void] Cleanup() {
        if ($this.IsMonitoring) {
            $this.StopMonitoring()
        }
        Write-TestLog -Message "Resource monitor $($this.MonitorId) cleaned up" -Level "INFO" -TestId "MONITOR"
    }

    # Enhanced file handle tracking methods
    [int] GetWindowsOpenFileCount([int] $processId) {
        try {
            # Use Get-Process to get handle count as a fallback
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($process) {
                return $process.HandleCount
            }
            return 0
        }
        catch {
            Write-TestLog -Message "Error getting Windows open file count: $($_.Exception.Message)" -Level "WARN" -TestId "MONITOR"
            return 0
        }
    }

    [array] GetWindowsOpenFiles([int] $processId) {
        $openFiles = @()
        try {
            # Use WMI to get more detailed information about open handles
            $handles = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
            if ($handles) {
                $openFiles += @{
                    Type = "Process"
                    Path = $handles.ExecutablePath
                    ProcessId = $processId
                    HandleCount = (Get-Process -Id $processId -ErrorAction SilentlyContinue).HandleCount
                }
            }

            # Try to get file handles using PowerShell's file system provider
            # This is limited but gives us some insight
            $tempPath = $env:TEMP
            if (Test-Path $tempPath) {
                $tempFiles = Get-ChildItem $tempPath -File -ErrorAction SilentlyContinue | Where-Object {
                    try {
                        $fileStream = [System.IO.File]::Open($_.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                        $fileStream.Close()
                        return $false  # File is not locked
                    }
                    catch {
                        return $true   # File is locked/in use
                    }
                }

                foreach ($file in $tempFiles) {
                    $openFiles += @{
                        Type = "File"
                        Path = $file.FullName
                        Size = $file.Length
                        LastModified = $file.LastWriteTime
                    }
                }
            }
        }
        catch {
            Write-TestLog -Message "Error getting Windows open files: $($_.Exception.Message)" -Level "WARN" -TestId "MONITOR"
        }

        return $openFiles
    }

    [array] GetLinuxOpenFiles([int] $processId) {
        $openFiles = @()
        try {
            $fdDir = "/proc/$processId/fd"
            if (Test-Path $fdDir) {
                $fileDescriptors = Get-ChildItem $fdDir -ErrorAction SilentlyContinue
                foreach ($fd in $fileDescriptors) {
                    try {
                        $target = $fd.Target
                        if ($target) {
                            $openFiles += @{
                                Type = if ($target -match "^/") { "File" } elseif ($target -match "socket:") { "Socket" } elseif ($target -match "pipe:") { "Pipe" } else { "Other" }
                                Path = $target
                                FileDescriptor = $fd.Name
                            }
                        }
                    }
                    catch {
                        # Some file descriptors may not be accessible
                        continue
                    }
                }
            }
        }
        catch {
            Write-TestLog -Message "Error getting Linux open files: $($_.Exception.Message)" -Level "WARN" -TestId "MONITOR"
        }

        return $openFiles
    }

    # Memory monitoring enhancements
    [hashtable] GetMemoryUsageDetails() {
        $details = @{
            CurrentProcessMemoryMB = 0
            SystemTotalMemoryMB = 0
            SystemAvailableMemoryMB = 0
            MemoryPressure = "Low"
            ProcessMemoryPercentage = 0
            Error = $null
        }

        try {
            $currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id

            switch ($this.Platform) {
                "Windows" {
                    $process = Get-Process -Id $currentPid
                    $details.CurrentProcessMemoryMB = [math]::Round($process.WorkingSet64 / 1MB, 2)

                    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
                    if ($os) {
                        $details.SystemTotalMemoryMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 2)
                        $details.SystemAvailableMemoryMB = [math]::Round($os.FreePhysicalMemory / 1024, 2)
                    }
                }
                "Linux" {
                    # Get current process memory
                    $memInfo = Get-Content "/proc/$currentPid/status" -ErrorAction SilentlyContinue | Where-Object { $_ -match "VmRSS:" }
                    if ($memInfo) {
                        $memKB = ($memInfo -split "\s+")[1]
                        $details.CurrentProcessMemoryMB = [math]::Round([int]$memKB / 1024, 2)
                    }

                    # Get system memory
                    if (Test-Path "/proc/meminfo") {
                        $systemMemInfo = Get-Content "/proc/meminfo"
                        $totalMem = ($systemMemInfo | Where-Object { $_ -match "MemTotal:" } | ForEach-Object { ($_ -split "\s+")[1] }) -as [int]
                        $availMem = ($systemMemInfo | Where-Object { $_ -match "MemAvailable:" } | ForEach-Object { ($_ -split "\s+")[1] }) -as [int]

                        if ($totalMem) { $details.SystemTotalMemoryMB = [math]::Round($totalMem / 1024, 2) }
                        if ($availMem) { $details.SystemAvailableMemoryMB = [math]::Round($availMem / 1024, 2) }
                    }
                }
            }

            # Calculate memory pressure and percentage
            if ($details.SystemTotalMemoryMB -gt 0) {
                $details.ProcessMemoryPercentage = [math]::Round(($details.CurrentProcessMemoryMB / $details.SystemTotalMemoryMB) * 100, 2)

                $availablePercent = ($details.SystemAvailableMemoryMB / $details.SystemTotalMemoryMB) * 100
                $details.MemoryPressure = if ($availablePercent -gt 50) { "Low" } elseif ($availablePercent -gt 20) { "Medium" } else { "High" }
            }
        }
        catch {
            $details.Error = $_.Exception.Message
            Write-TestLog -Message "Error getting memory usage details: $($_.Exception.Message)" -Level "WARN" -TestId "MONITOR"
        }

        return $details
    }

    # File handle leak detection algorithms
    [hashtable] DetectFileHandleLeaks([hashtable] $baselineSnapshot, [hashtable] $currentSnapshot) {
        $leakAnalysis = @{
            HasLeaks = $false
            LeakCount = 0
            LeakDetails = @()
            SuspiciousFiles = @()
            Recommendations = @()
        }

        try {
            # Compare file handle counts
            $handleDelta = $currentSnapshot.FileHandles - $baselineSnapshot.FileHandles
            $openFileDelta = $currentSnapshot.OpenFileCount - $baselineSnapshot.OpenFileCount

            if ($handleDelta -gt $this.Thresholds.MaxFileHandleIncrease) {
                $leakAnalysis.HasLeaks = $true
                $leakAnalysis.LeakCount = $handleDelta

                $leakAnalysis.LeakDetails += @{
                    Type = "FileHandles"
                    BaselineCount = $baselineSnapshot.FileHandles
                    CurrentCount = $currentSnapshot.FileHandles
                    Delta = $handleDelta
                    Severity = if ($handleDelta -gt ($this.Thresholds.MaxFileHandleIncrease * 2)) { "High" } else { "Medium" }
                }
            }

            # Analyze open files for suspicious patterns
            if ($currentSnapshot.OpenFiles -and $baselineSnapshot.OpenFiles) {
                $currentFiles = $currentSnapshot.OpenFiles | Where-Object { $_.Type -eq "File" }
                $baselineFiles = $baselineSnapshot.OpenFiles | Where-Object { $_.Type -eq "File" }

                # Find files that exist in current but not in baseline
                $newFiles = $currentFiles | Where-Object {
                    $currentFile = $_
                    -not ($baselineFiles | Where-Object { $_.Path -eq $currentFile.Path })
                }

                foreach ($file in $newFiles) {
                    $leakAnalysis.SuspiciousFiles += @{
                        Path = $file.Path
                        Type = $file.Type
                        DetectedAt = Get-Date
                        Reason = "New file handle not present in baseline"
                    }
                }
            }

            # Generate recommendations
            if ($leakAnalysis.HasLeaks) {
                $leakAnalysis.Recommendations += "Review file operations for proper handle disposal"
                $leakAnalysis.Recommendations += "Ensure all file streams are properly closed in finally blocks"
                $leakAnalysis.Recommendations += "Check for abandoned background processes"

                if ($leakAnalysis.SuspiciousFiles.Count -gt 0) {
                    $leakAnalysis.Recommendations += "Investigate the $($leakAnalysis.SuspiciousFiles.Count) suspicious file(s) listed"
                }
            }
        }
        catch {
            $leakAnalysis.Error = $_.Exception.Message
            Write-TestLog -Message "Error detecting file handle leaks: $($_.Exception.Message)" -Level "ERROR" -TestId "MONITOR"
        }

        return $leakAnalysis
    }

    # Memory leak detection algorithms
    [hashtable] DetectMemoryLeaks([hashtable] $baselineSnapshot, [hashtable] $currentSnapshot) {
        $leakAnalysis = @{
            HasLeaks = $false
            MemoryIncreaseMB = 0
            GrowthRate = 0
            LeakSeverity = "None"
            Recommendations = @()
        }

        try {
            $memoryDelta = $currentSnapshot.MemoryMB - $baselineSnapshot.MemoryMB
            $leakAnalysis.MemoryIncreaseMB = $memoryDelta

            if ($memoryDelta -gt $this.Thresholds.MaxMemoryIncreaseMB) {
                $leakAnalysis.HasLeaks = $true

                # Calculate growth rate if we have timing information
                if ($baselineSnapshot.Timestamp -and $currentSnapshot.Timestamp) {
                    $timeDelta = ($currentSnapshot.Timestamp - $baselineSnapshot.Timestamp).TotalMinutes
                    if ($timeDelta -gt 0) {
                        $leakAnalysis.GrowthRate = [math]::Round($memoryDelta / $timeDelta, 2)  # MB per minute
                    }
                }

                # Determine severity
                $leakAnalysis.LeakSeverity = if ($memoryDelta -gt ($this.Thresholds.MaxMemoryIncreaseMB * 3)) {
                    "Critical"
                } elseif ($memoryDelta -gt ($this.Thresholds.MaxMemoryIncreaseMB * 2)) {
                    "High"
                } else {
                    "Medium"
                }

                # Generate recommendations based on growth pattern
                $leakAnalysis.Recommendations += "Monitor memory usage patterns over longer periods"
                $leakAnalysis.Recommendations += "Review object lifecycle management in test operations"

                if ($leakAnalysis.GrowthRate -gt 1) {
                    $leakAnalysis.Recommendations += "URGENT: High memory growth rate detected ($($leakAnalysis.GrowthRate) MB/min)"
                }

                if ($leakAnalysis.LeakSeverity -eq "Critical") {
                    $leakAnalysis.Recommendations += "CRITICAL: Consider restarting the test process to prevent system instability"
                }
            }
        }
        catch {
            $leakAnalysis.Error = $_.Exception.Message
            Write-TestLog -Message "Error detecting memory leaks: $($_.Exception.Message)" -Level "ERROR" -TestId "MONITOR"
        }

        return $leakAnalysis
    }

    # Validation and testing methods
    [hashtable] ValidateEnhancedCapabilities() {
        $validation = @{
            Success = $true
            Capabilities = @{}
            Errors = @()
            Platform = $this.Platform
        }

        try {
            # Test basic monitoring
            Write-TestLog -Message "Validating enhanced resource monitoring capabilities..." -Level "INFO" -TestId "MONITOR"

            # Test memory details
            $memDetails = $this.GetMemoryUsageDetails()
            $validation.Capabilities.MemoryMonitoring = @{
                Available = ($memDetails.Error -eq $null)
                Details = $memDetails
            }

            # Test file handle tracking
            $currentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
            if ($this.Platform -eq "Windows") {
                $fileCount = $this.GetWindowsOpenFileCount($currentPid)
                $openFiles = $this.GetWindowsOpenFiles($currentPid)
                $validation.Capabilities.FileHandleTracking = @{
                    Available = $true
                    OpenFileCount = $fileCount
                    TrackedFiles = $openFiles.Count
                }
            } else {
                $openFiles = $this.GetLinuxOpenFiles($currentPid)
                $validation.Capabilities.FileHandleTracking = @{
                    Available = $true
                    TrackedFiles = $openFiles.Count
                }
            }

            # Test leak detection algorithms
            $baselineSnapshot = $this.CaptureResourceSnapshot("Validation-Baseline")
            Start-Sleep -Milliseconds 100  # Small delay to ensure different timestamps
            $currentSnapshot = $this.CaptureResourceSnapshot("Validation-Current")

            $memoryLeaks = $this.DetectMemoryLeaks($baselineSnapshot, $currentSnapshot)
            $handleLeaks = $this.DetectFileHandleLeaks($baselineSnapshot, $currentSnapshot)

            $validation.Capabilities.LeakDetection = @{
                MemoryAnalysis = ($memoryLeaks.ContainsKey("Error") -eq $false)
                FileHandleAnalysis = ($handleLeaks.ContainsKey("Error") -eq $false)
                AlgorithmsAvailable = $true
            }

            # Test trend analysis
            $this.ResourceHistory += $baselineSnapshot
            $this.ResourceHistory += $currentSnapshot
            $trends = $this.AnalyzeTrends()
            $validation.Capabilities.TrendAnalysis = @{
                Available = $true
                TrendsCalculated = ($trends.MemoryTrend -ne $null)
            }

            Write-TestLog -Message "Enhanced resource monitoring validation completed successfully" -Level "INFO" -TestId "MONITOR"
        }
        catch {
            $validation.Success = $false
            $validation.Errors += $_.Exception.Message
            Write-TestLog -Message "Enhanced resource monitoring validation failed: $($_.Exception.Message)" -Level "ERROR" -TestId "MONITOR"
        }

        return $validation
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