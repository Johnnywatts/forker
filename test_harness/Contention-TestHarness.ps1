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

# Define the test harness class
class ContentionTestHarness {
    [hashtable] $Configuration
    [string] $ReportsDirectory
    [object] $Results  # ContentionHarnessResult - using object for now
    [bool] $VerboseLogging
    [object] $EmergencyCleanup  # EmergencyCleanupManager

    ContentionTestHarness([string] $configPath, [bool] $verbose) {
        $this.VerboseLogging = $verbose
        $this.Results = New-Object ContentionHarnessResult

        # Initialize emergency cleanup
        $harnessId = $this.Results.ExecutionId
        $this.EmergencyCleanup = New-Object EmergencyCleanupManager -ArgumentList $harnessId

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

        # Store system information
        $platformInfo = Get-PlatformInfo
        $this.Results.AddSystemMetric("Platform", $platformInfo)
        $this.Results.AddSystemMetric("PowerShellVersion", "7.0+")
        $this.Results.AddSystemMetric("StartTime", (Get-Date))
    }

    [void] RunAllTests() {
        $this.LogInfo("Starting comprehensive contention test execution")

        foreach ($category in $this.Configuration.testCategories.PSObject.Properties) {
            if ($category.Value.enabled) {
                $this.RunTestCategory($category.Name)
            } else {
                $this.LogInfo("Skipping disabled category: $($category.Name)")
            }
        }
    }

    [void] RunTestCategory([string] $categoryName) {
        $this.LogInfo("Running test category: $categoryName")

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

    [object] RunSingleTest([string] $testId, [string] $category) {
        $this.LogInfo("Executing test: $testId")

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

        return $test.Execute()
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

    [void] Cleanup() {
        try {
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