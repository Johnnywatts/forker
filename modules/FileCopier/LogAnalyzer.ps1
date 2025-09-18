using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.Threading
using namespace System.IO
using namespace System.Text
using namespace System.Text.RegularExpressions

enum LogLevel {
    Debug = 0
    Information = 1
    Warning = 2
    Error = 3
    Critical = 4
}

class LogEntry {
    [DateTime] $Timestamp
    [LogLevel] $Level
    [string] $Message
    [string] $Category
    [hashtable] $Properties
    [string] $RawLine

    LogEntry([string]$rawLine) {
        $this.RawLine = $rawLine
        $this.Properties = @{}
        $this.ParseLogLine($rawLine)
    }

    [void] ParseLogLine([string]$line) {
        # Parse standard log format: [timestamp] [level] [category] message
        $pattern = '^\[([^\]]+)\]\s*\[([^\]]+)\]\s*(?:\[([^\]]+)\])?\s*(.*)$'

        if ($line -match $pattern) {
            try {
                $this.Timestamp = [DateTime]::ParseExact($matches[1], "yyyy-MM-dd HH:mm:ss", $null)
            } catch {
                $this.Timestamp = Get-Date
            }

            $this.Level = switch ($matches[2].ToUpper()) {
                'DEBUG' { [LogLevel]::Debug }
                'INFO' { [LogLevel]::Information }
                'INFORMATION' { [LogLevel]::Information }
                'WARN' { [LogLevel]::Warning }
                'WARNING' { [LogLevel]::Warning }
                'ERROR' { [LogLevel]::Error }
                'CRITICAL' { [LogLevel]::Critical }
                'FATAL' { [LogLevel]::Critical }
                default { [LogLevel]::Information }
            }

            $this.Category = if ($matches[3]) { $matches[3] } else { "General" }
            $this.Message = $matches[4]

            # Extract additional properties from structured messages
            $this.ExtractProperties()
        } else {
            # Fallback for unstructured lines
            $this.Timestamp = Get-Date
            $this.Level = [LogLevel]::Information
            $this.Category = "General"
            $this.Message = $line
        }
    }

    [void] ExtractProperties() {
        # Extract key-value pairs from message
        $kvPattern = '(\w+)=([^\s,]+)'
        $matches = [Regex]::Matches($this.Message, $kvPattern)

        foreach ($match in $matches) {
            $key = $match.Groups[1].Value
            $value = $match.Groups[2].Value
            $this.Properties[$key] = $value
        }

        # Extract file paths
        if ($this.Message -match '([A-Za-z]:\\[^\\/:*?"<>|\r\n]+(?:\\[^\\/:*?"<>|\r\n]+)*\.[A-Za-z0-9]+)') {
            $this.Properties['FilePath'] = $matches[1]
        }

        # Extract durations
        if ($this.Message -match '(\d+(?:\.\d+)?)\s*(seconds?|ms|milliseconds?)') {
            $this.Properties['Duration'] = $matches[1]
            $this.Properties['DurationUnit'] = $matches[2]
        }

        # Extract file sizes
        if ($this.Message -match '(\d+(?:\.\d+)?)\s*(MB|GB|KB|bytes?)') {
            $this.Properties['FileSize'] = $matches[1]
            $this.Properties['FileSizeUnit'] = $matches[2]
        }
    }
}

class LogAnalysisReport {
    [DateTime] $GeneratedAt
    [string] $AnalysisPeriod
    [int] $TotalLogEntries
    [hashtable] $LogLevelCounts
    [hashtable] $CategoryCounts
    [hashtable] $ErrorAnalysis
    [hashtable] $PerformanceAnalysis
    [hashtable] $TrendAnalysis
    [LogEntry[]] $CriticalEvents
    [LogEntry[]] $RecentErrors
    [hashtable] $Recommendations

    LogAnalysisReport() {
        $this.GeneratedAt = Get-Date
        $this.LogLevelCounts = @{}
        $this.CategoryCounts = @{}
        $this.ErrorAnalysis = @{}
        $this.PerformanceAnalysis = @{}
        $this.TrendAnalysis = @{}
        $this.CriticalEvents = @()
        $this.RecentErrors = @()
        $this.Recommendations = @{}
    }
}

class LogAnalyzer {
    [hashtable] $Config
    [object] $Logger
    [string] $LogFilePath
    [string] $AuditDirectory
    [List[LogEntry]] $LogEntries
    [System.Threading.Timer] $AnalysisTimer
    [bool] $IsRunning
    [object] $LockObject

    LogAnalyzer([hashtable]$config, [object]$logger) {
        $this.Config = $config
        $this.Logger = $logger
        $this.LogFilePath = $config['Logging']['FilePath']
        $this.AuditDirectory = $config['Logging']['AuditDirectory']
        $this.LogEntries = [List[LogEntry]]::new()
        $this.IsRunning = $false
        $this.LockObject = [object]::new()
    }

    [void] Start([int]$analysisIntervalMinutes = 60) {
        if ($this.IsRunning) {
            $this.Logger.LogWarning("Log analyzer is already running")
            return
        }

        try {
            $this.IsRunning = $true

            # Start analysis timer
            $this.AnalysisTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{
                    param($state)
                    $analyzer = $state
                    $analyzer.PerformAnalysis()
                },
                $this,
                [TimeSpan]::FromMinutes(5),  # Initial delay
                [TimeSpan]::FromMinutes($analysisIntervalMinutes)  # Analysis interval
            )

            $this.Logger.LogInformation("Log analyzer started with $analysisIntervalMinutes minute interval")
        }
        catch {
            $this.IsRunning = $false
            $this.Logger.LogError("Failed to start log analyzer", $_.Exception)
            throw
        }
    }

    [void] Stop() {
        if (-not $this.IsRunning) {
            return
        }

        try {
            $this.IsRunning = $false

            if ($this.AnalysisTimer) {
                $this.AnalysisTimer.Dispose()
                $this.AnalysisTimer = $null
            }

            $this.Logger.LogInformation("Log analyzer stopped")
        }
        catch {
            $this.Logger.LogError("Error stopping log analyzer", $_.Exception)
        }
    }

    [void] PerformAnalysis() {
        try {
            # Load recent log entries
            $this.LoadRecentLogEntries()

            # Generate analysis report
            $report = $this.GenerateAnalysisReport()

            # Save report
            $this.SaveAnalysisReport($report)

            # Check for critical issues
            $this.CheckForCriticalIssues($report)

            $this.Logger.LogDebug("Log analysis completed - analyzed $($this.LogEntries.Count) entries")
        }
        catch {
            $this.Logger.LogError("Error during log analysis", $_.Exception)
        }
    }

    [void] LoadRecentLogEntries([int]$hours = 24) {
        try {
            lock ($this.LockObject) {
                $this.LogEntries.Clear()

                if (-not (Test-Path $this.LogFilePath)) {
                    return
                }

                $cutoffTime = (Get-Date).AddHours(-$hours)
                $lines = Get-Content $this.LogFilePath -Tail 5000  # Limit to recent entries

                foreach ($line in $lines) {
                    if ([string]::IsNullOrWhiteSpace($line)) {
                        continue
                    }

                    $entry = [LogEntry]::new($line)

                    if ($entry.Timestamp -ge $cutoffTime) {
                        $this.LogEntries.Add($entry)
                    }
                }

                # Sort by timestamp
                $this.LogEntries = [List[LogEntry]]::new(($this.LogEntries | Sort-Object Timestamp))
            }
        }
        catch {
            $this.Logger.LogError("Error loading log entries", $_.Exception)
        }
    }

    [LogAnalysisReport] GenerateAnalysisReport() {
        $report = [LogAnalysisReport]::new()

        lock ($this.LockObject) {
            $report.TotalLogEntries = $this.LogEntries.Count
            $report.AnalysisPeriod = "Last 24 hours"

            # Analyze log levels
            $report.LogLevelCounts = $this.AnalyzeLogLevels()

            # Analyze categories
            $report.CategoryCounts = $this.AnalyzeCategories()

            # Error analysis
            $report.ErrorAnalysis = $this.AnalyzeErrors()

            # Performance analysis
            $report.PerformanceAnalysis = $this.AnalyzePerformance()

            # Trend analysis
            $report.TrendAnalysis = $this.AnalyzeTrends()

            # Critical events
            $report.CriticalEvents = $this.FindCriticalEvents()

            # Recent errors
            $report.RecentErrors = $this.FindRecentErrors()

            # Generate recommendations
            $report.Recommendations = $this.GenerateRecommendations($report)
        }

        return $report
    }

    [hashtable] AnalyzeLogLevels() {
        $counts = @{
            Debug = 0
            Information = 0
            Warning = 0
            Error = 0
            Critical = 0
        }

        foreach ($entry in $this.LogEntries) {
            $counts[$entry.Level.ToString()]++
        }

        return $counts
    }

    [hashtable] AnalyzeCategories() {
        $counts = @{}

        foreach ($entry in $this.LogEntries) {
            if ($counts.ContainsKey($entry.Category)) {
                $counts[$entry.Category]++
            } else {
                $counts[$entry.Category] = 1
            }
        }

        return $counts
    }

    [hashtable] AnalyzeErrors() {
        $errors = $this.LogEntries | Where-Object { $_.Level -in @([LogLevel]::Error, [LogLevel]::Critical) }

        $analysis = @{
            TotalErrors = $errors.Count
            ErrorsByCategory = @{}
            CommonErrorPatterns = @{}
            ErrorFrequency = @{}
        }

        # Group errors by category
        foreach ($error in $errors) {
            if ($analysis.ErrorsByCategory.ContainsKey($error.Category)) {
                $analysis.ErrorsByCategory[$error.Category]++
            } else {
                $analysis.ErrorsByCategory[$error.Category] = 1
            }
        }

        # Find common error patterns
        $errorMessages = $errors | ForEach-Object { $_.Message }
        $patterns = @(
            'hash.*mismatch',
            'access.*denied',
            'file.*not.*found',
            'network.*not.*found',
            'sharing.*violation',
            'disk.*full',
            'timeout',
            'connection.*failed'
        )

        foreach ($pattern in $patterns) {
            $matches = $errorMessages | Where-Object { $_ -match $pattern }
            if ($matches.Count -gt 0) {
                $analysis.CommonErrorPatterns[$pattern] = $matches.Count
            }
        }

        # Error frequency over time (hourly)
        $hourlyErrors = $errors | Group-Object { $_.Timestamp.Hour } | ForEach-Object {
            @{
                Hour = $_.Name
                Count = $_.Count
            }
        }
        $analysis.ErrorFrequency = $hourlyErrors

        return $analysis
    }

    [hashtable] AnalyzePerformance() {
        $performanceEntries = $this.LogEntries | Where-Object {
            $_.Properties.ContainsKey('Duration') -or
            $_.Properties.ContainsKey('FileSize') -or
            $_.Message -match 'processing.*completed|copy.*completed'
        }

        $analysis = @{
            TotalPerformanceEvents = $performanceEntries.Count
            ProcessingTimes = @()
            FileSizes = @()
            ThroughputAnalysis = @{}
            PerformanceTrends = @{}
        }

        # Extract processing times
        foreach ($entry in $performanceEntries) {
            if ($entry.Properties.ContainsKey('Duration')) {
                $duration = [double]$entry.Properties['Duration']
                $unit = $entry.Properties['DurationUnit']

                # Normalize to seconds
                $seconds = switch ($unit) {
                    'ms' { $duration / 1000 }
                    'milliseconds' { $duration / 1000 }
                    default { $duration }
                }

                $analysis.ProcessingTimes += $seconds
            }
        }

        # Calculate statistics
        if ($analysis.ProcessingTimes.Count -gt 0) {
            $times = $analysis.ProcessingTimes | Sort-Object
            $analysis.ThroughputAnalysis = @{
                AverageProcessingTime = ($times | Measure-Object -Average).Average
                MedianProcessingTime = $times[($times.Count / 2)]
                MinProcessingTime = ($times | Measure-Object -Minimum).Minimum
                MaxProcessingTime = ($times | Measure-Object -Maximum).Maximum
                TotalEvents = $times.Count
            }
        }

        return $analysis
    }

    [hashtable] AnalyzeTrends() {
        $analysis = @{
            HourlyActivity = @{}
            DailyPatterns = @{}
            ErrorTrends = @{}
            PerformanceTrends = @{}
        }

        # Hourly activity analysis
        $hourlyGroups = $this.LogEntries | Group-Object { $_.Timestamp.Hour }
        foreach ($group in $hourlyGroups) {
            $analysis.HourlyActivity[$group.Name] = @{
                TotalEvents = $group.Count
                Errors = ($group.Group | Where-Object { $_.Level -in @([LogLevel]::Error, [LogLevel]::Critical) }).Count
                Warnings = ($group.Group | Where-Object { $_.Level -eq [LogLevel]::Warning }).Count
            }
        }

        # Error trends over time
        $errors = $this.LogEntries | Where-Object { $_.Level -in @([LogLevel]::Error, [LogLevel]::Critical) }
        $errorsByHour = $errors | Group-Object { $_.Timestamp.ToString("HH:00") }

        foreach ($group in $errorsByHour) {
            $analysis.ErrorTrends[$group.Name] = $group.Count
        }

        return $analysis
    }

    [LogEntry[]] FindCriticalEvents() {
        $criticalEvents = $this.LogEntries | Where-Object {
            $_.Level -eq [LogLevel]::Critical -or
            $_.Message -match 'critical|fatal|emergency|service.*stopped|corruption|data.*loss'
        }

        return $criticalEvents | Sort-Object Timestamp -Descending | Select-Object -First 50
    }

    [LogEntry[]] FindRecentErrors() {
        $recentCutoff = (Get-Date).AddHours(-6)
        $recentErrors = $this.LogEntries | Where-Object {
            $_.Level -eq [LogLevel]::Error -and $_.Timestamp -ge $recentCutoff
        }

        return $recentErrors | Sort-Object Timestamp -Descending | Select-Object -First 20
    }

    [hashtable] GenerateRecommendations([LogAnalysisReport]$report) {
        $recommendations = @{
            Priority = @()
            Performance = @()
            Maintenance = @()
            Configuration = @()
        }

        # Priority recommendations based on errors
        if ($report.ErrorAnalysis.TotalErrors -gt 10) {
            $recommendations.Priority += "High error count detected ($($report.ErrorAnalysis.TotalErrors) errors). Investigate root causes."
        }

        if ($report.CriticalEvents.Count -gt 0) {
            $recommendations.Priority += "Critical events found. Immediate attention required."
        }

        # Performance recommendations
        if ($report.PerformanceAnalysis.ThroughputAnalysis.AverageProcessingTime -gt 300) {
            $recommendations.Performance += "Average processing time is high. Consider optimizing configuration."
        }

        # Common error pattern recommendations
        foreach ($pattern in $report.ErrorAnalysis.CommonErrorPatterns.Keys) {
            $count = $report.ErrorAnalysis.CommonErrorPatterns[$pattern]

            switch -Regex ($pattern) {
                'hash.*mismatch' {
                    $recommendations.Configuration += "Hash verification failures detected ($count). Check disk integrity."
                }
                'access.*denied' {
                    $recommendations.Configuration += "Permission errors detected ($count). Review service account permissions."
                }
                'network.*not.*found' {
                    $recommendations.Configuration += "Network connectivity issues detected ($count). Check network paths."
                }
                'sharing.*violation' {
                    $recommendations.Configuration += "File sharing violations detected ($count). Check for file locks."
                }
            }
        }

        # Maintenance recommendations
        if ($report.LogLevelCounts.Warning -gt 50) {
            $recommendations.Maintenance += "High warning count. Review and address warning conditions."
        }

        $logFileSize = if (Test-Path $this.LogFilePath) {
            [math]::Round((Get-Item $this.LogFilePath).Length / 1MB, 2)
        } else { 0 }

        if ($logFileSize -gt 45) {  # Close to 50MB limit
            $recommendations.Maintenance += "Log file is approaching size limit ($logFileSize MB). Monitor log rotation."
        }

        return $recommendations
    }

    [void] SaveAnalysisReport([LogAnalysisReport]$report) {
        try {
            $reportDir = Join-Path $this.AuditDirectory "Reports"
            if (-not (Test-Path $reportDir)) {
                New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
            }

            $timestamp = $report.GeneratedAt.ToString("yyyyMMdd_HHmmss")
            $reportPath = Join-Path $reportDir "log-analysis-$timestamp.json"

            # Convert report to JSON
            $reportData = @{
                GeneratedAt = $report.GeneratedAt.ToString("yyyy-MM-dd HH:mm:ss")
                AnalysisPeriod = $report.AnalysisPeriod
                TotalLogEntries = $report.TotalLogEntries
                LogLevelCounts = $report.LogLevelCounts
                CategoryCounts = $report.CategoryCounts
                ErrorAnalysis = $report.ErrorAnalysis
                PerformanceAnalysis = $report.PerformanceAnalysis
                TrendAnalysis = $report.TrendAnalysis
                CriticalEvents = $report.CriticalEvents | ForEach-Object { $_.ToHashtable() }
                RecentErrors = $report.RecentErrors | ForEach-Object { $_.ToHashtable() }
                Recommendations = $report.Recommendations
            }

            $reportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $reportPath -Encoding UTF8

            $this.Logger.LogDebug("Log analysis report saved to $reportPath")
        }
        catch {
            $this.Logger.LogError("Error saving analysis report", $_.Exception)
        }
    }

    [void] CheckForCriticalIssues([LogAnalysisReport]$report) {
        try {
            # Check for critical thresholds
            if ($report.CriticalEvents.Count -gt 0) {
                $this.Logger.LogError("Critical events detected in log analysis: $($report.CriticalEvents.Count) events")
            }

            if ($report.ErrorAnalysis.TotalErrors -gt 20) {
                $this.Logger.LogWarning("High error count in recent logs: $($report.ErrorAnalysis.TotalErrors) errors")
            }

            # Check error rate
            if ($report.TotalLogEntries -gt 0) {
                $errorRate = ($report.ErrorAnalysis.TotalErrors / $report.TotalLogEntries) * 100
                if ($errorRate -gt 10) {
                    $this.Logger.LogWarning("High error rate detected: $([math]::Round($errorRate, 1))%")
                }
            }
        }
        catch {
            $this.Logger.LogError("Error checking for critical issues", $_.Exception)
        }
    }

    [LogAnalysisReport] GetLatestReport() {
        $reportDir = Join-Path $this.AuditDirectory "Reports"

        if (-not (Test-Path $reportDir)) {
            return $null
        }

        $latestReport = Get-ChildItem $reportDir -Filter "log-analysis-*.json" |
                       Sort-Object LastWriteTime -Descending |
                       Select-Object -First 1

        if ($latestReport) {
            try {
                $reportData = Get-Content $latestReport.FullName | ConvertFrom-Json
                $report = [LogAnalysisReport]::new()

                # Populate report from JSON
                $report.GeneratedAt = [DateTime]::ParseExact($reportData.GeneratedAt, "yyyy-MM-dd HH:mm:ss", $null)
                $report.AnalysisPeriod = $reportData.AnalysisPeriod
                $report.TotalLogEntries = $reportData.TotalLogEntries
                $report.LogLevelCounts = $reportData.LogLevelCounts
                $report.CategoryCounts = $reportData.CategoryCounts
                $report.ErrorAnalysis = $reportData.ErrorAnalysis
                $report.PerformanceAnalysis = $reportData.PerformanceAnalysis
                $report.TrendAnalysis = $reportData.TrendAnalysis
                $report.Recommendations = $reportData.Recommendations

                return $report
            }
            catch {
                $this.Logger.LogError("Error loading latest report", $_.Exception)
            }
        }

        return $null
    }

    [LogEntry[]] SearchLogs([string]$pattern, [int]$hours = 24) {
        $this.LoadRecentLogEntries($hours)

        return $this.LogEntries | Where-Object {
            $_.Message -match $pattern -or $_.RawLine -match $pattern
        } | Sort-Object Timestamp -Descending
    }

    [void] CleanupOldReports([int]$retentionDays = 30) {
        try {
            $reportDir = Join-Path $this.AuditDirectory "Reports"

            if (-not (Test-Path $reportDir)) {
                return
            }

            $cutoffDate = (Get-Date).AddDays(-$retentionDays)
            $oldReports = Get-ChildItem $reportDir -Filter "log-analysis-*.json" |
                         Where-Object { $_.LastWriteTime -lt $cutoffDate }

            foreach ($report in $oldReports) {
                Remove-Item $report.FullName -Force
            }

            if ($oldReports.Count -gt 0) {
                $this.Logger.LogInformation("Cleaned up $($oldReports.Count) old analysis reports")
            }
        }
        catch {
            $this.Logger.LogError("Error cleaning up old reports", $_.Exception)
        }
    }
}

# Add ToHashtable method to LogEntry class
Add-Type -TypeDefinition @"
public static class LogEntryExtensions {
    public static System.Collections.Hashtable ToHashtable(this object entry) {
        var hashtable = new System.Collections.Hashtable();
        foreach (var prop in entry.GetType().GetProperties()) {
            hashtable[prop.Name] = prop.GetValue(entry);
        }
        return hashtable;
    }
}
"@ -ReferencedAssemblies @("System.Core")

# Export log analysis functions for console use
function Start-FileCopierLogAnalyzer {
    param(
        [hashtable]$Config,
        [object]$Logger,
        [int]$IntervalMinutes = 60
    )

    $analyzer = [LogAnalyzer]::new($Config, $Logger)
    $analyzer.Start($IntervalMinutes)
    return $analyzer
}

function Stop-FileCopierLogAnalyzer {
    param(
        [LogAnalyzer]$LogAnalyzer
    )

    $LogAnalyzer.Stop()
}

function Get-FileCopierLogAnalysis {
    param(
        [LogAnalyzer]$LogAnalyzer,
        [switch]$Latest
    )

    if ($Latest) {
        return $LogAnalyzer.GetLatestReport()
    } else {
        $LogAnalyzer.LoadRecentLogEntries()
        return $LogAnalyzer.GenerateAnalysisReport()
    }
}

function Search-FileCopierLogs {
    param(
        [LogAnalyzer]$LogAnalyzer,
        [string]$Pattern,
        [int]$Hours = 24
    )

    return $LogAnalyzer.SearchLogs($Pattern, $Hours)
}

function Clear-FileCopierOldReports {
    param(
        [LogAnalyzer]$LogAnalyzer,
        [int]$RetentionDays = 30
    )

    $LogAnalyzer.CleanupOldReports($RetentionDays)
}