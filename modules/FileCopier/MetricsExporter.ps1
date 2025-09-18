using namespace System.Collections.Concurrent
using namespace System.Collections.Generic
using namespace System.Threading
using namespace System.IO
using namespace System.Text
using namespace System.Net
using namespace System.Net.Http

enum ExportFormat {
    Json = 0
    Csv = 1
    Prometheus = 2
    Influx = 3
    Xml = 4
}

class MetricDataPoint {
    [DateTime] $Timestamp
    [string] $Name
    [object] $Value
    [hashtable] $Tags
    [string] $Unit

    MetricDataPoint([string]$name, [object]$value, [hashtable]$tags = @{}, [string]$unit = "") {
        $this.Timestamp = Get-Date
        $this.Name = $name
        $this.Value = $value
        $this.Tags = $tags
        $this.Unit = $unit
    }
}

class MetricsExporter {
    [hashtable] $Config
    [object] $Logger
    [DiagnosticCommands] $Diagnostics
    [PerformanceCounterManager] $PerfCounters
    [AlertingSystem] $AlertingSystem
    [System.Threading.Timer] $ExportTimer
    [bool] $IsRunning
    [string] $ExportDirectory
    [List[MetricDataPoint]] $MetricsBuffer
    [object] $LockObject

    MetricsExporter([hashtable]$config, [object]$logger) {
        $this.Config = $config
        $this.Logger = $logger
        $this.IsRunning = $false
        $this.ExportDirectory = Join-Path $config['Logging']['AuditDirectory'] "Metrics"
        $this.MetricsBuffer = [List[MetricDataPoint]]::new()
        $this.LockObject = [object]::new()

        # Ensure export directory exists
        if (-not (Test-Path $this.ExportDirectory)) {
            New-Item -Path $this.ExportDirectory -ItemType Directory -Force | Out-Null
        }

        $this.Diagnostics = [DiagnosticCommands]::new($config, $logger)

        if ($config['Performance']['Monitoring']['PerformanceCounters']) {
            $this.PerfCounters = [PerformanceCounterManager]::new($config, $logger)
        }
    }

    [void] Start([int]$intervalSeconds = 300) {
        if ($this.IsRunning) {
            $this.Logger.LogWarning("Metrics exporter is already running")
            return
        }

        try {
            $this.IsRunning = $true

            # Start export timer
            $this.ExportTimer = [System.Threading.Timer]::new(
                [System.Threading.TimerCallback]{
                    param($state)
                    $exporter = $state
                    $exporter.CollectAndExportMetrics()
                },
                $this,
                [TimeSpan]::FromSeconds(30),        # Initial delay
                [TimeSpan]::FromSeconds($intervalSeconds)  # Export interval
            )

            $this.Logger.LogInformation("Metrics exporter started with $intervalSeconds second interval")
        }
        catch {
            $this.IsRunning = $false
            $this.Logger.LogError("Failed to start metrics exporter", $_.Exception)
            throw
        }
    }

    [void] Stop() {
        if (-not $this.IsRunning) {
            return
        }

        try {
            $this.IsRunning = $false

            if ($this.ExportTimer) {
                $this.ExportTimer.Dispose()
                $this.ExportTimer = $null
            }

            # Export any remaining buffered metrics
            $this.FlushMetricsBuffer()

            $this.Logger.LogInformation("Metrics exporter stopped")
        }
        catch {
            $this.Logger.LogError("Error stopping metrics exporter", $_.Exception)
        }
    }

    [void] CollectAndExportMetrics() {
        try {
            $timestamp = Get-Date

            # Collect performance metrics
            $this.CollectPerformanceMetrics($timestamp)

            # Collect system health metrics
            $this.CollectHealthMetrics($timestamp)

            # Collect alert metrics
            $this.CollectAlertMetrics($timestamp)

            # Export collected metrics
            $this.ExportMetrics($timestamp)

            $this.Logger.LogDebug("Metrics collection and export completed")
        }
        catch {
            $this.Logger.LogError("Error during metrics collection and export", $_.Exception)
        }
    }

    [void] CollectPerformanceMetrics([DateTime]$timestamp) {
        try {
            if ($this.PerfCounters) {
                $counters = $this.PerfCounters.GetAllCounterValues()

                foreach ($counter in $counters.GetEnumerator()) {
                    $metric = [MetricDataPoint]::new(
                        "filecopy_$($counter.Key.ToLower().Replace(' ', '_'))",
                        $counter.Value,
                        @{ service = "filecopy"; host = $env:COMPUTERNAME },
                        $this.GetCounterUnit($counter.Key)
                    )
                    $metric.Timestamp = $timestamp

                    $this.AddMetric($metric)
                }
            }

            # Collect system resource metrics
            $currentProcess = Get-Process -Id $global:PID
            $memoryMB = [math]::Round($currentProcess.WorkingSet64 / 1MB, 2)

            $this.AddMetric([MetricDataPoint]::new(
                "filecopy_memory_usage_mb",
                $memoryMB,
                @{ service = "filecopy"; host = $env:COMPUTERNAME },
                "MB"
            ))

            # CPU usage
            $cpuCounter = Get-Counter "\Process(powershell*)\% Processor Time" -MaxSamples 1 -ErrorAction SilentlyContinue
            if ($cpuCounter) {
                $cpuPercent = [math]::Round($cpuCounter.CounterSamples[0].CookedValue, 1)
                $this.AddMetric([MetricDataPoint]::new(
                    "filecopy_cpu_usage_percent",
                    $cpuPercent,
                    @{ service = "filecopy"; host = $env:COMPUTERNAME },
                    "%"
                ))
            }

            # Disk space for critical paths
            $criticalPaths = @(
                @{ path = $this.Config['SourceDirectory']; name = "source" },
                @{ path = $this.Config['Processing']['QuarantineDirectory']; name = "quarantine" },
                @{ path = $this.Config['Processing']['TempDirectory']; name = "temp" }
            )

            foreach ($pathInfo in $criticalPaths | Where-Object { $_['path'] }) {
                if (Test-Path $pathInfo['path']) {
                    $freeSpace = $this.GetDiskSpace($pathInfo['path'])
                    $freeSpaceGB = [math]::Round($freeSpace / 1GB, 2)

                    $this.AddMetric([MetricDataPoint]::new(
                        "filecopy_disk_free_space_gb",
                        $freeSpaceGB,
                        @{ service = "filecopy"; host = $env:COMPUTERNAME; path_type = $pathInfo['name'] },
                        "GB"
                    ))
                }
            }
        }
        catch {
            $this.Logger.LogError("Error collecting performance metrics", $_.Exception)
        }
    }

    [void] CollectHealthMetrics([DateTime]$timestamp) {
        try {
            $health = $this.Diagnostics.GetSystemHealth()

            # Overall health status
            $healthValue = switch ($health.Status) {
                'Healthy' { 1 }
                'Warning' { 0.5 }
                'Critical' { 0 }
                default { -1 }
            }

            $this.AddMetric([MetricDataPoint]::new(
                "filecopy_health_status",
                $healthValue,
                @{ service = "filecopy"; host = $env:COMPUTERNAME; status = $health.Status },
                "status"
            ))

            # Component health
            foreach ($component in $health.Components.GetEnumerator()) {
                $componentValue = switch ($component.Value.Status) {
                    'Healthy' { 1 }
                    'Warning' { 0.5 }
                    'Critical' { 0 }
                    default { -1 }
                }

                $this.AddMetric([MetricDataPoint]::new(
                    "filecopy_component_health",
                    $componentValue,
                    @{ service = "filecopy"; host = $env:COMPUTERNAME; component = $component.Key; status = $component.Value.Status },
                    "status"
                ))
            }
        }
        catch {
            $this.Logger.LogError("Error collecting health metrics", $_.Exception)
        }
    }

    [void] CollectAlertMetrics([DateTime]$timestamp) {
        try {
            if ($this.AlertingSystem) {
                $activeAlerts = $this.AlertingSystem.GetActiveAlerts()

                # Count alerts by severity
                $alertCounts = @{
                    Info = 0
                    Warning = 0
                    Critical = 0
                    Emergency = 0
                }

                foreach ($alert in $activeAlerts) {
                    $alertCounts[$alert.Severity]++
                }

                foreach ($severity in $alertCounts.Keys) {
                    $this.AddMetric([MetricDataPoint]::new(
                        "filecopy_alerts_count",
                        $alertCounts[$severity],
                        @{ service = "filecopy"; host = $env:COMPUTERNAME; severity = $severity },
                        "count"
                    ))
                }

                # Total active alerts
                $this.AddMetric([MetricDataPoint]::new(
                    "filecopy_alerts_total",
                    $activeAlerts.Count,
                    @{ service = "filecopy"; host = $env:COMPUTERNAME },
                    "count"
                ))
            }
        }
        catch {
            $this.Logger.LogError("Error collecting alert metrics", $_.Exception)
        }
    }

    [void] AddMetric([MetricDataPoint]$metric) {
        lock ($this.LockObject) {
            $this.MetricsBuffer.Add($metric)
        }
    }

    [void] ExportMetrics([DateTime]$timestamp) {
        $metricsToExport = @()

        lock ($this.LockObject) {
            $metricsToExport = $this.MetricsBuffer.ToArray()
            $this.MetricsBuffer.Clear()
        }

        if ($metricsToExport.Count -eq 0) {
            return
        }

        # Export in multiple formats
        $this.ExportToJson($metricsToExport, $timestamp)
        $this.ExportToCsv($metricsToExport, $timestamp)
        $this.ExportToPrometheus($metricsToExport, $timestamp)

        $this.Logger.LogDebug("Exported $($metricsToExport.Count) metrics")
    }

    [void] ExportToJson([MetricDataPoint[]]$metrics, [DateTime]$timestamp) {
        try {
            $fileName = "metrics_$($timestamp.ToString('yyyyMMdd_HHmmss')).json"
            $filePath = Join-Path $this.ExportDirectory $fileName

            $jsonData = @{
                timestamp = $timestamp.ToString("yyyy-MM-dd HH:mm:ss")
                service = "FileCopier"
                host = $env:COMPUTERNAME
                metrics = @()
            }

            foreach ($metric in $metrics) {
                $jsonData.metrics += @{
                    timestamp = $metric.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
                    name = $metric.Name
                    value = $metric.Value
                    unit = $metric.Unit
                    tags = $metric.Tags
                }
            }

            $jsonData | ConvertTo-Json -Depth 10 | Out-File -FilePath $filePath -Encoding UTF8
        }
        catch {
            $this.Logger.LogError("Error exporting metrics to JSON", $_.Exception)
        }
    }

    [void] ExportToCsv([MetricDataPoint[]]$metrics, [DateTime]$timestamp) {
        try {
            $fileName = "metrics_$($timestamp.ToString('yyyyMMdd_HHmmss')).csv"
            $filePath = Join-Path $this.ExportDirectory $fileName

            $csvData = @()
            foreach ($metric in $metrics) {
                $tags = ($metric.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ";"

                $csvData += [PSCustomObject]@{
                    Timestamp = $metric.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
                    Name = $metric.Name
                    Value = $metric.Value
                    Unit = $metric.Unit
                    Tags = $tags
                    Service = "FileCopier"
                    Host = $env:COMPUTERNAME
                }
            }

            $csvData | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8
        }
        catch {
            $this.Logger.LogError("Error exporting metrics to CSV", $_.Exception)
        }
    }

    [void] ExportToPrometheus([MetricDataPoint[]]$metrics, [DateTime]$timestamp) {
        try {
            $fileName = "metrics_$($timestamp.ToString('yyyyMMdd_HHmmss')).prom"
            $filePath = Join-Path $this.ExportDirectory $fileName

            $content = New-Object StringBuilder
            $content.AppendLine("# FileCopier Service Metrics")
            $content.AppendLine("# Generated: $($timestamp.ToString('yyyy-MM-dd HH:mm:ss'))")
            $content.AppendLine("")

            foreach ($metric in $metrics) {
                # Generate Prometheus format
                $metricName = $metric.Name -replace '[^a-zA-Z0-9_]', '_'
                $labels = @()

                foreach ($tag in $metric.Tags.GetEnumerator()) {
                    $labels += "$($tag.Key)=`"$($tag.Value)`""
                }

                $labelString = if ($labels.Count -gt 0) { "{$($labels -join ',')}" } else { "" }
                $value = if ($metric.Value -is [string]) { "`"$($metric.Value)`"" } else { $metric.Value }

                $content.AppendLine("# HELP $metricName $($metric.Name)")
                if ($metric.Unit) {
                    $content.AppendLine("# UNIT $metricName $($metric.Unit)")
                }
                $content.AppendLine("$metricName$labelString $value $($metric.Timestamp.ToUniversalTime().Subtract([DateTime]'1970-01-01').TotalMilliseconds)")
                $content.AppendLine("")
            }

            $content.ToString() | Out-File -FilePath $filePath -Encoding UTF8
        }
        catch {
            $this.Logger.LogError("Error exporting metrics to Prometheus format", $_.Exception)
        }
    }

    [void] FlushMetricsBuffer() {
        try {
            if ($this.MetricsBuffer.Count -gt 0) {
                $this.ExportMetrics((Get-Date))
            }
        }
        catch {
            $this.Logger.LogError("Error flushing metrics buffer", $_.Exception)
        }
    }

    [string] GetCounterUnit([string]$counterName) {
        $units = @{
            'FilesProcessedTotal' = 'count'
            'FilesProcessedPerSecond' = 'per_second'
            'FilesInError' = 'count'
            'BytesProcessedTotal' = 'bytes'
            'BytesProcessedPerSecond' = 'bytes_per_second'
            'QueueDepth' = 'count'
            'ActiveCopyOperations' = 'count'
            'RetryAttempts' = 'count'
            'AverageProcessingTimeSeconds' = 'seconds'
            'AverageCopySpeedMBps' = 'mbps'
            'MemoryUsageMB' = 'mb'
            'CPUUsagePercent' = 'percent'
        }

        return $units[$counterName] ?? ""
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

    [void] SetAlertingSystem([AlertingSystem]$alertingSystem) {
        $this.AlertingSystem = $alertingSystem
    }

    [hashtable] GetExportStatistics() {
        return @{
            ExportDirectory = $this.ExportDirectory
            IsRunning = $this.IsRunning
            BufferedMetrics = $this.MetricsBuffer.Count
            ExportedFiles = (Get-ChildItem $this.ExportDirectory -File | Measure-Object).Count
        }
    }

    [void] CleanupOldExports([int]$retentionDays = 30) {
        try {
            $cutoffDate = (Get-Date).AddDays(-$retentionDays)
            $oldFiles = Get-ChildItem $this.ExportDirectory -File | Where-Object { $_.LastWriteTime -lt $cutoffDate }

            foreach ($file in $oldFiles) {
                Remove-Item $file.FullName -Force
            }

            if ($oldFiles.Count -gt 0) {
                $this.Logger.LogInformation("Cleaned up $($oldFiles.Count) old metric export files")
            }
        }
        catch {
            $this.Logger.LogError("Error cleaning up old metric exports", $_.Exception)
        }
    }

    [void] ExportCustomMetrics([hashtable]$customMetrics) {
        try {
            $timestamp = Get-Date

            foreach ($metric in $customMetrics.GetEnumerator()) {
                $metricPoint = [MetricDataPoint]::new(
                    "filecopy_custom_$($metric.Key)",
                    $metric.Value,
                    @{ service = "filecopy"; host = $env:COMPUTERNAME; type = "custom" },
                    ""
                )
                $metricPoint.Timestamp = $timestamp

                $this.AddMetric($metricPoint)
            }

            $this.Logger.LogDebug("Added $($customMetrics.Count) custom metrics")
        }
        catch {
            $this.Logger.LogError("Error exporting custom metrics", $_.Exception)
        }
    }
}

# Export metrics functions for console use
function Start-FileCopierMetricsExporter {
    param(
        [hashtable]$Config,
        [object]$Logger,
        [int]$IntervalSeconds = 300,
        [AlertingSystem]$AlertingSystem = $null
    )

    $exporter = [MetricsExporter]::new($Config, $Logger)

    if ($AlertingSystem) {
        $exporter.SetAlertingSystem($AlertingSystem)
    }

    $exporter.Start($IntervalSeconds)
    return $exporter
}

function Stop-FileCopierMetricsExporter {
    param(
        [MetricsExporter]$MetricsExporter
    )

    $MetricsExporter.Stop()
}

function Export-FileCopierCustomMetrics {
    param(
        [MetricsExporter]$MetricsExporter,
        [hashtable]$CustomMetrics
    )

    $MetricsExporter.ExportCustomMetrics($CustomMetrics)
}

function Get-FileCopierMetricsStats {
    param(
        [MetricsExporter]$MetricsExporter
    )

    return $MetricsExporter.GetExportStatistics()
}

function Clear-FileCopierOldMetrics {
    param(
        [MetricsExporter]$MetricsExporter,
        [int]$RetentionDays = 30
    )

    $MetricsExporter.CleanupOldExports($RetentionDays)
}