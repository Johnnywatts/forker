# Get-ServiceHealth.ps1 - FileCopier Service Health Check and Monitoring
# Part of Phase 5A: Service Deployment
# Provides health monitoring capabilities for external systems and monitoring tools

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Health check output format")]
    [ValidateSet("Text", "JSON", "XML", "CSV")]
    [string]$OutputFormat = "JSON",

    [Parameter(Mandatory = $false, HelpMessage = "Include detailed performance metrics")]
    [switch]$IncludeMetrics,

    [Parameter(Mandatory = $false, HelpMessage = "Include component-specific health details")]
    [switch]$Detailed,

    [Parameter(Mandatory = $false, HelpMessage = "Service name to monitor")]
    [string]$ServiceName = "FileCopierService",

    [Parameter(Mandatory = $false, HelpMessage = "Timeout for health checks in seconds")]
    [int]$TimeoutSeconds = 30,

    [Parameter(Mandatory = $false, HelpMessage = "Write results to file")]
    [string]$OutputFile,

    [Parameter(Mandatory = $false, HelpMessage = "Enable continuous monitoring")]
    [switch]$Monitor,

    [Parameter(Mandatory = $false, HelpMessage = "Monitoring interval in seconds")]
    [int]$MonitorInterval = 60,

    [Parameter(Mandatory = $false, HelpMessage = "Return exit code based on health status")]
    [switch]$ExitOnUnhealthy
)

# Import required modules
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $scriptDirectory "modules\FileCopier\FileCopier.psm1"

try {
    if (Test-Path $modulePath) {
        Import-Module $modulePath -Force -Global -ErrorAction Stop
    } else {
        Write-Warning "FileCopier module not found at: $modulePath"
        Write-Warning "Some advanced health checks may not be available"
    }
}
catch {
    Write-Warning "Failed to load FileCopier module: $($_.Exception.Message)"
}

# Health status enumeration
enum HealthStatus {
    Healthy = 0
    Warning = 1
    Critical = 2
    Unknown = 3
}

# Health check result structure
class HealthCheckResult {
    [string] $ServiceName
    [DateTime] $CheckTime
    [HealthStatus] $OverallStatus
    [string] $StatusMessage
    [hashtable] $Components
    [hashtable] $Metrics
    [hashtable] $Alerts
    [TimeSpan] $CheckDuration
    [string] $Version

    HealthCheckResult([string] $serviceName) {
        $this.ServiceName = $serviceName
        $this.CheckTime = Get-Date
        $this.Components = @{}
        $this.Metrics = @{}
        $this.Alerts = @{}
        $this.OverallStatus = [HealthStatus]::Unknown
        $this.StatusMessage = "Health check in progress"
        $this.Version = "Phase 5A"
    }
}

function Test-WindowsService {
    param([string] $ServiceName)

    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop

        return @{
            Status = "Healthy"
            IsInstalled = $true
            IsRunning = ($service.Status -eq 'Running')
            StartupType = $service.StartType.ToString()
            ProcessId = if ($service.Status -eq 'Running') {
                try { (Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'").ProcessId } catch { 0 }
            } else { 0 }
            Details = @{
                DisplayName = $service.DisplayName
                ServiceType = $service.ServiceType.ToString()
                Status = $service.Status.ToString()
                CanStop = $service.CanStop
                CanPauseAndContinue = $service.CanPauseAndContinue
            }
            Issues = @()
        }
    }
    catch [System.ServiceProcess.ServiceController] {
        return @{
            Status = "Critical"
            IsInstalled = $false
            IsRunning = $false
            Details = @{}
            Issues = @("Service '$ServiceName' is not installed")
        }
    }
    catch {
        return @{
            Status = "Critical"
            IsInstalled = $false
            IsRunning = $false
            Details = @{}
            Issues = @("Error checking service: $($_.Exception.Message)")
        }
    }
}

function Test-FileCopierServiceHealth {
    param([string] $ServiceName)

    # Try to get service health from the running instance
    try {
        # Check if we can access the global service instance
        $globalService = Get-Variable -Name "script:GlobalFileCopierService" -Scope Global -ValueOnly -ErrorAction SilentlyContinue

        if ($globalService) {
            # Get health status from running service
            $healthStatus = $globalService.GetHealthStatus()
            $serviceStatus = $globalService.GetServiceStatus()

            return @{
                Status = switch ($healthStatus.Status) {
                    "Healthy" { "Healthy" }
                    "Warning" { "Warning" }
                    default { "Critical" }
                }
                IsRunning = $serviceStatus.IsRunning
                StartTime = $serviceStatus.StartTime
                Uptime = if ($serviceStatus.StartTime) { (Get-Date) - $serviceStatus.StartTime } else { $null }
                Components = $healthStatus.Components
                Statistics = $serviceStatus.Statistics
                Configuration = @{
                    SourceDirectory = $serviceStatus.Configuration.SourceDirectory
                    TargetCount = $serviceStatus.Configuration.Targets.Count
                    VerificationEnabled = $serviceStatus.Configuration.Verification.Enabled
                }
                Issues = $healthStatus.Issues
                Details = @{
                    ServiceVersion = $serviceStatus.Version
                    ConfigurationValid = $true
                    MemoryUsageMB = [Math]::Round((Get-Process -Id $PID).WorkingSet64 / 1MB, 2)
                    ProcessorTime = (Get-Process -Id $PID).TotalProcessorTime
                }
            }
        }
    }
    catch {
        # Service instance not available, return basic health check
    }

    # Fallback to basic service health check
    $windowsService = Test-WindowsService -ServiceName $ServiceName

    return @{
        Status = if ($windowsService.IsRunning) { "Warning" } else { "Critical" }
        IsRunning = $windowsService.IsRunning
        StartTime = $null
        Uptime = $null
        Components = @{}
        Statistics = @{}
        Configuration = @{}
        Issues = if (-not $windowsService.IsRunning) { @("Service is not running", "Cannot access service instance") } else { @("Cannot access service instance") }
        Details = $windowsService.Details
    }
}

function Test-SystemResources {
    param([hashtable] $Thresholds = @{})

    $defaultThresholds = @{
        MemoryPercentage = 80
        CPUPercentage = 80
        DiskSpaceGB = 1
    }

    $thresholds = $defaultThresholds + $Thresholds

    try {
        # Memory check
        $memory = Get-WmiObject -Class Win32_ComputerSystem
        $memoryUsagePercent = 0
        if ($memory.TotalPhysicalMemory -gt 0) {
            $availableMemory = (Get-WmiObject -Class Win32_PerfRawData_PerfOS_Memory).AvailableBytes
            $memoryUsagePercent = [Math]::Round(((($memory.TotalPhysicalMemory - $availableMemory) / $memory.TotalPhysicalMemory) * 100), 2)
        }

        # CPU check (simplified)
        $cpu = Get-WmiObject -Class Win32_Processor | Measure-Object -Property LoadPercentage -Average
        $cpuUsagePercent = if ($cpu.Average) { $cpu.Average } else { 0 }

        # Disk space check
        $systemDrive = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'"
        $diskFreeSpaceGB = [Math]::Round($systemDrive.FreeSpace / 1GB, 2)

        $issues = @()
        $status = "Healthy"

        if ($memoryUsagePercent -gt $thresholds.MemoryPercentage) {
            $issues += "High memory usage: $memoryUsagePercent%"
            $status = "Warning"
        }

        if ($cpuUsagePercent -gt $thresholds.CPUPercentage) {
            $issues += "High CPU usage: $cpuUsagePercent%"
            $status = "Warning"
        }

        if ($diskFreeSpaceGB -lt $thresholds.DiskSpaceGB) {
            $issues += "Low disk space: $diskFreeSpaceGB GB free"
            $status = if ($diskFreeSpaceGB -lt 0.5) { "Critical" } else { "Warning" }
        }

        return @{
            Status = $status
            Metrics = @{
                MemoryUsagePercent = $memoryUsagePercent
                CPUUsagePercent = $cpuUsagePercent
                DiskFreeSpaceGB = $diskFreeSpaceGB
                TotalMemoryGB = [Math]::Round($memory.TotalPhysicalMemory / 1GB, 2)
                ProcessorCount = (Get-WmiObject -Class Win32_ComputerSystem).NumberOfProcessors
            }
            Issues = $issues
        }
    }
    catch {
        return @{
            Status = "Warning"
            Metrics = @{}
            Issues = @("Error checking system resources: $($_.Exception.Message)")
        }
    }
}

function Test-DirectoriesAndPermissions {
    param([hashtable] $Directories)

    $results = @{
        Status = "Healthy"
        Issues = @()
        Details = @{}
    }

    foreach ($dirType in $Directories.Keys) {
        $dirPath = $Directories[$dirType]

        try {
            if (Test-Path $dirPath) {
                # Test write permissions
                $testFile = Join-Path $dirPath "health-check-test.tmp"
                try {
                    "test" | Out-File -FilePath $testFile -Encoding ASCII -ErrorAction Stop
                    Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue

                    $results.Details[$dirType] = @{
                        Exists = $true
                        Writable = $true
                        Path = $dirPath
                    }
                }
                catch {
                    $results.Status = "Warning"
                    $results.Issues += "$dirType directory not writable: $dirPath"
                    $results.Details[$dirType] = @{
                        Exists = $true
                        Writable = $false
                        Path = $dirPath
                        Error = $_.Exception.Message
                    }
                }
            } else {
                $results.Status = "Warning"
                $results.Issues += "$dirType directory does not exist: $dirPath"
                $results.Details[$dirType] = @{
                    Exists = $false
                    Writable = $false
                    Path = $dirPath
                }
            }
        }
        catch {
            $results.Status = "Critical"
            $results.Issues += "Error checking $dirType directory: $($_.Exception.Message)"
            $results.Details[$dirType] = @{
                Exists = $false
                Writable = $false
                Path = $dirPath
                Error = $_.Exception.Message
            }
        }
    }

    return $results
}

function Get-HealthCheckResult {
    param([string] $ServiceName, [bool] $IncludeMetrics, [bool] $Detailed)

    $startTime = Get-Date
    $result = [HealthCheckResult]::new($ServiceName)

    try {
        # Check Windows service status
        Write-Verbose "Checking Windows service status..."
        $windowsServiceHealth = Test-WindowsService -ServiceName $ServiceName
        $result.Components["WindowsService"] = $windowsServiceHealth

        # Check FileCopier service health (if running)
        if ($windowsServiceHealth.IsRunning) {
            Write-Verbose "Checking FileCopier service health..."
            $fileCopierHealth = Test-FileCopierServiceHealth -ServiceName $ServiceName
            $result.Components["FileCopierService"] = $fileCopierHealth

            # Merge service-specific metrics
            if ($IncludeMetrics -and $fileCopierHealth.Statistics) {
                $result.Metrics = $fileCopierHealth.Statistics
            }
        }

        # Check system resources
        if ($IncludeMetrics) {
            Write-Verbose "Checking system resources..."
            $systemHealth = Test-SystemResources
            $result.Components["SystemResources"] = $systemHealth

            # Add system metrics
            if ($systemHealth.Metrics) {
                foreach ($metric in $systemHealth.Metrics.Keys) {
                    $result.Metrics["System_$metric"] = $systemHealth.Metrics[$metric]
                }
            }
        }

        # Check directories and permissions (if service is configured)
        if ($Detailed -and $result.Components["FileCopierService"].Configuration.SourceDirectory) {
            Write-Verbose "Checking directories and permissions..."
            $config = $result.Components["FileCopierService"].Configuration
            $directories = @{
                "Source" = $config.SourceDirectory
            }

            # Add target directories
            $targetCount = 0
            if ($config.TargetCount -gt 0) {
                # This is simplified - in real implementation, would get actual target paths
                $directories["QuarantineDirectory"] = "C:\FileCopier\Quarantine"
                $directories["LogDirectory"] = "C:\FileCopier\Logs"
            }

            $directoryHealth = Test-DirectoriesAndPermissions -Directories $directories
            $result.Components["DirectoryPermissions"] = $directoryHealth
        }

        # Determine overall health status
        $componentStatuses = $result.Components.Values | ForEach-Object { $_.Status }

        if ($componentStatuses -contains "Critical") {
            $result.OverallStatus = [HealthStatus]::Critical
            $result.StatusMessage = "One or more critical issues detected"
        }
        elseif ($componentStatuses -contains "Warning") {
            $result.OverallStatus = [HealthStatus]::Warning
            $result.StatusMessage = "Service is running with warnings"
        }
        elseif ($windowsServiceHealth.IsRunning) {
            $result.OverallStatus = [HealthStatus]::Healthy
            $result.StatusMessage = "Service is healthy and operational"
        }
        else {
            $result.OverallStatus = [HealthStatus]::Critical
            $result.StatusMessage = "Service is not running"
        }

        # Collect all issues
        $allIssues = @()
        foreach ($component in $result.Components.Values) {
            if ($component.Issues) {
                $allIssues += $component.Issues
            }
        }
        $result.Alerts["Issues"] = $allIssues

        # Performance alerts (if metrics available)
        if ($IncludeMetrics -and $result.Metrics) {
            $performanceAlerts = @()

            foreach ($metric in $result.Metrics.Keys) {
                # Add specific performance alerts based on metrics
                if ($metric -like "*MemoryUsage*" -and $result.Metrics[$metric] -gt 80) {
                    $performanceAlerts += "High memory usage: $($result.Metrics[$metric])%"
                }
                if ($metric -like "*CPUUsage*" -and $result.Metrics[$metric] -gt 80) {
                    $performanceAlerts += "High CPU usage: $($result.Metrics[$metric])%"
                }
            }

            if ($performanceAlerts.Count -gt 0) {
                $result.Alerts["Performance"] = $performanceAlerts
            }
        }

    }
    catch {
        $result.OverallStatus = [HealthStatus]::Critical
        $result.StatusMessage = "Health check failed: $($_.Exception.Message)"
        $result.Alerts["CriticalError"] = @($_.Exception.Message)
    }
    finally {
        $result.CheckDuration = (Get-Date) - $startTime
    }

    return $result
}

function Format-HealthResult {
    param(
        [HealthCheckResult] $Result,
        [string] $Format
    )

    switch ($Format.ToLower()) {
        "json" {
            return ($Result | ConvertTo-Json -Depth 10)
        }
        "xml" {
            # Convert to XML (simplified)
            $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<HealthCheck>
    <ServiceName>$($Result.ServiceName)</ServiceName>
    <CheckTime>$($Result.CheckTime.ToString('o'))</CheckTime>
    <OverallStatus>$($Result.OverallStatus)</OverallStatus>
    <StatusMessage>$($Result.StatusMessage)</StatusMessage>
    <CheckDuration>$($Result.CheckDuration.TotalMilliseconds)</CheckDuration>
    <Version>$($Result.Version)</Version>
</HealthCheck>
"@
            return $xml
        }
        "csv" {
            $csvData = [PSCustomObject]@{
                ServiceName = $Result.ServiceName
                CheckTime = $Result.CheckTime.ToString('yyyy-MM-dd HH:mm:ss')
                OverallStatus = $Result.OverallStatus.ToString()
                StatusMessage = $Result.StatusMessage
                CheckDurationMs = $Result.CheckDuration.TotalMilliseconds
                ComponentCount = $Result.Components.Count
                MetricCount = $Result.Metrics.Count
                AlertCount = $Result.Alerts.Count
            }
            return ($csvData | ConvertTo-Csv -NoTypeInformation)
        }
        "text" {
            $text = @"
=== FileCopier Service Health Check ===
Service Name: $($Result.ServiceName)
Check Time: $($Result.CheckTime.ToString('yyyy-MM-dd HH:mm:ss'))
Overall Status: $($Result.OverallStatus)
Status Message: $($Result.StatusMessage)
Check Duration: $([Math]::Round($Result.CheckDuration.TotalMilliseconds, 2)) ms
Version: $($Result.Version)

Components:
"@
            foreach ($comp in $Result.Components.Keys) {
                $compData = $Result.Components[$comp]
                $text += "`n  $comp : $($compData.Status)"
                if ($compData.Issues -and $compData.Issues.Count -gt 0) {
                    $text += " (Issues: $($compData.Issues -join ', '))"
                }
            }

            if ($Result.Metrics.Count -gt 0) {
                $text += "`n`nMetrics:"
                foreach ($metric in $Result.Metrics.Keys) {
                    $text += "`n  $metric : $($Result.Metrics[$metric])"
                }
            }

            if ($Result.Alerts.Count -gt 0) {
                $text += "`n`nAlerts:"
                foreach ($alertType in $Result.Alerts.Keys) {
                    $text += "`n  $alertType : $($Result.Alerts[$alertType] -join ', ')"
                }
            }

            return $text
        }
        default {
            return ($Result | ConvertTo-Json -Depth 10)
        }
    }
}

function Start-ContinuousMonitoring {
    param(
        [string] $ServiceName,
        [int] $IntervalSeconds,
        [string] $OutputFormat,
        [bool] $IncludeMetrics,
        [bool] $Detailed,
        [string] $OutputFile
    )

    Write-Host "Starting continuous monitoring of $ServiceName (Ctrl+C to stop)..." -ForegroundColor Green
    Write-Host "Monitoring interval: $IntervalSeconds seconds" -ForegroundColor Gray
    Write-Host "Output format: $OutputFormat" -ForegroundColor Gray

    $iteration = 0

    try {
        while ($true) {
            $iteration++
            Write-Host "`n--- Health Check #$iteration at $(Get-Date -Format 'HH:mm:ss') ---" -ForegroundColor Cyan

            $healthResult = Get-HealthCheckResult -ServiceName $ServiceName -IncludeMetrics $IncludeMetrics -Detailed $Detailed
            $formattedResult = Format-HealthResult -Result $healthResult -Format $OutputFormat

            # Display status
            $statusColor = switch ($healthResult.OverallStatus) {
                "Healthy" { "Green" }
                "Warning" { "Yellow" }
                "Critical" { "Red" }
                default { "Gray" }
            }
            Write-Host "Status: $($healthResult.OverallStatus) - $($healthResult.StatusMessage)" -ForegroundColor $statusColor

            # Write to file if specified
            if ($OutputFile) {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                "[$timestamp] $formattedResult" | Add-Content -Path $OutputFile -Encoding UTF8
            }

            # Show brief summary
            if ($healthResult.Components.Count -gt 0) {
                Write-Host "Components: " -NoNewline -ForegroundColor Gray
                $componentSummary = $healthResult.Components.Keys | ForEach-Object {
                    $status = $healthResult.Components[$_].Status
                    $color = switch ($status) {
                        "Healthy" { "Green" }
                        "Warning" { "Yellow" }
                        "Critical" { "Red" }
                        default { "Gray" }
                    }
                    "$_($status)"
                }
                Write-Host ($componentSummary -join ", ") -ForegroundColor Gray
            }

            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    catch [System.OperationCanceledException] {
        Write-Host "`nMonitoring stopped." -ForegroundColor Yellow
    }
    catch {
        Write-Host "`nMonitoring error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Main execution
function Main {
    Write-Verbose "Starting FileCopier Service health check..."

    if ($Monitor) {
        Start-ContinuousMonitoring -ServiceName $ServiceName -IntervalSeconds $MonitorInterval -OutputFormat $OutputFormat -IncludeMetrics $IncludeMetrics -Detailed $Detailed -OutputFile $OutputFile
        return
    }

    # Single health check
    $healthResult = Get-HealthCheckResult -ServiceName $ServiceName -IncludeMetrics $IncludeMetrics -Detailed $Detailed
    $formattedResult = Format-HealthResult -Result $healthResult -Format $OutputFormat

    # Output result
    if ($OutputFile) {
        $formattedResult | Out-File -FilePath $OutputFile -Encoding UTF8
        Write-Host "Health check results written to: $OutputFile" -ForegroundColor Green
    } else {
        Write-Output $formattedResult
    }

    # Exit with appropriate code if requested
    if ($ExitOnUnhealthy) {
        exit [int]$healthResult.OverallStatus
    }
}

# Execute main function
Main