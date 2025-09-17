# CV-002: Lock Release Validation Test
# Tests validation of file lock release and resource cleanup

. (Join-Path $PSScriptRoot ".." "framework" "TestUtils.ps1")
. (Join-Path $PSScriptRoot ".." "suites" "RecoveryTests.ps1")

class LockReleaseValidationTest : RecoveryTestBase {
    [hashtable] $LockScenarios
    [hashtable] $ValidationResults

    LockReleaseValidationTest() : base("CV-002") {
        $this.LockScenarios = @{
            ExclusiveLocks = @()
            SharedLocks = @()
            WriteLocks = @()
            ConcurrentLocks = @()
        }
        $this.ValidationResults = @{}
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
            Write-TestLog -Message "Starting CV-002 Lock Release Validation Test" -Level "INFO" -TestId $this.TestId

            # Setup test environment
            $this.SetupTest()

            # Phase 1: Create various types of file locks
            Write-TestLog -Message "Phase 1: Creating various types of file locks" -Level "INFO" -TestId $this.TestId
            $lockCreationResult = $this.CreateTestLocks()
            $result.Details.LockCreation = $lockCreationResult

            if (-not $lockCreationResult.Success) {
                throw "Failed to create test locks: $($lockCreationResult.Error)"
            }

            # Phase 2: Test exclusive lock release
            Write-TestLog -Message "Phase 2: Testing exclusive lock release" -Level "INFO" -TestId $this.TestId
            $exclusiveTest = $this.TestExclusiveLockRelease()
            $result.Details.ExclusiveLockTest = $exclusiveTest

            # Phase 3: Test shared lock release
            Write-TestLog -Message "Phase 3: Testing shared lock release" -Level "INFO" -TestId $this.TestId
            $sharedTest = $this.TestSharedLockRelease()
            $result.Details.SharedLockTest = $sharedTest

            # Phase 4: Test write lock release
            Write-TestLog -Message "Phase 4: Testing write lock release" -Level "INFO" -TestId $this.TestId
            $writeTest = $this.TestWriteLockRelease()
            $result.Details.WriteLockTest = $writeTest

            # Phase 5: Test concurrent lock scenarios
            Write-TestLog -Message "Phase 5: Testing concurrent lock scenarios" -Level "INFO" -TestId $this.TestId
            $concurrentTest = $this.TestConcurrentLockRelease()
            $result.Details.ConcurrentLockTest = $concurrentTest

            # Phase 6: Comprehensive lock validation
            Write-TestLog -Message "Phase 6: Comprehensive lock validation" -Level "INFO" -TestId $this.TestId
            $finalValidation = $this.ValidateComprehensiveLockRelease()
            $result.Details.FinalValidation = $finalValidation
            $result.ValidationResults = $finalValidation

            # Determine overall success
            $allPhasesSuccessful = $exclusiveTest.Success -and $sharedTest.Success -and
                                  $writeTest.Success -and $concurrentTest.Success -and
                                  $finalValidation.Success

            if ($allPhasesSuccessful) {
                $result.Status = "Passed"
                Write-TestLog -Message "CV-002 test completed successfully" -Level "INFO" -TestId $this.TestId
            } else {
                $failedPhases = @()
                if (-not $exclusiveTest.Success) { $failedPhases += "Exclusive locks" }
                if (-not $sharedTest.Success) { $failedPhases += "Shared locks" }
                if (-not $writeTest.Success) { $failedPhases += "Write locks" }
                if (-not $concurrentTest.Success) { $failedPhases += "Concurrent locks" }
                if (-not $finalValidation.Success) { $failedPhases += "Final validation" }

                throw "CV-002 test failed in phases: $($failedPhases -join ', ')"
            }
        }
        catch {
            $result.Status = "Failed"
            $result.ErrorMessage = $_.Exception.Message
            Write-TestLog -Message "CV-002 test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }
        finally {
            $result.EndTime = Get-Date
            $this.CleanupTest()
        }

        return $result
    }

    [hashtable] CreateTestLocks() {
        $creation = @{
            Success = $false
            Error = $null
            LocksCreated = 0
            Details = @{}
        }

        try {
            # Create files for lock testing
            Write-TestLog -Message "Creating test files for lock scenarios" -Level "INFO" -TestId $this.TestId

            # Files for exclusive locks
            $exclusiveFile1 = $this.CreateTempFile("exclusive1.dat", "Exclusive lock test data 1")
            $exclusiveFile2 = $this.CreateTempFile("exclusive2.dat", "Exclusive lock test data 2")

            # Files for shared locks
            $sharedFile1 = $this.CreateTempFile("shared1.dat", "Shared lock test data 1")
            $sharedFile2 = $this.CreateTempFile("shared2.dat", "Shared lock test data 2")

            # Files for write locks
            $writeFile1 = $this.CreateTempFile("write1.dat", "Write lock test data 1")
            $writeFile2 = $this.CreateTempFile("write2.dat", "Write lock test data 2")

            # Files for concurrent access testing
            $concurrentFile = $this.CreateTempFile("concurrent.dat", "Concurrent access test data")

            # Create exclusive locks
            Write-TestLog -Message "Creating exclusive locks" -Level "INFO" -TestId $this.TestId
            $this.LockScenarios.ExclusiveLocks = @(
                $this.CreateFileLock($exclusiveFile1, "Exclusive"),
                $this.CreateFileLock($exclusiveFile2, "Exclusive")
            )

            # Create shared locks (read locks)
            Write-TestLog -Message "Creating shared locks" -Level "INFO" -TestId $this.TestId
            $this.LockScenarios.SharedLocks = @(
                $this.CreateFileLock($sharedFile1, "Read"),
                $this.CreateFileLock($sharedFile2, "Read")
            )

            # Create write locks
            Write-TestLog -Message "Creating write locks" -Level "INFO" -TestId $this.TestId
            $this.LockScenarios.WriteLocks = @(
                $this.CreateFileLock($writeFile1, "Write"),
                $this.CreateFileLock($writeFile2, "Write")
            )

            # Create concurrent locks on same file
            Write-TestLog -Message "Creating concurrent locks on same file" -Level "INFO" -TestId $this.TestId
            $this.LockScenarios.ConcurrentLocks = @(
                $this.CreateFileLock($concurrentFile, "Read")
            )

            $creation.LocksCreated = $this.LockScenarios.ExclusiveLocks.Count +
                                    $this.LockScenarios.SharedLocks.Count +
                                    $this.LockScenarios.WriteLocks.Count +
                                    $this.LockScenarios.ConcurrentLocks.Count

            $creation.Details = @{
                ExclusiveLocks = $this.LockScenarios.ExclusiveLocks.Count
                SharedLocks = $this.LockScenarios.SharedLocks.Count
                WriteLocks = $this.LockScenarios.WriteLocks.Count
                ConcurrentLocks = $this.LockScenarios.ConcurrentLocks.Count
            }

            $creation.Success = $true
            Write-TestLog -Message "Created $($creation.LocksCreated) test locks successfully" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $creation.Error = $_.Exception.Message
            Write-TestLog -Message "Failed to create test locks: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $creation
    }

    [hashtable] TestExclusiveLockRelease() {
        $test = @{
            Success = $false
            Error = $null
            LocksTestedCount = 0
            LocksReleasedCount = 0
            Results = @()
        }

        try {
            Write-TestLog -Message "Testing exclusive lock release" -Level "INFO" -TestId $this.TestId

            foreach ($lockInfo in $this.LockScenarios.ExclusiveLocks) {
                $test.LocksTestedCount++

                # Verify lock is active initially
                $initiallyLocked = $this.IsFileLocked($lockInfo.FilePath)

                # Release the lock
                $this.ReleaseFileLock($lockInfo)

                # Verify lock is released
                $releaseResult = Test-FileLockRelease $lockInfo.FilePath -TimeoutSeconds 3
                if ($releaseResult.Success) {
                    $test.LocksReleasedCount++
                }

                # Test concurrent access after release
                $concurrentAccessResult = $this.TestConcurrentAccess($lockInfo.FilePath)

                $lockResult = @{
                    FilePath = $lockInfo.FilePath
                    LockType = $lockInfo.LockType
                    InitiallyLocked = $initiallyLocked
                    ReleaseSuccessful = $releaseResult.Success
                    ConcurrentAccessAllowed = $concurrentAccessResult.Success
                    ProperlyReleased = $initiallyLocked -and $releaseResult.Success -and $concurrentAccessResult.Success
                }

                $test.Results += $lockResult

                Write-TestLog -Message "Exclusive lock test: $($lockInfo.FilePath) - Released: $($lockResult.ProperlyReleased)" -Level "INFO" -TestId $this.TestId
            }

            $test.Success = ($test.LocksReleasedCount -eq $test.LocksTestedCount)
            Write-TestLog -Message "Exclusive lock release test: $($test.Success) ($($test.LocksReleasedCount)/$($test.LocksTestedCount) locks released)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $test.Error = $_.Exception.Message
            Write-TestLog -Message "Exclusive lock release test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $test
    }

    [hashtable] TestSharedLockRelease() {
        $test = @{
            Success = $false
            Error = $null
            LocksTestedCount = 0
            LocksReleasedCount = 0
            Results = @()
        }

        try {
            Write-TestLog -Message "Testing shared lock release" -Level "INFO" -TestId $this.TestId

            foreach ($lockInfo in $this.LockScenarios.SharedLocks) {
                $test.LocksTestedCount++

                # Verify lock is active initially
                $initiallyLocked = $this.IsFileLocked($lockInfo.FilePath)

                # Release the lock
                $this.ReleaseFileLock($lockInfo)

                # Verify lock is released
                $releaseResult = Test-FileLockRelease $lockInfo.FilePath -TimeoutSeconds 3
                if ($releaseResult.Success) {
                    $test.LocksReleasedCount++
                }

                # Test write access after release (should be allowed)
                $writeAccessResult = $this.TestWriteAccess($lockInfo.FilePath)

                $lockResult = @{
                    FilePath = $lockInfo.FilePath
                    LockType = $lockInfo.LockType
                    InitiallyLocked = $initiallyLocked
                    ReleaseSuccessful = $releaseResult.Success
                    WriteAccessAllowed = $writeAccessResult.Success
                    ProperlyReleased = $releaseResult.Success -and $writeAccessResult.Success
                }

                $test.Results += $lockResult

                Write-TestLog -Message "Shared lock test: $($lockInfo.FilePath) - Released: $($lockResult.ProperlyReleased)" -Level "INFO" -TestId $this.TestId
            }

            $test.Success = ($test.LocksReleasedCount -eq $test.LocksTestedCount)
            Write-TestLog -Message "Shared lock release test: $($test.Success) ($($test.LocksReleasedCount)/$($test.LocksTestedCount) locks released)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $test.Error = $_.Exception.Message
            Write-TestLog -Message "Shared lock release test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $test
    }

    [hashtable] TestWriteLockRelease() {
        $test = @{
            Success = $false
            Error = $null
            LocksTestedCount = 0
            LocksReleasedCount = 0
            Results = @()
        }

        try {
            Write-TestLog -Message "Testing write lock release" -Level "INFO" -TestId $this.TestId

            foreach ($lockInfo in $this.LockScenarios.WriteLocks) {
                $test.LocksTestedCount++

                # Verify lock is active initially
                $initiallyLocked = $this.IsFileLocked($lockInfo.FilePath)

                # Release the lock
                $this.ReleaseFileLock($lockInfo)

                # Verify lock is released
                $releaseResult = Test-FileLockRelease $lockInfo.FilePath -TimeoutSeconds 3
                if ($releaseResult.Success) {
                    $test.LocksReleasedCount++
                }

                # Test read access after release (should be allowed)
                $readAccessResult = $this.TestReadAccess($lockInfo.FilePath)

                $lockResult = @{
                    FilePath = $lockInfo.FilePath
                    LockType = $lockInfo.LockType
                    InitiallyLocked = $initiallyLocked
                    ReleaseSuccessful = $releaseResult.Success
                    ReadAccessAllowed = $readAccessResult.Success
                    ProperlyReleased = $releaseResult.Success -and $readAccessResult.Success
                }

                $test.Results += $lockResult

                Write-TestLog -Message "Write lock test: $($lockInfo.FilePath) - Released: $($lockResult.ProperlyReleased)" -Level "INFO" -TestId $this.TestId
            }

            $test.Success = ($test.LocksReleasedCount -eq $test.LocksTestedCount)
            Write-TestLog -Message "Write lock release test: $($test.Success) ($($test.LocksReleasedCount)/$($test.LocksTestedCount) locks released)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $test.Error = $_.Exception.Message
            Write-TestLog -Message "Write lock release test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $test
    }

    [hashtable] TestConcurrentLockRelease() {
        $test = @{
            Success = $false
            Error = $null
            ScenariosTested = 0
            ScenariosSuccessful = 0
            Results = @()
        }

        try {
            Write-TestLog -Message "Testing concurrent lock scenarios" -Level "INFO" -TestId $this.TestId

            foreach ($lockInfo in $this.LockScenarios.ConcurrentLocks) {
                $test.ScenariosTested++

                # Test multiple readers scenario
                $concurrentResult = $this.TestMultipleReaders($lockInfo.FilePath)

                # Release the original lock
                $this.ReleaseFileLock($lockInfo)

                # Verify all locks can be acquired after release
                $postReleaseResult = $this.TestPostReleaseConcurrentAccess($lockInfo.FilePath)

                $scenarioResult = @{
                    FilePath = $lockInfo.FilePath
                    ConcurrentReadersSuccess = $concurrentResult.Success
                    PostReleaseAccessSuccess = $postReleaseResult.Success
                    OverallSuccess = $concurrentResult.Success -and $postReleaseResult.Success
                }

                if ($scenarioResult.OverallSuccess) {
                    $test.ScenariosSuccessful++
                }

                $test.Results += $scenarioResult

                Write-TestLog -Message "Concurrent lock test: $($lockInfo.FilePath) - Success: $($scenarioResult.OverallSuccess)" -Level "INFO" -TestId $this.TestId
            }

            $test.Success = ($test.ScenariosSuccessful -eq $test.ScenariosTested)
            Write-TestLog -Message "Concurrent lock release test: $($test.Success) ($($test.ScenariosSuccessful)/$($test.ScenariosTested) scenarios successful)" -Level "INFO" -TestId $this.TestId
        }
        catch {
            $test.Error = $_.Exception.Message
            Write-TestLog -Message "Concurrent lock release test failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $test
    }

    [hashtable] ValidateComprehensiveLockRelease() {
        $validation = @{
            Success = $false
            Error = $null
            Summary = ""
            TotalLocksChecked = 0
            ActiveLocks = @()
            ValidationResults = @{}
        }

        try {
            Write-TestLog -Message "Performing comprehensive lock release validation" -Level "INFO" -TestId $this.TestId

            # Check all managed locks are released
            foreach ($lockInfo in $this.FileLocks) {
                $validation.TotalLocksChecked++

                if ($lockInfo.FileStream) {
                    $validation.ActiveLocks += @{
                        FilePath = $lockInfo.FilePath
                        LockType = $lockInfo.LockType
                        CreatedAt = $lockInfo.CreatedAt
                    }
                }
            }

            # Run system cleanup validation
            $systemValidation = $this.ValidateSystemCleanup()
            $validation.ValidationResults = $systemValidation

            # Test file accessibility for all test files
            $accessibilityResults = $this.TestAllFileAccessibility()
            $validation.ValidationResults.FileAccessibility = $accessibilityResults

            # Determine success
            $noActiveLocks = $validation.ActiveLocks.Count -eq 0
            $systemClean = $systemValidation.LocksClean
            $filesAccessible = $accessibilityResults.AllAccessible

            $validation.Success = $noActiveLocks -and $systemClean -and $filesAccessible

            if ($validation.Success) {
                $validation.Summary = "All locks released and files accessible"
                Write-TestLog -Message "Comprehensive lock validation: PASSED - All locks released" -Level "INFO" -TestId $this.TestId
            } else {
                $issues = @()
                if (-not $noActiveLocks) { $issues += "$($validation.ActiveLocks.Count) active locks remain" }
                if (-not $systemClean) { $issues += "System lock cleanup issues" }
                if (-not $filesAccessible) { $issues += "File accessibility issues" }

                $validation.Summary = "Lock validation failed: $($issues -join ', ')"
                Write-TestLog -Message "Comprehensive lock validation: FAILED - $($validation.Summary)" -Level "ERROR" -TestId $this.TestId

                # Log active locks
                foreach ($activeLock in $validation.ActiveLocks) {
                    Write-TestLog -Message "Active lock: $($activeLock.FilePath) ($($activeLock.LockType))" -Level "WARN" -TestId $this.TestId
                }
            }
        }
        catch {
            $validation.Error = $_.Exception.Message
            $validation.Summary = "Lock validation error: $($_.Exception.Message)"
            Write-TestLog -Message "Comprehensive lock validation failed: $($_.Exception.Message)" -Level "ERROR" -TestId $this.TestId
        }

        return $validation
    }

    # Helper methods for lock testing
    [bool] IsFileLocked([string] $filePath) {
        try {
            $testStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $testStream.Close()
            $testStream.Dispose()
            return $false
        } catch {
            return $true
        }
    }

    [hashtable] TestConcurrentAccess([string] $filePath) {
        try {
            $stream1 = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $stream2 = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $stream1.Close()
            $stream2.Close()
            $stream1.Dispose()
            $stream2.Dispose()
            return @{ Success = $true }
        } catch {
            return @{ Success = $false; Error = $_.Exception.Message }
        }
    }

    [hashtable] TestWriteAccess([string] $filePath) {
        try {
            $stream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $stream.Close()
            $stream.Dispose()
            return @{ Success = $true }
        } catch {
            return @{ Success = $false; Error = $_.Exception.Message }
        }
    }

    [hashtable] TestReadAccess([string] $filePath) {
        try {
            $content = Get-Content -Path $filePath -ErrorAction Stop
            return @{ Success = $true }
        } catch {
            return @{ Success = $false; Error = $_.Exception.Message }
        }
    }

    [hashtable] TestMultipleReaders([string] $filePath) {
        try {
            # Open multiple read streams
            $streams = @()
            for ($i = 0; $i -lt 3; $i++) {
                $stream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                $streams += $stream
            }

            # Close all streams
            foreach ($stream in $streams) {
                $stream.Close()
                $stream.Dispose()
            }

            return @{ Success = $true }
        } catch {
            return @{ Success = $false; Error = $_.Exception.Message }
        }
    }

    [hashtable] TestPostReleaseConcurrentAccess([string] $filePath) {
        try {
            # Test that exclusive access is now possible
            $exclusiveStream = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $exclusiveStream.Close()
            $exclusiveStream.Dispose()
            return @{ Success = $true }
        } catch {
            return @{ Success = $false; Error = $_.Exception.Message }
        }
    }

    [hashtable] TestAllFileAccessibility() {
        $accessibility = @{
            AllAccessible = $true
            Results = @()
            TotalFiles = 0
            AccessibleFiles = 0
        }

        try {
            # Test all lock scenario files
            $allFiles = @()
            $allFiles += $this.LockScenarios.ExclusiveLocks | ForEach-Object { $_.FilePath }
            $allFiles += $this.LockScenarios.SharedLocks | ForEach-Object { $_.FilePath }
            $allFiles += $this.LockScenarios.WriteLocks | ForEach-Object { $_.FilePath }
            $allFiles += $this.LockScenarios.ConcurrentLocks | ForEach-Object { $_.FilePath }

            foreach ($filePath in $allFiles) {
                $accessibility.TotalFiles++
                $accessResult = $this.TestReadAccess($filePath)

                $fileResult = @{
                    FilePath = $filePath
                    Accessible = $accessResult.Success
                }

                if ($accessResult.Success) {
                    $accessibility.AccessibleFiles++
                } else {
                    $accessibility.AllAccessible = $false
                }

                $accessibility.Results += $fileResult
            }
        }
        catch {
            $accessibility.AllAccessible = $false
        }

        return $accessibility
    }
}

# Factory function for creating CV-002 test
function New-LockReleaseValidationTest {
    return [LockReleaseValidationTest]::new()
}

Write-TestLog -Message "CV-002 Lock Release Validation Test loaded successfully" -Level "INFO" -TestId "CV-002"