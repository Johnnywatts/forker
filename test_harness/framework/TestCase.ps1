# Base Test Case Class for Contention Testing

. (Join-Path $PSScriptRoot "TestResult.ps1")

class ContentionTestCase {
    [string] $TestId
    [string] $TestCategory
    [string] $Description
    [hashtable] $Configuration
    [string] $TempDirectory
    [TestResult] $Result

    ContentionTestCase([string] $testId, [string] $category, [string] $description) {
        $this.TestId = $testId
        $this.TestCategory = $category
        $this.Description = $description
        $this.Configuration = @{}
        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $this.TempDirectory = Join-Path $tempBase "contention-test-$testId-$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
    }

    # Main execution method - override in derived classes
    [TestResult] Execute() {
        $this.Result = [TestResult]::new($this.TestId, $this.TestCategory)

        try {
            Write-Host "Executing test $($this.TestId): $($this.Description)" -ForegroundColor Cyan

            # Initialize test environment
            $this.Initialize()

            # Run the actual test
            $testSuccess = $this.RunTest()

            # Complete the test result
            if ($testSuccess) {
                $this.Result.Complete($true, "Test completed successfully")
                Write-Host "✅ $($this.TestId) PASSED" -ForegroundColor Green
            } else {
                $this.Result.Complete($false, "Test failed during execution")
                Write-Host "❌ $($this.TestId) FAILED" -ForegroundColor Red
            }
        }
        catch {
            $this.Result.Complete($false, "Test failed with exception: $($_.Exception.Message)")
            Write-Host "❌ $($this.TestId) EXCEPTION: $($_.Exception.Message)" -ForegroundColor Red
        }
        finally {
            # Always cleanup
            try {
                $this.Cleanup()
            }
            catch {
                Write-Warning "Cleanup failed for $($this.TestId): $($_.Exception.Message)"
            }
        }

        return $this.Result
    }

    # Virtual methods - override in derived classes
    [void] Initialize() {
        # Create temp directory for test
        if (-not (Test-Path $this.TempDirectory)) {
            New-Item -ItemType Directory -Path $this.TempDirectory -Force | Out-Null
        }

        $this.Result.AddDetail("TempDirectory", $this.TempDirectory)
    }

    [bool] RunTest() {
        # Override this method in derived classes
        throw "RunTest method must be implemented in derived class"
    }

    [void] Cleanup() {
        # Clean up temp directory
        if (Test-Path $this.TempDirectory) {
            Remove-Item $this.TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Helper methods for test implementations
    [void] AddTestDetail([string] $key, [object] $value) {
        $this.Result.AddDetail($key, $value)
    }

    [void] AddTestMetric([string] $key, [object] $value) {
        $this.Result.AddMetric($key, $value)
    }

    [string] CreateTempFile([string] $fileName, [string] $content = "Test data") {
        $filePath = Join-Path $this.TempDirectory $fileName
        Set-Content -Path $filePath -Value $content
        return $filePath
    }

    [string] CreateTempFile([string] $fileName, [int] $sizeBytes) {
        $filePath = Join-Path $this.TempDirectory $fileName
        $content = "X" * $sizeBytes
        Set-Content -Path $filePath -Value $content -NoNewline
        return $filePath
    }

    [void] LogInfo([string] $message) {
        Write-Host "[INFO] $($this.TestId): $message" -ForegroundColor Gray
    }

    [void] LogWarning([string] $message) {
        Write-Host "[WARN] $($this.TestId): $message" -ForegroundColor Yellow
    }

    [void] LogError([string] $message) {
        Write-Host "[ERROR] $($this.TestId): $message" -ForegroundColor Red
    }
}

# Dummy test case for framework validation
class DummyTest : ContentionTestCase {
    DummyTest() : base("DUMMY-001", "Framework", "Dummy test for framework validation") {}

    [bool] RunTest() {
        $this.LogInfo("Running dummy test")

        # Create a test file
        $testFile = $this.CreateTempFile("dummy.txt", "Hello, World!")
        $this.AddTestDetail("TestFile", $testFile)

        # Verify file exists
        if (Test-Path $testFile) {
            $content = Get-Content $testFile
            $this.AddTestDetail("FileContent", $content)
            $this.AddTestMetric("FileSize", (Get-Item $testFile).Length)

            $this.LogInfo("Dummy test completed successfully")
            return $true
        } else {
            $this.LogError("Test file was not created")
            return $false
        }
    }
}