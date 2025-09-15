# ValidateTests.ps1 - Validates test files and provides execution instructions

Write-Host "=== File Copier Service Test Validation ===" -ForegroundColor Cyan
Write-Host ""

# Check test file structure
$testRoot = $PSScriptRoot
$projectRoot = Split-Path $testRoot -Parent

Write-Host "Validating test file structure..." -ForegroundColor Yellow

$expectedFiles = @{
    "TestSetup.ps1" = "Test framework setup and utilities"
    "RunTests.ps1" = "Test runner script"
    "unit\Configuration.Tests.ps1" = "Configuration module unit tests"
}

$allFilesExist = $true

foreach ($file in $expectedFiles.Keys) {
    $filePath = Join-Path $testRoot $file
    if (Test-Path $filePath) {
        Write-Host "✅ $file - $($expectedFiles[$file])" -ForegroundColor Green

        # Basic syntax validation
        try {
            $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $filePath -Raw), [ref]$null)
            Write-Host "   Syntax: Valid" -ForegroundColor Green
        }
        catch {
            Write-Host "   Syntax: Error - $($_.Exception.Message)" -ForegroundColor Red
            $allFilesExist = $false
        }
    }
    else {
        Write-Host "❌ $file - Missing" -ForegroundColor Red
        $allFilesExist = $false
    }
}

Write-Host ""

# Check module files exist
Write-Host "Validating module files..." -ForegroundColor Yellow

$moduleFiles = @{
    "modules\FileCopier\FileCopier.psd1" = "Module manifest"
    "modules\FileCopier\Configuration.ps1" = "Configuration management module"
    "modules\FileCopier\Utils.ps1" = "Utility functions module"
}

foreach ($file in $moduleFiles.Keys) {
    $filePath = Join-Path $projectRoot $file
    if (Test-Path $filePath) {
        Write-Host "✅ $file - $($moduleFiles[$file])" -ForegroundColor Green
    }
    else {
        Write-Host "❌ $file - Missing" -ForegroundColor Red
        $allFilesExist = $false
    }
}

Write-Host ""

# Check config files exist
Write-Host "Validating configuration files..." -ForegroundColor Yellow

$configFiles = @{
    "config\settings.json" = "Default configuration"
    "config\settings-svs.json" = "SVS-optimized configuration"
    "config\settings.schema.json" = "JSON schema validation"
}

foreach ($file in $configFiles.Keys) {
    $filePath = Join-Path $projectRoot $file
    if (Test-Path $filePath) {
        Write-Host "✅ $file - $($configFiles[$file])" -ForegroundColor Green

        # Validate JSON syntax
        if ($file.EndsWith(".json")) {
            try {
                Get-Content $filePath -Raw | ConvertFrom-Json | Out-Null
                Write-Host "   JSON: Valid" -ForegroundColor Green
            }
            catch {
                Write-Host "   JSON: Error - $($_.Exception.Message)" -ForegroundColor Red
                $allFilesExist = $false
            }
        }
    }
    else {
        Write-Host "❌ $file - Missing" -ForegroundColor Red
        $allFilesExist = $false
    }
}

Write-Host ""

if ($allFilesExist) {
    Write-Host "✅ All files validated successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "=== How to Run Tests ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Install Pester if not already installed:" -ForegroundColor White
    Write-Host "   Install-Module -Name Pester -Force -SkipPublisherCheck" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "2. Navigate to the tests directory:" -ForegroundColor White
    Write-Host "   cd tests" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "3. Run all tests:" -ForegroundColor White
    Write-Host "   .\RunTests.ps1" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "4. Run tests with detailed output:" -ForegroundColor White
    Write-Host "   .\RunTests.ps1 -ShowPassed" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "5. Run tests with code coverage:" -ForegroundColor White
    Write-Host "   .\RunTests.ps1 -CodeCoverage" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "6. Run specific test file:" -ForegroundColor White
    Write-Host "   .\RunTests.ps1 -TestPath 'unit\Configuration.Tests.ps1'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "=== Expected Test Coverage ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Configuration.Tests.ps1 should test:" -ForegroundColor White
    Write-Host "• Configuration loading from JSON files" -ForegroundColor Gray
    Write-Host "• JSON schema validation" -ForegroundColor Gray
    Write-Host "• Environment variable overrides" -ForegroundColor Gray
    Write-Host "• Configuration validation and error handling" -ForegroundColor Gray
    Write-Host "• Hot configuration reload" -ForegroundColor Gray
    Write-Host "• Default value fallbacks" -ForegroundColor Gray
    Write-Host "• Error scenarios (malformed JSON, missing files, etc.)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Expected: ~50 test cases with >90% code coverage" -ForegroundColor Green
}
else {
    Write-Host "❌ Some files are missing or invalid." -ForegroundColor Red
    Write-Host "Please check the file structure and fix any issues before running tests." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Troubleshooting ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "If tests fail:" -ForegroundColor White
Write-Host "• Check PowerShell execution policy: Get-ExecutionPolicy" -ForegroundColor Gray
Write-Host "• Set execution policy if needed: Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor Gray
Write-Host "• Ensure you have write permissions to temp directories" -ForegroundColor Gray
Write-Host "• Check that all module dependencies are available" -ForegroundColor Gray