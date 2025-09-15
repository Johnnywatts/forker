# RunTests.ps1 - Test runner for File Copier Service

[CmdletBinding()]
param(
    [string]$TestPath = ".",
    [string]$OutputFormat = "NUnitXml",
    [string]$OutputPath = "TestResults.xml",
    [switch]$ShowPassed,
    [switch]$CodeCoverage,
    [string[]]$Tag,
    [string[]]$ExcludeTag
)

# Ensure we're in the tests directory
Push-Location $PSScriptRoot

try {
    Write-Host "=== File Copier Service Test Runner ===" -ForegroundColor Cyan
    Write-Host ""

    # Check if Pester is available
    try {
        Import-Module Pester -Force -ErrorAction Stop
        $pesterVersion = (Get-Module Pester).Version
        Write-Host "Using Pester version: $pesterVersion" -ForegroundColor Green
    }
    catch {
        Write-Error "Pester module not found. Please install Pester:"
        Write-Host "Install-Module -Name Pester -Force -SkipPublisherCheck" -ForegroundColor Yellow
        exit 1
    }

    # Configure Pester
    $pesterConfig = @{
        Run = @{
            Path = $TestPath
            PassThru = $true
        }
        Output = @{
            Verbosity = if ($ShowPassed) { 'Detailed' } else { 'Normal' }
        }
        TestResult = @{
            Enabled = $true
            OutputFormat = $OutputFormat
            OutputPath = $OutputPath
        }
    }

    # Add tags if specified
    if ($Tag) {
        $pesterConfig.Filter = @{ Tag = $Tag }
    }
    if ($ExcludeTag) {
        if (-not $pesterConfig.Filter) { $pesterConfig.Filter = @{} }
        $pesterConfig.Filter.ExcludeTag = $ExcludeTag
    }

    # Add code coverage if requested
    if ($CodeCoverage) {
        $pesterConfig.CodeCoverage = @{
            Enabled = $true
            Path = @(
                "$PSScriptRoot\..\modules\FileCopier\*.ps1"
            )
            OutputFormat = 'JaCoCo'
            OutputPath = 'coverage.xml'
        }
    }

    # Run the tests
    Write-Host "Running tests..." -ForegroundColor Yellow
    Write-Host ""

    $configuration = New-PesterConfiguration -Hashtable $pesterConfig
    $result = Invoke-Pester -Configuration $configuration

    # Display results summary
    Write-Host ""
    Write-Host "=== Test Results Summary ===" -ForegroundColor Cyan
    Write-Host "Total Tests:    $($result.TotalCount)" -ForegroundColor White
    Write-Host "Passed:         $($result.PassedCount)" -ForegroundColor Green
    Write-Host "Failed:         $($result.FailedCount)" -ForegroundColor $(if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' })
    Write-Host "Skipped:        $($result.SkippedCount)" -ForegroundColor Yellow
    Write-Host "Duration:       $($result.Duration)" -ForegroundColor White

    if ($CodeCoverage -and $result.CodeCoverage) {
        $coveragePercent = [math]::Round($result.CodeCoverage.CoveragePercent, 2)
        Write-Host "Code Coverage:  $coveragePercent%" -ForegroundColor $(if ($coveragePercent -ge 80) { 'Green' } else { 'Yellow' })
    }

    Write-Host ""

    # Show failed tests if any
    if ($result.FailedCount -gt 0) {
        Write-Host "=== Failed Tests ===" -ForegroundColor Red
        foreach ($test in $result.Failed) {
            Write-Host "❌ $($test.ExpandedPath)" -ForegroundColor Red
            if ($test.ErrorRecord) {
                Write-Host "   $($test.ErrorRecord.Exception.Message)" -ForegroundColor DarkRed
            }
        }
        Write-Host ""
    }

    # Return appropriate exit code
    if ($result.FailedCount -eq 0) {
        Write-Host "✅ All tests passed!" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "❌ Some tests failed." -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Error "Test execution failed: $($_.Exception.Message)"
    exit 1
}
finally {
    Pop-Location
}