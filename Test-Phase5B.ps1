# Phase 5B Monitoring & Diagnostics - Validation and Testing Script
# This script validates all Phase 5B components and performs comprehensive testing

param(
    [string]$ConfigPath = "config/service-config-development.json",
    [switch]$Detailed,
    [switch]$IncludePerformanceTests
)

Write-Host "=" * 80
Write-Host "FileCopier Service - Phase 5B Validation and Testing"
Write-Host "Testing Monitoring & Diagnostics Components"
Write-Host "=" * 80

# Initialize test results
$testResults = @{
    TotalTests = 0
    PassedTests = 0
    FailedTests = 0
    Warnings = 0
    Results = @()
}

function Add-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = "",
        [bool]$IsWarning = $false
    )

    $testResults.TotalTests++

    if ($IsWarning) {
        $testResults.Warnings++
        $status = "WARNING"
        $color = "Yellow"
    } elseif ($Passed) {
        $testResults.PassedTests++
        $status = "PASS"
        $color = "Green"
    } else {
        $testResults.FailedTests++
        $status = "FAIL"
        $color = "Red"
    }

    $result = @{
        TestName = $TestName
        Status = $status
        Message = $Message
        Timestamp = Get-Date
    }

    $testResults.Results += $result

    Write-Host "[$status] $TestName" -ForegroundColor $color
    if ($Message) {
        Write-Host "  $Message" -ForegroundColor Gray
    }
}

try {
    # Test 1: Configuration Loading
    Write-Host "`nTesting Configuration Loading..."

    if (-not (Test-Path $ConfigPath)) {
        Add-TestResult "Configuration File Exists" $false "Configuration file not found: $ConfigPath"
        throw "Cannot continue without configuration file"
    }

    Add-TestResult "Configuration File Exists" $true

    try {
        $config = Get-Content $ConfigPath | ConvertFrom-Json -AsHashtable
        Add-TestResult "Configuration JSON Valid" $true
    } catch {
        Add-TestResult "Configuration JSON Valid" $false $_.Exception.Message
        throw "Invalid configuration file"
    }

    # Test 2: Module Loading
    Write-Host "`nTesting Module Loading..."

    $modules = @(
        "modules/FileCopier/PerformanceCounters.ps1",
        "modules/FileCopier/DiagnosticCommands.ps1",
        "modules/FileCopier/MonitoringDashboard.ps1",
        "modules/FileCopier/AlertingSystem.ps1",
        "modules/FileCopier/MetricsExporter.ps1",
        "modules/FileCopier/LogAnalyzer.ps1",
        "modules/FileCopier/SystemIntegration.ps1"
    )

    foreach ($module in $modules) {
        try {
            if (Test-Path $module) {
                . $module
                Add-TestResult "Load $($module.Split('/')[-1])" $true
            } else {
                Add-TestResult "Load $($module.Split('/')[-1])" $false "Module file not found"
            }
        } catch {
            Add-TestResult "Load $($module.Split('/')[-1])" $false $_.Exception.Message
        }
    }

    # Test 3: Logger Setup (Mock)
    Write-Host "`nTesting Logger Setup..."

    $logger = [PSCustomObject]@{
        LogDebug = { param($message) Write-Verbose "DEBUG: $message" }
        LogInformation = { param($message) Write-Host "INFO: $message" }
        LogWarning = { param($message) Write-Warning "WARN: $message" }
        LogError = { param($message, $exception) Write-Error "ERROR: $message" }
        LogCritical = { param($message) Write-Error "CRITICAL: $message" }
    }

    Add-TestResult "Logger Mock Created" $true

    # Test 4: Performance Counters
    Write-Host "`nTesting Performance Counters..."

    try {
        $perfCounters = [PerformanceCounterManager]::new($config, $logger)
        Add-TestResult "PerformanceCounterManager Creation" $true

        # Test counter operations
        $perfCounters.IncrementFilesProcessed()
        $perfCounters.RecordProcessingTime(30.5)
        $perfCounters.UpdateQueueDepth(5)

        $counterValues = $perfCounters.GetAllCounterValues()
        Add-TestResult "Performance Counter Operations" ($counterValues.Count -gt 0) "Retrieved $($counterValues.Count) counter values"

    } catch {
        Add-TestResult "PerformanceCounterManager Creation" $false $_.Exception.Message
    }

    # Test 5: Diagnostic Commands
    Write-Host "`nTesting Diagnostic Commands..."

    try {
        $diagnostics = [DiagnosticCommands]::new($config, $logger)
        Add-TestResult "DiagnosticCommands Creation" $true

        # Test system health check
        $health = $diagnostics.GetSystemHealth()
        Add-TestResult "System Health Check" ($health.Status -ne $null) "Overall status: $($health.Status)"

        # Test connectivity check
        $connectivity = $diagnostics.TestConnectivity()
        Add-TestResult "Connectivity Test" ($connectivity.Status -ne $null) "Connectivity status: $($connectivity.Status)"

        # Test performance metrics
        if ($perfCounters) {
            $performance = $diagnostics.GetPerformanceMetrics()
            Add-TestResult "Performance Metrics" ($performance.Timestamp -ne $null) "Metrics collected successfully"
        }

    } catch {
        Add-TestResult "DiagnosticCommands Creation" $false $_.Exception.Message
    }

    # Test 6: Alerting System
    Write-Host "`nTesting Alerting System..."

    try {
        $alerting = [AlertingSystem]::new($config, $logger)
        Add-TestResult "AlertingSystem Creation" $true

        # Test alert creation
        $testAlert = [Alert]::new(
            [AlertSeverity]::Warning,
            [AlertCategory]::Performance,
            "Test Alert",
            "This is a test alert"
        )

        $alerting.RaiseAlert($testAlert)

        $activeAlerts = $alerting.GetActiveAlerts()
        Add-TestResult "Alert Creation and Retrieval" ($activeAlerts.Count -gt 0) "Created and retrieved $($activeAlerts.Count) alerts"

    } catch {
        Add-TestResult "AlertingSystem Creation" $false $_.Exception.Message
    }

    # Test 7: Metrics Exporter
    Write-Host "`nTesting Metrics Exporter..."

    try {
        $metricsExporter = [MetricsExporter]::new($config, $logger)
        Add-TestResult "MetricsExporter Creation" $true

        # Test custom metrics export
        $customMetrics = @{
            test_metric_1 = 42
            test_metric_2 = 3.14
        }

        $metricsExporter.ExportCustomMetrics($customMetrics)
        Add-TestResult "Custom Metrics Export" $true "Exported $($customMetrics.Count) custom metrics"

        $exportStats = $metricsExporter.GetExportStatistics()
        Add-TestResult "Export Statistics" ($exportStats.ExportDirectory -ne $null) "Export directory: $($exportStats.ExportDirectory)"

    } catch {
        Add-TestResult "MetricsExporter Creation" $false $_.Exception.Message
    }

    # Test 8: Log Analyzer
    Write-Host "`nTesting Log Analyzer..."

    try {
        $logAnalyzer = [LogAnalyzer]::new($config, $logger)
        Add-TestResult "LogAnalyzer Creation" $true

        # Create sample log entries for testing
        $sampleLogData = @(
            "[2025-09-18 12:00:01] [INFO] [FileProcessor] File processing started: test.svs",
            "[2025-09-18 12:00:02] [ERROR] [FileProcessor] Access denied: C:\test\file.svs",
            "[2025-09-18 12:00:03] [WARNING] [MemoryMonitor] Memory usage high: 85%",
            "[2025-09-18 12:00:04] [INFO] [FileProcessor] Processing completed in 30.5 seconds"
        )

        # Test log entry parsing
        $logEntries = $sampleLogData | ForEach-Object { [LogEntry]::new($_) }
        Add-TestResult "Log Entry Parsing" ($logEntries.Count -eq 4) "Parsed $($logEntries.Count) log entries"

        # Verify parsing results
        $errorEntry = $logEntries | Where-Object { $_.Level -eq [LogLevel]::Error } | Select-Object -First 1
        Add-TestResult "Error Level Detection" ($errorEntry -ne $null) "Found error level entry"

    } catch {
        Add-TestResult "LogAnalyzer Creation" $false $_.Exception.Message
    }

    # Test 9: System Integration Monitor
    Write-Host "`nTesting System Integration Monitor..."

    try {
        $systemIntegration = [SystemIntegrationMonitor]::new($config, $logger)
        Add-TestResult "SystemIntegrationMonitor Creation" $true

        # Test integration status
        $integrationStatus = $systemIntegration.GetIntegrationStatus()
        Add-TestResult "Integration Status" ($integrationStatus.TotalEndpoints -ne $null) "Total endpoints: $($integrationStatus.TotalEndpoints)"

        # Test event creation
        $testEvent = [IntegrationEvent]::new(
            "TestEvent",
            "ValidationScript",
            @{ message = "Test integration event" }
        )

        $systemIntegration.SendIntegrationEvent($testEvent)
        Add-TestResult "Integration Event Creation" $true "Created and queued test event"

    } catch {
        Add-TestResult "SystemIntegrationMonitor Creation" $false $_.Exception.Message
    }

    # Test 10: Monitoring Dashboard (Basic Test)
    Write-Host "`nTesting Monitoring Dashboard..."

    try {
        $dashboard = [MonitoringDashboard]::new($config, $logger)
        Add-TestResult "MonitoringDashboard Creation" $true

        # Test HTML generation
        $html = $dashboard.GenerateMainDashboard()
        $htmlValid = $html.Contains("<html>") -and $html.Contains("</html>")
        Add-TestResult "Dashboard HTML Generation" $htmlValid "Generated $($html.Length) characters of HTML"

        # Test CSS generation
        $css = $dashboard.GetCssStyles()
        $cssValid = $css.Contains("body") -and $css.Contains("color")
        Add-TestResult "Dashboard CSS Generation" $cssValid "Generated $($css.Length) characters of CSS"

        # Test JavaScript generation
        $js = $dashboard.GetJavaScript()
        $jsValid = $js.Contains("class") -and $js.Contains("function")
        Add-TestResult "Dashboard JavaScript Generation" $jsValid "Generated $($js.Length) characters of JavaScript"

    } catch {
        Add-TestResult "MonitoringDashboard Creation" $false $_.Exception.Message
    }

    # Test 11: Integration Testing
    Write-Host "`nTesting Component Integration..."

    try {
        # Test alerting system with diagnostics
        if ($alerting -and $diagnostics) {
            $alerting.Diagnostics = $diagnostics
            Add-TestResult "Alerting-Diagnostics Integration" $true "Components linked successfully"
        }

        # Test metrics exporter with alerting
        if ($metricsExporter -and $alerting) {
            $metricsExporter.SetAlertingSystem($alerting)
            Add-TestResult "MetricsExporter-Alerting Integration" $true "Components linked successfully"
        }

        # Test comprehensive workflow
        if ($diagnostics -and $alerting -and $metricsExporter) {
            # Simulate a complete monitoring cycle
            $health = $diagnostics.GetSystemHealth()

            if ($health.Status -eq 'Warning' -or $health.Status -eq 'Critical') {
                $alert = [Alert]::new(
                    [AlertSeverity]::Warning,
                    [AlertCategory]::SystemHealth,
                    "Health Check Alert",
                    "System health status: $($health.Status)"
                )
                $alerting.RaiseAlert($alert)
            }

            # Export metrics
            $customMetrics = @{
                integration_test_completed = 1
                health_status_numeric = if ($health.Status -eq 'Healthy') { 1 } else { 0 }
            }
            $metricsExporter.ExportCustomMetrics($customMetrics)

            Add-TestResult "End-to-End Workflow" $true "Complete monitoring cycle executed"
        }

    } catch {
        Add-TestResult "Component Integration" $false $_.Exception.Message
    }

    # Performance Tests (Optional)
    if ($IncludePerformanceTests) {
        Write-Host "`nRunning Performance Tests..."

        try {
            # Test performance counter operations
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            for ($i = 1; $i -le 1000; $i++) {
                $perfCounters.IncrementFilesProcessed()
                $perfCounters.RecordProcessingTime([math]::Round((Get-Random -Maximum 60 -Minimum 1), 2))
            }

            $stopwatch.Stop()
            $operationsPerSecond = [math]::Round(1000 / $stopwatch.Elapsed.TotalSeconds, 2)

            Add-TestResult "Performance Counter Throughput" ($operationsPerSecond -gt 100) "$operationsPerSecond operations/second"

            # Test alert processing performance
            $stopwatch.Restart()

            for ($i = 1; $i -le 100; $i++) {
                $testAlert = [Alert]::new(
                    [AlertSeverity]::Info,
                    [AlertCategory]::Performance,
                    "Performance Test Alert $i",
                    "Test alert for performance validation"
                )
                $alerting.RaiseAlert($testAlert)
            }

            $stopwatch.Stop()
            $alertsPerSecond = [math]::Round(100 / $stopwatch.Elapsed.TotalSeconds, 2)

            Add-TestResult "Alert Processing Throughput" ($alertsPerSecond -gt 10) "$alertsPerSecond alerts/second"

        } catch {
            Add-TestResult "Performance Tests" $false $_.Exception.Message
        }
    }

    # Test 12: Directory Structure Validation
    Write-Host "`nValidating Directory Structure..."

    $requiredDirectories = @(
        "modules/FileCopier",
        "config",
        "docs"
    )

    foreach ($dir in $requiredDirectories) {
        $exists = Test-Path $dir
        Add-TestResult "Directory Exists: $dir" $exists
    }

    # Test 13: File Validation
    Write-Host "`nValidating Required Files..."

    $requiredFiles = @(
        "modules/FileCopier/PerformanceCounters.ps1",
        "modules/FileCopier/DiagnosticCommands.ps1",
        "modules/FileCopier/MonitoringDashboard.ps1",
        "modules/FileCopier/AlertingSystem.ps1",
        "modules/FileCopier/MetricsExporter.ps1",
        "modules/FileCopier/LogAnalyzer.ps1",
        "modules/FileCopier/SystemIntegration.ps1",
        "docs/troubleshooting-guide.md"
    )

    foreach ($file in $requiredFiles) {
        $exists = Test-Path $file
        if ($exists) {
            $size = (Get-Item $file).Length
            Add-TestResult "File Exists: $($file.Split('/')[-1])" $true "$([math]::Round($size / 1KB, 1)) KB"
        } else {
            Add-TestResult "File Exists: $($file.Split('/')[-1])" $false "File not found"
        }
    }

} catch {
    Add-TestResult "Critical Error" $false $_.Exception.Message
    Write-Host "`nCritical error occurred: $($_.Exception.Message)" -ForegroundColor Red
}

# Display Results Summary
Write-Host "`n" + "=" * 80
Write-Host "VALIDATION RESULTS SUMMARY"
Write-Host "=" * 80

Write-Host "Total Tests: $($testResults.TotalTests)" -ForegroundColor White
Write-Host "Passed: $($testResults.PassedTests)" -ForegroundColor Green
Write-Host "Failed: $($testResults.FailedTests)" -ForegroundColor Red
Write-Host "Warnings: $($testResults.Warnings)" -ForegroundColor Yellow

$successRate = if ($testResults.TotalTests -gt 0) {
    [math]::Round(($testResults.PassedTests / $testResults.TotalTests) * 100, 1)
} else { 0 }

Write-Host "Success Rate: $successRate%" -ForegroundColor $(if ($successRate -ge 90) { "Green" } elseif ($successRate -ge 70) { "Yellow" } else { "Red" })

if ($testResults.FailedTests -gt 0) {
    Write-Host "`nFAILED TESTS:" -ForegroundColor Red
    $testResults.Results | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        Write-Host "  - $($_.TestName): $($_.Message)" -ForegroundColor Red
    }
}

if ($testResults.Warnings -gt 0) {
    Write-Host "`nWARNINGS:" -ForegroundColor Yellow
    $testResults.Results | Where-Object { $_.Status -eq "WARNING" } | ForEach-Object {
        Write-Host "  - $($_.TestName): $($_.Message)" -ForegroundColor Yellow
    }
}

if ($Detailed) {
    Write-Host "`nDETAILED RESULTS:" -ForegroundColor White
    $testResults.Results | ForEach-Object {
        $color = switch ($_.Status) {
            "PASS" { "Green" }
            "FAIL" { "Red" }
            "WARNING" { "Yellow" }
            default { "White" }
        }
        Write-Host "[$($_.Status)] $($_.TestName)" -ForegroundColor $color
        if ($_.Message) {
            Write-Host "    $($_.Message)" -ForegroundColor Gray
        }
        Write-Host "    Timestamp: $($_.Timestamp)" -ForegroundColor DarkGray
    }
}

Write-Host "`n" + "=" * 80
Write-Host "Phase 5B Validation Complete"

if ($testResults.FailedTests -eq 0) {
    Write-Host "All critical tests passed! Phase 5B is ready for deployment." -ForegroundColor Green
} elseif ($testResults.FailedTests -le 2 -and $successRate -ge 85) {
    Write-Host "Minor issues detected. Phase 5B is functional but may need attention." -ForegroundColor Yellow
} else {
    Write-Host "Significant issues detected. Please review and fix failed tests." -ForegroundColor Red
}

Write-Host "=" * 80

# Return test results for potential automation
return $testResults