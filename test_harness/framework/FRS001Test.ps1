# FRS-001: Process Termination Cleanup Validation Test
# Tests system state validation after forceful process failures

. (Join-Path $PSScriptRoot ".." "framework" "TestUtils.ps1")
. (Join-Path $PSScriptRoot ".." "suites" "RecoveryTests.ps1")

class ProcessTerminationTest : RecoveryTestBase {
    [hashtable] $TestData
    [hashtable] $ProcessCleanupResults

    ProcessTerminationTest() : base("FRS-001") {
        $this.TestData = @{
            TestFiles = @()
            TestProcesses = @()
            LockFiles = @()
            CleanupTasks = @()
        }
        $this.ProcessCleanupResults = @{}
    }

    [hashtable] ExecuteTest() {
        $result = @{
            TestId = $this.TestId
            Status = "Failed"
            StartTime = Get-Date
            EndTime = $null
            ErrorMessage = $null
            Details = @{}
            ValidationResults = @{}
        }

        try {
            Write-TestLog -Message "Starting FRS-001 Process Termination Cleanup Validation Test" -Level "INFO" -TestId $this.TestId

            # Setup test environment
            $this.SetupTest()

            # Phase 1: Create test scenario with processes and file locks
            Write-TestLog -Message "Phase 1: Setting up test scenario with processes and locks" -Level "INFO" -TestId $this.TestId
            $scenarioResult = $this.CreateTestScenario()
            $result.Details.ScenarioSetup = $scenarioResult

            if (-not $scenarioResult.Success) {
                throw "Failed to setup test scenario: $($scenarioResult.Error)"
            }

            # Phase 2: Simulate process termination
            Write-TestLog -Message "Phase 2: Simulating forceful process termination" -Level "INFO" -TestId $this.TestId
            $terminationResult = $this.SimulateProcessTerminations()
            $result.Details.ProcessTermination = $terminationResult

            if (-not $terminationResult.Success) {
                throw "Failed to simulate process termination: $($terminationResult.Error)"
            }

            # Phase 3: Validate cleanup after termination
            Write-TestLog -Message "Phase 3: Validating system cleanup after termination" -Level "INFO" -TestId $this.TestId
            $cleanupValidation = $this.ValidatePostTerminationCleanup()
            $result.Details.CleanupValidation = $cleanupValidation
            $result.ValidationResults = $cleanupValidation

            if (-not $cleanupValidation.Success) {
                throw "Cleanup validation failed: $($cleanupValidation.Summary)"
            }

            # Phase 4: Test recovery procedures
            Write-TestLog -Message "Phase 4: Testing recovery procedures" -Level "INFO" -TestId $this.TestId
            $recoveryResult = $this.TestRecoveryProcedures()
            $result.Details.RecoveryTest = $recoveryResult

            if (-not $recoveryResult.Success) {
                throw "Recovery procedures failed: $($recoveryResult.Error)"
            }

            $result.Status = "Passed"
            Write-TestLog -Message "FRS-001 test completed successfully" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $result.Status = "Failed"
            $result.ErrorMessage = $_.Exception.Message
            Write-TestLog -Message "FRS-001 test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
        finally {
            $result.EndTime = Get-Date
            $this.CleanupTest()
        }

        return $result
    }

    [hashtable] CreateTestScenario() {
        $scenario = @{
            Success = $false
            Error = $null
            ProcessesCreated = 0
            FilesCreated = 0
            LocksCreated = 0
            Details = @{}
        }

        try {
            # Create test files
            Write-TestLog -Message "Creating test files for lock testing" -Level "INFO" -TestId $this.TestId
            $testFile1 = $this.CreateTempFile("lock-test-1.dat", "Test data for exclusive lock")
            $testFile2 = $this.CreateTempFile("lock-test-2.dat", "Test data for shared lock")
            $testFile3 = $this.CreateTempFile("process-data.tmp", "Process working data")

            $this.TestData.TestFiles = @($testFile1, $testFile2, $testFile3)
            $scenario.FilesCreated = $this.TestData.TestFiles.Count

            # Create file locks to simulate active operations
            Write-TestLog -Message "Creating file locks to simulate active operations" -Level "INFO" -TestId $this.TestId
            $lock1 = $this.CreateFileLock($testFile1, "Exclusive")
            $lock2 = $this.CreateFileLock($testFile2, "Write")

            $this.TestData.LockFiles = @($lock1, $lock2)
            $scenario.LocksCreated = $this.TestData.LockFiles.Count

            # Create background processes that will hold resources
            Write-TestLog -Message "Creating background processes with resource usage" -Level "INFO" -TestId $this.TestId

            # Process 1: File writer process
            $writerProcess = $this.CreateManagedProcess("FileWriter", "pwsh", @(
                "-NoProfile", "-Command",
                "`$file = '$testFile3'; while (`$true) { Add-Content -Path `$file -Value `"Process data: `$(Get-Date)`"; Start-Sleep -Seconds 1 }"
            ))

            # Process 2: File reader process
            $readerProcess = $this.CreateManagedProcess("FileReader", "pwsh", @(
                "-NoProfile", "-Command",
                "`$file = '$testFile1'; while (`$true) { try { Get-Content -Path `$file -ErrorAction SilentlyContinue | Out-Null } catch { }; Start-Sleep -Seconds 2 }"
            ))

            $this.TestData.TestProcesses = @($writerProcess, $readerProcess)

            # Start the background processes
            foreach ($processInfo in $this.TestData.TestProcesses) {
                $this.StartManagedProcess($processInfo)
                Start-Sleep -Milliseconds 500  # Allow process to start
            }

            $scenario.ProcessesCreated = $this.TestData.TestProcesses.Count

            # Verify processes are running
            $runningCount = ($this.TestData.TestProcesses | Where-Object { $_.IsRunning }).Count
            if ($runningCount -ne $this.TestData.TestProcesses.Count) {
                throw "Not all test processes started successfully. Expected: $($this.TestData.TestProcesses.Count), Running: $runningCount"
            }

            $scenario.Details = @{
                TestFiles = $this.TestData.TestFiles
                ProcessNames = $this.TestData.TestProcesses | ForEach-Object { $_.Name }
                ProcessIds = $this.TestData.TestProcesses | ForEach-Object { $_.ProcessId }
                LockTypes = $this.TestData.LockFiles | ForEach-Object { $_.LockType }
            }

            $scenario.Success = $true
            Write-TestLog -Message "Test scenario created successfully: $($scenario.ProcessesCreated) processes, $($scenario.FilesCreated) files, $($scenario.LocksCreated) locks" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $scenario.Error = $_.Exception.Message
            Write-TestLog -Message "Failed to create test scenario: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $scenario
    }

    [hashtable] SimulateProcessTerminations() {
        $termination = @{
            Success = $false
            Error = $null
            ProcessesTerminated = 0
            TerminationDetails = @()
        }

        try {
            Write-TestLog -Message "Simulating forceful termination of background processes" -Level "INFO" -TestId $this.TestId

            foreach ($processInfo in $this.TestData.TestProcesses) {
                if ($processInfo.IsRunning) {
                    Write-TestLog -Message "Forcefully terminating process: $($processInfo.Name) (PID: $($processInfo.ProcessId))" -Level "INFO" -TestId $this.TestId

                    $terminationStart = Get-Date
                    $this.TerminateManagedProcess($processInfo, $true)  # Force termination
                    $terminationEnd = Get-Date

                    $terminationDetails = @{
                        ProcessName = $processInfo.Name
                        ProcessId = $processInfo.ProcessId
                        TerminationTime = $terminationEnd - $terminationStart
                        Success = -not $processInfo.IsRunning
                    }

                    $termination.TerminationDetails += $terminationDetails
                    if ($terminationDetails.Success) {
                        $termination.ProcessesTerminated++
                    }

                    Write-TestLog -Message "Process termination: $($processInfo.Name) - Success: $($terminationDetails.Success)" -Level "INFO" -TestId $this.TestId
                }
            }

            # Verify all processes are terminated
            $expectedTerminations = $this.TestData.TestProcesses.Count
            if ($termination.ProcessesTerminated -eq $expectedTerminations) {
                $termination.Success = $true
                Write-TestLog -Message "All processes terminated successfully: $($termination.ProcessesTerminated)/$expectedTerminations" -Level "INFO" -TestId $this.TestId
            } else {
                throw "Process termination incomplete: $($termination.ProcessesTerminated)/$expectedTerminations processes terminated"
            }
        }
        catch {
            $termination.Error = $_.Exception.Message
            Write-TestLog -Message "Process termination failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $termination
    }

    [hashtable] ValidatePostTerminationCleanup() {
        $validation = @{
            Success = $false
            Summary = ""
            ProcessCleanup = @{}
            FileCleanup = @{}
            LockCleanup = @{}
            SystemState = @{}
        }

        try {
            Write-TestLog -Message "Validating system state after process termination" -Level "INFO" -TestId $this.TestId

            # Wait a moment for system cleanup
            Start-Sleep -Seconds 2

            # Validate process cleanup
            Write-TestLog -Message "Checking for orphaned processes" -Level "INFO" -TestId $this.TestId
            $processIds = $this.TestData.TestProcesses | ForEach-Object { $_.ProcessId }
            $processCleanupResult = Test-ProcessCleanup $processIds -TimeoutSeconds 5

            $validation.ProcessCleanup = @{
                Expected = $processIds
                OrphanedProcesses = $processCleanupResult.OrphanedProcesses
                CleanupSuccess = $processCleanupResult.Success
                TimeoutReached = $processCleanupResult.TimeoutReached
            }

            if ($processCleanupResult.Success) {
                Write-TestLog -Message "Process cleanup validation: PASSED - No orphaned processes found" -Level "INFO" -TestId $this.TestId
            } else {
                Write-TestLog -Message "Process cleanup validation: FAILED - Orphaned processes: $($processCleanupResult.OrphanedProcesses -join ', ')" -Level "ERROR" -TestId $this.TestId
            }

            # Validate file lock cleanup
            Write-TestLog -Message "Checking file lock release after process termination" -Level "INFO" -TestId $this.TestId
            $lockCleanupResults = @()

            foreach ($lockInfo in $this.TestData.LockFiles) {
                $lockReleaseResult = Test-FileLockRelease $lockInfo.FilePath -TimeoutSeconds 3
                $lockCleanupResults += @{
                    FilePath = $lockInfo.FilePath
                    LockType = $lockInfo.LockType
                    Released = $lockReleaseResult.Success
                    TimeoutReached = $lockReleaseResult.TimeoutReached
                }

                if ($lockReleaseResult.Success) {
                    Write-TestLog -Message "Lock cleanup validation: PASSED - $($lockInfo.FilePath) ($($lockInfo.LockType))" -Level "INFO" -TestId $this.TestId
                } else {
                    Write-TestLog -Message "Lock cleanup validation: FAILED - $($lockInfo.FilePath) ($($lockInfo.LockType)) still locked" -Level "ERROR" -TestId $this.TestId
                }
            }

            $validation.LockCleanup = @{
                Results = $lockCleanupResults
                TotalLocks = $lockCleanupResults.Count
                ReleasedLocks = ($lockCleanupResults | Where-Object { $_.Released }).Count
                CleanupSuccess = ($lockCleanupResults | Where-Object { -not $_.Released }).Count -eq 0
            }

            # Validate file accessibility
            Write-TestLog -Message "Checking file accessibility after cleanup" -Level "INFO" -TestId $this.TestId
            $fileAccessResults = @()

            foreach ($filePath in $this.TestData.TestFiles) {
                $accessible = $false
                try {
                    $testContent = Get-Content -Path $filePath -ErrorAction Stop
                    $accessible = $true
                } catch {
                    $accessible = $false
                }

                $fileAccessResults += @{
                    FilePath = $filePath
                    Accessible = $accessible
                    Exists = (Test-Path $filePath)
                }

                Write-TestLog -Message "File access validation: $filePath - Accessible: $accessible" -Level "INFO" -TestId $this.TestId
            }

            $validation.FileCleanup = @{
                Results = $fileAccessResults
                TotalFiles = $fileAccessResults.Count
                AccessibleFiles = ($fileAccessResults | Where-Object { $_.Accessible }).Count
                ExistingFiles = ($fileAccessResults | Where-Object { $_.Exists }).Count
            }

            # Overall system cleanup validation
            $systemValidation = $this.ValidateSystemCleanup()
            $validation.SystemState = $systemValidation

            # Determine overall success
            $validation.Success = $validation.ProcessCleanup.CleanupSuccess -and
                                 $validation.LockCleanup.CleanupSuccess -and
                                 $systemValidation.Success

            if ($validation.Success) {
                $validation.Summary = "All cleanup validation checks passed successfully"
                Write-TestLog -Message "Post-termination cleanup validation: PASSED" -Level "INFO" -TestId $this.TestId
            } else {
                $failedChecks = @()
                if (-not $validation.ProcessCleanup.CleanupSuccess) { $failedChecks += "Process cleanup" }
                if (-not $validation.LockCleanup.CleanupSuccess) { $failedChecks += "Lock cleanup" }
                if (-not $systemValidation.Success) { $failedChecks += "System state" }

                $validation.Summary = "Cleanup validation failed: $($failedChecks -join ', ')"
                Write-TestLog -Message "Post-termination cleanup validation: FAILED - $($validation.Summary)" -Level "ERROR" -TestId $this.TestId
            }
        }
        catch {
            $validation.Summary = "Cleanup validation error: $($_.Exception.Message)"
            Write-TestLog -Message "Cleanup validation failed with error: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $validation
    }

    [hashtable] TestRecoveryProcedures() {
        $recovery = @{
            Success = $false
            Error = $null
            RecoverySteps = @()
            FinalState = @{}
        }

        try {
            Write-TestLog -Message "Testing recovery procedures after process termination" -Level "INFO" -TestId $this.TestId

            # Recovery Step 1: Explicit lock cleanup
            Write-TestLog -Message "Recovery Step 1: Explicit lock cleanup" -Level "INFO" -TestId $this.TestId
            $this.ReleaseAllFileLocks()
            $recovery.RecoverySteps += @{
                Step = "LockCleanup"
                Success = $true
                Details = "All file locks explicitly released"
            }

            # Recovery Step 2: File cleanup
            Write-TestLog -Message "Recovery Step 2: File cleanup" -Level "INFO" -TestId $this.TestId
            $fileCleanupResult = Test-FileCleanup $this.TestData.TestFiles -TimeoutSeconds 3
            if (-not $fileCleanupResult.Success) {
                # Force cleanup remaining files
                $this.CleanupTempFiles()
                Write-TestLog -Message "Forced cleanup of remaining temporary files" -Level "INFO" -TestId $this.TestId
            }

            $recovery.RecoverySteps += @{
                Step = "FileCleanup"
                Success = $true
                Details = "File cleanup completed (forced if necessary)"
            }

            # Recovery Step 3: Final system validation
            Write-TestLog -Message "Recovery Step 3: Final system validation" -Level "INFO" -TestId $this.TestId
            $finalValidation = $this.ValidateSystemCleanup()
            $recovery.FinalState = $finalValidation

            $recovery.RecoverySteps += @{
                Step = "FinalValidation"
                Success = $finalValidation.Success
                Details = if ($finalValidation.Success) { "System state clean" } else { "Issues remain: $($finalValidation.Issues -join '; ')" }
            }

            # Overall recovery success
            $allStepsSuccessful = ($recovery.RecoverySteps | Where-Object { -not $_.Success }).Count -eq 0
            $recovery.Success = $allStepsSuccessful -and $finalValidation.Success

            if ($recovery.Success) {
                Write-TestLog -Message "Recovery procedures completed successfully" -Level "INFO" -TestId $this.TestId
            } else {
                $recovery.Error = "Recovery validation failed"
                Write-TestLog -Message "Recovery procedures failed validation" -Level "ERROR" -TestId $this.TestId
            }
        }
        catch {
            $recovery.Error = $_.Exception.Message
            Write-TestLog -Message "Recovery procedures failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $recovery
    }
}

# Factory function for creating FRS-001 test
function New-ProcessTerminationTest {
    return [ProcessTerminationTest]::new()
}

Write-TestLog -Message "FRS-001 Process Termination Test loaded successfully" -Level "INFO" -TestId "FRS-001"