# FileCopier Service - Windows Laptop Testing Environment Setup
# This script creates a complete testing environment on a Windows laptop

param(
    [string]$TestRoot = "C:\FileCopierTest",
    [switch]$CleanInstall,
    [switch]$CreateSampleFiles,
    [int]$SampleFileCount = 10
)

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "FileCopier Service - Testing Environment Setup" -ForegroundColor Cyan
Write-Host "Setting up comprehensive testing on Windows laptop" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan

# Check PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "`nPowerShell Version: $psVersion" -ForegroundColor Green

if ($psVersion.Major -lt 5) {
    Write-Error "PowerShell 5.0 or higher required. Please update PowerShell."
    exit 1
}

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator. Some tests may fail."
    Write-Host "Consider running: Start-Process PowerShell -Verb RunAs" -ForegroundColor Yellow
}

# Clean up existing test environment if requested
if ($CleanInstall -and (Test-Path $TestRoot)) {
    Write-Host "`nCleaning existing test environment..." -ForegroundColor Yellow
    try {
        Remove-Item $TestRoot -Recurse -Force
        Write-Host "✓ Cleaned existing test environment" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to clean existing environment: $($_.Exception.Message)"
        exit 1
    }
}

# Create test directory structure
Write-Host "`nCreating test directory structure..." -ForegroundColor Yellow

$testDirectories = @(
    "$TestRoot\Source",
    "$TestRoot\TargetA",
    "$TestRoot\TargetB",
    "$TestRoot\Quarantine",
    "$TestRoot\Temp",
    "$TestRoot\Logs",
    "$TestRoot\Logs\Audit",
    "$TestRoot\Config",
    "$TestRoot\TestData",
    "$TestRoot\TestData\Large",
    "$TestRoot\TestData\Small",
    "$TestRoot\TestData\Mixed"
)

foreach ($dir in $testDirectories) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Write-Host "✓ Created: $dir" -ForegroundColor Green
    }
}

# Create test configuration file
Write-Host "`nCreating test configuration..." -ForegroundColor Yellow

$testConfig = @{
    SourceDirectory = "$TestRoot\Source"
    Targets = @{
        TargetA = @{
            Path = "$TestRoot\TargetA"
            Enabled = $true
            Description = "Primary test target"
        }
        TargetB = @{
            Path = "$TestRoot\TargetB"
            Enabled = $true
            Description = "Secondary test target"
        }
    }
    FileWatcher = @{
        PollingInterval = 2000
        StabilityCheckInterval = 1000
        StabilityChecks = 2
        IncludePatterns = @("*.svs", "*.tiff", "*.tif", "*.txt", "*.test", "*.jpg", "*.png")
        ExcludePatterns = @("*.tmp", "*.temp", "*~*", "*.partial")
        MinFileSizeBytes = 1024
        MaxFileSizeBytes = 1073741824  # 1GB for laptop testing
    }
    Processing = @{
        MaxConcurrentCopies = 2
        RetryAttempts = 2
        RetryDelay = 2000
        QueueCheckInterval = 500
        QuarantineDirectory = "$TestRoot\Quarantine"
        TempDirectory = "$TestRoot\Temp"
        CleanupRetentionDays = 1
    }
    Verification = @{
        Enabled = $true
        HashAlgorithm = "SHA256"
        HashRetryAttempts = 1
        HashRetryDelay = 1000
        StreamBufferSize = 65536
        ParallelHashingEnabled = $false
        VerifyAfterCopy = $true
        VerifySourceBeforeCopy = $false
    }
    Logging = @{
        Level = "Debug"
        FilePath = "$TestRoot\Logs\service.log"
        MaxFileSizeMB = 10
        MaxFiles = 5
        AuditDirectory = "$TestRoot\Logs\Audit"
        AuditFlushInterval = 5000
        PerformanceLogging = $true
        StructuredLogging = $true
    }
    Service = @{
        HealthCheckInterval = 10000
        ConfigReloadInterval = 60000
        IntegrationInterval = 1000
        MaxMemoryMB = 512
        GracefulShutdownTimeoutSeconds = 15
        ServiceRestartOnFailure = $false
    }
    Performance = @{
        Monitoring = @{
            Enabled = $true
            MetricsInterval = 30000
            PerformanceCounters = $true
            MemoryProfiling = $true
            DetailedTimings = $true
        }
        Optimization = @{
            LargeFileThresholdMB = 10
            LargeFileBufferMB = 1
            SmallFileBufferKB = 32
            ConcurrentIOOperations = 2
            PriorityBoostForLargeFiles = $false
        }
        Alerting = @{
            Enabled = $true
            MemoryThresholdMB = 400
            CPUThresholdPercent = 70
            QueueDepthThreshold = 10
            ProcessingTimeThresholdMinutes = 5
            ErrorRateThresholdPercent = 20
        }
    }
    Retry = @{
        Strategies = @{
            FileSystem = @{
                MaxAttempts = 3
                BaseDelayMs = 1000
                MaxDelayMs = 10000
                BackoffMultiplier = 1.5
                UseJitter = $true
                JitterFactor = 0.2
            }
            Network = @{
                MaxAttempts = 2
                BaseDelayMs = 2000
                MaxDelayMs = 30000
                BackoffMultiplier = 2.0
                UseJitter = $true
                JitterFactor = 0.3
            }
        }
        CircuitBreaker = @{
            Enabled = $true
            FailureThreshold = 5
            TimeoutMinutes = 5
            MonitoringInterval = 30000
        }
    }
    Security = @{
        AuditLogging = $true
        FileAccessLogging = $true
        SecurityEventLogging = $false
        EncryptionInTransit = $false
        FilePermissionValidation = $false
        RestrictedPaths = @()
    }
    Metadata = @{
        ConfigurationVersion = "1.0"
        ServiceVersion = "Phase 5B Testing"
        Description = "Local laptop testing configuration"
        Environment = "Testing"
        TestRoot = $TestRoot
    }
}

$configPath = "$TestRoot\Config\test-config.json"
$testConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $configPath -Encoding UTF8
Write-Host "✓ Created test configuration: $configPath" -ForegroundColor Green

# Create sample test files if requested
if ($CreateSampleFiles) {
    Write-Host "`nCreating sample test files..." -ForegroundColor Yellow

    # Small test files (1KB - 100KB)
    for ($i = 1; $i -le $SampleFileCount; $i++) {
        $content = "Test file $i - " + ("Sample data " * (Get-Random -Minimum 10 -Maximum 1000))
        $fileName = "small_test_$($i.ToString("D3")).txt"
        $filePath = "$TestRoot\TestData\Small\$fileName"
        $content | Out-File -FilePath $filePath -Encoding UTF8
    }
    Write-Host "✓ Created $SampleFileCount small test files" -ForegroundColor Green

    # Medium test files (1MB - 10MB) - simulated SVS files
    for ($i = 1; $i -le ($SampleFileCount / 2); $i++) {
        $sizeKB = Get-Random -Minimum 1000 -Maximum 10000
        $content = "SVS Header Data`n" + ("X" * ($sizeKB * 1024 - 20))
        $fileName = "medium_test_$($i.ToString("D3")).svs"
        $filePath = "$TestRoot\TestData\Large\$fileName"
        $content | Out-File -FilePath $filePath -Encoding UTF8
    }
    Write-Host "✓ Created $($SampleFileCount / 2) medium test files (SVS simulation)" -ForegroundColor Green

    # TIFF test files
    for ($i = 1; $i -le ($SampleFileCount / 4); $i++) {
        $content = "TIFF Header" + ("Image data " * (Get-Random -Minimum 100 -Maximum 500))
        $fileName = "image_test_$($i.ToString("D3")).tiff"
        $filePath = "$TestRoot\TestData\Mixed\$fileName"
        $content | Out-File -FilePath $filePath -Encoding UTF8
    }
    Write-Host "✓ Created $($SampleFileCount / 4) TIFF test files" -ForegroundColor Green
}

# Create test runner script
Write-Host "`nCreating test runner script..." -ForegroundColor Yellow

$testRunnerContent = @"
# FileCopier Test Runner - Execute from test environment
param(
    [switch]`$Quick,
    [switch]`$Performance,
    [switch]`$Stress,
    [switch]`$Integration
)

`$testRoot = "$TestRoot"
`$configPath = "`$testRoot\Config\test-config.json"

Write-Host "FileCopier Service Test Runner" -ForegroundColor Cyan
Write-Host "Test Root: `$testRoot" -ForegroundColor Gray
Write-Host "Config: `$configPath" -ForegroundColor Gray
Write-Host ""

# Change to the FileCopier repository directory
Set-Location "$((Get-Location).Path)"

if (`$Quick) {
    Write-Host "Running Quick Tests..." -ForegroundColor Yellow
    & .\Test-Phase5B.ps1 -ConfigPath `$configPath
}

if (`$Performance) {
    Write-Host "Running Performance Tests..." -ForegroundColor Yellow
    & .\Test-Phase5B.ps1 -ConfigPath `$configPath -IncludePerformanceTests
}

if (`$Integration) {
    Write-Host "Running Integration Tests..." -ForegroundColor Yellow
    & .\Test-Integration.ps1 -ConfigPath `$configPath -TestRoot `$testRoot
}

if (`$Stress) {
    Write-Host "Running Stress Tests..." -ForegroundColor Yellow
    & .\Test-StressTest.ps1 -ConfigPath `$configPath -TestRoot `$testRoot
}

if (-not (`$Quick -or `$Performance -or `$Integration -or `$Stress)) {
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Run-Tests.ps1 -Quick          # Basic validation tests"
    Write-Host "  .\Run-Tests.ps1 -Performance    # Performance benchmarks"
    Write-Host "  .\Run-Tests.ps1 -Integration    # End-to-end integration tests"
    Write-Host "  .\Run-Tests.ps1 -Stress         # Load and stress testing"
    Write-Host ""
    Write-Host "Test Environment Ready!" -ForegroundColor Green
    Write-Host "Source: `$testRoot\Source"
    Write-Host "Targets: `$testRoot\TargetA, `$testRoot\TargetB"
    Write-Host "Test Data: `$testRoot\TestData"
    Write-Host "Configuration: `$configPath"
}
"@

$testRunnerPath = "$TestRoot\Run-Tests.ps1"
$testRunnerContent | Out-File -FilePath $testRunnerPath -Encoding UTF8
Write-Host "✓ Created test runner: $testRunnerPath" -ForegroundColor Green

# Create monitoring startup script
$monitoringScript = @"
# Start FileCopier Monitoring Dashboard
param([int]`$Port = 8080)

`$config = Get-Content "$TestRoot\Config\test-config.json" | ConvertFrom-Json -AsHashtable

# Mock logger for testing
`$logger = [PSCustomObject]@{
    LogDebug = { param(`$message) Write-Verbose "DEBUG: `$message" -Verbose }
    LogInformation = { param(`$message) Write-Host "INFO: `$message" -ForegroundColor Cyan }
    LogWarning = { param(`$message) Write-Warning "WARN: `$message" }
    LogError = { param(`$message, `$exception) Write-Error "ERROR: `$message" }
    LogCritical = { param(`$message) Write-Error "CRITICAL: `$message" }
}

Write-Host "Loading FileCopier modules..." -ForegroundColor Yellow

# Load modules (adjust path as needed)
. .\modules\FileCopier\PerformanceCounters.ps1
. .\modules\FileCopier\DiagnosticCommands.ps1
. .\modules\FileCopier\MonitoringDashboard.ps1

Write-Host "Starting monitoring dashboard on port `$Port..." -ForegroundColor Green
Write-Host "Access dashboard at: http://localhost:`$Port" -ForegroundColor Cyan

try {
    `$dashboard = [MonitoringDashboard]::new(`$config, `$logger)
    `$dashboard.Start(`$Port)

    Write-Host "`nMonitoring dashboard is running. Press Ctrl+C to stop." -ForegroundColor Green
    Write-Host "Dashboard URL: http://localhost:`$Port" -ForegroundColor Cyan

    while (`$true) {
        Start-Sleep 1
    }
} finally {
    if (`$dashboard) {
        `$dashboard.Stop()
    }
}
"@

$monitoringPath = "$TestRoot\Start-Monitoring.ps1"
$monitoringScript | Out-File -FilePath $monitoringPath -Encoding UTF8
Write-Host "✓ Created monitoring script: $monitoringPath" -ForegroundColor Green

# Create README for test environment
$readmeContent = @"
# FileCopier Service - Test Environment

This directory contains a complete testing environment for the FileCopier Service.

## Directory Structure
- **Source/**: Source directory for file monitoring
- **TargetA/**: Primary target directory
- **TargetB/**: Secondary target directory
- **Quarantine/**: Failed file quarantine
- **Temp/**: Temporary processing directory
- **Logs/**: Service and audit logs
- **Config/**: Test configuration files
- **TestData/**: Sample test files

## Quick Start
1. Run tests: ``.\Run-Tests.ps1 -Quick``
2. Start monitoring: ``.\Start-Monitoring.ps1``
3. Copy files to Source/ and watch them get processed

## Test Commands
- ``.\Run-Tests.ps1 -Quick`` - Basic validation
- ``.\Run-Tests.ps1 -Performance`` - Performance tests
- ``.\Run-Tests.ps1 -Integration`` - End-to-end tests
- ``.\Run-Tests.ps1 -Stress`` - Load testing

## Configuration
Test configuration: ``Config/test-config.json``
Optimized for laptop testing with reduced resource usage.

## Monitoring
Dashboard: http://localhost:8080 (after running Start-Monitoring.ps1)

## Test Data
- Small files: TestData/Small/
- Large files: TestData/Large/
- Mixed formats: TestData/Mixed/

Created: $(Get-Date)
"@

$readmePath = "$TestRoot\README.md"
$readmeContent | Out-File -FilePath $readmePath -Encoding UTF8
Write-Host "✓ Created README: $readmePath" -ForegroundColor Green

# Display summary
Write-Host "`n" + "=" * 80 -ForegroundColor Green
Write-Host "TEST ENVIRONMENT SETUP COMPLETE!" -ForegroundColor Green
Write-Host "=" * 80 -ForegroundColor Green

Write-Host "`nTest Environment Details:" -ForegroundColor Cyan
Write-Host "📁 Root Directory: $TestRoot" -ForegroundColor White
Write-Host "⚙️  Configuration: $TestRoot\Config\test-config.json" -ForegroundColor White
Write-Host "🏃 Test Runner: $TestRoot\Run-Tests.ps1" -ForegroundColor White
Write-Host "📊 Monitoring: $TestRoot\Start-Monitoring.ps1" -ForegroundColor White

if ($CreateSampleFiles) {
    $fileCount = (Get-ChildItem "$TestRoot\TestData" -Recurse -File).Count
    Write-Host "📄 Sample Files: $fileCount test files created" -ForegroundColor White
}

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "1. cd '$TestRoot'" -ForegroundColor Gray
Write-Host "2. .\Run-Tests.ps1 -Quick     # Run basic tests" -ForegroundColor Gray
Write-Host "3. .\Start-Monitoring.ps1    # Start web dashboard" -ForegroundColor Gray
Write-Host "4. Copy files to Source/     # Test file processing" -ForegroundColor Gray

Write-Host "`nTesting Tips:" -ForegroundColor Yellow
Write-Host "• Monitor dashboard at http://localhost:8080" -ForegroundColor Gray
Write-Host "• Check logs in $TestRoot\Logs\" -ForegroundColor Gray
Write-Host "• Test files will be copied to TargetA/ and TargetB/" -ForegroundColor Gray
Write-Host "• Failed files go to Quarantine/" -ForegroundColor Gray

Write-Host "`nReady for comprehensive FileCopier testing! 🚀" -ForegroundColor Green