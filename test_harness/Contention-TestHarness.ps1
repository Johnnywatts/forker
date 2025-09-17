#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Contention Testing Harness for File Copier Service
.DESCRIPTION
    Comprehensive test harness for validating file copier service resilience
    under multi-process contention scenarios.
.PARAMETER RunAll
    Run all enabled test categories
.PARAMETER Category
    Run specific test category (FileLocking, RaceConditions, Recovery, Performance)
.PARAMETER TestId
    Run specific test by ID (e.g., RDW-001)
.PARAMETER ConfigPath
    Path to test configuration file
.PARAMETER ReportFormat
    Output report format (JSON, Summary, Detailed)
.PARAMETER Verbose
    Enable verbose logging
.EXAMPLE
    ./Contention-TestHarness.ps1 -RunAll
.EXAMPLE
    ./Contention-TestHarness.ps1 -Category "FileLocking"
.EXAMPLE
    ./Contention-TestHarness.ps1 -TestId "RDW-001" -Verbose
#>

param(
    [switch] $RunAll,
    [string] $Category,
    [string] $TestId,
    [string] $ConfigPath = "config/ContentionTestConfig.json",
    [ValidateSet("JSON", "Summary", "Detailed")]
    [string] $ReportFormat = "Summary",
    [switch] $Verbose
)

# Import framework components
$frameworkPath = Join-Path $PSScriptRoot "framework"
. (Join-Path $frameworkPath "TestResult.ps1")
. (Join-Path $frameworkPath "TestCase.ps1")
. (Join-Path $frameworkPath "TestUtils.ps1")
. (Join-Path $frameworkPath "TestIsolation.ps1")
. (Join-Path $frameworkPath "EmergencyCleanup.ps1")
. (Join-Path $frameworkPath "ProcessCoordinator.ps1")
. (Join-Path $frameworkPath "SharedState.ps1")
. (Join-Path $frameworkPath "FileAccessValidator.ps1")
. (Join-Path $frameworkPath "FileLockingTests.ps1")
. (Join-Path $frameworkPath "RDW001Test.ps1")
. (Join-Path $frameworkPath "DDO001Test.ps1")
. (Join-Path $frameworkPath "WDR001Test.ps1")
. (Join-Path $frameworkPath "RaceConditionTests.ps1")
. (Join-Path $frameworkPath "SAP001TestSimplified.ps1")
. (Join-Path $frameworkPath "AOV002Test.ps1")
. (Join-Path $frameworkPath "ResourceMonitor.ps1")

# Define the test harness class
class ContentionTestHarness {
    [hashtable] $Configuration
    [string] $ReportsDirectory
    [object] $Results  # ContentionHarnessResult - using object for now
    [bool] $VerboseLogging
    [object] $EmergencyCleanup  # EmergencyCleanupManager
    [object] $ResourceMonitor   # ResourceMonitor for system tracking

    ContentionTestHarness([string] $configPath, [bool] $verbose) {
        $this.VerboseLogging = $verbose
        $this.Results = New-Object ContentionHarnessResult

        # Initialize emergency cleanup
        $harnessId = $this.Results.ExecutionId
        $this.EmergencyCleanup = New-Object EmergencyCleanupManager -ArgumentList $harnessId

        # Initialize resource monitoring
        $this.ResourceMonitor = New-ResourceMonitor -MonitorId "ContentionHarness-$harnessId"

        $this.LoadConfiguration($configPath)
        $this.InitializeEnvironment()
    }

    [void] LoadConfiguration([string] $configPath) {
        $fullPath = Join-Path $PSScriptRoot $configPath

        if (-not (Test-Path $fullPath)) {
            throw "Configuration file not found: $fullPath"
        }

        try {
            $configContent = Get-Content $fullPath -Raw | ConvertFrom-Json
            $this.Configuration = @{}

            # Convert JSON to hashtable for easier access
            $configContent.PSObject.Properties | ForEach-Object {
                $this.Configuration[$_.Name] = $_.Value
            }

            $this.LogInfo("Configuration loaded from: $fullPath")
        }
        catch {
            throw "Failed to load configuration: $($_.Exception.Message)"
        }
    }

    [void] InitializeEnvironment() {
        # Create required directories
        $baseDir = $this.Configuration.testEnvironment.baseDirectory
        $tempDir = $this.Configuration.testEnvironment.tempDirectory
        $syncDir = $this.Configuration.testEnvironment.syncDirectory
        $reportsDir = $this.Configuration.testEnvironment.reportsDirectory

        @($baseDir, $tempDir, $syncDir, $reportsDir) | ForEach-Object {
            if (-not (Test-Path $_)) {
                New-Item -ItemType Directory -Path $_ -Force | Out-Null
                $this.LogInfo("Created directory: $_")
            }
        }

        $this.ReportsDirectory = $reportsDir

        # Register main directories with emergency cleanup
        $this.EmergencyCleanup.RegisterTempDirectory($tempDir)
        $this.EmergencyCleanup.RegisterTempDirectory($syncDir)

        # Configure resource monitoring with enhanced capabilities
        $this.ConfigureResourceMonitoring()

        # Store system information
        $platformInfo = Get-PlatformInfo
        $this.Results.AddSystemMetric("Platform", $platformInfo)
        $this.Results.AddSystemMetric("PowerShellVersion", "7.0+")
        $this.Results.AddSystemMetric("StartTime", (Get-Date))
    }

    [void] RunAllTests() {
        $this.LogInfo("Starting comprehensive contention test execution")

        # Start system resource monitoring
        $this.ResourceMonitor.StartMonitoring()
        $this.ResourceMonitor.LogResourceStatus("Pre-Execution")

        try {
            foreach ($category in $this.Configuration.testCategories.PSObject.Properties) {
                if ($category.Value.enabled) {
                    $this.RunTestCategory($category.Name)
                } else {
                    $this.LogInfo("Skipping disabled category: $($category.Name)")
                }
            }
        }
        finally {
            # Stop resource monitoring and check for leaks
            $this.ResourceMonitor.StopMonitoring()
            $this.ResourceMonitor.LogResourceStatus("Post-Execution")
            $this.ValidateSystemResources()
        }
    }

    [void] RunTestCategory([string] $categoryName) {
        $this.LogInfo("Running test category: $categoryName")

        # Start resource monitoring for category
        if (-not $this.ResourceMonitor.IsMonitoring) {
            $this.ResourceMonitor.StartMonitoring()
            $this.ResourceMonitor.LogResourceStatus("Pre-Category-$categoryName")
        }

        try {
            $categoryConfig = $this.Configuration.testCategories.$categoryName
            if (-not $categoryConfig) {
                throw "Unknown test category: $categoryName"
            }

            $suiteResult = New-Object TestSuiteResult -ArgumentList $categoryName

            foreach ($testId in $categoryConfig.tests) {
                try {
                    $testResult = $this.RunSingleTest($testId, $categoryName)
                    $suiteResult.AddTestResult($testResult)
                }
                catch {
                    $this.LogError("Failed to execute test $testId : $($_.Exception.Message)")
                    $failedResult = New-Object TestResult -ArgumentList $testId, $categoryName
                    $failedResult.Complete($false, "Test execution failed: $($_.Exception.Message)")
                    $suiteResult.AddTestResult($failedResult)
                }
            }

            $suiteResult.Complete()
            $this.Results.AddSuiteResult($suiteResult)

            $this.LogInfo("Category $categoryName completed: $($suiteResult.PassedTests)/$($suiteResult.TotalTests) passed")
        }
        finally {
            # Stop resource monitoring and validate for category
            if ($this.ResourceMonitor.IsMonitoring) {
                $this.ResourceMonitor.StopMonitoring()
                $this.ResourceMonitor.LogResourceStatus("Post-Category-$categoryName")
                $this.ValidateSystemResources()
            }
        }
    }

    [object] RunSingleTest([string] $testId, [string] $category) {
        $this.LogInfo("Executing test: $testId")

        # Take resource snapshot before test
        $preTestSnapshot = $this.ResourceMonitor.TakeSnapshot("Pre-$testId")

        # Apply category configuration
        $categoryConfig = $this.Configuration.testCategories.$category

        # Create appropriate test based on test ID and isolation level
        $isolationLevel = $categoryConfig.isolationLevel

        # Create specialized tests for specific test IDs
        if ($testId -eq "BARRIER-001") {
            $test = New-Object BarrierSynchronizationTest
        } elseif ($testId -eq "SHARED-001") {
            $test = New-Object SharedStateTest
        } elseif ($testId -eq "RDW-001") {
            $test = New-Object ReadDuringWriteTest
        } elseif ($testId -eq "DDO-001") {
            $test = New-Object DeleteDuringWriteTest
        } elseif ($testId -eq "WDR-001") {
            $test = New-Object WriteDuringReadTest
        } elseif ($testId -eq "SAP-001") {
            $test = New-Object SimultaneousAccessTestSimplified
        } elseif ($testId -eq "AOV-002") {
            $test = New-Object MultiDestinationAtomicityTest
        } elseif ($isolationLevel -eq "Process") {
            $test = New-Object IsolatedDummyTest
        } else {
            $test = New-Object DummyTest
        }
        $test.TestId = $testId
        $test.TestCategory = $category
        $test.Description = "Placeholder test for $testId"

        $test.Configuration = @{
            Timeout = $categoryConfig.timeoutSeconds
            Retries = $categoryConfig.defaultRetries
            IsolationLevel = $categoryConfig.isolationLevel
        }

        $testResult = $test.Execute()

        # Take resource snapshot after test and validate
        $postTestSnapshot = $this.ResourceMonitor.TakeSnapshot("Post-$testId")
        $this.ValidateTestResources($testId, $preTestSnapshot, $postTestSnapshot)

        return $testResult
    }

    [void] RunSpecificTest([string] $testId) {
        $this.LogInfo("Running specific test: $testId")

        # Find which category this test belongs to
        $category = $null
        foreach ($cat in $this.Configuration.testCategories.PSObject.Properties) {
            if ($testId -in $cat.Value.tests) {
                $category = $cat.Name
                break
            }
        }

        if (-not $category) {
            throw "Test $testId not found in any category"
        }

        $suiteResult = New-Object TestSuiteResult -ArgumentList "Single-$category"
        $testResult = $this.RunSingleTest($testId, $category)
        $suiteResult.AddTestResult($testResult)
        $suiteResult.Complete()

        $this.Results.AddSuiteResult($suiteResult)
    }

    [void] GenerateReport([string] $format) {
        $this.Results.Complete()

        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $reportFile = Join-Path $this.ReportsDirectory "contention-test-$timestamp"

        switch ($format) {
            "JSON" {
                $reportFile += ".json"
                $this.Results.ToHashtable() | ConvertTo-Json -Depth 10 | Set-Content $reportFile
                $this.LogInfo("JSON report saved: $reportFile")
            }
            "Summary" {
                $this.GenerateSummaryReport()
            }
            "Detailed" {
                $reportFile += ".html"
                $this.GenerateDetailedReport($reportFile)
                $this.LogInfo("Detailed report saved: $reportFile")
            }
        }
    }

    [void] GenerateSummaryReport() {
        Write-Host ""
        Write-Host "=== CONTENTION TEST HARNESS RESULTS ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Execution ID: $($this.Results.ExecutionId)" -ForegroundColor Gray
        Write-Host "Duration: $([math]::Round($this.Results.DurationSeconds, 2)) seconds" -ForegroundColor Gray
        Write-Host ""

        if ($this.Results.Success) {
            Write-Host "Overall Result: ✅ PASSED" -ForegroundColor Green
        } else {
            Write-Host "Overall Result: ❌ FAILED" -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "Test Summary:" -ForegroundColor Yellow
        Write-Host "  Total Suites: $($this.Results.TotalSuites)"
        Write-Host "  Total Tests: $($this.Results.TotalTests)"
        Write-Host "  Passed: $($this.Results.PassedTests)" -ForegroundColor Green
        Write-Host "  Failed: $($this.Results.FailedTests)" -ForegroundColor $(if ($this.Results.FailedTests -eq 0) { 'Green' } else { 'Red' })

        if ($this.Results.TotalTests -gt 0) {
            $successRate = [math]::Round(($this.Results.PassedTests / $this.Results.TotalTests) * 100, 1)
            Write-Host "  Success Rate: $successRate%" -ForegroundColor $(if ($successRate -eq 100) { 'Green' } else { 'Yellow' })
        }

        Write-Host ""
        Write-Host "Suite Details:" -ForegroundColor Yellow
        foreach ($suite in $this.Results.SuiteResults) {
            $status = if ($suite.Success) { "✅" } else { "❌" }
            $duration = [math]::Round($suite.DurationSeconds, 2)
            Write-Host "  $status $($suite.SuiteName): $($suite.PassedTests)/$($suite.TotalTests) passed ($duration s)"
        }

        Write-Host ""
    }

    [void] GenerateDetailedReport([string] $filePath) {
        # Placeholder for detailed HTML report - will be implemented in later commits
        $this.LogInfo("Detailed reporting will be implemented in future commits")
        $this.Results.ToHashtable() | ConvertTo-Json -Depth 10 | Set-Content $filePath
    }

    [void] ValidateSystemResources() {
        $resourceReport = $this.ResourceMonitor.GetResourceReport()
        $leaks = $resourceReport.Leaks

        if ($leaks.HasLeaks) {
            $this.LogError("System resource leaks detected after test execution")
            foreach ($violation in $leaks.Violations) {
                $this.LogError("$($violation.Type) leak: Current $($violation.Current), Threshold $($violation.Threshold), Severity $($violation.Severity)")
            }

            # Add leak information to results
            $this.Results.AddSystemMetric("ResourceLeaksDetected", $true)
            $this.Results.AddSystemMetric("LeakTypes", $leaks.LeakTypes)
        } else {
            $this.LogInfo("No system resource leaks detected")
            $this.Results.AddSystemMetric("ResourceLeaksDetected", $false)
        }

        # Add resource summary to results
        $this.Results.AddSystemMetric("ResourceSummary", $leaks.Summary)
    }

    [void] ValidateTestResources([string] $testId, [hashtable] $preSnapshot, [hashtable] $postSnapshot) {
        try {
            # Calculate basic resource delta for this specific test
            $memoryDelta = $postSnapshot.MemoryMB - $preSnapshot.MemoryMB
            $handlesDelta = $postSnapshot.FileHandles - $preSnapshot.FileHandles
            $processesDelta = $postSnapshot.ProcessCount - $preSnapshot.ProcessCount

            # Enhanced resource validation using new capabilities
            $memoryLeaks = $this.ResourceMonitor.DetectMemoryLeaks($preSnapshot, $postSnapshot)
            $handleLeaks = $this.ResourceMonitor.DetectFileHandleLeaks($preSnapshot, $postSnapshot)
            $memoryDetails = $this.ResourceMonitor.GetMemoryUsageDetails()

            # Log comprehensive resource usage for this test
            $resourceMsg = "Test $testId resource usage: Memory Δ$($memoryDelta)MB"
            if ($memoryDetails.ProcessMemoryPercentage -gt 0) {
                $resourceMsg += " ($($memoryDetails.ProcessMemoryPercentage)% of system)"
            }
            $resourceMsg += ", Handles Δ$handlesDelta"
            if ($postSnapshot.OpenFiles) {
                $resourceMsg += " (Files: $($postSnapshot.OpenFiles.Count))"
            }
            $resourceMsg += ", Processes Δ$processesDelta"
            if ($memoryDetails.MemoryPressure -ne "Low") {
                $resourceMsg += " - Memory Pressure: $($memoryDetails.MemoryPressure)"
            }
            $this.LogInfo($resourceMsg)

            # Check for memory leaks using enhanced detection
            if ($memoryLeaks.HasLeaks) {
                $this.LogError("MEMORY LEAK detected in test ${testId}:")
                $this.LogError("  Severity: $($memoryLeaks.LeakSeverity), Increase: $($memoryLeaks.MemoryIncreaseMB)MB")
                if ($memoryLeaks.GrowthRate -gt 0) {
                    $this.LogError("  Growth Rate: $($memoryLeaks.GrowthRate) MB/min")
                }
                foreach ($recommendation in $memoryLeaks.Recommendations) {
                    $this.LogError("  Recommendation: $recommendation")
                }
            }

            # Check for file handle leaks using enhanced detection
            if ($handleLeaks.HasLeaks) {
                $this.LogError("FILE HANDLE LEAK detected in test ${testId}:")
                $this.LogError("  Leaked Handles: $($handleLeaks.LeakCount)")
                if ($handleLeaks.SuspiciousFiles.Count -gt 0) {
                    $this.LogError("  Suspicious Files: $($handleLeaks.SuspiciousFiles.Count)")
                    foreach ($file in $handleLeaks.SuspiciousFiles) {
                        $this.LogError("    $($file.Type): $($file.Path) - $($file.Reason)")
                    }
                }
                foreach ($recommendation in $handleLeaks.Recommendations) {
                    $this.LogError("  Recommendation: $recommendation")
                }
            }

            # Check for process leaks (critical)
            if ($processesDelta -gt 0) {
                $this.LogError("PROCESS LEAK detected in test ${testId}: $processesDelta process(es) not cleaned up")
                $this.LogError("  Recommendation: Review test teardown for proper process cleanup")
            }

            # Check system memory pressure
            if ($memoryDetails.MemoryPressure -eq "High") {
                $this.LogError("HIGH MEMORY PRESSURE detected during test ${testId}")
                $this.LogError("  Available: $($memoryDetails.SystemAvailableMemoryMB)MB of $($memoryDetails.SystemTotalMemoryMB)MB")
                $this.LogError("  Recommendation: Consider reducing test concurrency or test data size")
            } elseif ($memoryDetails.MemoryPressure -eq "Medium") {
                $this.LogInfo("Medium memory pressure during test ${testId} - monitoring recommended")
            }

            # Log success for tests with no leaks
            if (-not $memoryLeaks.HasLeaks -and -not $handleLeaks.HasLeaks -and $processesDelta -eq 0) {
                $this.LogInfo("Test ${testId} completed with no resource leaks detected")
            }
        }
        catch {
            $this.LogError("Error validating test resources for ${testId} : $($_.Exception.Message)")
        }
    }

    [void] ConfigureResourceMonitoring() {
        try {
            $this.LogInfo("Configuring enhanced resource monitoring capabilities")

            # Configure monitoring thresholds from configuration
            $this.ResourceMonitor.SetThreshold("MaxMemoryIncreaseMB", $this.Configuration.monitoring.memoryThresholdMB)
            $this.ResourceMonitor.SetThreshold("MaxFileHandleIncrease", $this.Configuration.monitoring.fileHandleThreshold)
            $this.ResourceMonitor.SetThreshold("MaxProcessIncrease", 5)

            # Validate enhanced capabilities
            $validation = $this.ResourceMonitor.ValidateEnhancedCapabilities()

            if ($validation.Success) {
                $this.LogInfo("Enhanced resource monitoring validation PASSED")
                $this.LogInfo("Platform: $($validation.Platform)")

                # Log available capabilities
                foreach ($capability in $validation.Capabilities.GetEnumerator()) {
                    if ($capability.Value.Available) {
                        $this.LogInfo("  ✓ $($capability.Key): Available")
                    } else {
                        $this.LogInfo("  ✗ $($capability.Key): Not Available")
                    }
                }

                # Store capabilities information
                $this.Results.AddSystemMetric("ResourceMonitoringCapabilities", $validation.Capabilities)
            } else {
                $this.LogError("Enhanced resource monitoring validation FAILED")
                foreach ($error in $validation.Errors) {
                    $this.LogError("  Validation Error: $error")
                }
                # Continue anyway with basic monitoring
            }

            # Log current system resource status
            $memoryDetails = $this.ResourceMonitor.GetMemoryUsageDetails()
            if (-not $memoryDetails.Error) {
                $this.LogInfo("System Memory Status:")
                $this.LogInfo("  Process: $($memoryDetails.CurrentProcessMemoryMB)MB ($($memoryDetails.ProcessMemoryPercentage)% of system)")
                $this.LogInfo("  System: $($memoryDetails.SystemAvailableMemoryMB)MB available of $($memoryDetails.SystemTotalMemoryMB)MB total")
                $this.LogInfo("  Memory Pressure: $($memoryDetails.MemoryPressure)")

                # Store baseline system metrics
                $this.Results.AddSystemMetric("BaselineMemoryDetails", $memoryDetails)
            }
        }
        catch {
            $this.LogError("Error configuring resource monitoring: $($_.Exception.Message)")
            # Continue with basic monitoring
        }
    }

    [void] Cleanup() {
        try {
            # Clean up resource monitoring
            if ($this.ResourceMonitor) {
                $this.ResourceMonitor.Cleanup()
            }

            # Execute emergency cleanup for comprehensive cleanup
            $this.EmergencyCleanup.ExecuteEmergencyCleanup()
            $this.LogInfo("Emergency cleanup completed successfully")
        }
        catch {
            $this.LogError("Emergency cleanup failed: $($_.Exception.Message)")
        }

        # Clean up temporary directories (fallback)
        $tempDir = $this.Configuration.testEnvironment.tempDirectory
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            $this.LogInfo("Cleaned up temporary directory: $tempDir")
        }
    }

    [void] LogInfo([string] $message) {
        Write-TestLog -Message $message -Level "INFO" -TestId "HARNESS"
    }

    [void] LogError([string] $message) {
        Write-TestLog -Message $message -Level "ERROR" -TestId "HARNESS"
    }
}

# Main execution
function Main {
    try {
        $harness = [ContentionTestHarness]::new($ConfigPath, $Verbose)

        if ($TestId) {
            $harness.RunSpecificTest($TestId)
        } elseif ($Category) {
            $harness.RunTestCategory($Category)
        } elseif ($RunAll) {
            $harness.RunAllTests()
        } else {
            Write-Host "Usage: Specify -RunAll, -Category, or -TestId" -ForegroundColor Yellow
            Write-Host "Examples:" -ForegroundColor Gray
            Write-Host "  ./Contention-TestHarness.ps1 -RunAll" -ForegroundColor Gray
            Write-Host "  ./Contention-TestHarness.ps1 -Category 'FileLocking'" -ForegroundColor Gray
            Write-Host "  ./Contention-TestHarness.ps1 -TestId 'RDW-001'" -ForegroundColor Gray
            exit 1
        }

        $harness.GenerateReport($ReportFormat)
        $harness.Cleanup()

        # Exit with appropriate code
        if ($harness.Results.Success) {
            Write-Host "All tests completed successfully! 🚀" -ForegroundColor Green
            exit 0
        } else {
            Write-Host "Some tests failed. Check the report for details. ⚠️" -ForegroundColor Yellow
            exit 1
        }
    }
    catch {
        Write-Host "❌ FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }
}

# Execute main function
Main