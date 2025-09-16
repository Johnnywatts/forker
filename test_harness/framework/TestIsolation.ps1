# Test Isolation and Cleanup Framework

class TestIsolationContext {
    [string] $TestId
    [string] $IsolationId
    [string] $WorkingDirectory
    [hashtable] $EnvironmentBackup
    [hashtable] $ProcessList
    [bool] $IsIsolated

    TestIsolationContext([string] $testId) {
        $this.TestId = $testId
        $this.IsolationId = [System.Guid]::NewGuid().ToString('N')[0..7] -join ''
        $this.EnvironmentBackup = @{}
        $this.ProcessList = @{}
        $this.IsIsolated = $false
    }

    [void] EnterIsolation() {
        if ($this.IsIsolated) {
            throw "Test $($this.TestId) is already in isolation"
        }

        # Create isolated working directory
        $tempBase = if ($env:TEMP) { $env:TEMP } else { "/tmp" }
        $this.WorkingDirectory = Join-Path $tempBase "test-isolation-$($this.TestId)-$($this.IsolationId)"

        if (-not (Test-Path $this.WorkingDirectory)) {
            New-Item -ItemType Directory -Path $this.WorkingDirectory -Force | Out-Null
        }

        # Backup current environment variables that might affect tests
        $this.BackupEnvironment()

        # Record initial process state
        $this.RecordProcessBaseline()

        $this.IsIsolated = $true
        Write-Host "[ISOLATION] Entered isolation for test $($this.TestId)" -ForegroundColor DarkCyan
    }

    [void] ExitIsolation() {
        if (-not $this.IsIsolated) {
            return
        }

        try {
            # Cleanup any spawned processes
            $this.CleanupProcesses()

            # Restore environment
            $this.RestoreEnvironment()

            # Remove working directory
            if (Test-Path $this.WorkingDirectory) {
                Remove-Item $this.WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-Host "[ISOLATION] Exited isolation for test $($this.TestId)" -ForegroundColor DarkCyan
        }
        catch {
            Write-Warning "[ISOLATION] Cleanup failed for test $($this.TestId): $($_.Exception.Message)"
        }
        finally {
            $this.IsIsolated = $false
        }
    }

    [void] BackupEnvironment() {
        # Backup key environment variables that tests might modify
        $criticalVars = @('PATH', 'TEMP', 'TMP', 'HOME', 'PWD')

        foreach ($var in $criticalVars) {
            $value = [Environment]::GetEnvironmentVariable($var)
            if ($value) {
                $this.EnvironmentBackup[$var] = $value
            }
        }
    }

    [void] RestoreEnvironment() {
        foreach ($var in $this.EnvironmentBackup.Keys) {
            [Environment]::SetEnvironmentVariable($var, $this.EnvironmentBackup[$var])
        }
    }

    [void] RecordProcessBaseline() {
        # Record current PowerShell processes to detect leaks
        $currentProcesses = Get-Process -Name "pwsh" -ErrorAction SilentlyContinue
        $this.ProcessList['baseline'] = $currentProcesses.Id
    }

    [void] CleanupProcesses() {
        # Find any new PowerShell processes that might have been spawned
        $currentProcesses = Get-Process -Name "pwsh" -ErrorAction SilentlyContinue
        $baselineIds = $this.ProcessList['baseline']

        $newProcesses = $currentProcesses | Where-Object { $_.Id -notin $baselineIds -and $_.Id -ne $PID }

        foreach ($process in $newProcesses) {
            try {
                Write-Warning "[ISOLATION] Terminating leaked process: $($process.Id)"
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Warning "[ISOLATION] Failed to terminate process $($process.Id): $($_.Exception.Message)"
            }
        }
    }

    [string] CreateIsolatedFile([string] $fileName, [string] $content = "Test data") {
        $filePath = Join-Path $this.WorkingDirectory $fileName
        Set-Content -Path $filePath -Value $content -NoNewline
        return $filePath
    }

    [string] CreateIsolatedFile([string] $fileName, [int] $sizeBytes) {
        $filePath = Join-Path $this.WorkingDirectory $fileName
        $content = "X" * $sizeBytes
        Set-Content -Path $filePath -Value $content -NoNewline
        return $filePath
    }
}

class TestCleanupManager {
    [string] $TestId
    [string[]] $FilesToClean
    [string[]] $DirectoriesToClean
    [hashtable] $ResourcesToClean

    TestCleanupManager([string] $testId) {
        $this.TestId = $testId
        $this.FilesToClean = @()
        $this.DirectoriesToClean = @()
        $this.ResourcesToClean = @{}
    }

    [void] RegisterFile([string] $filePath) {
        $this.FilesToClean += $filePath
    }

    [void] RegisterDirectory([string] $directoryPath) {
        $this.DirectoriesToClean += $directoryPath
    }

    [void] RegisterResource([string] $resourceType, [object] $resource) {
        if (-not $this.ResourcesToClean.ContainsKey($resourceType)) {
            $this.ResourcesToClean[$resourceType] = @()
        }
        $this.ResourcesToClean[$resourceType] += $resource
    }

    [void] ExecuteCleanup() {
        $cleanupErrors = @()

        # Clean up files
        foreach ($file in $this.FilesToClean) {
            try {
                if (Test-Path $file) {
                    Remove-Item $file -Force -ErrorAction Stop
                }
            }
            catch {
                $cleanupErrors += "File cleanup failed for $file : $($_.Exception.Message)"
            }
        }

        # Clean up directories
        foreach ($directory in $this.DirectoriesToClean) {
            try {
                if (Test-Path $directory) {
                    Remove-Item $directory -Recurse -Force -ErrorAction Stop
                }
            }
            catch {
                $cleanupErrors += "Directory cleanup failed for $directory : $($_.Exception.Message)"
            }
        }

        # Clean up other resources
        foreach ($resourceType in $this.ResourcesToClean.Keys) {
            foreach ($resource in $this.ResourcesToClean[$resourceType]) {
                try {
                    switch ($resourceType) {
                        "Process" {
                            if ($resource -and -not $resource.HasExited) {
                                $resource.Kill()
                                $resource.WaitForExit(5000)
                            }
                        }
                        "FileStream" {
                            if ($resource) {
                                $resource.Close()
                                $resource.Dispose()
                            }
                        }
                        "Job" {
                            if ($resource) {
                                Stop-Job $resource -ErrorAction SilentlyContinue
                                Remove-Job $resource -ErrorAction SilentlyContinue
                            }
                        }
                        default {
                            if ($resource -and $resource.GetType().GetMethod("Dispose")) {
                                $resource.Dispose()
                            }
                        }
                    }
                }
                catch {
                    $cleanupErrors += "Resource cleanup failed for $resourceType : $($_.Exception.Message)"
                }
            }
        }

        # Report cleanup errors
        if ($cleanupErrors.Count -gt 0) {
            Write-Warning "[CLEANUP] Test $($this.TestId) had cleanup errors:"
            $cleanupErrors | ForEach-Object { Write-Warning "  $_" }
        }
    }
}

# Enhanced TestCase with isolation support
class IsolatedContentionTestCase : ContentionTestCase {
    [TestIsolationContext] $IsolationContext
    [TestCleanupManager] $CleanupManager

    IsolatedContentionTestCase([string] $testId, [string] $category, [string] $description) : base($testId, $category, $description) {
        $this.IsolationContext = [TestIsolationContext]::new($testId)
        $this.CleanupManager = [TestCleanupManager]::new($testId)
    }

    [void] Initialize() {
        # Enter isolation before base initialization
        $this.IsolationContext.EnterIsolation()

        # Use isolated working directory instead of temp directory
        $this.TempDirectory = $this.IsolationContext.WorkingDirectory

        # Register temp directory for cleanup
        $this.CleanupManager.RegisterDirectory($this.TempDirectory)

        $this.Result.AddDetail("IsolationId", $this.IsolationContext.IsolationId)
        $this.Result.AddDetail("WorkingDirectory", $this.IsolationContext.WorkingDirectory)
    }

    [void] Cleanup() {
        try {
            # Execute custom cleanup first
            $this.CleanupManager.ExecuteCleanup()
        }
        finally {
            # Always exit isolation
            $this.IsolationContext.ExitIsolation()
        }
    }

    [string] CreateIsolatedFile([string] $fileName, [string] $content = "Test data") {
        $filePath = $this.IsolationContext.CreateIsolatedFile($fileName, $content)
        $this.CleanupManager.RegisterFile($filePath)
        return $filePath
    }

    [string] CreateIsolatedFile([string] $fileName, [int] $sizeBytes) {
        $filePath = $this.IsolationContext.CreateIsolatedFile($fileName, $sizeBytes)
        $this.CleanupManager.RegisterFile($filePath)
        return $filePath
    }

    [void] RegisterCleanupFile([string] $filePath) {
        $this.CleanupManager.RegisterFile($filePath)
    }

    [void] RegisterCleanupDirectory([string] $directoryPath) {
        $this.CleanupManager.RegisterDirectory($directoryPath)
    }

    [void] RegisterCleanupResource([string] $resourceType, [object] $resource) {
        $this.CleanupManager.RegisterResource($resourceType, $resource)
    }
}

# Enhanced dummy test with isolation
class IsolatedDummyTest : IsolatedContentionTestCase {
    IsolatedDummyTest() : base("DUMMY-ISOLATED", "Framework", "Isolated dummy test for framework validation") {}

    [bool] RunTest() {
        $this.LogInfo("Running isolated dummy test")

        # Create multiple test files in isolation
        $testFile1 = $this.CreateIsolatedFile("dummy1.txt", "Hello, Isolated World!")
        $testFile2 = $this.CreateIsolatedFile("dummy2.dat", 1024)

        $this.AddTestDetail("TestFile1", $testFile1)
        $this.AddTestDetail("TestFile2", $testFile2)

        # Verify files exist in isolation
        if ((Test-Path $testFile1) -and (Test-Path $testFile2)) {
            $content1 = Get-Content $testFile1
            $size2 = (Get-Item $testFile2).Length

            $this.AddTestDetail("File1Content", $content1)
            $this.AddTestMetric("File2Size", $size2)

            # Test process spawning in isolation
            $job = Start-Job -ScriptBlock { Start-Sleep -Seconds 1; return "Isolated job completed" }
            $this.RegisterCleanupResource("Job", $job)

            $result = Wait-Job $job -Timeout 5
            if ($result) {
                $output = Receive-Job $job
                $this.AddTestDetail("JobOutput", $output)
            }

            $this.LogInfo("Isolated dummy test completed successfully")
            return $true
        } else {
            $this.LogError("Test files were not created in isolation")
            return $false
        }
    }
}